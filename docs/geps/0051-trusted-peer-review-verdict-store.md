---
gep: 0051
title: Trusted peer-review verdict store — derive provenance from the audit log
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Draft
type: Standards
created: 2026-05-22
requires: [41, 42]
see-also: [19, 33, 34, 36]
history:
  - date: 2026-05-22
    status: Draft
    note: |
      Initial draft. Captures the gate-trust cluster (findings C-061,
      C-064, C-066): the peer-review gate trusts verdict fields in
      agent-writable task frontmatter. Codex confirmed a frontmatter-only
      cross-check is insufficient; the gate must consult a trusted record.
---

# GEP-0051: Trusted peer-review verdict store — derive provenance from the audit log

## Problem

GEP-41's peer-review gate decides whether approval-gated work may proceed
by reading `peer_review_verdict` (and friends) from the **task
markdown's frontmatter**. But agents granted `tasks:update:<project>`
receive a **read-write bind mount** of the project's `tasks/` directory
(`lib/glorbo/sandbox/permission_mapper.ex`), so an agent can write those
fields directly — never touching the reviewer-guarded
`Actions.Tasks.record_peer_review_verdict/5` path that *does* enforce a
reviewer-identity check.

Three findings, one root cause (the gate trusts agent-mutable
frontmatter as authoritative for review state):

- **C-066 (gate trusts mutable frontmatter — core finding).**
  `Glorbo.Approvals.Gate.peer_review_ready?/1` returns `:ok` on
  `peer_review_verdict: "approve"` alone. It does **not** check
  `peer_review_verdict_by`, does not require it to equal the configured
  `reviewer`, and does not consult any audit record. An agent forges
  `peer_review_verdict: approve` (or removes `peer_review_required`) on a
  task awaiting approval; when the Director then performs a *legitimate*
  approval, the consumed director-mark makes the transition trusted and
  `resolve_granted/3` wakes the agent — though **no reviewer ever acted**.
- **C-061 (forged `block` short-circuit).** A `resolve_status/3` clause
  returns immediately on `status: denied` + `peer_review_verdict:
  block`, *before* director-mark consumption and revert. An agent forges
  both fields to impersonate the reviewer and permanently block/hide
  work with no audit and no revert.
- **C-064 (audit-dedupe abuse).** Both the `peer_review.requested` emit
  edge and the dedupe-clear edge are driven solely by frontmatter. An
  agent cycles `peer_review_required: true / verdict: nil` ↔ any verdict
  string to re-emit unbounded `actor: system` audit rows (audit-trail
  pollution + storage/availability DoS), and spam the reviewer inbox.

Codex's verdict across the cluster: a frontmatter-only cross-check
(even "require `peer_review_verdict_by == reviewer`") is insufficient —
the agent writes *both* the verdict **and** the claimed author into the
same writable file, so any field-vs-field comparison the agent can also
forge is not a trust boundary.

The fix is structural: **verdict provenance must come from a record the
agent cannot write.** The gate must consult that trusted record and
treat frontmatter as a non-authoritative cache.

## Goals

- The gate's "has this task passed peer review?" decision derives from a
  **trusted record the agent cannot write** — the append-only audit log
  (or a gate-owned sentinel outside the task file).
- A forged `peer_review_verdict` / `peer_review_verdict_by` /
  `peer_review_required` in task frontmatter has **no effect** on the
  gate decision (it may at most be a display cache that the gate
  overrides).
- The forged-`block` short-circuit (C-061) requires a trusted
  reviewer-authored block; otherwise the unauthorised status change is
  reverted and audited.
- `peer_review.requested` emission + dedupe (C-064) are tied to a
  trusted state transition, not to frontmatter cycling.
- The trusted record survives `glorbo reindex` (GEP-34) — it is
  rebuildable from the audit log, consistent with filesystem-as-source-
  of-truth.

## Non-goals

- **No change to the peer-review *workflow*** (GEP-41 severity tiers,
  GEP-42 reviewer auto-dispatch). This GEP changes *where the gate reads
  the verdict from*, not when review is required or who reviews.
- **No removal of the `tasks:update` RW bind mount.** Agents legitimately
  edit task bodies; the fix is to stop *trusting* the review fields, not
  to revoke write access.
- **No new reviewer-authentication mechanism.** Reviewer identity is
  already established by the Router-authenticated
  `record_peer_review_verdict/5` path (GEP-36); this GEP consumes its
  output, it doesn't re-invent it.
- **No retroactive re-verification of historically-approved tasks.**

## Design

### The trusted record: audit-log peer-review events

`record_peer_review_verdict/5` is the **only** Router-authenticated path
that records a verdict, and it already enforces
`guard_actor_is_reviewer/2` (`lib/glorbo/actions/tasks.ex`). This GEP
makes that path emit an **append-only audit event** that is the
authoritative verdict record:

```
task.peer_review.<verdict>          # verdict ∈ approve | revise | block
  actor:   <Router-authenticated reviewer slug>   # NOT agent-writable
  task_id: <project-prefixed id>
  reviewer_required: <true|false captured at request time>
  ts:      <append-only timestamp>
```

The audit log is append-only by crown-jewel invariant — an agent has no
write path to `audit/YYYY-MM.jsonl`. `actor` is stamped by the Router
from the authenticated caller, not copied from frontmatter. So
`{task_id → latest trusted verdict + reviewer}` is derivable from a
source the agent cannot forge.

### Gate consults the trusted record (frontmatter is a cache)

`Glorbo.Approvals.Gate` gains a trusted lookup —
`trusted_verdict(task_id)` — backed by the derived index (below). The
gate's three decision points change:

1. **`peer_review_ready?/1` (C-066).** Instead of matching
   `peer_review_verdict: "approve"` from the parsed `TaskDefinition`,
   require:
   - a trusted `task.peer_review.approve` event for this task whose
     `actor == effective_reviewer(td.reviewer)`, **and**
   - the `reviewer_required` captured at request time is satisfied.
   Frontmatter `peer_review_verdict` is ignored for the decision (it may
   be shown in the UI as a cache, reconciled from the trusted record).
   Absent a trusted approve → `:awaiting_peer_review`, so a later
   director approval does **not** wake unreviewed work.

2. **Forged-`block` short-circuit (C-061).** The
   `status: denied`+`peer_review_verdict: block` clause runs only if a
   trusted `task.peer_review.block` event from the reviewer exists.
   Without it, the frontmatter `block` is treated as an unauthorised
   status change → falls through to `revert_unauthorised_status/5` +
   a new `approval.forged_block_rejected` audit (instead of silently
   returning `state` unchanged).

3. **`peer_review.requested` emit + dedupe (C-064).** Emission and
   dedupe-clear key on a **trusted approval-state transition**, not
   frontmatter:
   - emit `peer_review.requested` when the task first *enters*
     `awaiting`-approval review state (a gate-owned transition), recorded
     so a frontmatter cycle can't re-trigger it;
   - clear the dedupe entry only when a *trusted* verdict event arrives,
     not when an agent writes a verdict string.
   The dedupe set is no longer cleared by an agent-writable field, so
   the cycle that drives unbounded `actor: system` rows is closed.

### Gate-owned sentinel (alternative / complement)

For state the gate must consult cheaply at file-event time without an
audit replay, the gate may keep a **gate-owned record outside the task
file** — e.g. `companies/<co>/state/peer-review/<task_id>.json` written
only by the Router/Actions layer, never bind-mounted writable into any
agent sandbox. This is the same shape as other gate-owned state
(GEP-43 derived state). It is a *cache of the trusted audit record*, not
an independent source — see D3. Either the audit log alone or the audit
log + sentinel cache satisfies the goal; the sentinel is a performance
detail, the audit log is the source of truth.

### Reindex / rebuild-from-audit (GEP-34)

The trusted verdict index is **derived state**, so it obeys
filesystem-as-source-of-truth:

- `glorbo reindex` rebuilds `{task_id → trusted verdict + reviewer}` by
  replaying `task.peer_review.<verdict>` events from `audit/*.jsonl`,
  taking the latest per task.
- Any gate-owned sentinel cache is rebuilt from the same replay; if the
  sentinel disagrees with the audit log, the audit log wins (it is
  append-only and authoritative).
- Frontmatter `peer_review_verdict` is **not** consulted during reindex
  for trust purposes — at most it is reconciled *to* match the trusted
  record (so the UI cache is correct), never the other way.

This keeps the audit log as the single rebuild source and means a
restored backup or a `reindex` cannot resurrect a forged verdict: there
is no forged-verdict audit event, because the agent can't write the
audit log.

## Migration / rollout

- **Pre-1.0, no kid gloves.** The gate stops trusting frontmatter
  verdicts outright; no dual-read window.
- Tasks currently `awaiting` approval with a frontmatter-only verdict and
  **no** corresponding trusted audit event become `:awaiting_peer_review`
  on the next file event — the reviewer must (re-)record the verdict via
  the guarded path. Acceptable: a frontmatter-only verdict was never a
  valid review under this model.
- `record_peer_review_verdict/5` starts emitting the
  `task.peer_review.<verdict>` audit event (additive). GEP-42's
  auto-dispatcher already routes through this path, so the trusted event
  is produced for the normal flow with no agent-facing change.
- One reindex after upgrade builds the initial trusted index.

## Failure modes

| Failure | Surface |
|---|---|
| Agent forges `peer_review_verdict: approve` | gate ignores it; no trusted event → `:awaiting_peer_review`; director approval does not wake (C-066 closed) |
| Agent forges `status: denied`+`verdict: block` | no trusted block event → `revert_unauthorised_status/5` + `approval.forged_block_rejected` audit (C-061 closed) |
| Agent cycles frontmatter to spam `peer_review.requested` | emit keyed on gate-owned transition, dedupe cleared only by trusted verdict → no unbounded `actor: system` rows (C-064 closed) |
| Audit log file missing/corrupt for a month | reindex skips unreadable shards (GEP-34); trusted index reflects what's readable; gate fails closed (`:awaiting_peer_review`) for tasks whose verdict event is unreadable |
| Reviewer slug changes after a verdict was recorded | trusted event retains the historical `actor`; `effective_reviewer` resolution must handle reassignment (open question) |
| Sentinel cache stale vs audit log | audit log wins on reindex; sentinel rebuilt from replay |

## Test strategy

- **Unit** (`Gate.peer_review_ready?`): frontmatter `approve` with no
  trusted event → `:awaiting_peer_review`; trusted approve from the
  reviewer → `:ok`; trusted approve from a *non*-reviewer actor →
  rejected.
- **Unit** (forged block): `denied`+`block` with no trusted block event
  → revert + `approval.forged_block_rejected` audit.
- **Unit** (C-064): frontmatter verdict cycling emits at most one
  `peer_review.requested`; dedupe cleared only by a trusted verdict
  event.
- **Integration** (`record_peer_review_verdict/5`): reviewer-guarded
  path emits `task.peer_review.<verdict>` with Router-stamped `actor`.
- **Integration** (reindex, GEP-34): trusted index rebuilt from audit
  replay; a task with frontmatter-only forged verdict is *not* trusted
  after reindex.
- **E2E (local):** agent edits task frontmatter to `approve`; director
  approves; agent is **not** woken (no trusted verdict) — the regression
  this whole GEP exists to prevent.

## Open questions

- **Reviewer reassignment.** If `td.reviewer` changes after a verdict
  was recorded, does an old trusted verdict from the *previous* reviewer
  still satisfy the gate? Leaning "verdict valid if `actor` was the
  effective reviewer *at verdict time*"; needs the request-time capture
  to record the then-current reviewer.
- **Sentinel vs pure-audit-replay on the hot path.** Is per-file-event
  audit replay cheap enough (GEP-43 ETS-cached) or is the gate-owned
  sentinel mandatory for performance? Implementation call.
- **Capturing `peer_review_required` at request time.** Where is the
  request-time snapshot stored so a later frontmatter edit can't relax
  it — in the same trusted record? (C-066 notes this; leaning yes.)

## Decision log

### D1. Verdict provenance comes from a trusted record, not frontmatter

- **Decided:** the gate derives "passed peer review?" from the
  append-only audit log's `task.peer_review.<verdict>` events (whose
  `actor` is the Router-authenticated reviewer), treating task
  frontmatter as a non-authoritative display cache.
- **Alternatives:** keep reading frontmatter but add a
  `peer_review_verdict_by == reviewer` cross-check (codex's first
  suggestion).
- **Why:** codex confirmed the cross-check is insufficient — the agent
  writes *both* the verdict and the claimed author into the same RW
  task file, so any field-vs-field comparison is itself forgeable. Only
  a record the agent has no write path to (the append-only audit log) is
  a real trust boundary. Root-cause fix for C-061/C-064/C-066.

### D2. Reuse the existing reviewer-guarded path as the trusted-event emitter

- **Decided:** `record_peer_review_verdict/5` (already
  reviewer-guarded, GEP-36/Router-authenticated) emits the
  `task.peer_review.<verdict>` audit event; the gate consumes it.
- **Alternatives:** add a new verdict-recording API; have the gate
  re-authenticate the reviewer itself.
- **Why:** the guarded path is the single legitimate verdict channel
  already; emitting an audit event there is additive and keeps one
  write locus. Re-authenticating in the gate duplicates trust logic.

### D3. Audit log is the source of truth; any sentinel is a derived cache

- **Decided:** if a gate-owned sentinel file is introduced for hot-path
  reads, it is a *cache* of the audit-derived record; on disagreement
  (e.g. after restore/reindex) the audit log wins.
- **Alternatives:** make the sentinel the primary store; make
  frontmatter the cache-of-record.
- **Why:** the append-only audit log already obeys
  filesystem-as-source-of-truth and is rebuildable (GEP-34). A second
  independent primary store would create a reconciliation problem and a
  second thing to keep agents away from. One source of truth, optional
  cache.

### D4. Forged block falls through to revert + audit, not silent accept

- **Decided:** `status: denied`+`peer_review_verdict: block` without a
  trusted block event is reverted via `revert_unauthorised_status/5` and
  audited as `approval.forged_block_rejected`.
- **Alternatives:** keep the early-return clause but gate it on
  frontmatter `peer_review_verdict_by` (forgeable); drop the
  short-circuit entirely.
- **Why:** C-061 — the silent early-return both impersonates the
  reviewer and evades the revert/audit. Routing an untrusted block
  through the existing revert path makes the forgery loud and
  recoverable, consistent with the H4 self-approval guard.

### D5. Trusted index is derived state, rebuilt by reindex from audit replay

- **Decided:** `{task_id → trusted verdict + reviewer}` is derived from
  `audit/*.jsonl` and rebuilt by `glorbo reindex` (GEP-34).
- **Alternatives:** store the verdict only in SQLite as primary; store
  it in the task frontmatter (status quo).
- **Why:** derived-from-audit means a forged frontmatter verdict can
  never survive a rebuild (there's no forged audit event), and the model
  stays consistent with filesystem-as-source-of-truth + SQLite-as-derived.

## Related

- GEP-41 — Agent peer-review gate (severity-based) — the gate this GEP
  hardens.
- GEP-42 — Reviewer auto-dispatcher (already routes verdicts through the
  guarded path).
- GEP-19 — Director approval workflow (the director-mark consumption the
  forged verdict rides on).
- GEP-34 — Reindex v2 (rebuild-from-audit; the trusted index is rebuilt
  here).
- GEP-36 — Actions layer as single Director-write channel (the
  Router-authenticated `record_peer_review_verdict/5` path).
- GEP-43 — ETS-first derived state (candidate cache for the trusted
  index on the hot path).
- Findings C-061 (forged block), C-064 (audit-dedupe abuse), C-066
  (gate trusts mutable frontmatter — core). See also D-166 (verdict
  append-only check is racy) for an adjacent gate concern.

## Implementation reconciliation (2026-06-14)

Append-only record per GEP-1 (an Accepted/Implemented GEP's body is not rewritten; reconciliation against shipped code is logged here, not by editing the sections above). Note: GEP-0051 is still **Draft**, so this is a scoping/accuracy correction rather than a record of shipped deviation.

- **C-066 — "gate does not consult any audit record" (Problem §, lines 36-44): partly stale → corrected-ref.** The GEP says `Glorbo.Approvals.Gate.peer_review_ready?/1` honours `peer_review_verdict: "approve"` alone and "does not consult any audit record." That is no longer true: the shipped approve clause at `lib/glorbo/approvals/gate.ex:592-604` calls `peer_review_verdict_corroborated?/2`, which at `gate.ex:634-654` scans `audit/*.jsonl` (via `Glorbo.Audit.Query.for_task/4`, current + previous UTC month) for a `task.peer_review.approve` row whose `actor` matches `peer_review_verdict_by` and whose `target` matches the task — GEP-41 D8's corroboration, added after this GEP was drafted (2026-05-22). The genuinely-open residue, which GEP-0051 should be re-scoped to, is that corroboration still keys on the agent-writable `peer_review_verdict_by` frontmatter field (`gate.ex:635`) rather than resolving the trusted/configured reviewer, and `peer_review_required` is read from frontmatter, not a request-time trusted snapshot.

- **C-061 — forged-block silent short-circuit: still live → known-gap (the gap this Draft exists to close).** Confirmed in current code: `gate.ex:436-442` unconditionally returns `state` for `%TaskDefinition{status: "denied", peer_review_verdict: "block"}` — no corroboration, asymmetric to the approve path at `gate.ex:592`. An agent with `tasks:update` RW (granted per GEP-0051 §Problem) can set both fields to permanently block/hide work with no revert and no audit. The behavior is pinned by the regression test at `test/glorbo/approvals/gate_test.exs:1166` ("denied + peer_review_verdict: block does NOT revert to awaiting"), which was written to preserve a legitimate reviewer block (GEP-41 D4 / codex P2) and currently cannot distinguish a forged block from a real one. No action unless GEP-0051 is promoted; when implemented, the block clause must gain a corroboration check symmetric to the approve path (D4: fall through to `revert_unauthorised_status/5` + `approval.forged_block_rejected` audit), and the gate_test.exs:1166 expectation must be updated to require a trusted `task.peer_review.block` audit event.
