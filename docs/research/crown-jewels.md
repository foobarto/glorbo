---
title: "Crown jewels — research & planning"
author: Glorbo Maintainers <security@example.invalid>
last-synthesised: 2026-04-24
status: research
---

# Crown jewels — what "top-notch agents" takes

Research and planning doc. Not a GEP yet — this is the
upstream thinking that will feed specific GEPs once the
maintainer picks the priorities.

## The goal (maintainer, 2026-04-24)

> The crown jewels of this project will be how good the
> agents are at autonomously interacting with each other,
> the director and the quality of their deliverables... all
> along avoiding creating slop or junk or getting stuck.... a
> lot of issues with the web/shell interface can be forgiven
> but these crown jewels just have to be top notch.

Four quality axes, all non-negotiable:

1. **Inter-agent interaction** — handoffs, collaboration,
   knowing when to call another agent vs do it yourself.
2. **Director interaction** — when to escalate, how much to
   bother the human, what earns their attention.
3. **Deliverable quality** — the artifact itself has to be
   usably good, not hand-wavy-"done."
4. **Anti-failure modes** — no slop (vague output), no junk
   (superficially complete but wrong), no stuck (silent
   looping, lost tasks).

This doc surveys what Glorbo has toward those axes, gaps vs.
state-of-the-art, and a ranked list of interventions.

## Infrastructure already in place

*(Full inventory from sub-agent research — condensed.)*

**Agent lifecycle** — mature. Agent.Server GenServer per
agent; DynamicSupervisor, :one_for_all sub-trees with clean
restart semantics. Heartbeat driven by cron-style Scheduler.
Wake-queue with coalescing.

**Routing** — centralized. `Glorbo.Company.Router` is the
single choke point; ACL checks, no broadcast, emits audit.
Channels use `[:append, :sync]` for OS-level serialization.

**Audit** — complete. JSONL + SQLite mirror; every
dispatch, approval, denial, loop, skill-missing logged with
actor/ts/target/detail. Filesystem is authoritative.

**Quality gates (3 layers):**

- Approvals (GEP-19) — `requires_approval: director`
  sentinel workflow, both Gate daemon + UI-direct paths.
- Path access (GEP-27) — per-task sandbox path-grant
  lifecycle via PathRequestGate.
- Proposals (GEP-28) — agent-created structural changes
  (hire, fire, budget, project) via director approval.

**Stuck detection:**

- LoopDetector after N consecutive task-dispatch failures
  (default 3). Sentinel blocks; director resolves via UI
  button or file-drop protocol.
- Pre-dispatch token-budget gate (alert 80%, stop at cap).
  No mid-flight budget enforcement.

**Provenance discipline** — strong at template level (every
role has "tool vs memory" rules); weak at system level (no
auto-route to Provenance-Auditor for claim-bearing outputs).

**Observability for the Director:**

- InboxLive aggregates approvals + stuck sentinels +
  audit-tail.
- ProposalsLive queues proposals.
- 14-day Activity rollup (runs/day, success-rate/day,
  tasks by status/priority).
- PubSub topics: `company:<co>:{projects,approvals,audit,
  agents:status}`.

## Quality dimensions that matter for multi-agent systems

From literature + production experience:

### A. Task framing quality

Every dispatch is only as good as the task that landed in
the inbox. A vague task → wandering output. A too-specific
task → no agent judgment.

**Signal:** tasks that took N>2 handoffs to produce
consensus-level output may have been mis-framed up front.

### B. Decomposition

Breaking big tasks into sizable sub-tasks. The hardest
judgement call an orchestrator makes.

**Signal:** CEO decomposes manually via prompt discipline;
no tooling help.

### C. Handoff fidelity

When agent A passes to B, does B receive enough context to
act without re-asking? Path-passing discipline + structured
handoff notes (newly added to templates) are Glorbo's
current answer.

### D. Quality verification (pre-ship)

Before output is marked `done`, does a second pair of eyes
check it? Glorbo has CritiqueOps + Provenance-Auditor roles
— manually routed today.

### E. Stuck detection + recovery

Catching "silent loop" early. LoopDetector's N-failure
threshold is coarse.

### F. Provenance chain

Tracing "this conclusion came from these sources through
these agents." Per-agent provenance discipline is strong;
chain-level aggregation is not.

### G. Peer review / multiple perspectives

Two reviewers catch more bugs than one; research literature
on multi-agent debate is clear on this. Glorbo has no
mandatory peer-review protocol.

### H. Director escalation

When an agent can't complete, how does work bump up? Today
via informal channel posts / DMs / approval requests. No
explicit `bump_up_reason:` pattern.

### I. Retrospective learning

After a chain completes, what do we learn? Today: nothing
structured.

### J. Outcome measurement

How do we know a chain produced good work? Today: director
judgment. No automated signal.

## External reference patterns (brief)

- **AutoGen (Microsoft)** — conversation-driven. Agents talk
  until convergence. Weakness: can loop.
- **LangGraph** — explicit state machines. Predictable,
  rigid; doesn't adapt well.
- **OpenAI Swarm** — handoff-based. Agent A `handoff(B,
  context)`. Close to where Glorbo's new handoff discipline
  lands.
- **CrewAI** — role-based with process choices (sequential
  vs. hierarchical). Maps well to Glorbo's role model.
- **MetaGPT** — software-dev-specific "dev team simulation."
  Strong role-specific prompts (like Glorbo); weak on
  security/sandboxing (Glorbo leads here).
- **Reflexion (Shinn et al.)** — self-critique after
  attempts, retry with feedback. LoopDetector is the coarse
  version; explicit reflexion is not yet present.
- **Plan-and-execute** — a planner agent produces structured
  plan, executor runs it. Relevant for decomposition.
- **Society of Mind / voting** — multiple agents propose,
  one selects. Good for subjective quality calls.

**Glorbo's differentiators vs. these:**

- Kernel-enforced isolation (bwrap + netns + proxy). Few
  frameworks have it.
- Filesystem-first (auditable, no hidden state). Most
  frameworks hide orchestration in process memory.
- Single-user-per-instance (no multi-tenant complexity).
- Role-templating with soul/heartbeat split. Unusual shape
  that pays off.
- Human-in-loop via approvals + proposals.

## Gap analysis — Glorbo now vs. "top-notch"

| Dimension | Current state | Gap |
|---|---|---|
| A. Task framing | Prompt discipline only; no `done_when:` field | No structured acceptance criteria; relies on agent to infer "done" |
| B. Decomposition | Manual (CEO writes sub-tasks via prompt) | No decomposition-aid tool; no structured sub-task graph |
| C. Handoff fidelity | Strong after today's template update | Prompt-level only; no `requested_by:` / `handoff_chain:` frontmatter |
| D. Quality verification | CritiqueOps + Provenance-Auditor exist, manually routed | No auto-routing based on output class or task severity |
| E. Stuck detection | N-failure LoopDetector | No time-based, no meandering-detection, no self-report channel |
| F. Provenance chain | Per-agent rules strong | Chain-level aggregation zero |
| G. Peer review | Not required | No mandatory-second-reviewer pattern |
| H. Director escalation | Ad-hoc (DM, channel, approval) | No explicit `bump_up:` pattern; director has to pattern-match on inbox |
| I. Retrospective learning | Nothing structured | No per-chain retro log; no aggregate learnings |
| J. Outcome measurement | Director judgment; 14-day Activity rollup | No per-chain performance report; no agent-level quality trends |

## Ranked interventions

Ranked by (crown-jewel impact) ÷ (build cost).

### Top tier — highest ROI

1. **`done_when:` field on task frontmatter**
   (FileSpec + validator change).
   Agents gain explicit "verify before reply" target.
   Structured acceptance criteria prevent "mostly done →
   done" slippage. Cost: small (1-line schema + body
   discipline); benefit: every task.

2. **Provenance-Auditor auto-gate for claim-bearing outputs**
   (Router/Actions update).
   Any task output going to channels, published artifacts,
   or Director with `(tool: <url>)` citations auto-routes
   to PA before acceptance. Uses existing agent role.
   Cost: medium (Router logic + config); benefit: eliminates
   the whole "fabrication slips past" class.

3. **Auto peer-review for non-trivial tasks**
   (Router/Actions update + role config).
   Tasks with `severity: major|critical` or `requires_approval:
   director` route to a second agent (e.g., CritiqueOps or a
   second instance of the same role) before marking `done`.
   Cost: medium; benefit: catches slop pre-director.

4. **Chain audit view — one-click "show me this task's
   full chain"** (LiveView, uses existing PubSub + audit).
   Dedicated task-chain page aggregating: assignments
   timeline, handoff notes, dispatches, approvals, loops,
   comments. Cost: medium (LiveView + query); benefit:
   director gains chain visibility in seconds, not minutes.

5. **Chain performance metrics — per-task rollup**
   (derived from audit).
   Metrics: chain length (distinct agents), total dispatches,
   handoff count, loop count, wall-time elapsed, total USD.
   Aggregates per-role-pair + per-agent. Cost: medium;
   benefit: data-driven optimization of which roles to hire,
   which chains to shorten.

### Second tier — medium-high ROI

6. **`requested_by:` + `handoff_chain:` frontmatter fields**
   (FileSpec change).
   Machine-readable chain state. Router appends to
   `handoff_chain:` on each `assigned_to:` swap. Enables
   easier chain queries; supports #4 and #5 above natively.
   Cost: small-medium; benefit: schema improvement that
   unlocks downstream features.

7. **Retrospective log per completed chain**
   (new file kind: `retro/v1` per task).
   When chain reaches `status: done`, CEO writes one-line
   retro ("Chain length 4; 1 loop at QA; lesson: next time
   frame the ask with acceptance criteria."). Or
   auto-generated from audit+chain then CEO reviews.
   Cost: medium; benefit: retrievable learnings across
   chains.

8. **Stuck-detection time-based signal**
   (LoopDetector extension).
   Add: task has been `in-progress` > N hours without a
   new dispatch event OR without task file mtime change.
   Emits `agent.task_stagnant` audit event; surfaces in
   InboxLive. Cost: small (extend LoopDetector); benefit:
   catches silent drop-off earlier than 3-dispatch-failure.

9. **Per-agent over/under-delegation metrics**
   (derived from audit).
   Track per-agent: (tasks reassigned) / (tasks landed).
   Flag on dashboard when >60% reassignment (shopping) or
   when agent works tasks outside declared skill set
   (under-delegation). Cost: small-medium; benefit:
   catches delegation pathologies.

### Third tier — nice to have, lower priority

10. **Decomposition-aid skill**
    (new skill template + tool).
    Optional skill: "given a task description, propose
    2-4 sub-tasks and suggest the right agent for each."
    CEO uses during initial triage.

11. **Agent self-report stuck signal**
    (template prompt addition — partially done today via
    "Stuck" subsection).
    Agent can write `STUCK: <what I tried, what I'm
    missing>` to its reply path; Router emits audit event;
    surfaces in InboxLive.

12. **Skill-effectiveness metrics**
    (derived from audit).
    Which skills fire most, which produce `skill.missing`,
    which correlate with higher success rates. Low ROI
    until skill library grows beyond current ~half-dozen.

13. **Director `bump_up_reason:` field pattern**
    (task frontmatter convention).
    When CEO decides to escalate to director, the task
    frontmatter gets `bump_up_reason:` + `assigned_to:
    director`. Today this is ad-hoc. Formalising is cheap
    and aids InboxLive rendering.

14. **Scope-creep detection**
    (Router check post-reply).
    Compare reply keywords to task description; warn on
    significant deviation. Fragile; many false positives
    likely. Skip unless a real problem materialises.

### Anti-patterns to avoid

- **Centralized "orchestrator agent"** — breaks the
  filesystem-first invariant. Don't do it.
- **Hidden state (in-memory chain)** — same. Everything
  must be rebuildable from disk.
- **Automatic agent hiring without director approval** —
  current GEP-28 has this guardrail (hire-within-budget
  auto-approve); loosening it further risks runaway cost
  + role sprawl.
- **Mandatory review for every task** — would slow trivial
  work to a crawl. Peer review should be threshold-gated
  (severity / priority / output-destination).

## How these interventions compose

A realistic task chain with the top-tier interventions
active:

1. **Director files task** "Research and implement the new
   deployment pipeline" with
   `done_when: "pipeline deploys from main branch on
   green CI; runbook at /projects/ops/runbook.md"`.
2. **CEO** picks it up, decomposes into 3 sub-tasks
   (research → implement → QA), assigns first to
   **researcher** with handoff chain started.
3. **Researcher** produces plan, cites sources;
   Provenance-Auditor auto-gates the source citations
   before `assigned_to: engineer` is accepted.
4. **Engineer** builds, auto peer-review by a second
   engineer (or CritiqueOps) before `assigned_to: qa`.
5. **QA** tests; if issues → `assigned_to: engineer` again.
6. Eventually chain returns to **CEO**; chain-metrics view
   shows 6 dispatches, 3 handoffs, 1 loop, 2 hours 40 min,
   chain length 4. CEO judges against `done_when:` criteria
   and sets `status: done` OR writes a bump-up-to-director
   task.
7. **Retrospective** auto-generates: "Chain of 4 agents;
   1 engineer-QA loop; done_when met; total USD $3.42."
   CEO adds a one-line learning.

## Open questions for maintainer

The interventions above fork substantially on design
calls I shouldn't make alone. Grilling questions for the
maintainer, focused on what unblocks the top-tier work:

1. **Which top-tier interventions to prioritize first?** Of
   `done_when:` / Provenance auto-gate / peer-review auto-
   gate / chain audit view / chain metrics — pick 2-3 for
   the initial crown-jewel GEP round.

2. **`done_when:` field** — OK to add to task frontmatter
   as optional? Requires FileSpec update + validator
   entry. Keeps hand-wave-done at bay.

3. **Peer-review trigger threshold.** Always require
   (slow)? Only `severity: major|critical` (reasonable)?
   Only tasks marked `peer_review_required: true` (opt-in)?
   Which role does the second review (a second instance of
   the same role, CritiqueOps, or a role-specific
   reviewer)?

4. **Provenance-Auditor auto-gate scope.** For tasks with
   `(tool: <url>)` citations in outputs, auto-route to PA
   before accepting? If yes — every such output, or only
   those heading to channels / published artifacts /
   Director?

5. **Retro log authorship.** Auto-generated from audit (no
   human write)? CEO writes one-line review? Dedicated
   retro-bot agent?

6. **Chain metrics — what surfaces where?** Which metrics
   go on the overview dashboard (high-traffic, has to be
   cheap to compute) vs. a dedicated Chain Audit view
   (click-to-open, can be more detailed)?

7. **`handoff_chain:` in frontmatter.** Worth formalising
   as a structured field (list of
   `[{from, to, reason, ts}]`), or keep the handoff-note
   body convention from the just-updated engineer template?

8. **Time horizon.** Crown-jewel work as v0.8.0 scope
   (along with `glorbo shell` + `Glorbo.Actions`
   extraction), or a dedicated v0.9.0?

## Related

- `priv/templates/agents/engineer.md` — first cairn-style
  agent template with handoff + anti-slop + L3 autonomy +
  structured reply.
- `docs/project-profile.md` — Glorbo's stance on risk,
  security, quality. Crown-jewels framing should be
  elevated there.
- `docs/knowledge-graph/notes.md` — tacit knowledge about
  LoopDetector and other infrastructure.
- GEP-14, GEP-16, GEP-19, GEP-27, GEP-28 — the existing
  agent-orchestration GEPs.
