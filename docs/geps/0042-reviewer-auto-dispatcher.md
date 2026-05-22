---
gep: 0042
title: Reviewer auto-dispatcher — close the GEP-41 peer-review loop
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-25
history:
  - date: 2026-04-25
    status: Draft
    note: |
      Initial draft. Extends GEP-41 phase-1 (severity-based gate +
      verdict layer + Kanban pill + chain audit) to actually wake
      the reviewer when the gate fires. Five design questions the
      GEP-41 history flagged as "deferred to a separate design
      exercise" are answered here.
  - date: 2026-04-25
    status: Accepted
    note: |
      Maintainer accepted the design as written — implementation
      starts immediately. D5 (missing-reviewer = stuck task) and
      D2 (write through Actions, not Gate) are the load-bearing
      calls; the rest are mechanical. Open questions in §Open
      questions stay parked until operational data accrues.
  - date: 2026-04-25
    status: Implemented
    note: |
      Phase-3 shipped the same day as Accept. Module touch list:

        * NEW `Glorbo.Actions.Reviews` (`request_peer_review/4`,
          `clear_request_sentinel/4`, `write_revise_feedback/5`).
        * NEW `Glorbo.FileSpec.PeerReviewRequestMd` +
          `Glorbo.FileSpec.PeerReviewFeedbackMd`, registered in
          `Glorbo.FileSpec.@specs`.
        * NEW per-kind doc pages auto-generated under
          `docs/file-formats/`.
        * MODIFIED `Glorbo.Approvals.Gate` —
          `maybe_emit_peer_review_requested/3` now dispatches
          via Actions on the same edge as the existing audit;
          MapSet dedupe is marked only when the dispatch
          succeeds so missing-reviewer cases retry on the next
          observation (D5).
        * MODIFIED `Glorbo.Actions.Tasks.record_peer_review_
          verdict/4` — clears the request sentinel on every
          verdict; `revise` additionally drops a feedback
          sentinel into the original assignee's inbox.

      10 new tests in `Glorbo.Actions.ReviewsTest` (request +
      clear + feedback paths, including the D5 missing-reviewer
      and the symlink-trap pre-flight). Existing
      Gate Round-N-3 dedupe test gained a setup that scaffolds
      `critiqueops` so the dispatch pre-flight passes; the
      dedupe semantics under test are preserved.

      Full suite: 2118 tests, 0 failures, 1 skipped (42
      excluded). Credo: 5104 mods/funs, 0 issues. Format clean.
requires: [2, 19, 36, 40, 41]
extended-by: [51]
see-also: [3, 25]
---

# GEP-42: Reviewer auto-dispatcher

## Problem

GEP-41 phase-1 shipped the *signal* half of peer review:

- `Glorbo.Approvals.Gate` detects when a task has
  `peer_review_required: true` and no recorded verdict.
- It blocks the Director-approval path until a verdict lands.
- It emits a `peer_review.requested` audit event, deduped per
  task-path through a MapSet so re-observations don't spam.
- `Glorbo.Actions.Tasks.record_peer_review_verdict/5` provides the
  verdict-side mutation (`approve` / `revise` / `block`).
- `GlorboWeb.TaskChainLive` renders the audit chain inline.

What's missing is the *action* half: when `peer_review.requested`
fires, **nothing wakes the reviewer.** The audit lands, the task
stays in `pending-approval`, and unless someone manually wakes
CritiqueOps (or the reviewer happens to scan the audit log on its
own cadence), the task sits indefinitely.

In effect, setting `peer_review_required: true` today means *"this
task gets stuck"* rather than *"this task gets reviewed."* That's
a half-feature.

The fix is small in mechanism — drop a sentinel into the reviewer's
inbox and the existing inotify → Watcher → AgentServer wake
pipeline does the rest. The substance of this GEP is the policy
around that drop: file shape, write surface, idempotency, return
path on the verdict, and what happens when the reviewer doesn't
exist.

## Goals

- **Close the loop.** When the gate observes a peer-review
  requirement, the reviewer wakes within one inotify event without
  manual intervention.
- **Reuse the existing wake pipeline.** No new transport, no new
  GenServer for routing. The reviewer's `inbox/` is the seam, same
  as every other agent-wake path.
- **Honest source of truth.** The sentinel is a pointer, not a
  copy. The reviewer reads the original task file; nothing
  duplicates the task body.
- **Respect GEP-36's write discipline.** The actual file write
  lives behind a new `Glorbo.Actions.Reviews` module; the Gate
  calls it. The Gate stays an observer.
- **Round-trip the verdict.** A `revise` verdict drops a feedback
  sentinel into the *original assignee's* inbox so the
  next-pass-and-re-review cycle is symmetric.
- **Fail safe on missing reviewer.** A reviewer that doesn't
  exist on disk = task stays stuck (with a loud audit), not a
  silent review-skip.

## Non-goals

- **No reviewer queue / cadence engine.** Inotify-driven FIFO is
  the queue. At expected scale (~tens of pending reviews per
  director-day) sub-second wake latency is fine. Building a
  scheduler now is premature.
- **No multi-reviewer voting.** GEP-41 D3 stands — single reviewer
  per invocation. If the configured reviewer is wrong, the
  Director re-routes manually.
- **No reviewer hot-swap mid-task.** The reviewer slug is read
  from the task's `reviewer:` field (or the company default) at
  request time and never re-resolved. Reassigning mid-review is
  a Director action, not an automatic feature.
- **No web UI for the sentinel.** The chain audit view already
  surfaces `peer_review.requested` events with reviewer + severity
  detail. The sentinel itself is a routing artifact, not Director
  UX.
- **No automatic reviewer-absent fallback.** A missing reviewer
  surfaces as a stuck task with an explicit audit; the Director
  resolves it (scaffold the reviewer, or unset
  `peer_review_required:`, or override via the approval gate).
  Auto-skipping is exfiltration-shaped — see D5.

## Design

### Trigger surface

`Glorbo.Approvals.Gate` already maintains
`peer_review_requested :: MapSet.t(String.t())` keyed by absolute
task path, populated when the gate first observes the
reviewer-blocked state. Phase-1 uses this MapSet purely to dedupe
the audit emit. Phase-3 adds a single side-effect on the same
edge: call `Glorbo.Actions.Reviews.request_peer_review/3`.

```elixir
# inside Gate.handle_request_status when reviewer-required blocks
unless MapSet.member?(state.peer_review_requested, abs_path) do
  emit_peer_review_requested_audit(state, abs_path, task)
  Reviews.request_peer_review(company, abs_path, task)
end
```

The MapSet entry is added *after* both calls succeed, so a Gate
restart between the audit and the inbox-write retries the
dispatch. (See §Failure modes for the full state-machine.)

### `Glorbo.Actions.Reviews`

New module under `lib/glorbo/actions/reviews.ex`, sibling to
`Actions.Tasks`. Single public function in phase-3:

```elixir
@spec request_peer_review(
        company :: String.t(),
        task_abs_path :: Path.t(),
        task :: TaskDefinition.t(),
        opts :: keyword()
      ) ::
        {:ok, %{sentinel_path: Path.t(), reviewer: String.t()}}
        | {:error, :reviewer_absent}
        | {:error, :inbox_unwritable}
        | {:error, term()}
```

The function:

1. Resolves the reviewer slug: `task.reviewer || "critiqueops"`
   (matching GEP-41 D2's default).
2. Pre-flight: refuse if `<base>/companies/<co>/agents/<reviewer>/
   agent.md` doesn't exist, OR the reviewer's `inbox/` directory
   isn't a writable regular directory (lstat against symlink
   trap, same pattern as `Actions.Agents.write_workspace_file`).
3. Composes the sentinel content (see §Sentinel shape).
4. Writes atomically (tmp + rename) to
   `<base>/companies/<co>/agents/<reviewer>/inbox/peer-review-
   <task-id>.md`. Filename is deterministic, so a duplicate
   call overwrites in place — no inbox accumulation.
5. Emits `peer_review.dispatched` audit with `reviewer`,
   `task_path`, `severity`, `requesting_agent` keys.

Errors:

- `:reviewer_absent` — pre-flight failed; the Gate logs +
  emits `peer_review.skipped_no_reviewer`. The MapSet entry is
  NOT added, so the next gate observation tries again (covers
  the case where the reviewer is scaffolded mid-flight).
- `:inbox_unwritable` — disk full, permission flip, the inbox
  was replaced with a symlink. Same retry posture.
- Other errors propagate unchanged.

### Sentinel shape

New file kind: `peer-review-request/v1`. FileSpec module
`Glorbo.FileSpec.PeerReviewRequestMd` registered with the
validator (GEP-25 R26.2b discipline).

Path: `<base>/companies/<co>/agents/<reviewer>/inbox/
peer-review-<task-id>.md`

Frontmatter:

```yaml
---
kind: peer-review-request/v1
task_path: projects/<project>/tasks/<task-id>.md
task_id: <task-id>
requesting_agent: <slug-of-current-assignee>
severity: minor | major | critical
requested_at: <ISO-8601 UTC>
reviewer: <slug>          # whoever the dispatcher resolved (logs the
                          # decision; agent doesn't strictly need it)
---

# Peer review: <task title>

You're being asked to review this task before Director approval.

Read the original task file at `<task_path>` (relative to the
company root) and produce a verdict using your standard
critiqueops/reviewer reply contract:

    VERDICT: approve | revise | block
    NOTE: <free text — required for revise / block>

The verdict file lands in your outbox; the Router routes it
through `Actions.Tasks.record_peer_review_verdict/4` and the
sentinel here gets cleared.
```

The body is verbatim instruction — agents can read it directly.
The `kind:` discriminator means `Glorbo.FileSpec.classify_by_path`
routes it through the new module's validator without ambiguity
against generic inbox messages.

The sentinel is **deleted on verdict** (see §Verdict return
path), so a follow-up `revise → engineer revises → status flips
back to pending-approval` cycle re-fires the gate, which
re-creates a fresh sentinel. Re-review happens automatically and
without per-cycle special-casing.

### Verdict return path

`Actions.Tasks.record_peer_review_verdict/5` already handles the
verdict file → frontmatter mutation. Phase-3 extends it with two
side-effects:

```elixir
case verdict do
  "approve" ->
    delete_review_sentinel(company, reviewer, task_id)
    # status stays "pending-approval"; Director takes over via
    # the existing approval pipeline.

  "revise" ->
    delete_review_sentinel(company, reviewer, task_id)
    write_revise_feedback(
      company,
      original_assignee,
      task_id,
      note
    )
    # status flips to "in-progress" (existing behaviour).
    # The feedback sentinel wakes the original assignee.

  "block" ->
    delete_review_sentinel(company, reviewer, task_id)
    # status flips to "denied" (existing behaviour). No further
    # routing — Director sees a blocked task in the kanban
    # `denied` column.
end
```

The revise feedback sentinel is its own kind:
`peer-review-feedback/v1`. Path:
`<base>/companies/<co>/agents/<original-assignee>/inbox/
peer-review-feedback-<task-id>.md`. Frontmatter carries the
verdict note + reviewer slug + back-pointer to the task file.
Body is a templated "your task got bounced — see notes, fix,
re-submit" message.

The sentinel deletes are best-effort: if the file is already
gone, that's fine; if it's there but disk is unwritable, log a
warning and proceed. The verdict frontmatter is the canonical
state — sentinels are wake triggers, not source of truth.

### Audit events added

| Action | Detail keys |
|---|---|
| `peer_review.dispatched` | `reviewer`, `task_path`, `severity`, `requesting_agent` |
| `peer_review.skipped_no_reviewer` | `reviewer_slug`, `task_path`, `reason` |
| `peer_review.feedback_sent` | `to_agent`, `task_path`, `note_bytes` |

`peer_review.requested` (existing) stays as-is — it fires before
the dispatch attempt and represents the *gate observation*, not
the dispatch outcome.

### Configuration surface

None. The reviewer slug is per-task (`reviewer:` frontmatter)
with a hardcoded company-wide fallback to `critiqueops`. There
is intentionally no global "auto-dispatch enabled" config —
shipping the gate without auto-dispatch has been the half-feature
state we're closing. Either GEP-41 + GEP-42 are both active, or
neither. Operators who want to opt out remove `peer_review_
required:` from individual tasks (or the company-default).

### Module touch list

- **New:** `lib/glorbo/actions/reviews.ex` (~80 LOC).
- **New:** `lib/glorbo/file_spec/peer_review_request_md.ex`
  (~40 LOC).
- **New:** `lib/glorbo/file_spec/peer_review_feedback_md.ex`
  (~40 LOC).
- **Modified:** `lib/glorbo/approvals/gate.ex` — call
  `Reviews.request_peer_review/3` on the same edge as the
  existing audit emit.
- **Modified:** `lib/glorbo/actions/tasks.ex` — verdict path
  deletes sentinel + writes feedback for `revise`.
- **Modified:** `lib/glorbo/file_spec.ex` — register the two
  new kinds in `classify_by_path/1`.

## Migration / rollout

Pre-1.0 atomic cut, consistent with GEP-41 phase-1's posture:

- `peer_review_required: true` tasks created BEFORE this GEP
  ships were stuck. After: they auto-dispatch on the next gate
  observation (which fires on every task status flip + every
  inotify event the gate consumes).
- The new file kinds (`peer-review-request/v1`,
  `peer-review-feedback/v1`) are opt-in by code path — no
  existing files match these paths.
- The new audits are additive — no existing audit consumer
  expects them to be absent.
- No config flag, no soft-migration period. Consistent with
  the user's pre-1.0 stance.

Rollout list:

1. FileSpec modules + classifier registration. (No callers yet.)
2. `Actions.Reviews.request_peer_review/3`. (No callers yet.)
3. Gate hook — wires (1) + (2) into the existing
   `peer_review.requested` edge.
4. Verdict-side sentinel cleanup + revise feedback write.
5. CHANGELOG + GEP-41 history note pointing at this GEP +
   GEP-42 status flip to `Implemented` once 1–4 land.

## Failure modes

| Failure | Surface | Recovery |
|---|---|---|
| Reviewer agent.md missing | `peer_review.skipped_no_reviewer` audit; task stays in `pending-approval`; MapSet entry NOT recorded so the next gate tick retries | Director scaffolds the reviewer or overrides the gate manually |
| Reviewer inbox/ replaced with a symlink | `:inbox_unwritable` from `Actions.Reviews`; same audit + non-record posture | Director restores the directory |
| Gate restarts between audit emit and sentinel write | MapSet is in-memory, rebuilt from on-disk state on init; the rebuild marks the task as already-requested only if the sentinel exists or the task has a verdict already | Restart safely re-fires the dispatch on the next observation |
| Reviewer's inbox dispatches but reviewer never produces a verdict | Existing `LoopDetector` covers the chain — three failed dispatches against the same task → stuck sentinel → Director ping | Same as today |
| Sentinel write succeeds but the reviewer's AgentServer is down | inotify event fires when the server boots; PubSub subscription replays no missed events but the on-boot inbox scan picks up the file | Same as inbox-driven wake (GEP-14) |
| Two concurrent gate ticks race on the MapSet | The atomic write makes the on-disk side a no-op overwrite; the MapSet `MapSet.put/2` is idempotent; at worst we emit two audit events for the same observation | Acceptable; a Phase-2 follow-up could move the MapSet update inside the lock if observed |

## Test strategy

- **Unit (`Actions.Reviews`):**
  - `request_peer_review/3` writes the sentinel at the canonical
    path with the canonical frontmatter
  - Pre-flight refusal when reviewer agent.md is absent
  - Pre-flight refusal when reviewer inbox is a symlink
  - Atomic write semantics (tmp + rename leaves no .tmp on
    failure)
  - Audit event emitted with all required keys
- **Unit (`FileSpec.PeerReviewRequestMd` /
  `PeerReviewFeedbackMd`):** golden fixtures for parse +
  validate, kind discriminator routing.
- **Unit (`Approvals.Gate`):** stub `Reviews.request_peer_
  review/3` to capture calls; assert it fires once per task on
  the same edge as the existing audit, no firing when a verdict
  is already recorded, retries when pre-flight fails.
- **Unit (`Actions.Tasks.record_peer_review_verdict`):**
  - `approve` deletes the request sentinel
  - `revise` deletes the request sentinel + writes the feedback
    sentinel into the original assignee's inbox
  - `block` deletes the request sentinel; no feedback sentinel
- **E2E:** seed a task with `peer_review_required: true`, fire
  the gate, observe the reviewer's inbox gains the sentinel,
  simulate a `revise` outbox message from the reviewer, observe
  the original assignee's inbox gains the feedback sentinel,
  observe both audit events landed in the JSONL.

No live-LLM tests required — this layer is pure routing.

## Open questions

- **Should the `peer-review-feedback/v1` sentinel itself wake the
  agent on every dispatch, or fold into the agent's normal inbox
  cadence?** Current draft: same as any other inbox file — fires
  the wake. If the agent is mid-task this could be noisy. Phase-2
  follow-up: maybe gate feedback delivery on agent idle. For now,
  inotify-driven is fine.
- **What happens if the reviewer issues `revise` without a note?**
  Current `record_peer_review_verdict/5` already requires a note
  for revise/block. The feedback sentinel inherits that — no note
  means the verdict doesn't land, so the sentinel doesn't get
  written. Self-resolving via the existing validation.
- **Should `peer_review.requested` and `peer_review.dispatched`
  collapse?** They fire on the same edge under the happy path.
  Keeping them separate makes it possible to observe a gate
  observation that *failed to dispatch* (reviewer absent) — that
  signal is lost if we collapse. Voting to keep them separate;
  worth a re-look once we have a few weeks of operational data.

## Decision log

### D1. Sentinel is a pointer, not a prompt copy

**Decided:** the `peer-review-request/v1` sentinel carries
`task_path`, not the task's prompt body or frontmatter. The
reviewer reads the original file via the path.

**Alternatives considered:**

- **Copy the prompt into the sentinel.** Self-contained, no
  cross-file lookups for the reviewer.
- **Reassign the task** — flip `assigned_to:` to the reviewer,
  let the existing inbox-scan find it.

**Why:** copying the prompt creates two copies of the same
truth. If the engineer edits the task between dispatch and
review, the reviewer would see stale content. Reassigning is
worse — it requires an automatic *un-reassign* on the verdict
path, adds a handoff_chain entry per cycle (so a revise loop
spams the chain), and confuses GEP-40's "chain shows
hand-off intent" semantics. Pointer-style keeps the chain
unchanged and the source-of-truth invariant intact.

### D2. Write through `Actions.Reviews`, not `Approvals.Gate`

**Decided:** the sentinel-writing function lives in a new
`Glorbo.Actions.Reviews` module. The Gate calls it.

**Alternatives considered:**

- **Inline write in `Gate.handle_request_status`.** One less
  module, one fewer indirection.

**Why:** GEP-36's "Actions is the single Director-write channel"
discipline. The Gate is an observer (parses task frontmatter,
emits audits, manages the in-memory dedupe set). Adding a write
surface to it crosses the boundary the GEP-36 cleanup arc just
finished drawing. Even though the Gate already writes
`approval_resolution/v1` sentinels — that predates GEP-36 and is
a known callout, not a precedent. New write surfaces go through
Actions.

### D3. Sentinel filename is deterministic; idempotency by overwrite

**Decided:** filename is `peer-review-<task-id>.md`. Two
dispatch calls for the same task overwrite the same file with
identical content; no accumulation.

**Alternatives considered:**

- **Timestamp-suffixed filenames** (`peer-review-<task-id>-
  <ts>.md`) — naturally append-only, easy to audit how many
  dispatches fired.
- **Mutex on the Gate's MapSet** — guarantee single-write per
  observation, no overwrite needed.

**Why:** timestamp-suffixed accumulates files even on the happy
path (one per re-review cycle), and the chain audit view already
gives you the dispatch history through `peer_review.dispatched`
audits. Mutex is overkill — overwrite is naturally idempotent
and the cost of a redundant atomic write is trivial. The
sentinel-deleted-on-verdict pattern means the sentinel's
*presence* is "review pending"; that's the meaningful state.

### D4. `revise` routes feedback sentinel to original assignee

**Decided:** when the verdict is `revise`, drop a
`peer-review-feedback-<task-id>.md` sentinel into the *original
assignee's* inbox (not the Director's). The sentinel carries the
reviewer's note.

**Alternatives considered:**

- **Director-mediated revise** — feedback lands in the Director's
  approval queue; Director decides whether to bounce back to the
  engineer or accept.
- **No automatic feedback delivery** — verdict updates frontmatter,
  engineer notices on their next status check.

**Why:** the whole point of the auto-dispatcher is keeping the
loop closed without Director intervention on the happy path.
Director-mediated revise reintroduces manual routing for the
common case ("reviewer says fix line 47" doesn't need Director
adjudication). Pure-frontmatter delivery loses the wake — the
engineer might not notice for hours. Inbox sentinel is the
existing wake mechanism; reusing it is cheap and consistent.

### D5. Missing reviewer = stuck task, not silent skip

**Decided:** if the reviewer's `agent.md` is missing or the
reviewer's inbox is unwritable, the dispatch fails, the audit
records the skip *with reason*, the gate's MapSet is NOT marked
(so subsequent observations retry), and the task stays in
`pending-approval`. Director must intervene.

**Alternatives considered:**

- **Auto-skip with `peer_review.skipped_no_reviewer` audit** —
  if the reviewer doesn't exist, treat it as if no review were
  required and let the Director-approval gate handle it.
- **Auto-fallback to a different reviewer** — try a config-listed
  alternate (e.g., `provenance-auditor` if `critiqueops` is
  absent).

**Why:** auto-skip is exfiltration-shaped. An attacker (or a
careless operator) who deletes the reviewer's `agent.md` would
silently bypass review for every subsequent task. Auto-fallback
is better than auto-skip but introduces "which reviewer reviewed
this?" ambiguity that GEP-41 D3 explicitly rejected.
Failing-loud-and-stuck is the conservative choice and matches
the project's general "no fallback that lowers the security bar"
stance. The Director sees an explicit audit and an obviously
stuck task — the failure is unmissable.

### D6. Re-review on `revise` is automatic

**Decided:** when the engineer revises a task and flips status
back to `pending-approval`, the gate observes the requirement
again, the MapSet is empty (cleared when the verdict landed), so
a fresh request sentinel gets dispatched. No special-casing.

**Alternatives considered:**

- **Skip second review** — once revised, trust the engineer.
- **Configurable re-review depth** — let the company.md set
  "max review iterations" and skip after N.

**Why:** skipping the second review means an engineer who didn't
actually address the notes can shovel a broken task past the
gate by toggling status. Configurable depth adds policy surface
that doesn't yet have a use case. Treating each
`pending-approval` flip as a fresh observation is consistent
with how the rest of the gate works and falls out of the MapSet
cleanup — no new logic.

### D7. No reviewer queue / cadence engine

**Decided:** the reviewer's `inbox/` IS the queue. Inotify-driven
FIFO is the cadence. No new `Glorbo.Reviews.Queue` GenServer.

**Alternatives considered:**

- **Per-reviewer queue with rate limits** — protect a busy
  reviewer from getting buried under simultaneous requests.

**Why:** at expected scale (single-user instances, tens of
concurrent tasks at most), the reviewer's inbox accumulating ~5
sentinels in a busy minute is fine. The reviewer wakes, reviews
the oldest one, the dispatch task picks the next one on the
next inotify event. A cadence engine adds latency, monitoring
surface, and a new failure mode (queue stuck) for a problem we
don't have. If the reviewer can't keep up, the right answer is
fewer auto-reviews, not a smarter queue.

## Related

- **GEP-41** — peer-review gate; this GEP closes its phase-3
  deferral. `requires: [41]`. GEP-41 history will gain a note
  pointing here once GEP-42 is Accepted.
- **GEP-40** — task chain observability; the `peer_review.
  dispatched` + `peer_review.feedback_sent` events render
  inline in `TaskChainLive` via the existing `peer_review_*`
  filter, no view change needed.
- **GEP-36** — Actions as single Director-write channel; D2
  honours that boundary.
- **GEP-25** — file format specs; the two new sentinel kinds
  follow the `kind: <name>/v1` discriminator pattern.
- **GEP-19** — Director approval workflow; peer-review runs
  before Director approval (GEP-41 D5), so the dispatcher
  fires before the Director ever sees the task in their queue.
- **GEP-3** — filesystem as source of truth; D1's pointer-not-
  copy choice exists to honour this invariant.
