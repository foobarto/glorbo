---
gep: 0019
title: Director Approval Workflow Protocol
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-19
history:
  - date: 2026-04-19
    status: Draft
    note: Retroactive capture of the shipped protocol; no behavioural change.
  - date: 2026-04-19
    status: Implemented
    note: Protocol has been live since v0.0.3 (GEP-8 milestone).
see-also: [3, 6, 14, 16]
extended-by: [23]
implemented-in: v0.0.3
---

# GEP-19: Director Approval Workflow Protocol

## Problem

Tasks flagged `requires_approval: director` in their frontmatter must
pause before the agent executes its side-effect and wait for explicit
Director approval. The workflow crosses module boundaries
(`Glorbo.Approvals.Gate`, `GlorboWeb.Actions.set_approval/4`,
`GlorboWeb.ApprovalQueueLive`, `Glorbo.TaskDefinition`) and uses
several on-disk artefacts that were introduced incrementally without
being captured as a single contract:

- `awaiting-approval-<task_id>.md` sentinel under
  `agents/<slug>/state/` — the "agent has parked on this task and
  needs approval" signal.
- `tasks_approval_state` SQLite table — Gate's index into which
  sentinels are live.
- Task frontmatter transitions (`status: pending-approval → approved
  | denied`, `assigned_to: <agent> ↔ director`, optional
  `denial_reason:`).
- Audit event vocabulary (`approval.requested`, `approval.granted` /
  `.approved`, `approval.denied`, plus edge-case events).
- Two code paths with the same semantics:
  - **Gate daemon path** — the agent writes the sentinel, Gate
    resolves it on filesystem event.
  - **UI-direct path** — Director clicks Approve/Deny in the dashboard,
    `GlorboWeb.Actions.set_approval/4` rewrites the task frontmatter
    without requiring Gate to be running.

Without a single document, invariants like "both paths must restore
`assigned_to` to the requesting agent on grant" and "both paths must
use `target:` (not `task_path:`) as the canonical audit pointer"
were discovered by divergence bugs rather than by design.

## Goals

- Document the complete sentinel contract (path shape, frontmatter
  fields, lifecycle).
- Specify the `assigned_to` swap invariant that links director focus
  to task ownership.
- Enumerate the audit-event vocabulary produced by both code paths
  and confirm they emit the same JSONL shape.
- Capture the Gate-daemon vs UI-direct equivalence so future edits
  keep the two in lockstep.

## Non-goals

- Replacing the current protocol. This GEP is Informational —
  retroactive capture of shipped behaviour.
- Approval workflows involving more than one approver. The current
  protocol is strictly "Director yes/no"; delegated / multi-stage
  approval is out of scope (and would supersede this GEP).
- Approval for inbound messages, channel posts, or wake requests.
  Only task-frontmatter `requires_approval: director` triggers the
  workflow.
- Cross-company approval. Each company's Gate + sentinel tree is
  isolated by the mount-namespace sandbox (GEP-5).

## Design

### On-disk artefacts

**Sentinel file** —
`~/.glorbo/companies/<co>/agents/<agent>/state/awaiting-approval-<task_id>.md`

```yaml
---
agent: <agent_slug>            # who requested approval
task_id: <task_id>             # short id without extension
task_path: projects/<proj>/tasks/<task_id>.md
requested_at: <ISO8601 UTC>
---

<optional prose — shown on the approval card as "reason">
```

- Written by: the agent (via its CLI tool's file-write tool), OR
  by `Glorbo.Approvals.Gate.request_approval/2` when the agent calls
  it through the library path.
- Read by: Gate (for indexing into `tasks_approval_state`), Actions
  (for `lookup_requesting_agent/3` when Gate isn't running), and
  `ApprovalQueueLive` (for rendering the queue).
- Deleted by: Gate on grant/deny, or `Actions.set_approval` on UI-path
  resolution.

**Task frontmatter transitions.** The task file
(`projects/<proj>/tasks/<task_id>.md`) moves through these states:

| Before request            | After request           | After grant          | After deny                   |
|---------------------------|-------------------------|----------------------|------------------------------|
| `status: pending-approval`| `status: pending-approval` | `status: approved` | `status: denied`             |
| `assigned_to: <agent>`    | `assigned_to: director` | `assigned_to: <agent>` | `assigned_to: <agent>`       |
| (no `denial_reason`)      | (no `denial_reason`)    | (no `denial_reason`) | `denial_reason: <text>` (optional) |

The `assigned_to` swap is **load-bearing**: while the Director is
reviewing, the task belongs to `director` on the Kanban; on resolution
it swings back to the requester so the agent sees the outcome on their
lane.

**SQLite index** — `tasks_approval_state(task_path PRIMARY KEY,
agent_slug, status, denial_reason, …)`. Derived (GEP-7): fully
rebuildable from sentinels + frontmatter via `glorbo reindex`. Gate
uses it as a fast lookup; UI-direct path bypasses it because it
reads the sentinel directly.

### Audit events

Emitted via `Glorbo.Company.AuditLog.append/1` with canonical keys:

| Action                       | Actor      | Target          | Extra detail                                    |
|------------------------------|------------|-----------------|-------------------------------------------------|
| `approval.requested`         | `<agent>`  | `<task_path>`   | `agent`, `task_id`, `previous_assigned_to`      |
| `approval.granted` (Gate) / `approval.approved` (UI) | `director` | `<task_path>`   | `agent` (restored), `approved_at` (Gate)        |
| `approval.denied`            | `director` | `<task_path>`   | `agent`, `denied_at` (Gate), `denial_reason`    |
| `approval.spurious`          | `director` | `<task_path>`   | `status` — resolved frontmatter without sentinel |
| `approval.parse_error`       | `system`   | `<task_path>`   | `error`                                         |
| `approval.rejected_traversal`| `system`   | `<task_path>`   | (path escape attempt)                           |
| `approval.rename_failed`     | `system`   | `<task_path>`   | `history_path`, `error`                         |

The `target:` field always points at the task — the sentinel is a
mechanism, not the subject (D3).

### The two code paths

**Gate daemon path (`Glorbo.Approvals.Gate`).** When the agent writes
a sentinel and updates the task frontmatter to `status:
pending-approval`, the Filesystem.Watcher fires an event on
`company:<co>:projects`. Gate receives it, `request_approval/2`
indexes the sentinel into `tasks_approval_state`, and reassigns the
task to `director`. Later, when the Director changes the task's
`status:` in the frontmatter (via any editor, CLI, or the UI), the
Watcher fires again; Gate's `resolve_*` functions run the grant or
deny path.

On grant: restore `assigned_to: <agent>`, delete the sentinel, wake
the agent with `trigger: :director_approval`.

On deny: restore `assigned_to: <agent>`, move the task file to
`history/tasks/<task_id>.md` (denied tasks leave the live tree),
delete the sentinel, do NOT wake.

**UI-direct path (`GlorboWeb.Actions.set_approval/4`).** The Director
clicks Approve/Deny on `/companies/<co>/approvals`. `set_approval`
rewrites the task frontmatter directly. The sentinel is looked up via
`lookup_requesting_agent/3` (scan
`agents/*/state/awaiting-approval-<task_id>.md`) to recover the
requester slug for the `assigned_to` restore and the audit payload.
The UI path does NOT move denied tasks to history (that's a
Gate-only side-effect); it does NOT wake the agent on grant either
(the agent will observe `status: approved` on its next scheduled
wake).

Both paths emit audit events with identical JSONL shape (D2).

## Test strategy

The protocol is exercised end-to-end by:

- `test/glorbo/approvals/gate_test.exs` (16 tests) — Gate-path grant,
  deny, concurrent requests, crash recovery, spurious transitions,
  parse errors, traversal rejection, `assigned_to` swap (G2a/G2b).
- `test/glorbo_web/actions_test.exs` (24 tests including 4
  approval-specific) — UI-direct path with and without denial
  reason; `assigned_to` restore on both grant and deny.
- `test/glorbo_web/live/approval_queue_live_test.exs` — dashboard
  rendering, Escape, j/k/y/n.
- `test/glorbo_web/live/approval_queue_integration_test.exs` — E2E
  request → dashboard shows → Approve click → frontmatter +
  sentinel + audit all land.

## Open questions

- **Multi-director approval.** If Glorbo ever grows multiple human
  reviewers, the `director` slug in `assigned_to` needs to become a
  list or a role. A superseding GEP can introduce `requires_approval:
  <role>` with a role registry. Current spec assumes exactly one
  Director per deployment.
- **Delegated approval.** Could a senior agent pre-approve tasks on
  behalf of the Director? The current answer is no — the Director
  literal is hardcoded. A future GEP could extend this.
- **Approval expiry.** A sentinel that sits for 30 days does nothing
  except take up space. Should there be a TTL / stale-prune? Punted.

## Decision log

### D1. `assigned_to` swap during review

- **Decided:** When the agent requests approval, task.assigned_to
  becomes `director`. On grant OR deny, it swings back to the
  requesting agent.
- **Alternatives:** Leave `assigned_to` untouched; add a separate
  `awaiting_review: <agent>` field.
- **Why:** The Kanban reads `assigned_to` to build swim lanes. If the
  value doesn't change during review, the Director's "things I need
  to act on" view has to join against the sentinel tree every render,
  and the agent's lane shows an unowned task. The swap keeps both
  views correct with zero extra queries.

### D2. Both paths emit identical audit JSONL shape

- **Decided:** The UI path uses `target:` (not `task_path:`) and
  `denial_reason:` (not `reason:`). Gate's payloads were aligned to
  this shape in commit 912c991.
- **Alternatives:** Keep the two shapes and teach the audit viewer
  to read both fields.
- **Why:** `target:` is the canonical top-level key in
  `Glorbo.Company.AuditLog` — unknown keys get merged into `detail`.
  Emitting `task_path:` left the record's top-level `target` null,
  so the audit UI row ("what was touched?") rendered blank for every
  Gate-originated event. One field per concept, consistently.

### D3. Sentinel is the mechanism; task_path is the subject

- **Decided:** Audit events name the task (`target:
  projects/.../t-01.md`), not the sentinel
  (`agents/<slug>/state/awaiting-approval-t-01.md`). The sentinel
  can be reconstructed from the audit stream via the (known) agent
  + task_id.
- **Alternatives:** Reference the sentinel path as `target:` because
  it's the file that actually changed.
- **Why:** The human-meaningful object is the task. A Director
  auditing "what approvals did I grant last month?" wants a list of
  tasks, not a list of sentinel paths; the sentinel path is
  operationally derivative.

### D4. UI-direct path does NOT move denied tasks to history

- **Decided:** Only Gate's `resolve_denied` performs the rename into
  `history/tasks/`. `Actions.set_approval(:denied)` rewrites the
  frontmatter and leaves the file in place.
- **Alternatives:** Always move to history regardless of code path;
  never move to history.
- **Why:** The Gate daemon is the authoritative resolver — if it's
  running, it will see the frontmatter change and complete the move.
  The UI-direct path is a fallback for when Gate is down; duplicating
  the history-move there would race with Gate on simultaneous
  resolution. Leaving the file in place is idempotent: a later Gate
  run will do the move once, not twice.

### D5. UI-direct path does NOT wake the agent on grant

- **Decided:** Only Gate's `resolve_granted` calls `safe_wake/4`.
  `Actions.set_approval(:approved)` just rewrites the frontmatter.
- **Alternatives:** Wake from both paths; wake from UI directly via
  `state/wake-request.md`.
- **Why:** The agent's next scheduled wake (heartbeat, inbox
  message, director wake) will observe `status: approved` on the
  task and proceed. Avoiding the wake from UI keeps Gate as the sole
  wake source for this trigger type — one code path to maintain.

## Related

- **GEP-3** — filesystem-as-source-of-truth: sentinels and
  frontmatter are both on disk; the SQLite index is derived.
- **GEP-6** — Phoenix LiveView dashboard: the approval queue is an
  LV that subscribes to `company:<co>:projects`.
- **GEP-14** — heartbeat semantics: `approval.denied` is an event
  the HEARTBEAT.md narrative summarises.
- **GEP-16** — wake + dispatch pipeline: grant triggers a
  `:director_approval` wake.
- `lib/glorbo/approvals/gate.ex` — Gate daemon code.
- `lib/glorbo_web/actions.ex` — `set_approval/4` UI-direct path.
- `lib/glorbo_web/live/approval_queue_live.ex` — dashboard.
