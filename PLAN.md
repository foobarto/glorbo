# PLAN — Glorbo UX parity with paperclip

_Written 2026-04-20 from the SoloSaaSHunter paperclip benchmark
(`.reports/uat/paperclip-benchmark.md`,
`.reports/uat/paperclip-ux-gaps.md`) and a fresh Glorbo scenario walk
against `/tmp/glorbo-plan-*` (`screens/glorbo-plan/`). Supersedes
the previous M-series PLAN — that work shipped through 6b8e602
(M5.4) and is now in git history for reference._

## Vision delta

The paperclip run proved that a local CEO on
`opencode + lmstudio/qwen/qwen3.6-35b-a3b` with a ~60-sec heartbeat
can bootstrap an org, self-recruit agents, deliver artifacts, and
respond to director instructions within minutes. Glorbo's shape
(filesystem-first, bwrap-sandboxed, LiveView dashboard) can reach
the same outcome — today it can actually *run* that CEO (verified
via our live integration test
`test/integration/opencode_lmstudio_live_test.exs`) — but the
**director experience of observing and directing agents** is thinner
than paperclip's.

Biggest missing pieces are **observability** (what is an agent
actually doing right now, and what did it just do?) and **director
ergonomics** (assign task, inbox, see recent activity at a glance).
Schema + policy layers are close to parity; GEP-7 (SQLite derived)
even side-steps the paperclip company-delete FK bug we documented
in `paperclip-ux-gaps.md` §17b.

This plan ranks work by (director-value ÷ build-cost) with five
items ready to ship and four bigger pieces flagged for GEPs.

## Scenario walk findings

| # | Scenario | Glorbo today | Paperclip bar | Gap |
|---|----------|-------------|---------------|-----|
| S1 | Bootstrap company + CEO in ≤5 min | `+new company` modal, `+new agent` modal; AGENT.md / HEARTBEAT.md / SOUL.md appear as `+ CREATE` placeholders | One 4-step wizard | Auto-scaffold the contract files on agent create |
| S2 | Observability of a live run | AgentLive `stdout` tab tails stdout; no run-record, no tool-call summary, no token cost | Runs tab with pagination, tool-call group lines, token counts, Nice/Raw toggle | **Per-agent Runs tab** is #1 gap |
| S3 | Approval / inbox loop | ApprovalQueueLive `/approvals`, text-only | Unified inbox (Mine/Recent/Unread/All/Archive) | Intermediate: rename to `InboxLive`, ship filter tabs |
| S4 | ~~Cost / budget~~ | deferred | deferred | deferred |
| S5 | Agent lifecycle mgmt | `edit AGENT.md`, `send message`, `stop`, `wake now` (reason modal) | `Assign Task / Run Heartbeat / Pause` top-of-page | Add `assign task` button on AgentLive |
| S6 | Research-template sanity | No templates; every `agent.md` hand-written | BLA has Researcher / Editor / CritiqueOps patterns informally | Ship agent templates in `priv/templates/agents/` with provenance rules baked in |
| S7 | Sub-task / blocker graph | Flat markdown, no parent/children | Sub-issues + blocked_by edges | Per steer: no sub-issues; autolinker for `PCY-7`-style references |
| S8 | Agent detail summary of recent actions + tasks assigned | Config + files + stdout; **no recent-runs or current-assignment summary** | "AGENTS / Live now" card + running tasks | Prepend a recent-runs + assigned-tasks panel to AgentLive dashboard |
| S9 | Goals | None | First-class `goals` | `company.md` frontmatter `goals:` list; tasks reference via `goal:` |
| S10 | Wake semantics | `wake now` writes `state/wake-request.md` | `Run Heartbeat` fires immediately | Keep as-is — reason capture is good for audit |

## Ranked items

### Ship this round (single session)

#### P1-1 — Per-agent Runs tab with transcript viewer (S2, S8)

**Scope**

- New tab on AgentLive (`:runs`) that parses
  `agents/<slug>/history/*.jsonl` (one file per run) into a paginated
  list: run-id, trigger, start time, duration, exit status, reply
  preview.
- Row click expands the raw jsonl stream inline with a Nice/Raw
  toggle.
- Fallback copy when history is empty.

**Files**

- `lib/glorbo_web/live/agent_live.ex` — add `:runs` tab handler +
  render.
- `lib/glorbo/agent/run_log.ex` (new) — `list/1` returns parsed runs.
- `test/glorbo/agent/run_log_test.exs` (new).
- `test/glorbo_web/live/agent_live_test.exs` — runs-tab assertions.

**Acceptance**

- AgentLive → Runs tab lists last N runs with summary line.
- Clicking a run expands to show the raw jsonl steps.
- When `history/` is empty, shows existing empty-copy.

**Effort**: ~half-session.

#### P1-2 — "Working on" summary in CompanyLive roster + AgentLive dashboard (S2, S8)

**Scope**

- Thread a `currently_working_on: String.t() | nil` through
  `:agents:status` PubSub — populated by `Glorbo.Agent.Server` when
  a dispatch starts, cleared when done.
- Render as a second line in CompanyLive roster + top of AgentLive
  dashboard.

**Files**

- `lib/glorbo/agent/server.ex` — publish richer status messages.
- `lib/glorbo_web/live/company_live.ex` — consume + render.
- `lib/glorbo_web/live/agent_live.ex` — consume + render.
- `test/glorbo/agent/server_test.exs` — extend coverage.

**Acceptance**

- When agent is dispatching, roster + dashboard show
  `working on: projects/foo/tasks/PCY-7.md`.
- Idle agents render nothing extra (not "idle" text).

**Effort**: ~third-session.

#### P1-3 — Assign-task button on AgentLive (S5)

**Scope**

- Add `assign task` button next to existing wake / send / stop.
- Navigates to Kanban new-task modal with `assigned_to=<slug>`
  pre-filled, cancel returns to agent page.

**Files**

- `lib/glorbo_web/live/agent_live.ex` — button.
- `lib/glorbo_web/live/kanban_live.ex` — accept `?assignee=<slug>`
  + `?return_to=<url>` query params.

**Acceptance**

- From agent page, click `assign task` → Kanban new-task modal
  opens with assignee preset.

**Effort**: ~quarter-session.

#### P1-4 — Auto-scaffold AGENT.md / HEARTBEAT.md / SOUL.md on agent create (S1)

**Scope**

- When `new_agent_create` fires (CLI + LiveView), write the three
  canonical contract files with starter content (templates referenced
  by slug + role).
- Templates at `priv/templates/agents/default/<NAME>.md.eex`,
  rendered via tiny EEx pass.

**Files**

- `lib/glorbo/cli/scaffold/agent.ex` — extend scaffold.
- `priv/templates/agents/default/AGENT.md.eex`,
  `priv/templates/agents/default/HEARTBEAT.md.eex`,
  `priv/templates/agents/default/SOUL.md.eex`.
- `test/glorbo/cli/scaffold/agent_test.exs`.

**Acceptance**

- Agent scaffold writes all three files.
- AgentLive shows them as existing files (no `+ CREATE`).

**Effort**: ~third-session.

#### P1-5 — Task-reference autolinking (S7)

**Scope**

- Post-render pass detects `[A-Z]+-\d+` or
  `projects/<p>/tasks/<id>.md` tokens in markdown bodies and wraps
  in `<.link navigate={...}>`.
- Raw markdown unchanged (agents see original token); rendering is
  UI-only.

**Files**

- `lib/glorbo_web/markdown/linkify.ex` (new).
- Patches to ChannelLive, KanbanLive task-detail, AuditLive
  renderings.
- `test/glorbo_web/markdown/linkify_test.exs`.

**Acceptance**

- Channel message "blocked on PCY-7" renders PCY-7 as clickable
  link to Kanban task overlay.
- Unknown tokens don't crash or mangle.

**Effort**: ~quarter-session.

### Next round (distinct GEPs)

#### P2-1 — Inbox view (S3)

Rename `ApprovalQueueLive` → `InboxLive` at
`/companies/<co>/inbox`; add Mine/Recent/Unread/All/Archive tabs.
Start approvals-only, expand to @-mentions + task-assignments as
GEP-17-style protocol matures.

#### P2-2 — Goals as `company.md` frontmatter (S9)

Schema: `company.md` frontmatter gets `goals:` list of
`{slug, title, description, status, created_at}`. Tasks reference
via optional `goal: <slug>`. KanbanLive renders goals filter
alongside existing project filter.

Needs a GEP — schema extension + filesystem invariant change.

#### P2-3 — Activity feed with `<ACTOR> <verb> <OBJECT>` framing (S2)

Upgrade AuditLive to render the paperclip-style sentence pattern
with delta rendering for status changes. Heavier than it looks
because audit entries are shaped for `:action` + `:target` + blob
today, not diffs.

#### P2-4 — Built-in `glorbo` skill + agent templates (S6)

Ship `priv/templates/skills/glorbo/SKILL.md` documenting `GLORBO_*`
env-vars + ACTIONS DSL, auto-attached at dispatch. Plus
`priv/templates/agents/researcher/`, `editor/`, `critiqueops/` with
baked-in provenance rules (addresses `paperclip-benchmark.md` O6).

## Items explicitly **not** in plan

- Cost / budget page (deferred)
- Per-agent Configuration tab (file-tree editor covers it)
- Sub-issues / blocker graph (autolinker in P1-5 is sufficient)
- Cross-company "live now" global view

## Execution order (this session)

1. **P1-1** Runs tab — highest director value.
2. **P1-2** Working-on summary — smallest change with visible impact.
3. **P1-3** Assign-task button — one small file per LV.
4. **P1-4** Auto-scaffold contract files.
5. **P1-5** Autolinker (if session-time allows).

Each lands as its own commit, gated on `mix precommit` + CI green.

## Shipped on 2026-04-20

| # | Commit | Item |
|---|--------|------|
| 1 | `be2e8a0` | P1-1 — Runs tab on AgentLive (groups dispatch+complete by invocation_id) |
| 2 | `a067a5f` | P1-2 — "working on: …" line on CompanyLive roster + AgentLive header |
| 3 | `1490e8a` | P1-3 — `+ assign task` button on AgentLive → Kanban new-task modal prefilled |
| 4 | `eba06b4` | P1-4 — default scaffold writes SOUL.md (all three contract files always exist) |
| 5 | `b25235c` | P1-5 — `<project>-<digits>` task-id autolinker in markdown pipeline |
| 6 | `96de769` | P2-4 — editor + critiqueops templates; researcher provenance rubric tightened |
| 7 | `e452dac` | Ad-hoc — TaskLive dedicated page + Kanban right-shelf overlay (JIRA pattern) |
| 8 | `8c4cf55` | Ad-hoc — every template (incl. default) requires tool-vs-memory provenance tagging |
| 9 | `b3b608d` | P2-4 (continued) — builtin `glorbo` skill + every template auto-attaches it |
| 10 | `503bf64` | GLORBO_AGENT/COMPANY/TIMESTAMP env vars populated (were empty) |
| 11 | `16bc460` | skill doc walked back to match shipping features |
| 12 | `d65d66c` | Router picks up agent-authored `/outbox/tasks/` + `/outbox/comments/` |
| 13 | `0eef9da` | skill doc describes new outbox routes |
| 14 | `7642ea3` | bwrap `/workspace/outbox` alias + opencode permission bypass + frontmatter validation |
| 15 | `40e4831` | P2-1 — InboxLive at `/companies/:co/inbox` with Mine/Recent/All/Archive filter tabs |
| 16 | `d813894` | P2-2 — goals as `company.md` frontmatter; tasks get `goal:` field; Kanban `?goal=` filter |
| 17 | `9f11287` | P2-3 — `<ACTOR> <verb> <OBJECT>` sentence renderer for AuditEntry |
| 18 | `c21ec34` | Stretch — `provenance-auditor` template (narrow CritiqueOps variant) |
| 19 | `d4bd6d2` | Stretch — shared `TaskDetailForm` component; TaskLive gains save/delete surface |

## Round 2 — paperclip-ux-gaps closeout (still 2026-04-20)

Second sweep targets gaps explicitly called out in
`.reports/uat/paperclip-ux-gaps.md` that weren't part of the
original P1/P2 set (§§4, 5, 9, 13, 15, 18).

| # | Commit | Gap | Item |
|---|--------|-----|------|
| 20 | `2af3c33` | §15 | Two-letter actor avatars on audit rows (CE / DI / SY) |
| 21 | `661caaf` | §18 | Inline slug-availability probe on new-company modal |
| 22 | `a38f7e5` | §4  | 14-day rollups strip — runs · success · tasks-by-status · tasks-by-priority |
| 23 | `356e3af` | §5  | AgentLive config edit form writes AGENT.md frontmatter via new FrontmatterWriter |
| 24 | `27004c2` | §9  | SkillsLive at `/companies/:co/skills` — bundle view with used-by counts |
| 25 | `0e9bb62` | §13 | `create + continue →` chains company → agent → project wizard |
| 26 | `399623b` | —   | Credo cleanup (cond in SkillsLive mount, two nested-depth flattens) |

## Paperclip-baseline parity — MET 2026-04-20

See `.reports/uat/glorbo-vs-paperclip.md`. Verified end-to-end:
CEO on `opencode + lmstudio/qwen/qwen3.6-35b-a3b` autonomously
reads the `glorbo` skill, files three hire-request tasks to
`/outbox/tasks/blog/`, the Router materialises them under
`projects/blog/tasks/`, the Kanban UI renders them ready for
Director action. Same outcome shape paperclip produces via its
HTTP `hire_agent` approval flow — just filesystem-first.

## Items still open (none from original plan)

All P1 / P2 / stretch items plus the Round-2 paperclip-gap sweep
(§§4, 5, 9, 13, 15, 18) shipped. Genuinely new scope for a future
session:

- TaskLive body editing (currently frontmatter-only on the page;
  body edit stays in the Kanban shelf). Requires a small safe
  YAML emitter or a `write_body/2` helper on `TaskDefinition`.
- Inbox @-mention + task-assignment feeds beyond approvals (needs
  new event sources to subscribe to).
- Archive actions on the InboxLive archive tab.
- Cost/budget page (§6 — deferred in the original PLAN).
- Command palette (§16) — affordance exists as g-prefix shortcuts
  but no searchable overlay.
- Sub-issues / blocker graph (§8) — user steered away from this;
  autolinker covers the common case.
- Full `/goals` page (§7) — frontmatter + Kanban `?goal=` filter
  shipped; a dedicated goals LV with aggregation is the next step.
