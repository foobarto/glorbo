---
gep: 0041
title: "Agent peer-review gate — severity-based + opt-in escalation"
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Draft
    note: |
      Initial draft. Crown-jewels phase-1 scope per maintainer
      directive (2026-04-24). Depends on GEP-40 for the
      `severity:` + `peer_review_required:` frontmatter fields;
      see that GEP for schema context. Maintainer's design
      brief: severity-based automatic trigger with optional
      agent self-request ("peer review please"), using the
      existing CritiqueOps role as the reviewer.
  - date: 2026-04-24
    status: Accepted
    note: |
      Accepted as part of the crown-jewels phase-1 bundle (with
      GEP-36 + GEP-40) after maintainer sign-off on D1
      (severity + opt-in trigger), D2 (CritiqueOps default with
      config overrides), D3 (single reviewer per invocation),
      D4 (three-way verdict), D5 (peer review before Director
      approval), D6 (append-only peer_review_required flag),
      D7 (verb-list alignment to lower-case). Implementation
      lands in v0.8.0 after GEP-36's Actions extraction + GEP-40's
      schema additions.
  - date: 2026-04-24
    status: Implemented
    note: |
      Phase-1 rollout complete across rounds J, K, N (N-1 / N-2 /
      N-3), O, and P within v0.8.0's crown-jewels cut.

        1. Router Peer_review module — `Glorbo.Approvals.Gate`
           now blocks director approval until
           `peer_review_verdict` lands (Round K).
        2. `Glorbo.Actions.Tasks.record_peer_review_verdict/5`
           emits `task.peer_review.<verdict>` audit + writes
           verdict fields (Round J → Actions extraction).
        3. CritiqueOps template verb alignment
           (approve/revise/block lower-case) — Round J.
        4. Severity auto-flip at task creation:
           `severity: major|critical` forces
           `peer_review_required: true` unless authored
           explicitly false — Round N-1.
        5. Kanban `⧗ peer-review` pill marks cards awaiting
           reviewer (Round N-2).
        6. `Glorbo.Approvals.Gate` emits
           `peer_review.requested` audit once per task-path
           when it first observes the reviewer-blocked state
           (Round N-3).
        7. Peer-review opt-in paragraph propagated to the 5
           non-reviewer agent templates (engineer, ceo, editor,
           researcher, provenance-auditor) — Round O.
        8. Chain audit view (`TaskChainLive`) renders
           `peer_review.requested` + `task.peer_review.<v>`
           events inline in a `<details>` section — Round P.

      Deferred to a future GEP-41 phase-3: reviewer auto-
      dispatcher (inbox delivery, sentinel dedupe, cadence,
      retry, reviewer-absent fallback). Phase-3 is a separate
      design exercise, not a rollout-list gap.

      *Update 2026-04-25:* phase-3 shipped as GEP-42, which
      closes the auto-dispatcher gap. See GEP-42's decision log
      for the routing model, missing-reviewer policy, and
      verdict-return path.

      Deferral: D6's runtime enforcement
      (`peer_review_flag_rewound` rejection of `true → false`
      flips) holds *vacuously* at v0.8.0 — the field is only
      ever written at task creation through
      `Glorbo.Actions.Tasks.create/4`; no Director-facing
      surface and no Router outbox handler currently mutates
      `peer_review_required` post-creation. If a mutation
      path is added later, the enforcement lands in that
      same commit.
requires: [2, 19, 40]
extended-by: [42, 51]
see-also: [6, 19, 28, 30, 36, 37]
---

# GEP-41: Agent peer-review gate

## Problem

Agents can — and do — ship output that looks fine at first
read but falls apart under spot-checking. Fabricated citations,
confident-but-wrong code, misunderstood acceptance criteria,
scope creep past the original ask. Glorbo has two specialised
reviewer roles (`critiqueops`, `provenance-auditor`), but they
only run when an agent *manually* routes a task to them.

Non-trivial work ships past the Director with no second pair
of eyes in the normal case. The Director catches what they
can, but they shouldn't be the first-line quality gate — the
whole point of the agent chain is to deliver work worth the
Director's attention, not work the Director has to sanity-
check from scratch.

Research literature on multi-agent systems is unambiguous: a
second reviewer catches substantially more issues than the
producer's self-review. Without a peer-review gate, the system
privileges speed over quality. For Glorbo's
"paying-customer-grade" quality bar (per
`docs/project-profile.md`), that's the wrong trade.

## Goals

- **Peer review fires automatically** on tasks flagged
  `severity: major|critical` or `peer_review_required: true`
  (both fields formalised in GEP-40).
- **Any agent can self-escalate** a task into peer review by
  setting `peer_review_required: true` before marking `done`.
  Used when the agent has doubts ("I think this is right but
  I'm unsure") or when the task crossed a boundary (new
  security path, user-facing copy, external integration).
- **Reviewer role is configurable** per company. Default:
  `critiqueops`. Override via company config or per-task
  `reviewer:` frontmatter field.
- **Reviewer produces a verdict**: `approve` / `revise` /
  `block`. Approve lets the task proceed to `done` (or the
  next handoff). Revise sends the task back to the previous
  assignee with specific findings. Block escalates to the
  Director with a reason.
- **Reviewer verdict joins the handoff chain.** GEP-40's
  `handoff_chain:` gets an entry when the reviewer reassigns
  back (revise) or to the director (block).
- **Quality signal is visible in the chain audit view**
  (GEP-40). Timeline shows the peer-review event + verdict
  inline with dispatches and approvals.

## Non-goals

- **Not a mandatory-for-every-task gate.** Would drown agents
  in review round-trips for trivial work (typo fixes, dep
  bumps). Severity / opt-in is the threshold.
- **Not Director approval (GEP-19).** Peer review is
  inter-agent quality control before the Director sees the
  task. GEP-19's `requires_approval: director` continues to
  work for "Director must yes/no this specifically." The two
  can coexist — peer-reviewed task that still needs Director
  approval runs both gates in sequence.
- **Not automated provenance verification.** The
  Provenance-Auditor auto-gate is a separate intervention
  (phase 2 of crown-jewels arc). Peer review reads output +
  done-criteria; PA gate reads output + citations. Different
  checks, different GEPs.
- **Not multi-reviewer / voting.** Single reviewer per
  invocation. If the first review comes back `revise`, the
  producing agent fixes and the *same* reviewer re-checks —
  no second reviewer introduced.
- **Not a replacement for the engineer template's
  `code-review` skill.** That skill is the agent's
  self-review of their own diff pre-reply. Peer review is
  the independent second-pair-of-eyes after.

## Design

### Trigger rules

The Router's task-acceptance pipeline gains a peer-review
decision point. Before an assignment setting `status: done`
is accepted:

1. **Check `peer_review_required: true`** → gate fires.
2. **Check `severity: major|critical`** → gate fires.
3. **Otherwise** → no gate; task proceeds.

When the gate fires, the Router:

1. Sets `assigned_to: <reviewer-slug>` (default
   `critiqueops`, override via per-company config or task's
   `reviewer:` field).
2. Appends to `handoff_chain` with `reason:
   "peer review: <severity-auto | self-request>"`.
3. Holds `status:` at `in-progress` (does not let `done`
   land).
4. Emits `agent.peer_review_requested` audit event.
5. Wakes the reviewer via inbox (standard dispatch path).

The reviewer's task reply writes a structured verdict (see
below). The Router reads the verdict on the reviewer's
outbox:

- `approve:` → Router flips `status: done` (if that was the
  pending state) or hands off to the next assignee per normal
  chain rules; emits `agent.peer_review_approved`.
- `revise:` → Router sets `assigned_to:` back to the
  reviewer's previous handoff chain entry's `from`;
  appends a handoff entry with the findings summary as
  `reason:`; emits `agent.peer_review_revised`.
- `block:` → Router sets `assigned_to: director`; appends
  `reason: "peer review blocked: <summary>"`; emits
  `agent.peer_review_blocked`. Director sees it in
  InboxLive under a new "Review-blocked" section.

### Reviewer role config

Each company's `company.md` can optionally carry:

```yaml
---
kind: company/v1
name: acme
peer_reviewer:
  default: critiqueops      # default reviewer for all tasks
  by_severity:              # optional overrides
    critical: director      # director reviews critical tasks directly
  by_assignee_role:         # optional per-role-pair overrides
    engineer: critiqueops   # engineer→critiqueops (default anyway)
    researcher: editor      # researcher work reviewed by editor
---
```

If the override logic produces a role with no agent hired
(e.g., company has no `critiqueops` and config says
`critical: critiqueops`), the gate falls back to
`director` and emits `peer_review_no_reviewer_available`
audit. Never silently skips.

### Reviewer reply contract

The reviewer agent's reply (via `$GLORBO_REPLY_PATH`) must
start with one of three verdict tags, followed by the
findings:

```
VERDICT: approve
(optional notes: "Clean. Done-when criteria met.")
```

```
VERDICT: revise
Findings:
1. Done-when line "runbook at /projects/ops/runbook.md" — file
   exists but is empty. Populate before marking done.
2. Tests added in /tests/pipeline_test.sh fail on Bazzite
   (tmpdir path assumption). Fix the path.
3. Scope: the ask was "deployment pipeline"; the added
   `.github/workflows/release.yml` step is out of scope —
   move to a separate task.
```

```
VERDICT: block
Reason: fabricated source citation
Detail: Line 47 cites https://example.com/paper.pdf which
returns 404. Claim cannot be verified. Director must decide
whether to drop the claim or source it another way.
```

The CritiqueOps template (`priv/templates/agents/critiqueops.md`)
already produces `APPROVE` / `BLOCK` / `REVISE` shapes; this
GEP formalises the contract and aligns the verbs.

### Router integration

`Glorbo.Company.Router` (the GEP-36 cleanup arc's refactor
target) gains a `Peer_review` module that:

1. Intercepts task-mutation messages where the new
   `status:` would be `done` or the new `assigned_to:` would
   leave this chain.
2. Consults trigger rules → yields `{:gate, reviewer} | :none`.
3. Rewrites the assignment to the reviewer, amends the
   handoff chain, emits the audit event.

On the return path (reviewer's outbox message with a VERDICT
tag), the Router routes based on verdict per §Trigger rules.

`Glorbo.Actions` (pure module, per GEP-36's decision) grows
functions:

- `request_peer_review(company, task_path, opts)` — internal;
  called by Router trigger rules.
- `resolve_peer_review(company, task_path, verdict, opts)` —
  called when reviewer's outbox message lands.

### Chain audit view integration (GEP-40)

The chain timeline (per GEP-40's `TaskChainLive`) renders
peer-review events inline:

```
→ 14:00  director → ceo          (initial dispatch)
→ 14:05  ceo → researcher        (needs plan)
→ 14:35  researcher → engineer   (plan ready)
✎ 15:10  engineer  dispatch      (2 runs, $0.12)
→ 15:15  engineer → critiqueops  (peer review: severity-auto)
✎ 15:18  critiqueops  dispatch   (1 run, $0.03)
⚠ 15:18  critiqueops  VERDICT: revise (3 findings)
→ 15:18  critiqueops → engineer  (revise: see findings)
✎ 15:30  engineer  dispatch      (1 run, $0.05)
→ 15:32  engineer → critiqueops  (peer review: auto-re-request)
✎ 15:33  critiqueops  dispatch   (1 run, $0.02)
✓ 15:33  critiqueops  VERDICT: approve
→ 15:33  critiqueops → ceo       (chain closes)
✓ 15:35  ceo → done               (done-when criteria met)
```

### Template updates

`priv/templates/agents/critiqueops.md` already has the
verdict-producing shape; no template change needed beyond
formalising the verb list (VERDICT: approve | revise | block
instead of the current APPROVE | BLOCK | REVISE). Align to
lower-case verb for uniformity.

Other agent templates (ceo, engineer, editor, researcher,
provenance-auditor) gain a short paragraph in their
"Reply contract" section:

> If you're unsure whether your output meets the task's
> `done_when:` criteria, or the task crossed a boundary
> (new security path, user-facing content, external
> integration), set `peer_review_required: true` in the task
> frontmatter before marking `done`. Peer review is cheap
> insurance; the Director would rather review a
> reviewer-approved task than a possibly-fabricated one.

## Migration / rollout

Atomic cut per pre-1.0 discipline. Order:

1. **GEP-40 ships first.** Schema must exist before GEP-41
   can key off `severity` + `peer_review_required`.
2. **Router `Peer_review` module.** Trigger rules + routing.
3. **`Glorbo.Actions` functions.** Request + resolve.
4. **CritiqueOps template verb alignment.** Change
   `APPROVE|REVISE|BLOCK` → `approve|revise|block` in the
   template body + reply-contract docs.
5. **Other agent templates** gain the opt-in paragraph.
6. **Chain audit view rendering.** Hook into
   `agent.peer_review_*` audit events.
7. **Tests + UAT.** Walk a severity-critical task through
   the full gate end-to-end.
8. **CHANGELOG Unreleased entry; company template demo
   showing the flow.**

No migration for existing tasks — the trigger rules only
fire on new `assigned_to:`/`status:` changes after the feature
lands. Tasks in flight at rollout time get no special
handling; they finish under old rules.

## Failure modes

| Mode | Surface | Handling |
|---|---|---|
| No reviewer role available (config says critiqueops, none hired) | Router audit + Director inbox | Fall back to `director`; emit `peer_review_no_reviewer_available`; surface in InboxLive. |
| Reviewer agent itself marks `done` on its own task without a verdict | Router | Router only resolves peer-review tasks when reply matches `VERDICT: <approve|revise|block>` regex. Unparsed → task stays in `in-progress`, `peer_review_reply_unparsed` audit emitted, Director sees it in InboxLive. |
| Reviewer re-reviews endlessly (engineer→critiqueops→engineer→critiqueops…) | LoopDetector | Existing LoopDetector catches N-failure loops; peer-review revise cycles that loop 3+ times hit the sentinel. Director resolves. |
| Reviewer verdict is `block` but no reason given | Router | Reject the outbox message with `peer_review_block_without_reason` reason; don't mutate task; audit logged. |
| Task creator flips `peer_review_required: false` mid-chain to dodge the gate | Router | Peer-review flag is append-only once set to `true`. Router validator rejects flips to `false` with `peer_review_flag_rewound`. |
| Peer-review trigger clashes with `requires_approval: director` | Router | Peer review runs first (inter-agent gate); on `approve`, task proceeds to Director approval per GEP-19. On `revise|block`, task stays inter-agent or bumps to Director per verdict. |

## Test strategy

**Unit tests:**

- Router trigger rules: `severity: major` → gate fires;
  `severity: low` + `peer_review_required: false` → no gate.
- Reviewer role resolution: default `critiqueops`; override
  via company config; fallback to `director` when resolved
  role has no hired agent.
- Verdict parsing: well-formed verdicts extract correctly;
  malformed → `peer_review_reply_unparsed` event.
- `peer_review_required` append-only invariant: flip
  `true → false` rejected.

**Integration tests:**

- End-to-end: engineer finishes `severity: major` task →
  Router routes to CritiqueOps → CritiqueOps approves →
  task returns to engineer's previous chain holder → done.
  Assert handoff chain has the expected entries.
- Revise loop: CritiqueOps revises twice before approving;
  chain reflects both round-trips; LoopDetector doesn't fire
  (2 is below the 3-failure threshold).
- Block path: CritiqueOps blocks → task lands in Director's
  inbox with block-reason visible.

**LiveView tests:**

- Chain audit view renders peer-review events inline.
- InboxLive surfaces `agent.peer_review_blocked` under the
  "Review-blocked" section.

**E2E / UAT:**

- Manual browser walk: create task with `severity: critical`,
  let agent process, verify CritiqueOps gets dispatched,
  verify verdict renders in chain view.

## Open questions

- **Fallback when critiqueops is down.** If the role is
  hired but the agent's process is not running (crashed,
  budget-stopped), Router emits the "fell back to director"
  event. Should we add a "peer review queued; retry when
  critiqueops returns" soft path? Parked for
  post-implementation data.
- **Reviewer's own reviewer.** If CritiqueOps produces
  output that itself needs review — who reviews the
  reviewer? Current answer: don't. CritiqueOps' output is
  a verdict + findings, not a substantive artefact; the
  Director's audit check covers it. Revisit if fabricated
  verdicts become a problem.
- **Multi-company company-template shape.** The `peer_reviewer:`
  block in `company.md` adds schema to the company FileSpec.
  Should we scaffold it into the bench-* templates? Lean: yes,
  all benchmark companies ship with `peer_reviewer: {default:
  critiqueops}` explicit so the default behaviour is visible.

## Decision log

### D1. Severity-based trigger + opt-in flag, not always-on

- **Decided:** Gate fires on `severity: major|critical` OR
  `peer_review_required: true`. Tasks without either flag
  don't route through peer review.
- **Alternatives:** Always require peer review
  (rejected — drowns small tasks); opt-in only (rejected —
  too easy to skip; the producing agent is the one most
  likely to think their work is fine); file-type-based
  (rejected — not robust).
- **Why:** Severity is already a human-chosen-or-agent-
  chosen signal that the work has real consequences. Opt-in
  self-escalation catches the cases where severity was
  underestimated but the producing agent has doubts. The
  combination is specific enough to not trigger on trivial
  work and broad enough to catch the cases where it
  matters.

### D2. CritiqueOps as default reviewer, configurable

- **Decided:** Default reviewer role is `critiqueops`.
  Per-company override via `company.md` config;
  per-task override via `reviewer:` frontmatter field.
- **Alternatives:** Same-role peer (engineer→engineer);
  director-always (rejected — defeats the "inter-agent
  gate before Director" purpose); provenance-auditor
  default (rejected — PA's job is narrower).
- **Why:** CritiqueOps exists as a role specifically for
  this purpose (see `priv/templates/agents/critiqueops.md`).
  Same-role peer would need a second instance of the role
  (company hires 2 engineers); fine for some companies but
  not a safe default. CritiqueOps default + config overrides
  covers both "small company, one reviewer" and "specialised
  reviewers per domain."

### D3. Single reviewer per invocation, not voting

- **Decided:** One reviewer per peer-review round. If first
  review is `revise`, the same reviewer re-checks after the
  fix.
- **Alternatives:** 2-of-3 voting; escalate to a second
  reviewer on blocks.
- **Why:** Token cost + orchestration complexity of voting
  schemes is too high for the marginal benefit at Glorbo's
  single-user scale. If a reviewer is systematically wrong,
  the Director sees the pattern and retrains / replaces the
  agent. Not the same problem as multi-reviewer crowd-
  sourcing on adversarial data.

### D4. Verdict is `approve | revise | block`, not boolean

- **Decided:** Three-way verdict with clear routing semantics
  per outcome.
- **Alternatives:** Boolean (`approved: true|false`);
  five-way (add `comment` / `defer`).
- **Why:** Two outcomes isn't enough — `revise` has
  fundamentally different routing (back to producer) vs.
  `block` (forward to Director). Five-way adds cases
  (`comment`, `defer`) whose routing semantics are unclear
  and can be subsumed into `revise` with a note.

### D5. Peer review runs before Director approval (sequential)

- **Decided:** If a task has both `peer_review_required:
  true` and `requires_approval: director`, peer review runs
  first. Only after `approve` does it proceed to Director
  approval.
- **Alternatives:** Parallel (both run simultaneously);
  Director-first.
- **Why:** Peer review is cheaper (agent time) than Director
  review (human time). Running peer review first filters
  obvious problems before the Director sees them. If peer
  review rejects, the Director was never bothered. This is
  the whole point of the gate.

### D6. `peer_review_required` is append-only (true→false rejected)

- **Decided:** Router rejects any task mutation that changes
  `peer_review_required` from `true` to `false`. One-way
  flag.
- **Alternatives:** Fully mutable; only Director can clear
  the flag.
- **Why:** Preserves the intent. An agent that had doubts and
  set the flag shouldn't have those doubts auto-cleared by a
  later agent who'd rather skip review. If the Director
  judges the review was unnecessary in hindsight, they can
  manually mark the task `status: done` and the audit shows
  they did so explicitly.

### D7. Aligns CritiqueOps verb list to lower-case

- **Decided:** Change the critiqueops template body from
  `APPROVE | BLOCK | REVISE` to `approve | revise | block`
  for uniformity with new Router parsing.
- **Alternatives:** Keep upper-case; accept both.
- **Why:** Router regex is simplest against a single canonical
  form. Upper-case was the convention when critiqueops was
  a standalone-reviewer pattern; formalising the gate is
  the right moment to align. One-time template change; no
  backwards compat needed (pre-1.0).

### D8. `approve` verdict requires corroborating audit row

- **Decided (PR #36, 2026-05-24):** The Approvals.Gate's
  `peer_review_ready?/1` no longer trusts `peer_review_verdict:
  "approve"` in the task frontmatter alone. The gate now scans
  the company audit log for a corroborating
  `task.peer_review.approve` entry with
  `actor: <bare-slug>` matching the task's
  `peer_review_verdict_by` field AND `target: <task_path>`.
  Scan window: current + previous UTC month
  (audit-file-rotation boundary safety).
- **Alternatives:**
  - Trust the frontmatter (the original D4 contract). **Rejected:**
    the task .md is agent-writable for any assignee with
    `projects:write:<project>` — the assignee could pre-seed
    `peer_review_required: true` + `peer_review_verdict:
    "approve"` directly in their own task frontmatter and skip
    the reviewer-actor check that
    `Actions.Tasks.record_peer_review_verdict/4` enforces.
  - Cryptographically sign the verdict at the reviewer.
    **Rejected:** keys-on-disk for a single-user dashboard adds
    complexity disproportionate to the threat. Audit log is
    already append-only and tamper-evident via reindex
    rebuild (GEP-34); leveraging it is cheap.
- **Why:** Mirrors the round-3 `LoopDetector` corroboration
  pattern shipped in PR #35 — the same "agent owns the
  state file, audit log doesn't trust it" shape. The audit row
  is emitted by the legit reviewer path
  (`Actions.Tasks.record_peer_review_verdict/4` ⇒
  `emit_verdict_audit/6`), which already enforces
  `guard_actor_is_reviewer/2`. The `Tools.valid_audit_action?/1`
  whitelist (PR #35) prevents agents from forging the
  corroboration row through `audit_events`.
- **Implementation note:** the legit emitter writes
  `actor: <bare-slug>` (no `agent:` prefix); the gate
  compare uses that bare-slug shape. A cross-file contract
  test in `test/glorbo/approvals/gate_test.exs` pins this
  invariant so future emitter shape changes surface as a
  gate-test failure rather than silent corroboration
  regression.

## Related

- **GEP-2** — architecture overview; peer-review gate is a
  Router extension, not a new supervision tree.
- **GEP-19** — Director approval workflow; this GEP
  complements but doesn't replace it. Peer review → Director
  approval is a valid sequential pipeline for
  high-stakes tasks.
- **GEP-28** — agent-created proposals; proposals currently
  go straight to Director. Could layer peer review on them
  in a follow-up (proposal from engineer reviewed by
  critiqueops before Director sees).
- **GEP-30** — task comments; peer-review findings can live
  in task comments in addition to the reviewer's reply.
- **GEP-36** — `Glorbo.Actions` write-seam cleanup; peer
  review requests + resolutions go through
  `Glorbo.Actions`.
- **GEP-37** — `glorbo shell`; deferred behind crown-jewels.
  Shell's approvals view will render peer-review events
  when it lands.
- **GEP-40** — chain observability; peer-review events
  appear inline in the chain audit view; `severity` and
  `peer_review_required` frontmatter fields introduced
  there.

## Implementation reconciliation (2026-06-14)

This is an append-only record of where the shipped code diverges from the body above. Per GEP-1, an Accepted/Implemented GEP's body is not rewritten; deviations are captured here instead.

- **Trigger fires only through the Director-approval flow, not as a standalone severity/opt-in gate (Goals line 113; Trigger rules lines 163-183; Non-goals lines 142-146).** The GEP says peer review fires automatically on `severity: major|critical` OR `peer_review_required: true` by intercepting the `status: done`/leaving-chain transition in the Router, *independent* of Director approval. In reality the Router carries no `severity`/`peer_review_required` logic at all (`lib/glorbo/company/router.ex` — `maybe_request_approval/6` at :1070 only keys off `requires_approval: director` / `status: pending(_/-)approval`); all peer-review gating lives in `Glorbo.Approvals.Gate.peer_review_ready?/2` (`lib/glorbo/approvals/gate.ex:576-615`), which is consulted only while evaluating an approval sentinel (:412). So a `severity: major` task with no Director-approval requirement is never held for review. The append-only D8 entry (lines 521-560) further re-centres the whole mechanism on `Approvals.Gate`. Disposition: **known-gap** — the spec'd Director-independent trigger is not built; the gate is effectively coupled to the GEP-19 approval path.

- **Company-level `peer_reviewer:` config block is unimplemented (§Reviewer role config lines 202-223; Failure modes line 353; Test strategy line 366).** The GEP specifies a `peer_reviewer:` block in `company.md` with `default` / `by_severity` / `by_assignee_role` overrides plus a `director` fallback emitting `peer_review_no_reviewer_available`. None of these tokens exist anywhere in `lib/` or `priv/` (grep returns nothing), and they are not in the company_md FileSpec — so such a block would be rejected as an unknown key. Reviewer resolution is hard-coded: per-task `reviewer:` field else default `critiqueops` (`lib/glorbo/actions/tasks.ex:721-728`, `lib/glorbo/actions/reviews.ex:220-224`). The reviewer-absent case emits `:reviewer_absent` (`reviews.ex:243`), not `peer_review_no_reviewer_available`. Disposition: **deferred** — company-config reviewer resolution and its named fallback audit are specced but not shipped.

- **Reviewer reply contract is an ACTIONS block, not a `VERDICT:`-prefixed reply (§Reviewer reply contract lines 226-258; §Router integration line 272; Failure modes line 354).** The GEP mandates a reply starting with `VERDICT: approve|revise|block` and a Router regex matching that line. The code instead parses an ACTIONS block — `verdict_from/1` matches `{"verdict", "approve"|"revise"|"block"}` tuples from `parse_task_actions/1` (`lib/glorbo/agent/server.ex:1072-1078`, :981-985); there is no `VERDICT:` regex. The request sentinel still instructs the spec'd format (`lib/glorbo/actions/reviews.ex:281`: `VERDICT: approve | revise | block`), which is now misleading. Disposition: **as-shipped** for the parsing contract (the GEP body describing `VERDICT:` is stale relative to the ACTIONS-block format that shipped); the sentinel instruction text at `reviews.ex:281` is a **corrected-ref**-style residual that should describe the ACTIONS shape.

- **`block` verdict with an empty note is accepted; `peer_review_block_without_reason` is not enforced (Failure modes line 356).** The GEP says a `block` verdict with no reason must be rejected with `peer_review_block_without_reason`, leaving the task unmutated. No such guard exists: `validate_note("")` returns `:ok` (`lib/glorbo/actions/tasks.ex:709`), `record_peer_review_verdict` has no block-specific reason requirement, and `next_status_for(:block, _)` flips status to `denied` regardless (`tasks.ex:735`). The existing test asserts the opposite — `test/glorbo/actions/tasks_test.exs:322-332` passes `:block` with no note and asserts `{:ok, %{verdict: :block, next_status: "denied"}}`. Disposition: **known-gap** — the failure-mode invariant is unimplemented and the test pins the contrary behaviour.
