---
gep: 0040
title: "Task chain observability — `done_when:`, `handoff_chain:`, chain audit view"
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Draft
    note: |
      Initial draft. Crown-jewels phase-1 scope per maintainer
      directive "pivot to crown jewels now and defer glorbo
      shell until this is done" (2026-04-24 session). First of
      the crown-jewels GEP arc; GEP-41 follows with the
      peer-review gate that consumes this GEP's schema.
requires: [2, 3, 7, 25]
see-also: [13, 19, 28, 30, 41]
---

# GEP-40: Task chain observability

## Problem

Today, when a non-trivial task flows through multiple agents
(CEO → researcher → engineer → QA → CEO), reconstructing **what
happened** requires:

- Reading `audit/YYYY-MM.jsonl` and grep-filtering by `target:
  <task_path>`.
- Reading the task's frontmatter for the *current* `assigned_to`
  only (no history).
- Reading the task-comments sidecar file for director-agent
  discussion.
- Inferring handoff intent from timestamps + assignment flips.

This fails three of the project's four crown-jewel axes:

1. **Inter-agent interaction** — handoffs are a body-convention
   (the engineer template's `## Handoff` section shipped in
   commit `fe658ee` on 2026-04-24). The convention is
   unstructured, not queryable, and breaks if any agent in the
   chain forgets to follow it.
2. **Director interaction** — there's no single view showing
   "what happened in this task's chain." Director reconstructs
   by grep. Bumped-up tasks that need escalation judgement are
   invisible until the director opens the task page and
   reads-back every comment.
3. **Deliverable quality** — agents infer "done" from the task
   title + body. No explicit acceptance criteria field. "Mostly
   done" gets rounded up to `status: done`.

The existing infrastructure (GEP-19 approval, GEP-27 path
grants, GEP-28 proposals, GEP-30 task-comments, LoopDetector)
covers **enforcement points** well. What's missing is the
**observability layer** — structured, queryable chain state
that feeds every higher-level quality intervention (peer
review, retrospectives, chain metrics).

## Goals

- **Acceptance criteria are explicit.** Every non-trivial task
  carries a `done_when:` statement defining what the assignee
  must produce/verify before marking `status: done`. Agents
  self-check against this field in their reply.
- **Handoff chain is structured, not prose.** Task frontmatter
  carries a `handoff_chain:` list of append-only audit entries
  (`{ts, from, to, reason}`). Every `assigned_to:` flip appends
  to the list. No re-ordering, no rewriting — audit log
  semantics.
- **Original requester is always recoverable.** A new
  `requested_by:` field fixes the requester at task creation
  and never changes. Answers "who bumped this up" without
  walking the chain.
- **Severity and peer-review-opt-in are part of the schema.**
  Schema drift fixed: `severity:` (currently used by
  `Glorbo.TaskDefinition` + kanban form + dispatch but not in
  the FileSpec optional list) is formalised. New
  `peer_review_required:` flag lets any agent self-escalate a
  task into the peer-review path.
- **Director gets a chain audit view.** New LiveView route
  aggregates handoff_chain + dispatches + audit entries +
  comments into one timeline. One click, not six greps.

## Non-goals

- **Not a task decomposition engine.** CEO still breaks tasks
  manually; no auto-delegation or sub-task graph.
- **Not retrospective / learning infrastructure.** Per-chain
  retros live in GEP-42.
- **Not an aggregate metrics dashboard.** Per-task chain
  timeline only; company-wide chain-length averages and
  sparklines wait for phase-2.
- **Not backwards-compatible migration.** Pre-1.0, atomic cut
  per project-profile risk tolerance. Existing tasks without
  the new optional fields continue to work unchanged; agents
  adopt the fields on new tasks going forward.
- **Not peer-review routing itself.** GEP-41 wires the
  severity-based peer-review gate on top of this schema;
  GEP-40 only establishes the fields.

## Design

### Schema changes (FileSpec `task/v1`)

Four new optional frontmatter fields on `task/v1`:

```yaml
---
kind: task/v1
id: release-1
title: Cut the v1 release
status: todo
assigned_to: ceo
requested_by: director              # NEW — fixed at creation; never changes
severity: major                     # NEW — formalises existing TaskDefinition field
peer_review_required: false         # NEW — opt-in escalation into peer-review (GEP-41)
done_when: |                        # NEW — explicit acceptance criteria
  tag `v1.0.0` exists; signed GH Release published;
  Homebrew tap formula updated; CHANGELOG has v1.0.0 section.
handoff_chain:                      # NEW — append-only audit log
  - ts: "2026-04-24T14:00:00Z"
    from: director
    to: ceo
    reason: "initial dispatch"
  - ts: "2026-04-24T14:15:00Z"
    from: ceo
    to: engineer
    reason: "needs build + tag work"
---
```

**Validator changes** (`Glorbo.FileSpec.TaskMd`):

- `optional:` list extends with `:requested_by`, `:severity`,
  `:peer_review_required`, `:done_when`, `:handoff_chain`.
- `enums:` gains `severity: ["info", "minor", "major",
  "critical"]` — formalises what `Glorbo.TaskDefinition` already
  coerces at line 191-195 but the FileSpec never declared.
- `enums:` gains `peer_review_required: [true, false]` — only
  accepts booleans (no string-ish truthy).
- `canonical_key_order` extends with the new fields in a
  sensible order: `severity` near `priority`, `requested_by`
  near `assigned_to`, `peer_review_required` near
  `requires_approval`, `done_when` before `handoff_chain`
  (both near the end since they're larger).
- `handoff_chain` inner-map schema validated: each entry must
  carry `ts:`, `from:`, `to:`, `reason:`; extra keys ignored
  with an info-level finding.

### Where `handoff_chain` entries come from

The Router (`Glorbo.Company.Router`) gains a new step in its
task-mutation pipeline: when an incoming outbox message mutates
a task's `assigned_to:` and the task has a previous value, the
Router appends a `handoff_chain` entry before writing the task
file:

```elixir
# pseudo-code
def apply_assignment(task, new_assignee, reason, actor_slug) do
  entry = %{
    ts: DateTime.utc_now() |> DateTime.to_iso8601(),
    from: actor_slug,
    to: new_assignee,
    reason: reason || ""
  }

  task
  |> Map.update(:handoff_chain, [entry], &(&1 ++ [entry]))
  |> Map.put(:assigned_to, new_assignee)
end
```

Agents **can also** append handoff entries themselves by writing
to the task file directly (via `Glorbo.Actions` once carved out
per GEP-36). The Router's pipeline is the primary path; the
direct-write path is for migrations and edge cases. Both paths
must emit the same `task.assigned` audit event so chain
reconstruction works uniformly.

When `assigned_to:` is set at task creation (no previous
assignee), the first handoff-chain entry records
`from: requested_by` → `to: <initial assignee>` with reason
`"initial dispatch"`.

### Chain audit view — `/companies/:co/tasks/:task_id/chain`

New LiveView route at `GlorboWeb.TaskChainLive`. Renders one
timeline aggregating:

1. **Handoff events** — from `handoff_chain` frontmatter.
   Primary timeline axis.
2. **Dispatch events** — from audit (`agent.dispatch`,
   `agent.complete`). Superimposed per assignee.
3. **Approval events** — from audit
   (`approval.requested|granted|denied`). Inline.
4. **Loop sentinels** — from audit
   (`agent.loop_detected|loop_resolved`). Inline.
5. **Comments** — from `<task-id>.comments.md`. Inline.

Top of the page renders chain-summary metrics derived from the
above:

- Chain length: `length(Enum.uniq_by(handoff_chain, & &1.to))`
  — distinct agents touched.
- Total dispatches: count of `agent.dispatch` events for this
  target.
- Handoff count: `length(handoff_chain)`.
- Loop count: count of `agent.loop_detected` events.
- Wall-time elapsed: `max(event.ts) - min(event.ts)`.
- Total USD: sum of `spent_usd_cents` across all
  `agent.complete` events / 100.

Data source: PubSub subscriptions to `company:<co>:projects`
(task mutations) + `company:<co>:audit` (new events) + direct
file reads on mount. No new persistence.

**Navigation:**

- TaskLive page gains a "Chain" tab linking to the new view
  when `handoff_chain` is non-empty (i.e., the task has been
  handed off at least once).
- InboxLive approval rows carry a secondary link to the chain
  view for escalated tasks.

### Done-when validation

No hard-enforcement at validator level — `done_when:` is free-
form text (agents write it, agents interpret it). But three
soft signals:

1. **Missing `done_when:` on a task with `severity: major|
   critical`** — FileSpec.Validator emits info-level finding.
   Soft nudge, not a block.
2. **Agent replies must reference `done_when:`** — this is a
   template-level convention (already in the engineer
   template's reply contract: *"Design calls / review /
   skipped"* sections). We extend the contract to include a
   `Done-when check: <addressed | not met because X>` line.
3. **CEO's retro (GEP-42) gets a "done_when actually met?"
   field** — agent can self-assess, CEO cross-checks. Not in
   GEP-40's scope but downstream consumer.

### Example chain frontmatter

Realistic task that's been through 3 agents:

```yaml
---
kind: task/v1
id: deploy-pipeline
title: Implement the new deployment pipeline
status: in-progress
assigned_to: engineer
requested_by: director
severity: major
peer_review_required: true
done_when: |
  pipeline deploys from main on green CI;
  runbook at projects/ops/runbook.md;
  tested on staging at least once.
handoff_chain:
  - ts: "2026-04-24T14:00:00Z"
    from: director
    to: ceo
    reason: "initial dispatch"
  - ts: "2026-04-24T14:05:00Z"
    from: ceo
    to: researcher
    reason: "needs plan before build"
  - ts: "2026-04-24T14:35:00Z"
    from: researcher
    to: engineer
    reason: "plan at /projects/ops/tasks/deploy-plan-1.md; please implement"
priority: medium
---
```

## Migration / rollout

Pre-1.0 atomic cut. Three coordinated commits:

1. **Schema + validator.** `Glorbo.FileSpec.TaskMd` extended;
   `Glorbo.TaskDefinition` parses the new fields into the
   existing struct + adds `:requested_by, :handoff_chain,
   :peer_review_required, :done_when` to the struct. Existing
   tasks without the fields continue to load cleanly (nil
   defaults).
2. **Router wiring.** Router's task-mutation pipeline appends
   to `handoff_chain` on every `assigned_to:` flip; audit
   event shape adjusted to reference handoff chain where
   present.
3. **LiveView.** `GlorboWeb.TaskChainLive` at
   `/companies/:co/tasks/:task_id/chain`; link added to
   TaskLive + InboxLive.

Templates that create tasks (CEO template actions table,
Kanban new-task form, MCP `create_task` tool) gain support for
setting `done_when:` and `requested_by:`. Existing tasks
without the fields keep working; new tasks use the new shape.

UAT update: `docs/testing/uat.md` gets a "Chain view" section
testing the new route.

## Failure modes

| Mode | Surface | Handling |
|---|---|---|
| Handoff_chain write-race (two agents write task concurrently) | Task file | Router is single-threaded per company; all writes serialize through Router. Direct writes from agents (path-request exception etc.) go through `Glorbo.Filesystem.AgentWritableFile` atomic rename. |
| Handoff_chain tampered (agent tries to rewrite history) | Router validation | Validator in FileSpec checks that new list is strict prefix of old list (append-only). Tampering rejected at Router with `:handoff_chain_rewound` reason; audit entry logged. |
| `done_when:` free-text abused (agent writes empty string) | FileSpec info finding | Empty string treated as "no criteria"; flagged info, not blocking. Agent's reply contract asks them to fill or explicitly state "no formal criteria; reviewer judges fit." |
| Chain audit view slow on long chains | LiveView | Cap displayed timeline at 500 events (sufficient for any realistic chain). "Older events truncated; see audit log" footer if exceeded. |
| Severity enum violation (misspelling) | FileSpec | Validator rejects with error-level finding; task file remains parseable (field falls back to nil via `coerce_severity/1`). |

## Test strategy

**Unit tests:**

- `Glorbo.FileSpec.TaskMd` schema — four new optional fields
  parse correctly; enums rejected on bad values; canonical
  key order idempotent through formatter.
- `Glorbo.TaskDefinition.from_frontmatter/2` — new fields
  populate struct; missing fields → nil.
- Router handoff-chain appender — `apply_assignment/4` appends
  the right entry; rejects append-only violations.

**Integration tests:**

- End-to-end: director creates task → CEO reassigns →
  researcher reassigns → engineer picks up. Task file's
  `handoff_chain` has 3 entries in order, first marked
  `"initial dispatch"`.
- Invalid chain rewrite (simulate malicious agent):
  write task with shorter handoff_chain than on disk →
  Router rejects, audit entry logged, task untouched.

**LiveView tests:**

- `TaskChainLive` renders handoff events + dispatches +
  approvals + loops + comments inline.
- Chain-summary metrics computed correctly from fixture.
- Navigation link from TaskLive appears only when
  `handoff_chain != []`.

**E2E (UAT):**

- New task chain view verified against live director
  workflow; browser-based check per `docs/testing/uat.md`
  protocol. Targeted case: "Create task assigned to CEO, CEO
  reassigns to engineer, engineer completes, verify chain view
  shows 2 handoffs + 1 dispatch + expected summary metrics."

## Open questions

- **Enum value for `peer_review_required`.** Booleans look
  clean but YAML conventions vary. Current pick: strict
  booleans (`true`/`false`, not strings). Revisit if agents
  trip on it — worst case, accept `"true"|"false"` as
  equivalents with a normalisation pass.
- **Handoff-chain cap.** Should a task's `handoff_chain` ever
  be truncated (very long chains)? My lean: no — if a chain
  grows past 20 entries something else is wrong. Revisit if
  real usage demands it.
- **Chain view access control.** Right now any director view
  works on localhost with no auth (per GEP-6 D5). If / when
  multi-user lands, chain view follows the director-only
  surface convention — unchanged from existing LiveViews.

## Decision log

### D1. Structured `handoff_chain:` field, not body convention

- **Decided:** Dedicated YAML frontmatter field (list of
  `{ts, from, to, reason}` maps). Append-only (Router
  enforces the prefix rule).
- **Alternatives:** Keep the body-convention from the engineer
  template (prose `## Handoff` blocks); use a sidecar file
  (`<task-id>.chain.md`); extend task-comments to tag handoff
  entries.
- **Why:** Body-convention is unqueryable; every consumer
  (chain view, metrics, peer-review gate) would re-parse
  prose. Sidecar files multiply the file count per task; keep
  the task file self-describing. Tagging comments mixes two
  concerns (discussion vs. chain). Structured frontmatter is
  small, queryable, and fits the existing FileSpec discipline.
  The body `## Handoff` notes from the engineer template can
  continue to exist as *human-readable* context alongside the
  structured field; they're not redundant because the body
  note can carry path pointers and longer prose the YAML
  entry can't.

### D2. Append-only, not a stack

- **Decided:** `handoff_chain` is a strict append-only list.
  Once an entry is written, it never moves or gets deleted.
  Router rejects any mutation that doesn't start with the
  existing list as a prefix.
- **Alternatives:** Stack that pushes/pops as tasks return to
  their requester (maintainer's initial intuition, rejected
  after discussion 2026-04-24); sparse array keyed by
  timestamp.
- **Why:** Audit-log semantics beat stack semantics for this
  use case. A stack loses information: a researcher→engineer
  handoff that returns to researcher (then to QA) collapses
  back to just [researcher, QA] on the stack, erasing the
  engineer visit. Append-only preserves the real trajectory,
  and consumers (peer-review gate, chain audit view, retros)
  care about full history. Roll-up-for-display is cheap
  (group consecutive duplicates in the view layer); reverse
  extrapolation from a rolled-up stack is impossible.

### D3. `requested_by:` separate from the first handoff-chain entry

- **Decided:** `requested_by:` is a top-level frontmatter
  field set once at creation and never changed. It duplicates
  information in `handoff_chain[0].from`, but by design.
- **Alternatives:** Derive `requested_by` from
  `handoff_chain[0]`; don't record it at all.
- **Why:** Predictability. A peer-review gate or retro check
  that wants "who originally asked for this?" should not
  have to scan the whole chain. A single top-level field
  answers the question in O(1). The duplication is tiny
  (one string); the consistency guarantee (first entry ==
  requested_by) can be a validator check.

### D4. `done_when:` is free-text, not structured

- **Decided:** Free-form markdown in the `done_when:` field.
  No sub-schema, no checklist-format enforcement.
- **Alternatives:** Structured list of `{criterion, check}`
  entries; boolean `done_when_met:` field agent self-sets.
- **Why:** Acceptance criteria are context-dependent; a
  structured schema would either over-fit (can't express
  qualitative criteria like "runbook reads well") or
  under-fit (every schema has an "other" escape hatch). Free
  text lets agents + director express what "done" means in
  natural language; the discipline is *that the field exists
  and is addressed by the agent's reply*, not that it's
  parseable. Downstream tooling (peer-review gate, retro)
  reads the field as prompt input; LLMs are the right
  consumer for free-form acceptance criteria.

### D5. Schema drift fix — `severity` formalised in FileSpec

- **Decided:** `severity:` + `enums: severity: ["info",
  "minor", "major", "critical"]` added to TaskMd FileSpec.
- **Alternatives:** Leave `severity` as an unknown-but-
  tolerated field; move it out of TaskDefinition entirely.
- **Why:** `Glorbo.TaskDefinition` already parses + coerces
  `severity` (lines 64, 75, 95, 168, 191-195). The Kanban
  new-task form writes it. Dispatch uses it. The FileSpec is
  the canonical schema; not listing `severity` is drift that
  this GEP takes the opportunity to fix. No new code —
  validator already accepts unknown fields as info findings;
  this just promotes `severity` to a proper enum-validated
  optional.

### D6. Chain audit view under `/tasks/:task_id/chain`, not top-level

- **Decided:** Chain view is a nested route under TaskLive,
  reachable via a "Chain" tab on the task page (when
  `handoff_chain != []`).
- **Alternatives:** Top-level `/companies/:co/chains` listing
  all in-flight chains; embed the timeline inline in TaskLive
  without a separate route.
- **Why:** Chain state is *per-task*; there's no "list of
  chains" concept separate from the list of tasks. Inline
  embedding in TaskLive would bloat the task page for simple
  tasks that never got handed off. Nested route gets the
  detail only when the user wants it, keeps TaskLive focused
  on the current task content. Phase-2 aggregate dashboards
  (out of scope) can still render top-level metrics derived
  from the per-task views.

## Related

- **GEP-2** — architecture overview; filesystem-as-truth
  invariant this GEP respects.
- **GEP-3** — filesystem as source of truth; handoff chain
  lives in the task file, not in-memory.
- **GEP-7** — SQLite as derived data; handoff chain not
  mirrored to SQLite in phase 1 (can be later if queries
  become hot).
- **GEP-13** — project-prefixed task IDs; chain view respects
  the ID scheme.
- **GEP-19** — approval workflow; approval events join the
  chain view timeline.
- **GEP-25** — FileSpec framework; this GEP extends the
  `task/v1` spec.
- **GEP-28** — proposals; proposal files don't currently have
  a chain concept (single-author → director). Out of scope.
- **GEP-30** — task comments sidecar; chain view renders
  comments inline on the timeline.
- **GEP-41** — peer-review gate (forthcoming) consumes
  `severity:` and `peer_review_required:` fields introduced
  here.
