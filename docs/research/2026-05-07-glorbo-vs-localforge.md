# Glorbo vs LocalForge — comparison + bridge-gap plan

Date: 2026-05-07
Subject: [leonvanzyl/localforge](https://github.com/leonvanzyl/localforge)
(Apache-2.0; Next.js + React 19 + SQLite/Drizzle; Pi coding-agent
SDK over LM Studio / Ollama; ~"build a webapp on autopilot"
positioning).

This is a static comparison built from the project's README +
how-to docs. Interactive UI testing in a real browser was
requested but the claude-in-chrome extension isn't connected on
this host — the `mcp__claude-in-chrome__*` tools refuse with
"Browser extension is not connected". Live UI walk-through is a
follow-up once the extension is wired (or run from an Ubuntu
distrobox per `docs/testing/uat.md`).

## TL;DR

LocalForge is a **single-project, single-agent feature-loop** tool:
chat with a bootstrapper → generate features → kanban-driven
sequential dispatch → per-feature Playwright acceptance gate →
visible "build something cool, watch the bar fill, confetti".

Glorbo is a **multi-company multi-agent orchestration platform**:
filesystem-truth, sandbox-enforced permissions, per-agent skills,
provider-pluggable (claude-code / gemini-cli / codex / stado-acp /
native), egress proxy, approvals + path-grant gates, audit log,
budgets.

Their feature surfaces overlap in maybe 20% of cases. The places
where LocalForge **clearly does better** are a tight list — and
each maps to a small, well-scoped Glorbo addition.

## Side-by-side

| Dimension                         | LocalForge                                          | Glorbo                                                                         |
|---|---|---|
| **Positioning**                   | "Build apps on autopilot"                           | "Multi-agent company orchestration with hard isolation"                        |
| **UI**                            | Web (Next.js + shadcn/ui) on `localhost:7777`       | Phoenix LiveView dashboard + `glorbo shell` TUI + Burrito CLI                  |
| **State**                         | SQLite + Drizzle; project folder on disk            | Filesystem (`~/.glorbo/`) is truth; SQLite is derived (`glorbo reindex` rebuilds) — GEP-3, GEP-7 |
| **Provider model**                | Pi coding-agent SDK over OpenAI-compatible endpoint (LM Studio / Ollama)             | CLI-tool wrappers: claude-code, gemini-cli, codex, stado-acp, native harness — GEP-4, GEP-32, GEP-45 |
| **Bootstrapping a new project**   | **Interactive AI chat: describe app → auto-generate features**          | Manual: `glorbo new company`, then `glorbo new agent` per role                 |
| **Workflow shape**                | **Kanban (Backlog / In Progress / Completed)** with priority + dependencies | Per-task markdown files; status frontmatter; cron heartbeats — GEP-13, GEP-14 |
| **Per-task acceptance gate**      | **Playwright verification per feature**, optional headed mode           | Peer-review gate (GEP-41); no automated acceptance/test loop                  |
| **On-failure handling**           | **Demoted priority + requeue to backlog**                                | Retry budget (max_retries) + loop-detector sentinel; no priority demotion     |
| **Concurrency**                   | One feature at a time, sequential                   | Multi-agent (different agents in parallel); GEP-46 just added per-agent + per-company caps |
| **Sandbox / permissions**         | None described                                      | bwrap mount-namespace sandbox per dispatch; `permissions:` enforced at Router AND kernel — GEP-2, GEP-5 |
| **Multi-company / multi-tenant**  | One project at a time                               | Per-company supervision tree; absolute isolation                              |
| **Skill / plugin system**         | `.agents/skills` dir hinted; no documented system   | First-class skill registry (browse / install / per-agent allowlist) — GEP-10, GEP-22 |
| **Audit log**                     | SSE activity panel (live only)                      | Append-only JSONL `audit/YYYY-MM.jsonl` per company                           |
| **Cost / budget tracking**        | Not present (local-only)                            | Per-company `BudgetTracker` GenServer + ledger; `usage_parser` per provider   |
| **Egress / network policy**       | Local model only; no policy                         | Egress proxy with smart classifier — GEP-23                                   |
| **Approvals workflow**            | None                                                | Director approvals gate; PathRequestGate for sandbox path requests — GEP-19, GEP-27 |
| **MCP / external protocols**      | Not mentioned                                       | MCP server (GEP-29) + ACP (GEP-9, GEP-45)                                     |
| **Live activity feed**            | **SSE-streamed unified activity panel**             | LiveView with PubSub; per-agent run log; no single unified "everything happening now" feed |
| **First-run feel**                | "Click Start, confetti when done"                   | Operator-heavy; `glorbo doctor`, scaffold, configure providers                |

## Where LocalForge does it better — concrete bridge tasks

The high-leverage gaps. Each is small enough to scope as a
follow-up GEP or short-form task.

### 1. **AI bootstrapper chat for new companies** (task #16)

**LocalForge:** "Create a new project from the sidebar, describe
your app — the AI bootstrapper generates features automatically."
A multi-turn chat asks clarifying questions before scaffolding the
project's feature backlog.

**Glorbo today:** `glorbo new company` is non-interactive — you
write a `company.md` + per-agent `AGENT.md` files yourself.

**Bridge:** new verb `glorbo new company --interactive` (or a
LiveView wizard at `/companies/new`) that drives a configured
provider through a clarifying-question loop:

1. What's this company's mission?
2. What roles / agents do you need?
3. Per-role: provider, model, network policy, budget.
4. Top-level goals?

Output: scaffolded `company.md`, `AGENT.md` files, a starter
`HEARTBEAT.md` per agent, a `goals.md`, optional `inbox/welcome.md`
to seed first dispatch.

**Implementation surface:** small. New CLI verb invokes a stateless
provider call (any configured model), writes files atomically,
pipes audit. ~1 GEP, modest size.

### 2. **Kanban view + feature-priority queue**

**LocalForge:** Kanban board shows Backlog / In Progress /
Completed columns; features have priority + dependencies; the
orchestrator pulls the highest-priority "ready" feature.

**Glorbo today:** tasks are flat markdown files with `status:`
frontmatter. There's a board-style view in CompanyLive but no
priority queue or dependency resolver.

**Bridge:** add a new file kind `feature/v1` (or extend `task/v1`)
with:
- `priority: 1..100` (lower = higher priority)
- `depends_on: [<task_id>...]`
- `status: backlog | in_progress | completed | blocked`

Plus a Kanban LiveView at `/companies/<co>/board` that renders
columns from the SQLite-derived index (rebuilds via reindex per
GEP-7). The orchestrator already exists in spirit: GEP-24 task
scheduler. Adding "pull highest-priority unblocked task" is a
small step on top.

**Implementation surface:** medium. Schema bump, LiveView, scheduler
hook. ~1 GEP.

### 3. **Per-task acceptance gate (automated test verification)**

**LocalForge:** "agent writes code, runs Playwright tests, and
captures screenshots." A test must pass before the feature moves to
Completed; a fail demotes it back to backlog.

**Glorbo today:** GEP-41 peer-review gate is the closest analogue
but it's a SECOND agent reviewing — not an automated test. There's
no `acceptance:` field on tasks.

**Bridge:** add an optional `acceptance:` block in `TASK.md`:

```yaml
acceptance:
  - type: shell
    cmd: mix test
  - type: shell
    cmd: ./bin/check-feature
```

After dispatch, run each acceptance command **in the same bwrap
sandbox** as the agent (existing primitive). Exit 0 on all → mark
completed. Any fail → mark `failed` + emit `task.acceptance_failed`
audit + (with the kanban work above) demote priority + requeue.

**Implementation surface:** medium. Reuses the bwrap dispatch path;
only adds a post-dispatch shell-out and the file-format key. ~1
GEP.

### 4. **Unified "what's happening" activity feed**

**LocalForge:** SSE-streamed activity panel. Every agent action
(file write, shell exec, test run, model call) shows up live in
one column.

**Glorbo today:** LiveView per agent shows its run log; no single
"all-companies activity" view. PubSub fan-out exists but isn't
surfaced as one feed.

**Bridge:** new LiveView at `/activity` that subscribes to every
company's `audit` PubSub topic and renders rows live. Per-row link
back to the agent / company / task. Filterable by company,
event-kind, agent.

**Implementation surface:** small. Pure LiveView + existing PubSub
fan-out. No GEP needed unless audit-event shapes change.

### 5. **Failed-task requeue with priority demotion**

**LocalForge:** "On failure the feature returns to the backlog
with demoted priority so other features can go first."

**Glorbo today:** retries are configurable per-agent
(`max_retries`); after exhaustion the loop-detector emits a
sentinel for Director attention. The TASK itself doesn't reorder.

**Bridge:** ride on the kanban + acceptance work above. When a
task hits its retry cap or fails the acceptance gate, decrement
its priority and put it back in `backlog`. Operator can still
sentinel-escalate at any time.

**Implementation surface:** small. Comes for free with the kanban
+ acceptance GEPs above.

## Where Glorbo does it better

Worth recording so the bridge plan doesn't lose them by accident:

- **True multi-agent.** LocalForge has one agent per project at a
  time. Glorbo runs many agents per company in parallel (now
  bounded by GEP-46 caps).
- **Hard sandbox.** GEP-5 bwrap mount namespaces. LocalForge's
  agent runs unsandboxed.
- **Filesystem-truth + SQLite-derived.** A Glorbo install can be
  tarred, restored, and `glorbo reindex` rebuilds every derived
  row. LocalForge couples projects to its own SQLite schema.
- **Skill registry.** Loadable per-agent skills with browse /
  install / allowlist (GEP-10, GEP-22). LocalForge has a `.agents/skills`
  directory but no described system.
- **Provider variety.** claude-code / gemini-cli / codex /
  stado-acp / native harness. LocalForge is local-LLM-only via
  OpenAI-compatible endpoints.
- **Egress policy.** GEP-23 smart classifier; LocalForge skips the
  problem by going local-only.
- **Audit + budgets + approvals.** Production-grade flows;
  LocalForge has activity stream only.
- **Multi-tenancy.** Multiple isolated companies; LocalForge is
  one project at a time.
- **Protocol integrations.** MCP server, ACP transport;
  LocalForge does neither.

## Things to NOT copy

- LocalForge's "confetti when done" — fine for solo-builder
  prototyping, fits the audience. Glorbo's audience runs longer-
  lived companies; the equivalent UX is the audit row, not a
  one-shot completion.
- LM-Studio-only assumption. Don't constrain Glorbo's provider
  matrix to local OpenAI-compat — the existing CLI-tool model is
  more general.

## Recommended ordering

1. **#16 AI company bootstrapper** — biggest UX win, smallest
   scope. Land first.
2. **Activity feed** — tiny code, immediate operator value. Land
   second; informs design of the kanban view.
3. **Kanban + priority queue** — moderate; needs schema bump
   (`task/v1` extensions) so worth a GEP.
4. **Acceptance gate** — depends on the kanban being there for
   the requeue-on-failure half to be meaningful.
5. **Priority demotion on failure** — comes for free with #4.

## Open

- Live UI walk-through still pending (browser extension not
  connected). Once available, run the LocalForge demo end-to-end
  alongside Glorbo's `/agents/<co>/<agent>` view; capture
  screenshots; refine bridge-task scoping.
- The two queued companion ideas (#17 in-agent glorbo skill,
  bootstrapper as a real GEP) belong here too once the comparison
  is locked.
