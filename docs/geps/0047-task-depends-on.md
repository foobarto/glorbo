---
gep: 0047
title: "`depends_on:` for tasks — explicit blocking dependencies"
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-05-07
history:
  - date: 2026-05-07
    status: Draft
    note: Initial draft. Decisions D1-D9 settled in Phase 1+2 Q&A; remaining design choices deferred to operator per Phase-2 hand-off.
  - date: 2026-05-07
    status: Accepted
    note: Operator approved the design; ready to ship.
  - date: 2026-05-07
    status: Implemented
    note: v1 ships D1, D2, D3, D5 (TaskScheduler integration), D7 partial (`task.blocked_on_deps`, `task.cycle_detected`, `task.blocked_on_failed_dep` as v1 stand-in for `task.failure_propagated`), D8. v2 work — D4 propagation walker, D6 Router enforcement, D9 SQLite index — listed under §Implementation status.
requires: [2, 13, 24]
see-also: [7, 16, 19, 40, 41, 43, 46]
---

# GEP-47: `depends_on:` for tasks — explicit blocking dependencies

## Problem

Glorbo's task model is flat. `task/v1` files carry `status:` plus
ordering hints (`schedule:`, `priority:`, `done_when:`,
`handoff_chain:`), but there is no first-class field that says
*"this task must not start until task X is finished."* Director and
scheduler both read tasks independently; if work needs ordering, it
is encoded implicitly — by the agent leaving an inbox message for the
next agent (out of band), or by the human keeping later tasks at
`status: todo` and manually flipping them only after upstream work is
verified done.

Three concrete failure modes follow from this:

1. **The scheduler does not wait.** If a `schedule: hourly` task
   depends on a one-shot setup task that has not finished, the
   scheduler still fires on the hour. The agent picks up the
   scheduled task, half-runs against missing prerequisites, and
   leaves a wake-on-failure trail.
2. **The dashboard cannot show a chain.** `GlorboWeb.TaskChainLive`
   (GEP-40) renders `handoff_chain:` but `handoff_chain` records *who
   carried the task* — not *what other tasks must finish first*.
3. **Failure does not propagate.** A task whose prerequisite is
   denied or cancelled has no signal that the work is now moot. It
   sits at `todo` indefinitely, eats the next scheduler tick, and the
   agent has to re-derive *"the upstream got killed"* from context
   the agent cannot see.

The localforge comparison in `docs/research/2026-05-07-glorbo-vs-
localforge.md` surfaced this as bridge task #1 (split out from the
broader kanban + priority-queue work — those land in a follow-up
GEP). `depends_on` is the smallest, most-asked-for primitive of the
three and is genuinely independent of the kanban presentation layer:
it changes scheduling correctness, not the dashboard's render path.

## Goals

- Add an optional `depends_on: [<task_id>, ...]` field to `task/v1`
  frontmatter. When present and non-empty, the task is not dispatched
  until every listed task has reached a *done-terminal* state.
- Allow dependencies to reference any task in the same company,
  across projects. Cross-company dependencies remain structurally
  forbidden (GEP-2 D7).
- Propagate failure: when a referenced task reaches a *failure-
  terminal* state, the dependent is auto-cancelled with a recorded
  reason — recursively, so failure walks the chain.
- Detect cycles at parse/reindex time. A cyclic graph produces a
  validator finding and the scheduler refuses to evaluate the
  involved tasks (preventing dispatch loops and infinite dep walks).
- Make the rule visible: new audit events (`task.blocked_on_deps`,
  `task.unblocked`, `task.failure_propagated`, `task.cycle_detected`)
  surface dep-driven scheduling decisions in the same JSONL the
  dashboard already reads.

## Non-goals

- **Numeric priority queue or kanban view.** `priority:` stays the
  existing four-level enum. Reordering, "ready-tasks" pull semantics,
  and the kanban LiveView land in a follow-up GEP.
- **Acceptance gate.** Automated post-dispatch test verification is
  out of scope. `done` remains *agent-attested*; whether `done_when:`
  is actually satisfied is the agent's responsibility.
- **Cross-company dependencies.** Forbidden by GEP-2 D7's company-
  isolation invariant; this GEP just doesn't add an exception.
- **Mutation tooling.** No CLI verb is added to remove a dep
  in-place. `depends_on` is append-only after first write
  (see D6); operators who need to *remove* a dep must edit the file
  by hand and accept the audit (Router rejects rewinds).
- **Approval-expiry / timeout.** A task blocked behind a
  `pending-approval` dep waits indefinitely. Defining a TTL is
  GEP-19's open question, not GEP-47's.

## Design

### File-format change

`task/v1` (`lib/glorbo/file_spec/task_md.ex`) gains two optional
fields:

| Field | Shape | Notes |
|---|---|---|
| `depends_on` | `[String.t()]` (list of `task_id` strings) | Optional. Each entry is a bare `task_id` like `"release-01"`. GEP-13 guarantees `task_id` is unique within a company. Empty list = no deps. |
| `cancelled_reason` | `String.t()` | Optional, set by the failure-propagation walker (or by an operator-initiated cancel) when `status: cancelled`. Free text, ≤ 1024 bytes. |

`status:` enum gains `"cancelled"`. Definition:

> The task did not complete and will not run. Distinct from `denied`
> (which has GEP-19 director-approval semantics): `cancelled` covers
> non-approval terminal failure — failure-propagation from an
> upstream dep, manual cancel, retry-exhaustion sentinels, etc.

No new on-disk *`blocked`* status. Whether a task is currently
blocked is a derived view computed by walking `depends_on` against
the live tree.

### Reference shape (D1)

`depends_on` entries are bare `task_id` strings, not full
`task_path`. GEP-13 D1 makes `<project-slug>-NN.md` task IDs unique
within a company, so a single string resolves unambiguously across
projects without a path prefix.

The known fragility — `task_id` can be reused after deletion — is
addressed by:

1. The validator emits a `task.dependency_missing` finding when a
   `depends_on` entry resolves to no live task and no history task.
2. The scheduler treats a missing target as failure-terminal — the
   dependent is auto-cancelled with `cancelled_reason: "depends_on
   target <task_id> not found"`, surfacing the issue immediately
   rather than letting a silent reuse go unnoticed.

### Terminal-state classification (D3)

The scheduler categorises every referenced task into one of three
buckets:

| Bucket | Meaning | Status condition |
|---|---|---|
| **Done-terminal** | Unblocks dependents | `status == "done"` AND (`peer_review_required` ≠ `true` OR `peer_review_verdict == "approve"`) |
| **Failure-terminal** | Propagates failure to dependents | `status ∈ {"denied", "cancelled"}` OR (`peer_review_required` AND `peer_review_verdict == "block"`) OR `task_id` resolves to no file |
| **Non-terminal** | Dependents stay blocked, no propagation | Everything else (including `done` with peer-review pending or verdict `revise`) |

The peer-review interaction is load-bearing: without it, a dependent
could start work on the back of upstream code that GEP-41 later flips
to `revise` or `block`. With it, dependents wait for the full chain.

### Failure propagation (D4) — auto-cancel

When the scheduler observes a failure-terminal target for a
dependent, the dependent is rewritten:

```yaml
status: cancelled
cancelled_reason: "dependency <upstream_task_id> failed (<status>)"
```

… and an audit event `task.failure_propagated` is appended. The walk
is recursive: if A is cancelled, every task that names A in its
`depends_on` is also cancelled, with `cancelled_reason: "dependency
A cancelled (failure-propagation from <root>)"`.

The walk runs as part of the scheduler's 60s rescan (GEP-24 D6), so
propagation is eventually consistent — newly failed tasks cancel
their fan-out within one rescan tick, no faster.

Propagation is *automatic, not interactive*. Sentinel-escalating
each propagation would flood the director's queue on big chains;
auto-cancelling with an audit trail keeps the operator informed
without forcing intervention. Operators who want intervention-
required behaviour can set `peer_review_required: true` upstream so
the chain holds at the peer-review gate instead of propagating.

### Gate placement (D5) — shared `DependencyGate` helper

Two write paths today produce inbox events that drive dispatch:

1. `Glorbo.Company.TaskScheduler.fire/2` — scheduled-task
   dispatches.
2. The Director-wake path (Router writes `wake-request.md` /
   inbox-message) — operator-initiated dispatches.

Both must consult the same dependency-readiness check; otherwise a
manual wake bypasses the gate the scheduler just respected.

A new module `Glorbo.Task.DependencyGate` exposes:

```elixir
@spec ready?(Task.Definition.t(), Glorbo.Company.t()) ::
        :ok
        | {:blocked, [unmet :: String.t()]}
        | {:propagate_failure, root :: String.t(), reason :: String.t()}
```

`ready?/2` reads the company's task index (live + history) and
returns one of:

- `:ok` — every dep is done-terminal; dispatch may proceed.
- `{:blocked, unmet}` — one or more deps are non-terminal; emit
  `task.blocked_on_deps` (deduped per `(task, unmet-set)` with TTL)
  and skip.
- `{:propagate_failure, root, reason}` — at least one dep is
  failure-terminal; the caller writes
  `status: cancelled` + `cancelled_reason` to the dependent and
  emits `task.failure_propagated`.

Both write paths call `DependencyGate.ready?/2` before writing the
inbox event. A single helper means the scheduler and the Router
cannot drift from each other; cycle-detection state and the readied/
unblocked transitions live in one place.

### Mutability (D6) — append-only, Router-enforced

`depends_on` follows the GEP-40 D2 pattern for `handoff_chain`:
**append-only.** A new `depends_on` list submitted via the Router
must contain the existing list as a prefix. Removing or reordering
entries is rejected with `:depends_on_rewound` and a corresponding
audit denial.

Why append-only and not immutable-after-creation:

- Adding a dep is *strictly more conservative* — it can only further
  block the task. Operators who realise mid-flight that a task needs
  to wait for additional work should be able to add a dep without
  recreating the file.
- Removing a dep silently makes a previously-blocked task suddenly
  dispatchable. That's a hidden side effect with no audit trail; the
  Router refuses it.
- The (rare) genuine need to remove a dep is satisfied by editing
  the file by hand outside the Router (which lands an audit entry
  via the FilesystemWatcher) and accepting the rewind warning. This
  intentionally adds friction.

### Cycle detection (D8) — DFS at parse/reindex

Each `glorbo reindex` and each FilesystemWatcher event that touches
a task file triggers a depth-first search across the company's task
graph using three-colour marking. Detected cycles produce:

- A validator finding `task.cycle_detected` per cycle.
- A `task.cycle_detected` audit event with the cycle path.
- A skip in `DependencyGate.ready?/2` for any task that participates
  in a cycle (`{:blocked, [<cycle members>]}`); this prevents an
  infinite dep walk and keeps the scheduler responsive.

Cycle errors do not crash anything — log finding, skip, move on.
Operator can resolve by editing the file (which runs through the
append-only Router and will fail with `:depends_on_rewound`, forcing
an out-of-band manual edit + audit acknowledgement).

### Audit events (D7)

Four new event kinds:

| Event | Fields | When |
|---|---|---|
| `task.blocked_on_deps` | `task`, `unmet: [task_id, ...]` | Scheduler/Router skipped dispatch because deps are non-terminal. Deduped per `(task, unmet-set)` with 60s TTL to avoid log floods on heartbeating tasks. |
| `task.unblocked` | `task`, `resolved_by: <last_dep>` | The last unmet dep reached done-terminal; next scheduler/wake will dispatch. Emitted exactly once per blocked → ready transition. |
| `task.failure_propagated` | `task`, `cancelled: <task>`, `chain: [...]`, `root: <task_id>` | A dependent was auto-cancelled because an upstream dep failed. Walk emits one event per dependent cancelled. |
| `task.cycle_detected` | `cycle: [task_id, task_id, ...]` | Validator/reindex/watcher found a cycle. One event per detected cycle per scan. |

### SQLite derivation (D9)

A new derived table stores edges:

```sql
CREATE TABLE task_dependencies (
  company TEXT NOT NULL,
  task_path TEXT NOT NULL,
  depends_on_task_id TEXT NOT NULL,
  PRIMARY KEY (company, task_path, depends_on_task_id)
);
```

Repopulated from on-disk `depends_on` during `glorbo reindex` per
GEP-7 D6 (every column derivable from disk). No FK constraint —
`depends_on_task_id` may legitimately resolve to a history-moved or
missing task; the validator handles those cases.

Two derived views power the dashboard:

- `Tasks blocking this one` — `SELECT depends_on_task_id FROM
  task_dependencies WHERE company=? AND task_path=?`
- `Tasks blocked on this one` — `SELECT task_path FROM
  task_dependencies WHERE company=? AND depends_on_task_id=?`

When GEP-43 (ETS-first derived state) lands, this table moves to an
ETS table with the same shape. Migration is mechanical.

## Migration / rollout

The change is **purely additive on disk** — existing tasks without
`depends_on` continue to dispatch exactly as today. No file
migration is required. `glorbo reindex` repopulates the new
`task_dependencies` table from existing files (which all yield
empty dep lists initially).

Status enum migration: every existing task is in
`{todo, in-progress, pending, pending-approval, approved, denied,
done}`. Adding `cancelled` to the enum does not invalidate any
existing file. The validator's enum check is forward-compatible.

CLI surface adds nothing in this GEP. A future bridge GEP may add
`glorbo task cancel <task_id> [--reason "..."]` for ergonomic
manual cancellation; for v1, operators write `status: cancelled` +
`cancelled_reason:` directly via their editor (which the Router /
FilesystemWatcher audit identically).

## Failure modes

| Mode | Surface |
|---|---|
| Reused `task_id` after deletion | Validator finding (`task.dependency_missing`) at parse/reindex; failure-propagation auto-cancels the dependent on next scheduler tick. |
| Cycle (A → B → A or longer) | `task.cycle_detected` audit + finding. Scheduler skips all involved tasks. Operator must edit out-of-band. |
| Append-only Router rejection | `:depends_on_rewound` denial. Operator who genuinely needs to remove a dep edits the file directly (FilesystemWatcher path). |
| Missing target (no live, no history) | Same as reused-after-deletion: validator finding + auto-cancel via failure-propagation. |
| Pending-approval upstream stuck forever | Inherits GEP-19's open approval-expiry question; the dependent stays blocked. Audit event surfaces the situation. |
| Deeply chained failure-propagation amplification | Bounded by the company's task count; one audit event per cancelled dependent, deduped per scheduler tick. No tail recursion / no risk of stack blow-up — uses iterative BFS. |

## Test strategy

Unit:
- `Glorbo.FileSpec.TaskMd` accepts/rejects `depends_on` shapes
  (string list, nil, non-list).
- `Glorbo.Task.DependencyGate.ready?/2` returns `:ok` /
  `{:blocked, _}` / `{:propagate_failure, _, _}` for every cell of
  the terminal-state matrix (D3).
- Cycle-detection DFS catches direct (A→A), short (A→B→A), and long
  (A→B→C→D→A) cycles.
- Append-only Router enforcement: prefix-match accepted, reorder
  rejected, removal rejected.

Integration:
- `Glorbo.Company.TaskScheduler` skips a fire when deps unmet, fires
  on the next tick after the last dep flips to done.
- Failure-propagation walker cascades through a 4-level chain in a
  single rescan tick, emits the right number of audit events, and is
  idempotent (a second rescan tick produces no new events).
- Reindex of an existing fixture company populates
  `task_dependencies` correctly.

Property:
- For any randomly generated DAG of N≤20 tasks, the dependency walk
  terminates and emits exactly the right set of unblock / propagate
  events.

## Open questions

- **Project-rename cascade.** Inherited from GEP-13. Renaming a
  project breaks every `depends_on` referencing its tasks. A future
  GEP may add `glorbo migrate project --rename <old> <new>` which
  rewrites both task IDs and `depends_on` entries atomically.
- **Approval-expiry.** Inherited from GEP-19. A dep stuck at
  `pending-approval` blocks dependents forever. Whether to add a
  TTL → auto-deny lives in GEP-19's open work, not here.
- **Should the scheduler route through `Router.route/2`?** GEP-24's
  open question. Until resolved, GEP-47 patches both bypass paths
  via the shared `DependencyGate` helper. If the bypass is closed
  later, the helper call moves into the Router and both paths
  collapse to one.
- **ETS migration boundary.** GEP-43 is Placeholder; GEP-47 builds
  on SQLite for now. When GEP-43 ships, `task_dependencies` is one
  of the simplest tables to migrate (PK is composite, no FK,
  no joins).

## Implementation status

GEP-47 lands in two waves. v1 (this commit) covers the load-bearing
behaviour change — **the scheduler respects `depends_on`** — plus
cycle detection. v2 covers the surrounding niceties (file-rewrite
propagation, Router enforcement, SQLite index).

### Shipped in v1 (2026-05-07)

| Decision | Where |
|---|---|
| **D1** — bare `task_id` references | `Glorbo.FileSpec.TaskMd` schema; `Glorbo.TaskDefinition` parser; `coerce_depends_on/1` |
| **D2** — `cancelled` enum value, `cancelled_reason:` optional field | `Glorbo.FileSpec.TaskMd` |
| **D3** — terminal-state classification (done-terminal / failure-terminal / non-terminal) | `Glorbo.Task.DependencyGate.classify_dep/2` |
| **D5** — shared `DependencyGate` helper | new module `Glorbo.Task.DependencyGate`; called from `Glorbo.Company.TaskScheduler.maybe_fire/4` |
| **D7 partial** — three of the four audit events (`task.blocked_on_deps`, `task.cycle_detected`, `task.blocked_on_failed_dep`) | `Glorbo.Company.TaskScheduler` |
| **D8** — cycle detection via three-colour DFS; deduped per-rescan | `Glorbo.Task.DependencyGate.cycle_detect/1`; called from the 60s rescan |

### Shipped in v2 (2026-05-21)

- **F10 `auto_dispatch` path now gated.** Tracing the dispatch surface
  for the "non-scheduler paths bypass the gate" item found that the
  most reachable bypass was not the Director-wake path but the F10
  `auto_dispatch` flow: an agent filing a task with `auto_dispatch: true`
  + a valid `assigned_to` + an unmet `depends_on` was dispatched
  immediately, ignoring the gate the scheduler enforces.
  `Glorbo.Company.Router.maybe_auto_dispatch/5` now consults
  `DependencyGate.ready?/2` and emits `task.blocked_on_deps` /
  `task.blocked_on_failed_dep` instead of writing the inbox event when
  the deps are unmet — same classification + audit actions as the
  scheduler.
- **Shared `Glorbo.Task.Snapshot`.** The on-disk snapshot builder was
  extracted from `TaskScheduler.build_task_snapshot/1` into
  `Glorbo.Task.Snapshot.build/2` so the scheduler and the Router share
  one snapshot shape (`DependencyGate` stays a pure rule module).

### Queued for v2 (follow-up commit, same GEP)

| Decision | Why deferred |
|---|---|
| **D4** — failure-propagation walker that rewrites `status: cancelled` into dependent task files | Needs a dedicated `Glorbo.Task.StatusRewriter` for safe in-place YAML edits (atomic write, frontmatter-only-region edit). v1 substitute: `task.blocked_on_failed_dep` audit makes the situation visible so operators can intervene. |
| **D6** — Router append-only enforcement of `depends_on` (mirroring `handoff_chain` per GEP-40 D2) | **Largely moot in practice:** agents cannot rewrite an existing task file at all — `handle_outbox_task`'s `refuse_if_exists` rejects the write and `projects/` is ro-mounted in the sandbox. The only `depends_on` writers are Director-side Actions (trusted). Keep as defence-in-depth for the Director write path if/when a remove-deps edit becomes possible; not a current correctness gap. |
| **D7 remaining** — `task.failure_propagated` (depends on D4) and `task.unblocked` (depends on cross-rescan diff state) | Coupled with D4; the data plumbing for "this dep just settled" needs a state-diff between consecutive rescans, which v1's per-fire snapshot doesn't carry. |
| **D9** — `task_dependencies` SQLite edge table + reindex hook | The on-demand snapshot in `Glorbo.Task.Snapshot.build/2` works for typical task counts; a dedicated index is a perf optimisation, not a correctness gap. Lands when reindex is next touched. |
| **Remaining ungated dispatch path** — the Kanban "assigned_to changed" notification (`KanbanLive.maybe_notify_assignee`) writes an inbox event for the assignee without consulting the gate. Centralising every dispatch-initiation behind one `DependencyGate` chokepoint is the **open design fork** (GEP-16/GEP-24: the scheduler bypasses the Router, so there is no single chokepoint today). Resolve where the shared gate lives before wiring the last path. |

The gate is the load-bearing piece; remaining v2 items are durability, ergonomics, perf, and the dispatch-chokepoint design decision around the established correctness contract.

## Decision log

### D1. Reference shape — bare `task_id`

- **Decided:** `depends_on` entries are bare `task_id` strings
  (`["release-01", "blog-2"]`).
- **Alternatives:**
  - Project-scoped shorthand (`["release/release-01", ...]`) —
    redundant for same-project case (since `<proj>/<proj>-NN`
    repeats the slug), same delete-recreate fragility.
  - Full `task_path` (`projects/release/tasks/release-01.md`) —
    most explicit, ugliest in YAML, same delete-recreate fragility
    because `task_path` is just the filename.
- **Why:** GEP-13's namespacing already makes `task_id` unique
  within a company. The delete-recreate fragility is the same in
  all three shapes; paying YAML cost for a longer form buys
  nothing real. The validator + auto-cancel-on-missing combo
  surfaces the rare reuse case loudly.

### D2. Status enum — add `cancelled`, no on-disk `blocked`

- **Decided:** Status enum gains `"cancelled"` plus a
  `cancelled_reason:` optional field. No `"blocked"` enum value;
  blocked-state is computed at read time from `depends_on`.
- **Alternatives:**
  - Add both `cancelled` and `blocked`. — `blocked` would be
    derivable state written to disk; that duplicates the source of
    truth and complicates back-transitions when deps complete.
  - Reuse `denied` for non-approval terminal failure with
    `denial_reason: dependency-failed`. — `denied` has GEP-19
    director-approval semantics (assigned-to swap, history move);
    overloading it is muddy.
- **Why:** Filesystem-as-truth (GEP-3) prefers derivable states
  computed once at read time over states stored in two places.
  `cancelled` distinct from `denied` keeps GEP-19's approval
  semantics intact while giving failure-propagation a clean
  terminal target.

### D3. Terminal-state classification — three buckets, peer-review-aware

- **Decided:** `done` unblocks dependents only when peer-review is
  not pending; `denied` and `cancelled` propagate failure;
  peer-review verdicts `revise` (non-terminal) and `block`
  (failure-terminal) integrate cleanly. Full table in §Design.
- **Alternatives:**
  - `status == "done"` is enough, ignore peer-review. — Allows
    dependents to start on the back of upstream code that
    peer-review later flips to `revise`/`block`; the dependent's
    work becomes invalid silently.
  - Require an explicit `done_when_met:` boolean attestation. —
    No current attestation mechanism; GEP-40 D4 deliberately keeps
    `done_when:` free-form.
- **Why:** Honouring peer-review costs latency for some chains but
  prevents *built-on-revoked-work* failures, which are far more
  expensive to clean up than the wait.

### D4. Failure propagation — auto-cancel, recursive, audit-traced

- **Decided:** When a dep is failure-terminal, the dependent's
  `status:` is rewritten to `cancelled` with
  `cancelled_reason:` and a `task.failure_propagated` audit event.
  Walk recurses through fan-out.
- **Alternatives:**
  - Sentinel-escalate to director per propagation. — Floods
    director's action queue on long chains; one root failure
    becomes N director-actions for no incremental information.
  - Mark dependent `failed-by-dependency` (a fourth terminal). —
    Adds a state without changing semantics; `cancelled` already
    covers it.
  - Block the dependent indefinitely (no propagation). — Quietly
    accumulates abandoned tasks; the operator only learns about
    the problem when they manually inspect.
- **Why:** Auto-cancel is reversible (operator re-creates the task
  or updates the upstream); audit trail keeps operator informed;
  no flood; no abandoned tasks. Sentinel mode is still available
  via `peer_review_required: true` on the upstream task.

### D5. Gate placement — shared `DependencyGate` helper

- **Decided:** `Glorbo.Task.DependencyGate.ready?/2` is the single
  point of truth; both `TaskScheduler.fire/2` and the
  Director-wake path call it before writing the inbox event.
- **Alternatives:**
  - Patch each write path in-place. — Two implementations drift;
    a manual wake bypasses the scheduled-dispatch gate.
  - Put the check inside `Agent.Server` after the wake arrives. —
    Inbox events are already written by then; spurious "blocked"
    events surface in the audit log on every heartbeat.
  - Push the check into `Router.route/2` only. — System-initiated
    writes (scheduler, wake) bypass the Router today (open
    question in GEP-16/GEP-24); a Router-only gate would miss them.
- **Why:** One helper module makes the contract explicit, keeps
  the cycle-detection state in one place, and is trivial to move
  into the Router if the bypass-vs-Router question resolves later.

### D6. `depends_on` mutability — append-only via Router

- **Decided:** New `depends_on` list submitted via the Router must
  contain the existing list as a prefix. Reorder/remove rejected
  with `:depends_on_rewound` and an audit denial.
- **Alternatives:**
  - Fully immutable after creation. — Can't add a forgotten dep
    without recreating the task.
  - Free-form mutable. — Removing a dep silently unblocks; no
    audit trail; surprising side effects.
  - Stack-style push/pop. — Loses information; same problem as
    the rejected `handoff_chain`-as-stack alternative in GEP-40 D2.
- **Why:** Mirrors GEP-40 D2 (`handoff_chain` append-only) for
  consistency. Adding deps is conservative (only more blocking);
  removal genuinely needs friction so an operator who wants it
  has to acknowledge the audit.

### D7. Audit event vocabulary — four new kinds

- **Decided:** `task.blocked_on_deps`, `task.unblocked`,
  `task.failure_propagated`, `task.cycle_detected`. Field shapes
  in §Design.
- **Alternatives:**
  - Reuse `task.scheduler_skipped` with a sub-kind. — Sub-kinds
    in audit events confuse the dashboard's filter UI; one event
    per situation is simpler.
  - Skip audit events entirely (rely on file mtimes). — Hides
    propagation from the audit trail; dashboard cannot show
    "task X cancelled because Y failed."
- **Why:** Each event answers a different operator question;
  separate kinds keep the audit shape grep-friendly. Dedup on
  `task.blocked_on_deps` prevents flooding on heartbeats; the
  other three are naturally one-per-occurrence.

### D8. Cycle detection — DFS at parse / reindex / file-change

- **Decided:** Three-colour DFS on the company's task graph,
  triggered by `glorbo reindex`, FilesystemWatcher task changes,
  and (lazily, in the rare case state is stale) `DependencyGate.
  ready?/2` itself. Cycles produce a finding + audit event;
  involved tasks are returned as `{:blocked, [...]}` so the
  scheduler doesn't infinite-loop.
- **Alternatives:**
  - Reject cycle-introducing writes at the Router. — Misses
    out-of-band edits; FilesystemWatcher catches everything.
  - Eager rebuild on every dispatch. — Wasted work; companies
    rarely have task graphs that change between dispatches.
- **Why:** Reindex + watcher + lazy double-check covers every
  way a cycle can land in the on-disk state. DFS is O(V+E); for
  realistic V ≤ a few hundred, well under a millisecond.

### D9. SQLite derivation — separate `task_dependencies` edge table

- **Decided:** New table `task_dependencies(company, task_path,
  depends_on_task_id)`, repopulated by `glorbo reindex`. No FK
  constraint.
- **Alternatives:**
  - JSON-array column on `tasks`. — Awkward to query for
    "what's blocked on me?" (reverse direction).
  - Two parallel columns (`depends_on_csv`, `depended_on_by_csv`)
    on the tasks table. — Denormalised; reindex must rebuild both
    coherently; JSON-array still simpler.
- **Why:** Edge tables are cheap in SQLite; both
  forward and reverse queries are simple `WHERE` clauses; the
  shape transfers directly to ETS when GEP-43 lands.

## Related

- **GEP-2** — architecture invariants (company isolation,
  filesystem-as-truth, single-host).
- **GEP-7** — SQLite as derived state; `task_dependencies` table
  must be reindex-rebuildable.
- **GEP-13** — task IDs are `<project-slug>-NN`, unique within
  company. Underwrites D1.
- **GEP-16** — agent wake/dispatch pipeline. The dep gate sits
  upstream of the inbox-write step that triggers the pipeline.
- **GEP-19** — director approval workflow. `denied` semantics +
  history-move are inherited; the dep walker treats `denied` as
  failure-terminal and reads from both live + history paths.
- **GEP-24** — task scheduler. The 60s rescan loop is what makes
  `task.unblocked` propagation eventually consistent.
- **GEP-40** — task chain observability. `handoff_chain:` is
  *who carried the task*; `depends_on:` is *what must finish
  first*. Append-only mutability pattern (D2) is mirrored here in
  D6.
- **GEP-41** — peer-review gate. Verdicts `revise` and `block`
  participate in the terminal-state classification (D3).
- **GEP-43** — ETS-first derived state (Placeholder). The eventual
  migration target for `task_dependencies`.
- **GEP-46** — concurrency caps. Multiple agents dispatching in
  parallel inside one company means the dep gate must be the
  serialisation point — `DependencyGate.ready?/2` is called per
  dispatch attempt, not once per scheduler tick.
- `docs/research/2026-05-07-glorbo-vs-localforge.md` — bridge
  task #1 (this GEP), with the broader kanban + priority-queue
  bridges queued as follow-up GEPs.

## Implementation reconciliation (2026-06-14)

This is an append-only record (GEP-1: an Accepted/Implemented GEP's body is not rewritten; deviations are recorded here rather than by editing the sections above).

- **`task.dependency_missing` validator finding — known-gap (with a runtime substitute already shipped).** The GEP promises this finding in three places: §Reference shape (D1, lines 129-134), the Failure-modes table (lines 316/319), and the `DependencyGate` moduledoc (`lib/glorbo/task/dependency_gate.ex:36`, repeated at `:112`). The finding is **not implemented**: `grep` for `dependency_missing` across `lib/` and `test/` returns only those two descriptive moduledoc/comment lines — it is never emitted as an audit action or a validator finding (the full set of emitted `task.*` actions includes `task.blocked_on_deps`, `task.blocked_on_failed_dep`, and `task.cycle_detected`, but no `task.dependency_missing`). `Glorbo.FileSpec.Validator` (`lib/glorbo/file_spec/validator.ex`) is a per-file schema validator that walks paths and checks each file against its spec module; it has no company-graph-aware pass that resolves every `depends_on` entry against the live+history task set, which is exactly what this finding would require. What the code *does* deliver is the runtime half of D1's two-part promise: `DependencyGate.classify_dep/2` (`lib/glorbo/task/dependency_gate.ex:110-113`) treats a missing target as failure-terminal (`{:failure_terminal, "depends_on target <id> not found"}`), so the scheduler/Router auto-cancels the dependent on the next tick. Only the parse/reindex-time *validator finding* is absent. Disposition: **known-gap** — record the validator finding as not-yet-shipped; the missing-target case is surfaced at scheduling time but not at parse/reindex time as the GEP body advertises. (This is consistent with §Implementation status, lines 369-415, which never lists a `task.dependency_missing` validator among the shipped items but also never explicitly disclaims the three D1/Failure-mode/moduledoc promises.)
  - **RESOLVED (2026-06-14).** Implemented the parse-time finding. `Glorbo.FileSpec.Validator`'s `TaskMd` per-kind check now resolves every `depends_on` entry against the on-disk task set — a live task (`projects/*/tasks/<id>.md`) or an archived one (`projects/*/history/tasks/<id>.md`), searched across all of the company's projects (the `task_id` is company-unique per GEP-13, so the project is not encoded in the id). An entry that resolves to neither emits an `error`-severity `:task_dependency_missing` finding (`glorbo validate` exits non-zero). The id is matched against the GEP-13 task-id charset before any filesystem lookup, so a malformed/`..`-bearing entry is reported as unresolved rather than escaping the company tree. So D1's parse/reindex-time promise now holds alongside the already-shipped `DependencyGate` runtime half. Six regression tests in `Glorbo.FileSpec.ValidatorTest` (dangling, live same-project, cross-project, archived/history, path-escape, no-deps).
