# Phase 4: LiveView Dashboard + Real-Time Channels - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning
**Mode:** Auto-generated (--auto; recommended defaults)

<domain>
## Phase Boundary

A Director opens `http://localhost:4000` and sees the filesystem come alive. Seven DESIGN.md §9 views render the current state of `~/.glorbo/companies/` and update in sub-second real-time via the Phase 2 `Filesystem.Watcher` → Phoenix.PubSub → LiveView pipeline (already wired in Phase 3). The dashboard is strictly a *render* of filesystem state — every Director write-action (post message, approve task) resolves to Elixir appending to or editing a markdown file; the agent layer sees the change exactly as if a text editor made it. No in-memory state that isn't derivable from files + SQLite.

**In scope:**
- Phoenix LiveView mounted on `http://localhost:4000`; authenticated via the "single-Director, owns-the-host-user" trust model (see §Auth below — v0.0.1 relies on loopback + filesystem perms, no login page)
- Seven views from DESIGN.md §9: (1) Multi-company overview, (2) Kanban board per company, (3) Agent detail with live stdout tail + wake-history + budget ring, (4) Chat UI rendering channel markdown files, (5) Approval queue over every `awaiting-approval-*.md` sentinel, (6) Audit log viewer, (7) System health (Elixir process tree, supervisor children, budget totals, doctor summary)
- Phoenix Channels + PubSub wiring for sub-second updates on file changes (reusing existing `company:<co>:{inbox,outbox,projects,channels,audit,alerts}` topics from Phase 3's Watcher)
- Director write-actions: post to channel (Elixir appends `## <timestamp> | Director\n<body>` to `channels/<n>.md`); approve/deny task (Elixir edits task frontmatter `status:`); wake agent manually (Elixir writes `agents/<name>/state/wake-request.md` — the fourth wake trigger)
- Assets pipeline: re-introduce `esbuild` + minimal CSS (Phase 1 stripped the full asset pipeline; now re-add only what the dashboard needs)
- Routes + navigation + layout shell

**Out of scope (deferred to Phase 5 or later):**
- Multi-user / multi-Director authentication (trust model is single-operator)
- Mobile-optimised layouts (desktop-first; responsive is nice-to-have but not required)
- Long-form markdown editing in the dashboard (Director edits with their own editor; dashboard is read-first)
- Dashboard-driven agent creation (AGT-05: agent creation is Director-only via filesystem)
- Notifications / toast system (visual feedback on approval click, but no Service-Worker push)
- Custom dashboards / saved views / dashboard DSL

</domain>

<decisions>
## Implementation Decisions

### Framework, tooling, asset pipeline
- **D-01:** Phoenix LiveView (locked by PROJECT.md) — no React/Vue/Svelte. Server-rendered HTML with LiveView diffs over the wire.
- **D-02:** `esbuild` re-introduced as the JS bundler (Phoenix default; Phase 1 stripped it; Phase 4 reintroduces only what's needed — LiveView's JS + a couple of hooks). `tailwind` NOT re-added; use plain CSS with CSS custom properties. Rationale: Glorbo's aesthetic is terminal-adjacent, a single hand-written CSS file is sufficient and keeps the binary small.
- **D-03:** `heroicons` not re-added; ship a tiny inline-SVG icon set (6-8 glyphs: check, x, play, pause, user, folder, message, lightning) as a Phoenix component `<.icon name="..."/>`.
- **D-04:** Dev mode: `phx.server` (default from Phase 1). Prod mode: single-binary Burrito release (Phase 1) serves Phoenix on `0.0.0.0:4000` by default, configurable via `~/.glorbo/config.md` `port:`/`host:`.
- **D-05:** Assets live at `assets/js/` and `assets/css/`. CSS file is hand-written, ~400-600 LOC total — no Tailwind, no daisyUI, no PostCSS beyond what esbuild needs.

### Authentication
- **D-06:** **No login page in v0.0.1.** Trust model = single Director owning `~/.glorbo/`. Security comes from:
  - Phoenix bound to `127.0.0.1:4000` by default (loopback only; change via `config.md` `host: 0.0.0.0` for LAN access)
  - `~/.glorbo/glorbo.db` being `chmod 0600` (Director-only read — any other OS user gets EACCES on the socket file too since we bind-mount into the Director's session)
  - Optional: a secret from `~/.glorbo/config.md` `dashboard_token:` added to the URL (`?token=...`) — unset by default, opt-in for LAN exposure
- **D-07:** CSRF + LiveView session signing use a generated secret stored in `~/.glorbo/config.md` (`secret_key_base:`). Generated on first boot if missing. Reason: no shared secret across hosts; each install has its own.

### Routes + layout
- **D-08:** Routes:
  - `/` → redirect to `/companies` (overview)
  - `/companies` → Multi-company overview (list + per-company summary cards)
  - `/companies/:company` → Company overview (agents, kanban, pinned channels)
  - `/companies/:company/kanban` → Kanban board of all tasks in the company
  - `/companies/:company/agents/:agent` → Agent detail (live stdout, wake-history, budget, current task, permissions)
  - `/companies/:company/channels/:channel` → Chat view for one channel
  - `/companies/:company/approvals` → Approval queue (cross-agent)
  - `/companies/:company/audit` → Audit log viewer
  - `/health` → System health (Elixir supervision tree, doctor summary, supervisor children across all companies)
- **D-09:** Layout: persistent left sidebar with companies list + a small "health" strip at bottom. Main pane renders the route-specific LiveView.
- **D-10:** Back-navigation via the browser; no custom history system.

### LiveView module structure
- **D-11:** Module layout under `lib/glorbo_web/live/`:
  - `OverviewLive` — all companies
  - `CompanyLive` — one company's dashboard
  - `KanbanLive` — task board
  - `AgentLive` — agent detail + live stdout
  - `ChannelLive` — one channel
  - `ApprovalQueueLive` — approval queue
  - `AuditLive` — audit log
  - `HealthLive` — system health
- **D-12:** Shared components under `lib/glorbo_web/components/`:
  - `CompanyCard`, `AgentCard`, `TaskCard`, `ApprovalCard`, `ChannelMessage`, `AuditEntry`, `BudgetRing`, `StdoutTail`, `Icon`.
- **D-13:** Presence: use `Phoenix.Presence` on the `dashboard:*` topic so Director can see they're connected from N tabs/devices (nice-to-have; low-priority implementation).

### Real-time pipeline (reuses Phase 3 plumbing)
- **D-14:** Each LiveView subscribes on `mount/3` to the relevant Phase-3 PubSub topics:
  - `OverviewLive` → `companies` (company add/remove) + per-company `:agents`, `:audit`, `:alerts`
  - `CompanyLive` → `company:<co>:{agents,audit,alerts,approvals}`
  - `KanbanLive` → `company:<co>:projects` (Watcher already emits on `projects/**/*.md`)
  - `AgentLive` → `company:<co>:agents:<ag>:stdout` (new topic — Watcher emits on stdout.log updates) + `company:<co>:agents:<ag>:budget`
  - `ChannelLive` → `company:<co>:channels:<channel>` (new topic — Watcher emits per-channel)
  - `ApprovalQueueLive` → `company:<co>:approvals` (new topic — Gate broadcasts on sentinel add/remove)
  - `AuditLive` → `company:<co>:audit` (Watcher emits on `audit/*.jsonl` append)
  - `HealthLive` → polls Elixir supervision tree + doctor every 3s; no PubSub needed
- **D-15:** Stdout tail — `GlorboWeb.StdoutStreamer` starts a per-agent process on agent-page mount that uses a `File.stream!` + `Process.send_after` polling loop (inotify events indicate "file changed" but don't carry the new bytes; tail from last-read offset). Streams each new line as a PubSub broadcast `{:stdout_line, company, agent, line}` — AgentLive appends to a rolling buffer (last ~1000 lines).
- **D-16:** PubSub topic additions (beyond Phase 3's set): `company:<co>:agents:<ag>:stdout`, `company:<co>:agents:<ag>:budget`, `company:<co>:channels:<channel>`, `company:<co>:approvals`. Watcher's `dispatch_by_prefix` is extended to publish to these.

### Director write-actions
- **D-17:** Post to channel: Director types in `ChannelLive`; LiveView submits `{:post_message, body}`; `GlorboWeb.Actions.post_message/4` authenticates (Director-only; no sender-permission check since the Director is not an agent), appends `## <ISO timestamp> | Director\n<body>\n\n` to `channels/<channel>.md` via `[:append, :sync]`, writes a `chat.post` audit event. Watcher fires, other clients see the update.
- **D-18:** Approve/deny task: ApprovalCard click; `GlorboWeb.Actions.set_approval/4` reads task markdown, updates frontmatter `status:` (via `Glorbo.TaskDefinition.write/2` — small helper that parses frontmatter, updates, writes back atomically), audit event `approval.approve` or `approval.deny`. Watcher fires, Gate (Phase 3) wakes the agent.
- **D-19:** Manual agent wake: AgentLive "Wake agent" button; LiveView submits `{:wake, reason}`; `GlorboWeb.Actions.wake_agent/3` writes `agents/<slug>/state/wake-request.md` (a fourth trigger type the Agent.Server learns about). Watcher fires, Server wakes on the `state/` event prefix (new routing in Watcher's `dispatch_by_prefix`). Reason: keeps "filesystem is source of truth" — the wake is a real file write.
- **D-20:** All write-actions produce audit events with `actor: director`.

### Seven views — key behaviours
- **D-21:** OverviewLive shows companies as cards with (name, # agents, # tasks in-progress, monthly $ spent, alert count, health dot). Click → CompanyLive.
- **D-22:** CompanyLive shows per-company summary at top (agents grid + open-tasks ribbon) + tabbed pane (Kanban | Chat | Approvals | Audit | Agents). Default tab = Kanban.
- **D-23:** KanbanLive renders 3 columns matching task `status:` values (`todo | in-progress | done`). Task cards show title, assignee, priority badge, `requires_approval` lightning glyph if set. Drag-drop deferred to v1.1 — v0.0.1 is read-only (Director edits via text editor).
- **D-24:** AgentLive header shows avatar + role + provider + budget ring (used / cap). Body is split: left = current task + wake history (last 20), right = live stdout (auto-scrolling, last 1000 lines, pause-scroll button). Below: permissions table.
- **D-25:** ChannelLive renders channel markdown with per-entry author + timestamp + body. Message-compose input at bottom for Director posts. Auto-scroll to bottom on new message.
- **D-26:** ApprovalQueueLive lists all `agents/*/state/awaiting-approval-*.md` sentinels across the company with task title + requesting agent + approve/deny buttons.
- **D-27:** AuditLive renders the current month's `audit/YYYY-MM.jsonl` tail (last 500 entries, loadable backward in chunks of 500). Filter by `actor` and `action`. Entries expand to show full JSON payload.
- **D-28:** HealthLive shows Elixir process tree (via `:erlang.processes()` + `:proc_lib.translate_initial_call`), supervisor child states (all per-company), `Glorbo.Doctor.run_checks/0` summary, and Phase-3 integration status (bwrap available? CLI tools on PATH?).

### Styling
- **D-29:** Typography — system monospace UI (terminal aesthetic). CSS `font-family: ui-monospace, Menlo, Consolas, "JetBrains Mono", monospace`.
- **D-30:** Color palette — dark-mode-first. Background `#0d1117` (GitHub dark), surface `#161b22`, text `#c9d1d9`, accent `#58a6ff`, success `#3fb950`, warning `#d29922`, error `#f85149`. Light mode deferred to v1.1.
- **D-31:** Layout — CSS grid for overall app shell; CSS flexbox for card rows. No CSS framework. Total CSS budget: ~500 LOC in `assets/css/app.css`.
- **D-32:** Icons — hand-written inline SVG Phoenix component (D-03). No icon library dep.
- **D-33:** Responsive — desktop-first; sidebar collapses below 900px into hamburger; deferred to v1.1 if time-constrained. Phase 4 ships desktop-only-acceptable.
- **D-34:** Animations — minimal. Transitions (200ms) on hover states + LiveView diffs. No custom keyframes.

### Testing
- **D-35:** LiveView tests via `Phoenix.LiveViewTest` (`Phoenix.LiveView.Test` module); per-view happy-path + 1-2 edge cases.
- **D-36:** Integration tests via `LiveViewTest` + a seeded `~/.glorbo/companies/acme/` fixture; assert real-time updates propagate when fixtures change.
- **D-37:** Visual smoke tests via Playwright (optional — tagged `:e2e`, requires browser on host). `:e2e` tests check rendered-in-browser output; optional because they slow the suite. Defer if time-constrained.

### Claude's Discretion
- Exact color palette hex tweaks (D-30 is a starting point; refine during implementation).
- Sidebar width (200px starting point).
- Card radius (8px starting point).
- Icon SVG details (path data).
- Kanban board column header styling.
- Chat message rendering (markdown → HTML; use `earmark` Hex if full markdown is needed, or keep simpler heading/paragraph).
- Budget ring SVG path calculation (arc math; trivial).
- Whether a `BeforeUnload` warning is needed when Director has unsaved compose input (probably not for v0.0.1).
- Whether stdout highlighting (ANSI color → HTML) is in scope or deferred (deferred unless trivial).
- Route-level LiveView crash recovery UX (standard Phoenix error template is fine).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §9 — Dashboard (Phoenix LiveView). Seven views enumerated.
- `DESIGN.md` §6 — Communication (channel markdown file shape; stdout streaming).
- `DESIGN.md` §8.2 — Approval gates (task frontmatter `status:` mutation by Director).
- `DESIGN.md` §8.3 — Audit log JSONL shape.
- `DESIGN.md` §10 — CLI (especially `glorbo serve` which starts Phoenix).

### Project-level
- `.planning/REQUIREMENTS.md` UI-01, UI-02, UI-03 (3 requirements).
- `.planning/ROADMAP.md` Phase 4 (4 success criteria).
- `CLAUDE.md` — Load-bearing invariants. Dashboard must NOT introduce any state that isn't derivable from filesystem + SQLite; Elixir stays the sole writer of `channels/*.md`.

### Phase 3 handoffs (live dependencies)
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/03-CONTEXT.md` — Watcher PubSub topic schema; Approval gate + sentinel file shape; budget ledger schema; audit event registry.
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` — 20+ audit event `action:` keys the dashboard renders.
- `lib/glorbo/filesystem/watcher.ex` — PubSub broadcaster; Phase 4 extends with new topics (`agents:<ag>:stdout`, `channels:<c>`, `approvals`).
- `lib/glorbo/approvals/gate.ex` — source of approval sentinels; dashboard's ApprovalQueueLive consumes them.
- `lib/glorbo/budget.ex` + `lib/glorbo/budget/ledger.ex` — budget data source; dashboard reads via Ecto.
- `lib/glorbo/company/supervisor.ex` — supervision tree shape; HealthLive introspects.
- `lib/glorbo/doctor.ex` — HealthLive calls `Glorbo.Doctor.run_checks/0`.

### Phase 1/2 infrastructure
- `lib/glorbo_web/endpoint.ex` — Phoenix endpoint (already in place from Phase 1; Phase 4 wires LiveView Socket).
- `lib/glorbo_web/router.ex` — likely a stub; Phase 4 adds the 8 routes.
- `config/config.exs`, `config/dev.exs`, `config/prod.exs` — endpoint port/host config.

### External specs / research
- Phoenix LiveView docs: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html — lifecycle, `handle_info`, `assign`, `stream`.
- Phoenix.PubSub docs: https://hexdocs.pm/phoenix_pubsub — topic conventions, `broadcast_from`.
- `Phoenix.Presence` — if used for dashboard-open indicator.
- `earmark` markdown renderer: https://hexdocs.pm/earmark — if channel markdown rendering wanted.
- File tail pattern in Elixir: `File.stream!` + offset tracking, or a GenServer + `Process.send_after(..., 300ms)` polling loop.
- LiveView streams (new-ish API): `Phoenix.LiveView.stream/4` — good for large scrolling lists (audit, stdout).
- esbuild + Phoenix: https://hexdocs.pm/phoenix/asset_management.html — minimal `assets.setup` + `assets.build` / `assets.deploy` aliases in mix.exs.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable assets
- **Phoenix skeleton** — Endpoint + Router + minimal scaffolding from Phase 1.
- **`Phoenix.PubSub`** — registered in Application supervisor from Phase 2 (named `Glorbo.PubSub`). All Phase 3 Watcher/Router/Gate broadcasts already flow through this.
- **`Glorbo.Filesystem.Watcher`** — per-company inotify watcher with path-prefix dispatch + PubSub broadcast. Extend with new topics rather than replace.
- **`Glorbo.Company.Supervisor`** — per-company 6/7-child supervision tree. HealthLive introspects via `Supervisor.which_children/1`.
- **Ecto schemas** — `Glorbo.Company`, `Glorbo.Agent`, `Glorbo.AuditEvent`, `Glorbo.Budget`, `Glorbo.TasksApprovalState`, `Glorbo.ReindexState`. Dashboard reads via `Glorbo.Repo` queries.
- **`Glorbo.TaskDefinition`** (Phase 3) — task frontmatter parser; dashboard's approval actions use `TaskDefinition.write/2` (if added) for atomic frontmatter mutations.

### Established patterns
- **Dep-injection via opts** — pattern preserved through all prior phases. LiveViews that need injectable dependencies (e.g., a `budget_repo_fun` for testability) should follow.
- **Filesystem-first** — every Director action is a file write. No in-memory state that can't be reconstructed.
- **Append-only audit** — every Director action appends to `audit/YYYY-MM.jsonl`. Never modify.
- **File-artefact hooks** — approval sentinels, budget alerts — Phase 3 shipped the shapes; Phase 4 renders them.

### Integration points
- **Watcher PubSub extension**: Phase 4 adds 4 new topic classes — `agents:<ag>:stdout`, `channels:<c>`, `approvals`, `agents:<ag>:budget`. Watcher's `dispatch_by_prefix` needs the routing.
- **TaskDefinition.write/2**: new helper in `lib/glorbo/task_definition.ex` for atomic frontmatter mutation when Director approves/denies. Should be disjoint from Phase 3 code (extension, not modification).
- **Wake-request files** (`agents/<slug>/state/wake-request.md`) — new Watcher-driven trigger type. Agent.Server consumes it; Phase 4 producer writes it.
- **Phase 5 handoff**: `glorbo serve` CLI verb ships in Phase 5; it's a thin `Glorbo.Endpoint.start_link/0` equivalent. Phase 4's Phoenix config must be compatible with running inside a Burrito release (Phase 1 infrastructure).

</code_context>

<specifics>
## Specific Ideas

- **Everything is a file write.** The dashboard is purely a *renderer*. Every Director write-action (post, approve, wake) resolves to Elixir appending/editing a markdown file on disk. If you skip the file write, the agent layer doesn't know the action happened — and "filesystem is source of truth" breaks.
- **PubSub topics are the only in-memory state.** LiveViews hold render state, but they re-derive it from the filesystem + SQLite on mount. Crash a LiveView, re-mount, everything is there.
- **The "seven views" are the whole feature surface.** No dashboards-of-dashboards, no custom widget builder, no user-configurable layouts. DESIGN.md §9 is the spec.
- **Desktop + terminal aesthetic.** Mono font, dark bg, minimal ornamentation. The dashboard should feel like `htop` with more context — dense, information-rich, low-latency.
- **Approval UX is a single click with audit.** Director clicks "Approve" on a task card → Elixir edits frontmatter → Watcher fires → Gate wakes agent. The click is the trigger; there's no "Are you sure?" dialog (the Director is authenticated by owning the host user; undo is a file edit).
- **Stdout tail is the highest-latency-sensitive element.** Other views update on file-change inotify events (already sub-second). Stdout needs to feel "live" — 200-500ms is fine; anything >1s feels broken. The File.stream! + Process.send_after(300) polling loop per agent page is the v0.0.1 approach.
- **Phase 4 does NOT own authentication.** Director = owner of `~/.glorbo/`. Phoenix binds to loopback. That's the trust boundary; no login page needed. If LAN exposure is needed later (LLM agents running on a home-server), we add a `dashboard_token:` as opt-in.
- **Target feel:** Fresh host, `glorbo init`, `glorbo up` (or `glorbo serve`), open `http://localhost:4000`. See the example `acme` company with its CEO agent. Click CEO → see agent card with "No current task, 3 wake triggers logged, 0 spent this month". Type a message in `#general` chat → @Engineer mention wakes the Engineer (if one existed). Approve a pending task → see it flip to in-progress. All in under 30 seconds of interaction.

</specifics>

<deferred>
## Deferred Ideas

- Multi-user auth / SSO / OAuth (out of v1 trust model).
- Mobile-optimised layouts / responsive below 900px width.
- Custom dashboard layouts / saved views / user-configurable widgets.
- In-browser markdown editor for tasks / agents / channels (Director uses their own editor).
- Dashboard-driven agent creation (AGT-05 locks agent creation to Director filesystem).
- Service Worker / push notifications.
- Real-time stdout ANSI color → HTML (unless trivial).
- Drag-drop kanban reordering (v1.1 if user demand).
- Light mode.
- i18n.
- Dashboard plugin system (out of scope permanently — extensibility via markdown skills).
- Gantt charts / burndown / sprint analytics (v1.1+).
- Cross-company search.
- Dashboard exports (PDF / CSV). Use `jq` on audit JSONL, `cat` on markdown — filesystem-first.
- Mobile native apps.

</deferred>

---

*Phase: 04-liveview-dashboard-real-time-channels*
*Context gathered: 2026-04-16 (--auto)*
