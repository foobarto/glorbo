# Glorbo Web UI — Mockup Alignment Sprint

Source mockup: `~/Pobrane/abc.zip` (7 views — terminal-TUI phosphor aesthetic,
IBM Plex Mono + JetBrains Mono, OKLCH tokens, ASCII tree prefixes,
lowercase-slash panel headers).

Driving goal: bring the LiveView dashboard in line with the mockup's visual
language and feature surface without breaking the filesystem-first
invariants in `DESIGN.md` / `CLAUDE.md`.

---

## Milestone map

| Milestone | Scope                                                 | Status          |
| --------- | ----------------------------------------------------- | --------------- |
| **M1**    | Shell & visual language (tokens, topbar, statusbar, pills) | ✅ shipped      |
| **M2**    | Company overview rewrite (stats + roster + orgchart + audit) | ✅ shipped      |
| **M3**    | Agent detail rewrite (3-column: identity / tabs / config) | ✅ shipped      |
| **M4**    | Kanban drag-drop, Chat switcher+DMs, Approvals diff, Audit search, Providers grid | ✅ shipped      |
| **M5**    | Keyboard shortcuts (`g` prefix), Tweaks persistence, vocab toggle, new-X entry points | 🟡 in progress |

## Prior P0/P1/P2/P3 tracks (completed ahead of M-series)

- **P0** — OverviewLive real stats, AgentLive placeholder removal, HealthLive
  slug (not PID) strings, dead "Agents" tab removed, sidebar footer health
  actually reflects Doctor state, shared `CompanyTabs` with active-state
  persistence across sub-views. All shipped — see recent commit history
  (c470e47 through 6b25e32).
- **P1** — accessibility sweep (ARIA labels, keyboard nav on AuditEntry,
  HealthDot reuse, skip-to-content, distinguishable flash variants). Shipped.
- **P2** — polish (dead `AgentCard`, confirmation dialogs, denial reason,
  Audit month selector, channel auto-scroll, capitalization fix, loading
  states). Shipped.
- **P3** — deferred; feature-scale work requiring own GEPs.

---

## M1 — shell & visual language (shipped)

### M1.1 — OKLCH phosphor token set + font stack
`assets/css/app.css` — base tokens (`--gl-bg`, `--gl-ink`, phosphor green,
amber-warn, rose-stop, muted grays), `IBM Plex Mono` for text /
`JetBrains Mono` for UI chrome.

### M1.2 — `lib/glorbo_web/components/topbar.ex`
Persistent top row. Brand + company picker (writes path from assigns),
version strip: `Application.spec(:glorbo, :vsn)`, `bwrap --version` (shelled,
cached), `uname -r`. Kbd hints, TWEAKS affordance.

### M1.3 — `lib/glorbo_web/components/statusbar.ex`
Persistent bottom row: daemon state, live agent count
(`Glorbo.Agent.Registry.count_match/3`), sqlite pidfile, inotify status,
clock. Pulse animation on the alive dot.

### M1.4 — `lib/glorbo_web/components/status_pill.ex`
Five variants: `:alive | :idle | :warn | :stop | :info`. Plus label+slot.
Replaces scattered inline `<span class="…">` status markers.

### M1 — layouts/app.html.heex
Skip link, topbar above sidebar, statusbar at bottom. Flash variants get
distinct classes (error = rose, info = phosphor).

### M1 — tests
- `test/glorbo_web/components/topbar_test.exs` (5)
- `test/glorbo_web/components/statusbar_test.exs` (6)
- `test/glorbo_web/components/status_pill_test.exs` (7) — `render_pill/1`
  helper to avoid collision with imported `Phoenix.LiveViewTest.render/1`
- `test/glorbo_web/components/stat_card_test.exs` (7)

---

## M2 — company overview rewrite (shipped)

### M2.1 — spark + stat_card components
- `lib/glorbo_web/components/spark.ex` — inline SVG-less sparkline,
  normalizes to 0..1, empty → renders nothing.
- `lib/glorbo_web/components/stat_card.ex` — label/value/unit/sub/spark,
  tone variants `default | accent | amber | rose`.

### M2.2 — CompanyLive rewrite
`lib/glorbo_web/live/company_live.ex`:

- 4-card stat row (agents online / spend MTD / approvals / crashes) with
  synthetic sparklines (`div(System.os_time(:second), 3600)` seed — will
  swap to real audit-backed history in a later milestone).
- Agents roster table: status pill | agent | activity | provider | net |
  budget | last-wake — all pulled from live state.
- ASCII org chart via `build_org_chart/1` walking `reports_to` fields in
  `agent.md` frontmatter (added in M2.0 to `Glorbo.Agent.Spec` +
  `Glorbo.Agent.Parser`).
- Audit tail, projects burn bars (per-project in-progress / pending /
  done), providers runtime summary.

### M2 — css
`.gl-stat-card__*`, `.gl-agent-table`, `.gl-budget-bar`, `.gl-activity`,
`.gl-bar-list`, `.gl-overview__*`, `.gl-orgchart__*`.

### M2 — tests
CompanyLive tests updated for new markup; all green.

---

## M3 — agent detail rewrite (🟡 code complete, uncommitted)

### M3.1 — three-column grid
`lib/glorbo_web/live/agent_live.ex`: `gl-agent-detail__grid` with left
(identity + workspace filetree + not-mounted list), center (tabbed
stdout/sandbox-argv/inbox-outbox), right (config dl + budget meter +
permissions).

### M3.2 — workspace filetree (left column)
ASCII tree prefixes walking `agents/<name>/` (agent.md, inbox/, outbox/,
state/, stdout.log). Entries the agent *can't* see (because bwrap denies)
listed below as "not mounted". Classification via
`Glorbo.Permissions.Mount` vs router-only rules.

### M3.3 — sandbox argv tab (center)
Renders the exact `bwrap` argv that would launch this agent. Same source
of truth as actual launch (`Glorbo.Agent.Sandbox.build_argv/1`). Empty if
not bound to a runtime.

### M3.4 — inbox/outbox tab (center)
Lists `inbox/*.md` and `outbox/*.md` with size / mtime. Filesystem-only —
no SQLite read.

### M3.5 — config / budget / permissions (right column)
- `<dl class="gl-kv">` for config frontmatter.
- `.gl-meter__*` budget meter; threshold-coloured at 80% and 100%.
- `<ul class="gl-perms">` with `mount` vs `router` chips via
  `permission_row/1` + `permission_sandbox_line/1` helpers classifying
  each `resource:action:scope` triple.
- Actions header: inline wake form (unchanged from P0), disabled
  edit / send / stop buttons (P3 — visual completeness only, not wired).

### M3 — css
`.gl-agent-detail__*`, `.gl-agent-identity__*`, `.gl-filetree__*`,
`.gl-sandbox__*`, `.gl-io-*`, `.gl-kv`, `.gl-meter__*`, `.gl-perms`,
`.gl-perm__*`, `.gl-wake-inline__*`. Plus `.gl-perm__token` flex fix for
inline-flex spacing of resource:action:scope segments.

### M3 — tests
`test/glorbo_web/live/agent_live_test.exs`:
- "renders agent header + stdout tab + wake CTA" — tab labels are
  lowercase `stdout` (mockup-aligned).
- "renders three-column layout (identity, center tabs, config)" —
  asserts `gl-agent-detail__grid`, `gl-agent-identity`, `sandbox argv`,
  `inbox/outbox`, `config`.
- "unknown agent redirects to company view" — unchanged.
- "wake button writes state/wake-request.md" — unchanged.

### M3 — gates (last verified before compaction)
- `mix test` → 755/755 green.
- `mix credo --strict` → clean.
- `mix format --check-formatted` → clean (after permissions-token HEEX
  line-split fix).

### M3 — remaining
1. Rerun the three gates after compaction resumes the session.
2. Single commit covering M3.1-M3.5, noting `stop` action is still a
   disabled P3 placeholder (no server-side sentinel yet).

---

## M4 — feature surface per sub-view (⏳ pending)

### M4.1 — Kanban drag-and-drop
`kanban_live.ex`: HTML5 DnD (`phx-hook`) to move tasks between lanes.
Writes the `status` frontmatter field of `projects/*/tasks/*.md` via
`Glorbo.TaskDefinition.write_status/2` (new helper). File-system-first —
the move is a file write; the UI refreshes from inotify.

### M4.2 — Chat channel switcher + DMs
`channel_live.ex`: left-column channel list (all `channels/*.md` +
DM synthesised from pairs of `agents/<a>/outbox → agents/<b>/inbox`). URL
param `?channel=` drives which messages render.

### M4.3 — Approvals diff + keyboard
`approval_queue_live.ex`: unified diff rendering of the pending change;
`j` / `k` to step rows, `y` / `n` to approve/deny (still guarded by
confirmation dialog from P2).

### M4.4 — Audit unified search
`audit_live.ex`: free-text search across the JSONL audit log (streamed,
line-by-line grep — no schema). Query param `?q=…`.

### M4.5 — Providers grid + TOML snippet
`providers_live.ex` (new route `/providers`): card grid of detected CLI
providers from `Glorbo.Provider.Registry`, each card shows the TOML
snippet from `priv/providers/*.toml` (GEP-8).

---

## M5 — polish & shortcuts (⏳ pending)

### M5.1 — keyboard shortcuts (`g` prefix)
`g o` → overview, `g h` → health, `g a` → providers, etc. Implemented via
a single `phx-window-keydown` at layout level dispatching to a small
router module.

### M5.2 — Tweaks persistence
The TWEAKS button in topbar opens a panel (dense / loose, vocab toggle,
colour). Settings persist in `cookie` via `Plug.Conn.put_resp_cookie`
with a small signed session.

### M5.3 — vocab toggle
Alternate labels (eg "agents" ↔ "crew", "companies" ↔ "orgs") keyed off
cookie. Pure render-time lookup in `GlorboWeb.Vocab`.

### M5.4 — "+ new agent / task / company" entry points
P3 features (each one is its own future sprint — shipping only the entry
points here with a "coming soon" flash on submit so the information
architecture is correct).

---

## Deferred (not in this sprint)

- Real audit-backed sparkline history (M2 currently uses a synthetic
  seed).
- The P3 disabled buttons in M3.5 (edit agent.md, send message, stop)
  becoming real — each needs its own GEP.
- Mobile breakpoints — explicit non-goal for the dashboard; it is a
  desktop TUI-style tool.

---

## Repo / env cheatsheet

- Env: `eval "$(mise activate bash)" && export LD_LIBRARY_PATH=/home/linuxbrew/.linuxbrew/lib:$LD_LIBRARY_PATH`
- Test: `mix test`
- Lint: `mix credo --strict`
- Format: `mix format --check-formatted`
- Full gate: `mix precommit`
- Mockup source: `~/Pobrane/abc.zip`

## Current progress snapshot

- Working tree modified files (uncommitted):
  - `assets/css/app.css`
  - `lib/glorbo_web/live/agent_live.ex`
  - `test/glorbo_web/live/agent_live_test.exs`
- Untracked: `TODO.md`, `TODO2.md` (scratch; to delete once M-series
  finishes).
- Branch: `main`, 48 commits ahead of `origin/main`.
- Immediate next: rerun gates → single commit for M3 → start M4.1
  (Kanban DnD).
