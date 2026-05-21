---
gep: 0036
title: Actions layer as the single Director-write channel
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Opencode round-2 flagged `KanbanLive`, `AgentLive`, and
      `TaskLive` bypassing the `GlorboWeb.Actions` layer (GEP-6 D6
      explicitly forbids this — "Actions is the enforcement point
      for permissions + audit and must not be bypassed"). They
      mutate filesystem state via `File.mkdir_p!`, `File.write!`,
      `File.rename` directly. That means two surfaces — LV + MCP —
      can produce divergent on-disk shapes, audit gaps, and
      permission bypasses.
  - date: 2026-04-24
    status: Placeholder
    note: |
      Scope expanded: GEP-38 (frontend adapter contracts) marked
      Superseded-by-this-GEP per user directive
      ("GEP-36/38 confusing, let's do the Glorbo.Actions and
      route everything through it properly"). GEP-36 now covers
      both the concrete atomic `Glorbo.Actions` carve-out AND
      the principle that every frontend (web LV, MCP, shell,
      future frontends) routes through it. The principle was
      previously reserved in GEP-38's sketch.

      Shape-level decisions settled pending Draft promotion:
      - `Glorbo.Actions` is **pure module + functions**, not a
        GenServer. Rationale per maintainer 2026-04-24: no
        current use case where concurrent shell/web/MCP writes
        would race on state needing Actions as a gatekeeper;
        filesystem atomic-rename + append-only audit handle
        concurrency correctly at the OS level. Revisit if such
        a use case materialises — a GenServer can wrap the pure
        module later without rewriting callers.
      - Absorbs GEP-38's principle: every Director-facing
        capability exposed through `Glorbo.Actions`; frontends
        are thin adapters; no parallel write paths.
      - Extracts every mutation that today lives inline in
        LiveView handlers (create_task, move_task, trash_task,
        dispatch_task, create_project, create_agent) — GEP-37's
        same carve-out list.
  - date: 2026-04-24
    status: Draft
    note: |
      Promoted to Draft with full body (Goals, Non-goals, Design,
      Migration, Failure modes, Test strategy, Decision log).
      Part of the crown-jewels phase-1 bundle (36 + 40 + 41);
      this GEP is the write-seam foundation that GEP-40/41 build
      on. Targeted for v0.8.0 alongside the observability +
      peer-review work.
  - date: 2026-04-24
    status: Accepted
    note: |
      Accepted as part of the crown-jewels phase-1 bundle (with
      GEP-40 + GEP-41) after maintainer sign-off on D1 (pure
      module + functions), D2 (lives in core, not glorbo_web),
      D3-D7 (resource-organised submodules, delegation facade
      with scheduled removal, Credo-blocks-CI enforcement,
      mandatory :actor opt). Implementation starts with FileSpec
      schema work driven by GEP-40; GEP-36's Actions extraction
      follows in the same v0.8.0 cut.
  - date: 2026-04-24
    status: Implemented
    note: |
      Round M (6 sub-rounds: M-1, M-2, M-3, M-4, M-5a, M-5b,
      M-5c, M-6) migrated every raw File.* write in
      lib/glorbo_web/live/ into a Glorbo.Actions.* module.
      Modules shipped: Tasks, Companies, Projects, Audit,
      Channels, Inbox, Attachments, Agents. Post-M refactor
      extracted the shared helpers (slug validation, AuditLog
      routing, put_detail, default_base) into
      Glorbo.Actions.Support. The GEP-36 Credo ratchet
      allowlist is now empty — every write in lib/glorbo_web/
      live/ routes through Actions. (Detail was in the
      2026-04-24 session log, since pruned — see git history.)
supersedes: [38]
see-also: [6, 29, 37, 40, 41]
---

# GEP-36: Actions layer as the single Director-write channel

## Problem

GEP-6 D6 says `GlorboWeb.Actions` is the single enforcement point
for permissions + audit + filesystem writes originating from the
Director surface. MCP tools (GEP-29) honour this rigorously —
every write goes through the same Actions API LiveView uses. But
several LiveView handlers do not:

- **`KanbanLive`** — task creation, drag-to-column moves, new-task
  wizard. Writes `projects/<p>/tasks/<id>.md` via raw
  `File.mkdir_p!` + `File.write!` + `File.rename`.
  ([kanban_live.ex:1140-1280](../../lib/glorbo_web/live/kanban_live.ex#L1140-L1280))
- **`AgentLive`** — wake requests (already via Actions), but some
  file-tree mutations bypass.
- **`TaskLive`** — task trash (move to `.history/tasks/`) via raw
  `File.rename`.
  ([task_live.ex:270-285](../../lib/glorbo_web/live/task_live.ex#L270-L285))

Consequences:

1. **Audit gaps.** The LV path may forget to emit the
   corresponding `*.trashed` / `*.moved` audit event that the
   Actions path would have.
2. **Permission drift.** Actions enforces slug + size + role
   checks at the boundary; raw LV writes do not.
3. **Divergent on-disk shape.** MCP and LV produce different
   artefacts. A task created by MCP carries `Actions`'s stamp (Context
   footer, frontmatter normalisation); a LV-created task does not.
4. **Future invariants impossible to enforce.** Any new audit-
   trail rule or permission system has to be re-applied to every
   LV that writes.

## Goals

- **One write path per mutation.** Every Director-facing
  capability exposed through a single `Glorbo.Actions.*`
  call that does permission check + validation + audit emit
  + atomic write. No parallel write paths from LV / MCP /
  shell / any future frontend.
- **Move Actions out of `glorbo_web`.** The module lives in
  `glorbo` core (`lib/glorbo/actions/`), not in Phoenix.
  Frontends depend *on Actions*, Actions doesn't depend on
  any frontend. `GlorboWeb.Actions` becomes a thin
  delegation facade during the migration window, then
  eventually deletes (pre-1.0, atomic cut).
- **Expose every LV-inline mutation.** Extract every
  `File.*!` call currently buried in LiveView `handle_event`
  bodies into a named `Glorbo.Actions` function. Concrete
  list below.
- **Enforce the rule with a Credo check.** After the cut,
  `lib/glorbo_web/live/*.ex` cannot call `File.write!`,
  `File.rename`, `File.mkdir_p!`, `File.rm!`, `File.rm_rf!`
  on domain state. Exceptions for genuinely LV-local UI
  state (e.g. `_inbox_archive.json` per GEP-20 D2) go in a
  narrow allowlist.
- **Shell uses the same Actions.** GEP-37's `glorbo shell`
  (Accepted, implementation deferred) depends on
  `Glorbo.Actions` existing in core. Shipping GEP-36 first
  unblocks the shell without it having to re-do the
  extraction.

## Non-goals

- **Not a GenServer.** `Glorbo.Actions` is pure module +
  functions. See D1 below for the full rationale.
- **Not a new process supervision tree.** Actions functions
  run in the caller's process (LV's GenServer process, MCP
  SSE's Plug process, shell's runtime process). No new
  supervisor, no new runtime cost.
- **Not an abstract behaviour layer.** No `@behaviour
  Glorbo.Action.Callback` protocol. Actions is just a
  namespace of related functions. Behaviour / protocol
  layers invite speculative abstraction the pre-1.0
  project-profile rejects.
- **Not a read-path refactor.** This GEP is write-only. Read
  paths (LV queries, MCP resource subscriptions) continue
  to use direct `File.read` / `Ecto.Repo.all` against the
  filesystem + SQLite mirror per GEP-7. GEP-35's
  `AgentWritableFile` read seam is a separate concern.
- **Not a permissions redesign.** The allow-list +
  role-check logic already lives in `GlorboWeb.Actions`;
  it moves into `Glorbo.Actions` unchanged. This GEP relocates
  and unifies; it doesn't redesign.

## Design

### Module layout

New tree under `lib/glorbo/actions/`:

```
lib/glorbo/actions/
├── actions.ex              # Top-level umbrella (re-exports)
├── channels.ex             # Glorbo.Actions.Channels
├── tasks.ex                # Glorbo.Actions.Tasks
├── agents.ex               # Glorbo.Actions.Agents
├── projects.ex             # Glorbo.Actions.Projects
├── approvals.ex            # Glorbo.Actions.Approvals
├── proposals.ex            # Glorbo.Actions.Proposals
└── audit.ex                # internal — emit helper used by others
```

**Public API** (every function returns `{:ok, result} |
{:error, reason}`; `actor` carried in `opts` keyword):

| Function | Purpose | Source today |
|---|---|---|
| `Channels.post_message(co, ch, body, opts)` | Append message to channel | existing `GlorboWeb.Actions` |
| `Tasks.create(co, project, params, opts)` | Write new task file | inline in `KanbanLive` |
| `Tasks.move(co, task_path, new_status, opts)` | Status + column flip | inline in `KanbanLive` |
| `Tasks.trash(co, task_path, opts)` | Move to history/ | inline in `TaskLive` |
| `Tasks.dispatch(co, task_path, opts)` | Wake agent + record dispatch | scattered |
| `Tasks.update_status(co, task_path, new_status, opts)` | Any status change | partly `GlorboWeb.Actions` |
| `Tasks.assign(co, task_path, new_assignee, opts)` | Assignment + handoff_chain append | new (GEP-40 consumer) |
| `Tasks.post_comment(co, task_path, body, opts)` | Append to .comments.md | existing |
| `Tasks.request_peer_review(co, task_path, opts)` | GEP-41 trigger | new (GEP-41 consumer) |
| `Tasks.resolve_peer_review(co, task_path, verdict, opts)` | GEP-41 return path | new (GEP-41 consumer) |
| `Agents.wake(co, slug, reason, opts)` | Wake-queue trigger | existing |
| `Agents.create(co, params, opts)` | New-agent wizard write | inline in wizard LV |
| `Agents.update_config(co, slug, params, opts)` | AGENT.md edit | inline in `AgentLive` |
| `Projects.create(co, name, params, opts)` | New project tree | inline in dashboard |
| `Approvals.request(co, task_path, opts)` | Approval sentinel write | existing (Gate) |
| `Approvals.resolve(co, task_path, decision, opts)` | Grant/deny | existing |
| `Proposals.decide(co, proposal_id, decision, opts)` | Director verdict on proposal | inline in `ProposalsLive` |

Each function carries the same invariants today's
`GlorboWeb.Actions` does:

1. **Validate inputs.** Slug regex, body size caps, enum
   value checks. Reject early with a typed error.
2. **Check permissions.** Actor's role + company-scoped
   allowlist. Raises `ArgumentError` for malformed actor,
   returns `{:error, :permission_denied}` for unauthorized.
3. **Perform the write** via `Glorbo.Filesystem.AgentWritableFile`
   (atomic tmp+rename, lstat guard, path traversal check).
4. **Emit audit** via `Glorbo.Company.AuditLog.append_for/2`.
   Synchronous — ordering matters; audit-before-return so a
   crash after the write can't lose the record.
5. **Return typed result.** `{:ok, %{path: ..., ts: ...}}` or
   `{:error, reason}`. No raised exceptions on expected
   failure paths.

### `GlorboWeb.Actions` as delegation facade

During the migration window (v0.8.0), `GlorboWeb.Actions`
continues to exist but only as delegation:

```elixir
defmodule GlorboWeb.Actions do
  @moduledoc """
  Thin delegation facade over `Glorbo.Actions`. Exists for
  backwards compat during v0.8.0 migration; slated for
  removal in v0.9.0 once no LV / MCP caller references
  `GlorboWeb.Actions` directly.
  """

  defdelegate post_message(co, ch, body, opts), to: Glorbo.Actions.Channels
  defdelegate post_task_comment(co, path, body, opts), to: Glorbo.Actions.Tasks, as: :post_comment
  defdelegate set_approval(co, task_path, decision, opts), to: Glorbo.Actions.Approvals, as: :resolve
  defdelegate wake_agent(co, slug, reason, opts), to: Glorbo.Actions.Agents, as: :wake
end
```

LV + MCP callers migrate to `Glorbo.Actions.*` directly. The
facade exists to make the migration incremental — one caller
at a time — rather than atomic across every call site in a
single commit. Per the pre-1.0 discipline the facade
*eventually* deletes; it's not a permanent compatibility
layer.

### Credo check for raw `File.*!` writes in LV

Custom Credo check: `Glorbo.Credo.NoRawFileWritesInLV`.

- Scope: matches file paths under `lib/glorbo_web/live/**/*.ex`.
- Flags calls: `File.write!/2,3`, `File.write/2,3`,
  `File.rename!/2`, `File.rename/2`, `File.mkdir_p!/1`,
  `File.mkdir_p/1`, `File.rm!/1`, `File.rm/1`,
  `File.rm_rf!/1`, `File.rm_rf/1`, `File.cp!/2,3`,
  `File.cp/2,3`.
- Exception list: files explicitly approved for LV-local UI
  state (e.g., `inbox_live.ex` writing `_inbox_archive.json`
  per GEP-20 D2). Tracked in `config/credo.exs` with
  inline rationale.
- Severity: `:error` → fails the strict Credo run →
  blocks CI.

### Migration order within v0.8.0

Stepwise — each step independently reviewable, tests green
throughout:

1. **Create `lib/glorbo/actions/` tree + move the four
   existing functions.** `post_message`, `post_task_comment`,
   `set_approval`, `wake_agent`. `GlorboWeb.Actions` becomes
   delegation. No behavior change; tests unchanged.
2. **Extract task mutations.** `Tasks.{create, move, trash,
   update_status, dispatch}`. Rewrite `KanbanLive` +
   `TaskLive` handlers to call them. Carve out the
   `File.*!` calls currently inline.
3. **Extract agent + project mutations.**
   `Agents.{create, update_config}` + `Projects.create`.
   Rewrite agent-wizard + project-creation handlers.
4. **Add the Credo check.** Should pass clean on the now-
   extracted code; exception list for LV-local UI state.
5. **Add new functions for GEP-40/41.** `Tasks.assign`
   (with handoff_chain append), `Tasks.request_peer_review`,
   `Tasks.resolve_peer_review`. These are net-new APIs, not
   refactors; they land after the extraction stabilises.

Each step is one commit (or a small commit group). Tests
run green after each.

## Migration / rollout

**Atomic cut** at the pre-1.0 discipline level — we're not
shipping a dual-writer phase, no feature flag, no gradual
rollout. But the implementation sequence above *is* staged
inside v0.8.0 to keep diffs reviewable.

**What ships in v0.8.0:**

- Full `Glorbo.Actions` module tree.
- All LV + MCP callers migrated to `Glorbo.Actions.*`
  (either directly or through the `GlorboWeb.Actions`
  delegation facade).
- Credo check live; CI fails on reintroduction of raw LV
  writes.
- Audit events unchanged in shape (actor, action, target,
  ts). The Actions layer now emits them uniformly across
  all call paths.

**What ships in v0.9.0 (or later):**

- `GlorboWeb.Actions` delegation facade deleted once no
  caller references it. Target: v0.9.0. If a caller still
  references it at that cut, the PR blocks until migration
  completes.

**Documentation:**

- `docs/DESIGN.md` §"Actions layer" section added, naming
  `Glorbo.Actions.*` as the canonical write surface.
- `docs/architecture.md` updated with the new module tree.
- CLAUDE.md §"Load-bearing invariants" gains: "All
  Director-facing mutations go through `Glorbo.Actions.*`.
  Raw `File.*!` writes in LiveView are blocked by Credo."

## Failure modes

| Mode | Surface | Handling |
|---|---|---|
| Actor parameter missing or malformed | `Glorbo.Actions.*` entry | Raise `ArgumentError` at the boundary. Bug in the caller, not expected runtime. |
| Slug/path validation fails | Typed return | `{:error, :invalid_slug}` etc. Caller surfaces in UI. |
| Permission denied | Typed return | `{:error, :permission_denied}`. Actions-layer audit entry `action.denied` emitted. |
| Filesystem write race (two callers create same path) | `AgentWritableFile` | Atomic tmp+rename makes last-writer-wins correct. Audit logs both attempts; the loser's result is simply overwritten but no data corruption. If the caller needs "created-by-me" semantics, they check the file contents after. |
| Audit emit fails (disk full, etc.) | Typed return | `{:error, :audit_failed}`. The write already happened at that point; caller has a chance to compensate / retry. Logged to `log/glorbo.log`. |
| LV calls old `GlorboWeb.Actions` path during migration | None — delegation facade transparently routes | Works for one release cycle; Credo starts warning on direct `GlorboWeb.Actions` calls after v0.8.0. |
| Credo check false positive (new LV doing genuine UI-state write) | CI fail | Add to the exception list in `config/credo.exs` with inline rationale. Intentional friction. |

## Test strategy

### Unit tests

- Every `Glorbo.Actions.*` function tested in isolation:
  happy path, invalid input path, permission-denied path.
- `AuditLog` emissions asserted for every mutation —
  action name, target path, actor, timestamp well-formed.
- `AgentWritableFile` integration: atomic rename, lstat
  guard (symlink rejection), path-traversal rejection.

### Integration tests

- LV test (`KanbanLiveTest`): create task via LV event →
  file exists on disk → audit entry emitted → task appears
  in LV's render.
- MCP test (`MCPTest`): create task via MCP tool call →
  same assertions. Both paths produce the same on-disk
  shape + the same audit event kind.
- Delegation facade: every delegated function call verified
  (the delegation is mechanical but the test catches
  accidental renames breaking the facade).

### End-to-end / regression

- Full `mix test` green after each migration-step commit.
- Existing 1996-test baseline must not regress.
- Credo check: `mix credo --strict` passes; reintroducing a
  `File.write!` in a LV is a CI blocker.

### Performance

Not a perf-sensitive layer; dispatch + LV rendering are not
the bottleneck. No benchmarks planned. If a real hot path
emerges post-implementation, revisit.

## Decision log

### D1. `Glorbo.Actions` is pure module + functions, not a GenServer

- **Decided:** The whole tree is pure functions in modules.
  State (audit log, filesystem) is external and
  concurrency-safe without a serialization point.
- **Alternatives:** Per-company GenServer serialising all
  Director-facing writes; per-entity (task / channel /
  agent) GenServer; pool of workers; Task.Supervisor queue.
- **Why:** Per maintainer 2026-04-24 directly:
  *"no current use case where concurrent shell/web/MCP
  writes would race on state needing Actions as a
  gatekeeper; filesystem atomic-rename + append-only audit
  handle concurrency correctly at the OS level. Revisit if
  such a use case materialises — a GenServer can wrap the
  pure module later without rewriting callers."*
  The filesystem-is-truth invariant (GEP-3) + atomic
  rename (`AgentWritableFile`) + append-only audit (GEP-7)
  handle the race conditions that would motivate a
  GenServer. A GenServer today is a bottleneck without a
  concrete problem. Adding one later wraps the pure module;
  callers don't change.

### D2. Actions lives in `glorbo` core, not `glorbo_web`

- **Decided:** Module namespace `Glorbo.Actions.*`, directory
  `lib/glorbo/actions/`. `GlorboWeb.Actions` becomes
  delegation facade with planned removal in v0.9.0.
- **Alternatives:** Keep in `glorbo_web`; create a third
  top-level app.
- **Why:** `glorbo_web` is a frontend — Phoenix LV + MCP.
  Core capabilities should not live inside a frontend;
  `glorbo shell` (GEP-37), MCP (GEP-29), future surfaces all
  need to depend on Actions without taking a dependency on
  Phoenix. The inversion-of-module-graph argument is the
  original motivation for GEP-38 (superseded by this one).

### D3. One function per concrete operation, not behaviour-polymorphic

- **Decided:** Named functions per operation (`Tasks.create`,
  `Tasks.move`, etc.). No `@behaviour`
  `Glorbo.Action.Callback`, no `c:execute(params, opts)`
  protocol layer.
- **Alternatives:** Behaviour-based: `Glorbo.Action.execute
  %Tasks.Create{...}`; command-bus pattern with dispatcher.
- **Why:** The pre-1.0 project-profile rejects speculative
  abstractions. There's no generic "action runner"
  consumer — callers know which action they want at compile
  time. Named functions are discoverable via autocomplete +
  doctests; a behaviour layer adds indirection without
  enabling anything. Revisit if a generic "replay actions"
  or "batch actions" use case materialises.

### D4. Delegation facade with scheduled removal, not hard cutover

- **Decided:** `GlorboWeb.Actions` stays as `defdelegate`-only
  during v0.8.0. Removed in v0.9.0 (or whatever cycle has
  zero remaining callers).
- **Alternatives:** Remove `GlorboWeb.Actions` in the same
  commit that creates `Glorbo.Actions` (hard cut); keep
  `GlorboWeb.Actions` permanently as a dual API.
- **Why:** Hard cut means one gigantic PR rewriting every LV
  + MCP + test caller simultaneously. Reviewable? Barely.
  Permanent dual API means two things to keep in sync
  forever; drift is inevitable. Delegation facade is the
  middle path — callers migrate incrementally, facade is
  trivial to audit, removal is atomic and triggered by
  call-site count (grep shows zero → delete).

### D5. Credo check blocks CI, not lints advisory-only

- **Decided:** Credo check severity `:error`; any
  re-introduction fails the strict run → fails CI.
- **Alternatives:** Severity `:warning` (non-blocking);
  advisory-only via a comment pattern; no enforcement.
- **Why:** The whole point of extracting Actions is to
  enforce one write path per mutation. If the enforcement
  is advisory, drift returns within 3 months. Pre-1.0
  discipline + no-kid-gloves + paranoid security posture
  all argue for hard enforcement. The exception-list
  mechanism covers genuine UI-state writes (`_inbox_archive.json`
  per GEP-20 D2); this is intentional friction for
  cross-cutting changes, not a "maybe" suggestion.

### D6. Module tree organised by resource, not by operation

- **Decided:** Submodules per resource (`Tasks`, `Agents`,
  `Projects`, etc.). Operations are functions within the
  resource module.
- **Alternatives:** Submodules per operation (`Create`,
  `Move`, `Delete`); flat namespace
  (`Glorbo.Actions.create_task`, `Glorbo.Actions.move_task`).
- **Why:** Resource grouping matches how callers think
  ("I want to create a task → `Tasks.create`"). Operation
  grouping splits related behaviour (`create_task` and
  `update_task` drift apart in different modules).
  Flat namespace bloats one file. The convention matches
  existing Elixir libraries like Ecto (`Ecto.Repo.insert`,
  `Ecto.Repo.update`) and Phoenix (`Phoenix.Controller.*`).

### D7. Every Actions function takes `opts` with `actor:` required

- **Decided:** Every public function signature includes
  `opts :: keyword()` with a mandatory `:actor` key.
  Missing `:actor` raises `ArgumentError`.
- **Alternatives:** Implicit actor via process dictionary;
  actor as a positional arg (`actor :: String.t()`);
  per-caller default actor.
- **Why:** Actor must be part of every audit entry (GEP-3
  invariant). Implicit via process dict would be "magical"
  and break in async contexts (`Task.async` inside an LV
  handler). Positional arg locks the signature for future
  keyword options; `opts` keyword is extensible. Missing
  actor should *crash*, not silently default, per the
  security-paranoid posture.

## Related

- **GEP-2** — architecture overview. Actions is the
  enforcement point for the permissions + audit invariants.
- **GEP-3** — filesystem as source of truth. Actions'
  writes must preserve this.
- **GEP-6 D6** — the original "Actions is the single
  enforcement point" rule. This GEP operationalises it.
- **GEP-7** — SQLite as derived. Audit table mirror
  rebuilds from JSONL; Actions emits the JSONL, not SQLite.
- **GEP-19** — Director approval workflow. The
  `Approvals.resolve` function is the entry point.
- **GEP-27** — agent sandbox path requests. Path-request
  gate uses Actions' audit infrastructure; doesn't mutate
  via Actions itself (the request sentinel is an
  agent-side write).
- **GEP-28** — agent-created proposals.
  `Proposals.decide` lands here.
- **GEP-29** — MCP server. The other write surface that
  already routes through today's `GlorboWeb.Actions`;
  migrates to `Glorbo.Actions` transparently.
- **GEP-37** — `glorbo shell`. Accepted, implementation
  deferred. Shell depends on `Glorbo.Actions` existing in
  core; this GEP ships first.
- **GEP-38** — frontend adapter contracts. Superseded by
  this GEP.
- **GEP-40** — task chain observability. `Tasks.assign`
  (new) lives in this GEP's tree and implements the
  `handoff_chain:` append semantics.
- **GEP-41** — peer-review gate. `Tasks.request_peer_review`
  + `Tasks.resolve_peer_review` (new) live in this GEP's
  tree.
