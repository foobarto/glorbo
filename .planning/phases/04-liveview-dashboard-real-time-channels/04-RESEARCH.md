# Phase 4: LiveView Dashboard + Real-Time Channels — Research

**Researched:** 2026-04-16
**Domain:** Phoenix LiveView 1.1 + Phoenix.PubSub + inotify-driven file tailing + Burrito-compat dashboard
**Confidence:** HIGH

## Summary

Phase 4 wires a Phoenix LiveView dashboard (`http://localhost:4000`) that renders 8 views as pure projections of `~/.glorbo/companies/`. All existing Phase 3 plumbing stays — PubSub topology, Watcher, Approvals.Gate, AuditLog, TaskDefinition parser. Phase 4 adds: (a) 8 LiveView modules under `lib/glorbo_web/live/`, (b) ~12 functional components in `GlorboWeb.CoreComponents` + a few per-component files, (c) 4 new PubSub topic classes in Watcher.dispatch_by_prefix, (d) `Glorbo.TaskDefinition.write/2` for atomic frontmatter mutation, (e) a new `state/wake-request.md` prefix routing so Director-triggered wakes are real file writes, (f) reintroduction of the esbuild asset pipeline (stripped in Phase 1), (g) `earmark` + `html_sanitize_ex` for channel markdown rendering.

Every Director write-action resolves to a filesystem mutation; Elixir stays the sole writer of `channels/*.md`; LiveView holds zero state that isn't re-derivable on remount. The highest-latency-sensitive surface is stdout tailing, handled by a per-agent-page `GlorboWeb.StdoutStreamer` GenServer using `File.open!/2` + offset tracking + `Process.send_after(self(), :poll, 300)` — inotify events only tell us *that* the file changed, not the new bytes.

**Primary recommendation:** Structure the phase as **3 plans in 2 waves**:
- Wave 0: esbuild + asset pipeline reintroduction + Watcher PubSub extension + TaskDefinition.write/2 + StdoutStreamer + Director Actions module + test fixtures. (1 plan, foundational)
- Wave 1: three parallel LiveView plans — (a) OverviewLive + CompanyLive + KanbanLive + AgentLive + shared components, (b) ChannelLive + ApprovalQueueLive + AuditLive + chat markdown rendering, (c) HealthLive + Router wiring + Burrito serve integration + end-to-end integration tests. (2 plans parallel + 1 integration plan after merge is overkill for a dashboard that's 500 LOC CSS + ~2500 LOC Elixir; prefer 2 parallel plans + verify.)

Final shape: **3 plans, 2 waves** (Wave 0 foundation; Wave 1 two parallel implementation plans + an integration/verify checkpoint).

---

## User Constraints (from CONTEXT.md)

### Locked Decisions

**Framework / tooling / assets:**
- D-01: Phoenix LiveView only — no React/Vue/Svelte. Server-rendered HTML with LiveView diffs.
- D-02: `esbuild` reintroduced (Phase 1 stripped it). **No Tailwind.** Plain CSS with CSS custom properties.
- D-03: `heroicons` not re-added; ship a ~9-glyph inline-SVG icon component set. (UI-SPEC upgrades 6–8 → 9: `check`, `x`, `play`, `pause`, `user`, `folder`, `message`, `lightning`, `pulse`.)
- D-04: Dev = `phx.server`. Prod = Burrito single-binary on `0.0.0.0:4000` default; loopback default per D-06.
- D-05: Assets at `assets/js/` + `assets/css/`. Hand-written CSS, ~400–600 LOC total. No PostCSS beyond esbuild.

**Authentication:**
- D-06: **No login page in v0.0.1.** Phoenix bound to `127.0.0.1:4000` by default; optional `dashboard_token:` query param from `~/.glorbo/config.md`.
- D-07: CSRF + LiveView session secret = generated `secret_key_base:` stored in `~/.glorbo/config.md` on first boot.

**Routes + layout:**
- D-08: 8 routes — `/` (redirect `/companies`), `/companies`, `/companies/:company`, `/companies/:company/kanban`, `/companies/:company/agents/:agent`, `/companies/:company/channels/:channel`, `/companies/:company/approvals`, `/companies/:company/audit`, `/health`.
- D-09: Persistent left sidebar (220px fixed) + companies list + bottom health strip.
- D-10: Browser back-nav only; no custom history.

**LiveView structure:**
- D-11: 8 LV modules under `lib/glorbo_web/live/`: `OverviewLive`, `CompanyLive`, `KanbanLive`, `AgentLive`, `ChannelLive`, `ApprovalQueueLive`, `AuditLive`, `HealthLive`.
- D-12: Shared components under `lib/glorbo_web/components/`: `CompanyCard`, `AgentCard`, `TaskCard`, `ApprovalCard`, `ChannelMessage`, `AuditEntry`, `BudgetRing`, `StdoutTail`, `Icon`.
- D-13: `Phoenix.Presence` on `dashboard:*` topic — **low priority**, defer if time-constrained.

**Real-time pipeline:**
- D-14: Subscribe on `mount/3` to Phase-3 topics; add per-view overrides.
- D-15: Stdout tail = per-agent-page `GlorboWeb.StdoutStreamer` GenServer; `File.stream!` / offset tracking + `Process.send_after(self(), :poll, 300ms)`; broadcast `{:stdout_line, company, agent, line}` via PubSub.
- D-16: 4 new PubSub topics: `company:<co>:agents:<ag>:stdout`, `company:<co>:agents:<ag>:budget`, `company:<co>:channels:<channel>`, `company:<co>:approvals`. Extend `Watcher.dispatch_by_prefix`.

**Director write-actions:**
- D-17: Post to channel = append to `channels/<channel>.md` with `[:append, :sync]`, emit `chat.post` audit event. `GlorboWeb.Actions.post_message/4`.
- D-18: Approve/deny task = `Glorbo.TaskDefinition.write/2` edits frontmatter `status:`, audit event `approval.approve` / `approval.deny`. Gate (Phase 3) wakes agent via existing PubSub path.
- D-19: Manual wake = `GlorboWeb.Actions.wake_agent/3` writes `agents/<slug>/state/wake-request.md`. Watcher gets a new `state/` prefix routing; Agent.Server subscribes to new topic `company:<co>:agents:<ag>:wake`. **Fourth wake trigger type** (after inbox / heartbeat / mention).
- D-20: All write-actions produce audit events with `actor: director`.

**View behaviours:** D-21..D-28 lock per-view layouts (see CONTEXT.md lines 94–102 verbatim).

**Styling:** D-29..D-34 — mono UI stack, GitHub-dark palette (verified in UI-SPEC §Color), ~500 LOC CSS budget, minimal animations.

**Testing:** D-35 `Phoenix.LiveViewTest` happy + edges; D-36 fixture-driven integration; D-37 optional Playwright `:e2e`.

### Claude's Discretion

- Color-palette hex tweaks within GitHub-dark range (UI-SPEC locked the specific values — consume as-is).
- Sidebar width (UI-SPEC locked 220px).
- Card radius (UI-SPEC locked 6px).
- Icon SVG path details.
- Kanban column header styling (UI-SPEC locked).
- Chat markdown rendering — UI-SPEC already picked `earmark` with a sanitizer allowlist.
- Budget ring SVG math (UI-SPEC locked threshold mapping).
- `BeforeUnload` on compose draft — **skip** per UI-SPEC Motion table (Escape clears draft).
- Stdout ANSI color — **defer** (UI-SPEC: strip ANSI server-side before PubSub).
- LiveView route-crash UX — default Phoenix error template.

### Deferred Ideas (OUT OF SCOPE)

Multi-user auth / SSO / OAuth. Mobile / <900px responsive. Custom dashboard layouts / saved views. In-browser markdown editor. Dashboard-driven agent creation. Service Worker / push notifications. ANSI color rendering in stdout. Drag-drop kanban. Light mode. i18n. Plugin system. Gantt / burndown. Cross-company search. Dashboard exports (PDF/CSV). Mobile native apps.

---

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| UI-01 | Phoenix LiveView dashboard on `localhost:4000` — 7 views (overview, kanban, agent detail w/ stdout, chat, approvals, audit, health). | §Standard Stack (Phoenix LiveView 1.1.28, verified via hex.pm); §Architecture Patterns (LV module layout, mount/subscribe pattern); §Code Examples (LV template + component structure). |
| UI-02 | Phoenix Channels + PubSub deliver sub-second real-time updates for agent chat and stdout streaming. | §Watcher Extension (4 new topic classes); §StdoutStreamer (per-page polling loop since inotify doesn't carry bytes); §LiveView streams for rolling stdout with limit. |
| UI-03 | Append-only channel markdown files; Elixir is sole writer; `@agent` mention wakes the agent. | §Director Actions (`post_message` uses `File.open!(path, [:append, :sync])`); §Sole-writer safeguard + dedup strategy; Phase 3 Router already handles `@` mention fanout once Watcher fires on `channels/`. |

---

## Project Constraints (from CLAUDE.md)

The following are load-bearing invariants. Research and planning MUST NOT produce designs that violate these:

1. **Kernel is the policy engine.** (N/A for Phase 4 directly — dashboard is a Director surface; no agent permissions are evaluated here. The Director is trusted by host-user ownership.)
2. **Filesystem is the source of truth.** Dashboard must NOT hold any in-memory state that isn't re-derivable from disk + SQLite on remount. Every Director click that mutates state writes to a file FIRST.
3. **One-way inbox/outbox flow.** Dashboard never writes to `agents/<name>/inbox/` — only Elixir's Router does. Wake-requests go to `agents/<name>/state/` (new prefix, not inbox).
4. **Audit log is append-only.** Every Director action emits a `chat.post | approval.approve | approval.deny | agent.wake_request` audit event via `Glorbo.Company.AuditLog.append/2` — never via direct SQLite write.
5. **Python never runs on the host.** (N/A — no Python in Phase 4. Dashboard is pure Elixir.)
6. **Company isolation is absolute.** Routes are company-scoped; LiveViews mount with `:company` param and reject mismatched PubSub events.
7. **Crash isolation follows the OTP supervision tree.** `StdoutStreamer` GenServers are started per-LiveView-mount and MUST be cleaned up on unmount; they live under a `DynamicSupervisor`, not linked directly to the LV (crash in streamer = restart streamer, not the LV).

**Phase 4 specific:** Director is NOT an agent — `chat:write` permission check is skipped. Director's sole-operator auth is loopback-bind + filesystem ownership.

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `phoenix` | 1.8.5 | HTTP + routing framework (already in mix.lock) | [VERIFIED: mix.lock] Latest stable Phoenix 1.8 line. |
| `phoenix_live_view` | 1.1.28 | Server-rendered reactive UI | [VERIFIED: hex.pm 2026-03-27] Current stable LV 1.1 line; already in mix.lock. |
| `phoenix_pubsub` | 2.2.0 | Topic-based broadcast (already in supervisor as `Glorbo.PubSub`) | [VERIFIED: mix.lock] Phase 2 wired; Phase 4 extends. |
| `phoenix_html` | 4.2 | HEEx templates + helpers | [VERIFIED: mix.lock] Phase 1 dep. |
| `bandit` | 1.6 | HTTP 1/2 server adapter | [VERIFIED: mix.lock] Phase 1 dep; Phoenix 1.8 default. |
| `file_system` | 1.1.1 | inotify watcher (already in Watcher) | [VERIFIED: mix.lock] Phase 2 dep; Phase 4 does NOT add additional watchers — only new topic routing in existing Watcher. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `esbuild` (Hex) | 0.10.0 | Elixir wrapper for the `esbuild` binary; auto-downloads per-target binary to `_build/`; no `npm` or `package.json` required | [VERIFIED: hex.pm 2025-05-27] Preferred over `npm install esbuild` — keeps the repo Node-free. |
| `earmark` | 1.5.0-pre1 (or stable 1.4.x) | Markdown renderer for chat message bodies | [VERIFIED: hex.pm] UI-SPEC locked; GFM subset + hard-break friendly. Note: 1.5.0-pre1 is pre-release; **recommend pinning 1.4.x stable** unless Phase 4 needs new features. [ASSUMED] 1.4.46 is the current stable — verify with `mix hex.info earmark` before plan execution. |
| `html_sanitize_ex` | 1.5.0 | Allowlist-based HTML scrubber for Earmark output | [VERIFIED: web docs 2026-03-29] Industry-standard Elixir HTML sanitizer; `HtmlSanitizeEx.markdown_html/1` is the canonical scrubber for user-typed markdown. Earmark has NO built-in sanitization and explicitly says "sanitize the output." |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `earmark` | `md` (ExDoc's shared backend) or pure-regex pre-pass | earmark is the established Elixir markdown lib; UI-SPEC already locked it. |
| `html_sanitize_ex` | Custom allowlist via regex | Trivial XSS surface if hand-rolled; use the lib. |
| `esbuild` Hex wrapper | `npm install esbuild` in `assets/package.json` | Hex wrapper avoids the npm dependency entirely; Phase 1 deliberately stripped the JS ecosystem. Choose the wrapper. |
| Phoenix LiveDashboard | Custom HealthLive | LiveDashboard shows generic BEAM/process info but not Glorbo's company/agent model. HealthLive is ~80 LOC; don't pull the dep. UI-SPEC confirms "overkill — stay with hand-written component." |
| `Phoenix.LiveView.stream/4` with `limit: -N` | Traditional `assign` with `Enum.take/2` | Streams avoid re-sending the full list on every update; use streams for audit (500+ rows), stdout (1000 rolling lines), and kanban tasks (per-column). |

### Installation

Add to `mix.exs` deps:

```elixir
{:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
{:earmark, "~> 1.4"},
{:html_sanitize_ex, "~> 1.5"},
```

Note: `esbuild` uses `runtime: Mix.env() == :dev` so it doesn't ship inside the Burrito release binary — production uses pre-built `priv/static/assets/`.

**Version verification (ASSUMED items):** Run `mix hex.info earmark` to confirm latest 1.4.x stable vs 1.5.0-pre1 before committing.

---

## Architecture Patterns

### Recommended Project Structure

```
lib/glorbo_web/
├── endpoint.ex                       # existing (Phase 1) — wire LiveView Socket
├── router.ex                         # existing (Phase 1) — add 8 routes
├── telemetry.ex                      # existing
├── controllers/                      # existing — keep PageController for /health fallback
│   ├── error_html.ex
│   ├── error_json.ex
│   └── page_controller.ex
├── components/
│   ├── core_components.ex            # extend: .icon, .health_dot, .tab_bar, .sidebar
│   ├── layouts.ex                    # extend: app layout + root layout
│   ├── layouts/
│   │   ├── root.html.heex            # existing — extend with CSS asset link
│   │   └── app.html.heex             # NEW — sidebar + main-pane grid shell
│   ├── company_card.ex               # NEW
│   ├── agent_card.ex                 # NEW
│   ├── task_card.ex                  # NEW
│   ├── approval_card.ex              # NEW
│   ├── channel_message.ex            # NEW
│   ├── audit_entry.ex                # NEW
│   ├── budget_ring.ex                # NEW
│   └── stdout_tail.ex                # NEW
├── live/                             # NEW directory
│   ├── overview_live.ex              # /companies
│   ├── company_live.ex               # /companies/:company
│   ├── kanban_live.ex                # /companies/:company/kanban
│   ├── agent_live.ex                 # /companies/:company/agents/:agent
│   ├── channel_live.ex               # /companies/:company/channels/:channel
│   ├── approval_queue_live.ex        # /companies/:company/approvals
│   ├── audit_live.ex                 # /companies/:company/audit
│   └── health_live.ex                # /health
├── actions/                          # NEW — Director write-actions
│   └── actions.ex                    # GlorboWeb.Actions.post_message, set_approval, wake_agent
└── stdout_streamer.ex                # NEW — GenServer (per LV mount) for tail-log polling
                                       # Alternatively: lib/glorbo/stdout_streamer.ex (Glorbo namespace)
                                       #   — prefer GlorboWeb because it's a UI-specific concern.

assets/                               # NEW (reintroduced after Phase 1 strip)
├── css/
│   └── app.css                       # ~500 LOC hand-written
└── js/
    └── app.js                        # ~40 LOC: Socket + LiveSocket + 2–3 hooks

priv/static/                          # existing; esbuild outputs here
└── assets/
    ├── app.css                       # copied by esbuild --loader=css
    └── app.js                        # bundled by esbuild
```

**Module layout rationale (gap 1 — "8 LVs + shared components to avoid circular mount deps"):**

- LiveViews subscribe to PubSub topics but **never call each other**. A click in `CompanyLive` that navigates to `/companies/:co/kanban` goes through `push_navigate/2`, which tears down the current LV and mounts `KanbanLive` fresh — no cross-LV communication.
- Shared components are pure `Phoenix.Component` functions (stateless) — they take assigns and render HEEx. No mounted state, no subscribe. They live in `GlorboWeb.Components.*` or extend `CoreComponents`.
- **Anti-pattern to avoid:** LiveComponents (`Phoenix.LiveComponent`) for the card widgets. LiveComponents have their own mount/update/handle_event lifecycle; they're overkill for read-only cards. Use function components unless you specifically need per-card interactivity with server state (we don't — all clicks bubble to the parent LV via `phx-click`).

### Pattern 1: LiveView Mount + PubSub Subscribe

**What:** Every LV subscribes on `mount/3` guarded by `connected?/1` to avoid double-subscribing during disconnected render (mount runs twice — once SSR, once on WebSocket connect).

**When to use:** Every LV in this phase.

**Example:**

```elixir
# Source: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html
# (pattern verified against LV 1.1.28 docs)
defmodule GlorboWeb.ChannelLive do
  use GlorboWeb, :live_view

  @impl true
  def mount(%{"company" => co, "channel" => ch}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels:#{ch}")
    end

    messages = load_channel_messages(co, ch)  # pure filesystem read

    socket =
      socket
      |> assign(company: co, channel: ch)
      |> stream(:messages, messages, limit: -500)

    {:ok, socket}
  end

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    # File changed on disk — re-read tail (since inotify doesn't carry bytes)
    # and stream-insert any new messages.
    new = tail_new_messages(socket.assigns.company, socket.assigns.channel,
                            since: socket.assigns.last_offset)

    socket = Enum.reduce(new, socket, fn msg, acc ->
      stream_insert(acc, :messages, msg, at: -1, limit: -500)
    end)

    {:noreply, socket}
  end
end
```

### Pattern 2: Phoenix.LiveView Streams for Rolling Lists

**What:** `stream/4` with `limit: -N` maintains a rolling list on the client; older items are pruned automatically as new ones append.

**When to use:**
- **Audit log** (500-entry page with "Load 500 older" — prepend older with `at: 0`).
- **Stdout tail** (1000 rolling lines, append with `at: -1, limit: -1000`).
- **Kanban tasks per column** (each column is a stream; reordering is fine since tasks carry a DOM id).

**Anti-pattern:** Don't use streams for the 8 company cards in OverviewLive — they all render at once and fit comfortably in regular `@companies` assign. Streams earn their complexity above ~100 items.

**Example (stdout rolling tail):**

```elixir
# Source: https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#stream/4
def mount(%{"company" => co, "agent" => ag}, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:stdout")
    # Start per-mount stdout streamer under DynamicSupervisor
    {:ok, pid} = GlorboWeb.StdoutStreamer.start(co, ag)
    Process.monitor(pid)
    socket = assign(socket, :streamer_pid, pid)
  end

  {:ok, stream(socket, :stdout, [], limit: -1000)}
end

def handle_info({:stdout_line, _co, _ag, line}, socket) do
  {:noreply, stream_insert(socket, :stdout, %{id: line.id, body: line.body},
                            at: -1, limit: -1000)}
end

def terminate(_reason, socket) do
  # Stop the per-mount streamer cleanly. Process.monitor above ensures
  # we also learn about streamer crashes (fall back to re-spawn).
  if pid = socket.assigns[:streamer_pid], do: GlorboWeb.StdoutStreamer.stop(pid)
  :ok
end
```

### Pattern 3: Functional Components in a Single Module

**What:** Phoenix.Component's `attr/3` + `slot/3` + a render function. Per-UI-SPEC we have 9+ components; keep them as one function each in per-file modules for grep-ability but skip `LiveComponent`.

**When to use:** All reusable UI cells (company_card, agent_card, task_card, etc.).

**Example:**

```elixir
# Source: https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html
defmodule GlorboWeb.Components.AgentCard do
  use Phoenix.Component

  alias GlorboWeb.CoreComponents

  attr :agent, :map, required: true
  attr :company_slug, :string, required: true

  def agent_card(assigns) do
    ~H"""
    <a class="gl-agent-card" href={~p"/companies/#{@company_slug}/agents/#{@agent.slug}"}>
      <header>
        <CoreComponents.icon name="user" />
        <span class="gl-agent-name">{@agent.name}</span>
        <span class="gl-muted">{@agent.role}</span>
      </header>
      <GlorboWeb.Components.BudgetRing.budget_ring used={@agent.used} cap={@agent.cap} size={40} />
    </a>
    """
  end
end
```

### Anti-Patterns to Avoid

- **Writing to `channels/*.md` from the LiveView process.** Always funnel through `GlorboWeb.Actions.post_message/4` so the audit event and sole-writer contract are in one place.
- **Holding in-memory `messages: [...]` list per-LV.** Use `stream/4` so remount cost = filesystem-read only.
- **Subscribing to PubSub without `connected?/1` guard.** Double-subscribes during SSR + WS connect, doubling all `handle_info` delivery.
- **Linking `StdoutStreamer` to the LiveView pid.** If the streamer crashes, the LV crashes too. Use `DynamicSupervisor.start_child/2` + `Process.monitor/1`.
- **Hand-rolling HTML sanitization.** Use `html_sanitize_ex`; the XSS surface is tiny but real.
- **LiveComponent for the cards.** They need no local state; function components are cheaper and simpler.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tail a growing file | Custom inotify consumer | `File.open!/2` + `:file.position/2` + `Process.send_after` | inotify only fires "changed" events without new bytes; polling the file offset is unavoidable. See §StdoutStreamer. |
| Markdown → HTML | Regex replacement | `earmark` + `html_sanitize_ex` | GFM details (tables, autolinks, fenced code) are nontrivial; sanitization is table-stakes. |
| YAML frontmatter rewrite | String-split + regex | **Must build a small helper** (`TaskDefinition.write/2`) — see §Director Action Atomicity. `yaml_front_matter` / `yaml_elixir` parse but don't write; we build a tiny serialization helper that preserves unknown keys. | No complete Elixir YAML round-tripper; but we own the write-side for a narrow key set (`status`, `denial_reason`). |
| Atomic file-write | `File.write!(path, body)` (partial write risk on crash) | `File.write!(tmp, body); File.rename!(tmp, final)` | Rename is atomic on the same filesystem; protects against partial reads by Watcher. |
| Asset bundler | Custom cat/minify | `esbuild` Hex wrapper | Auto-downloads per-platform binary; no npm; integrates with `mix assets.build`. |
| LV socket routing | Hand-rolled WebSocket | Phoenix's built-in `socket "/live"` already in endpoint.ex | Already wired in Phase 1; nothing to do. |
| Rolling list with limit | Keep in assigns + `Enum.take` | `Phoenix.LiveView.stream/4` with `limit: -N` | Stream-based; client-side pruning; avoids resending full list per update. |
| CSRF / session signing | Custom token | Phoenix session + `protect_from_forgery` plug | Already in router.ex. |

**Key insight:** Phase 4 is a thin rendering + action surface over infrastructure that already exists. Most "hard problems" (file watching, permissions, audit, budget, approvals gate) belong to Phase 3. Don't rebuild them.

---

## Runtime State Inventory

Phase 4 is greenfield for the dashboard surface but **does not** rename/refactor anything in the Phase 3 codebase. No runtime state migration is needed. However, two items are worth explicit accounting:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **Nothing new persisted.** Dashboard reads SQLite via existing Ecto schemas (`Company`, `Agent`, `AuditEvent`, `Budget`, `TasksApprovalState`). LV assigns are transient. | None. |
| Live service config | `~/.glorbo/config.md` gains a `secret_key_base:` key (generated on first boot) and an optional `dashboard_token:` — read by `runtime.exs` on Burrito boot. | Add config.md parsing to `Glorbo.Config` (new small module) or extend Phase 2's init. |
| OS-registered state | None — no systemd / launchd / Task Scheduler. Phoenix Endpoint is a child in the Elixir supervision tree, started by `Glorbo.Application`. | None. |
| Secrets/env vars | `SECRET_KEY_BASE` (optional override); `PORT` / `PHX_HOST` (optional override). All already handled in `config/runtime.exs` — extend to read from `~/.glorbo/config.md` when env var is absent. | Small diff to runtime.exs to prefer config.md over env var fallback. |
| Build artifacts | `priv/static/assets/app.js` and `priv/static/assets/app.css` — produced by `mix assets.build` / `assets.deploy`. Must be shipped inside the Burrito release (Phase 1 stripped them, so `mix release` currently skips them). | Update `mix.exs` aliases + ensure the Burrito `steps: [:assemble, &Burrito.wrap/1]` picks up `priv/static`. |

**Nothing found in category:** All accounted for.

---

## Common Pitfalls

### Pitfall 1: inotify fires but the new bytes aren't delivered

**What goes wrong:** inotify (via `file_system` lib) emits `{:file_event, pid, {path, events}}` but `events` is `[:modified]`, `[:created]`, etc. — **no payload**. If the LV naively re-reads the whole file on every event, stdout tailing becomes O(N²).

**Why it happens:** inotify is a kernel notification, not a streaming interface. Only the filename and event type cross the boundary.

**How to avoid:** Track an offset per-file. On each event, `:file.position/2` to the previous offset, read to EOF, split on newlines, advance offset. `StdoutStreamer` encapsulates this.

**Warning signs:** Stdout view's memory grows with the log; updates feel laggy after a few MB.

### Pitfall 2: LiveView mounted twice ⇒ duplicate PubSub subscriptions

**What goes wrong:** Every mount runs (a) during HTTP render (disconnected) and (b) on WebSocket connect (connected). If you `Phoenix.PubSub.subscribe/2` in both, you get duplicate `handle_info` deliveries.

**Why it happens:** Phoenix's SSR + live-mount model. Two separate LV processes touch the same topic.

**How to avoid:** Guard with `if connected?(socket), do: subscribe(...)`. The disconnected render needs the initial data (re-fetch from disk/SQLite), not the live stream.

**Warning signs:** Chat messages appearing twice; audit rows flickering; "phantom" stdout lines.

### Pitfall 3: Director posts a message → dashboard shows it twice

**What goes wrong:** Director clicks Send → LV optimistically appends (for snappy UX) → Actions.post_message writes file → Watcher fires → LV receives `{:file_event, ...}` → LV appends AGAIN.

**Why it happens:** Optimistic UI + real file-event path both mutate the stream.

**How to avoid:** **Do NOT optimistically append.** Submit → disable compose → on success the Watcher event arrives within ~200ms and `stream_insert` renders it. The compose input shows a transient "Posting…" state but doesn't pre-render the message. **Alternatively**, tag each message with a deterministic id (timestamp + author hash) and use `stream_insert` which upserts by id — the optimistic insert is replaced by the real insert without duplication. Pick the simpler option first (no optimistic) unless UX is visibly sluggish.

**Warning signs:** Duplicate messages in chat; "flash" effect where own message renders twice.

### Pitfall 4: StdoutStreamer leaks processes on rapid navigation

**What goes wrong:** Director opens AgentLive for Agent A (starts streamer A), immediately clicks Agent B (starts streamer B). If A's streamer is linked to LV-A and terminate/2 doesn't fire cleanly, A keeps polling.

**Why it happens:** LiveView's `terminate/2` is only called when trapping exits; `Process.flag(:trap_exit, true)` is required, and even then some crash modes skip it.

**How to avoid:** (a) Start streamers under a named `DynamicSupervisor` (`GlorboWeb.StdoutStreamer.Supervisor`), (b) use `Process.monitor(streamer_pid)` from the LV so dead LVs' streamers get the `:DOWN` message and self-terminate, (c) streamer self-terminates when no `handle_info(:poll, ...)` deliveries succeed OR when the monitored LV process dies.

**Warning signs:** `Process.list() |> length` grows over time; CPU climbs during idle.

### Pitfall 5: Frontmatter write corrupts the task file

**What goes wrong:** `Glorbo.TaskDefinition.write/2` parses `status: pending`, flips to `status: approved`, re-serializes. If the original YAML had quirks (comments, unquoted strings, multi-line values), the round-trip loses them.

**Why it happens:** YAML is not a lossless round-trip format; no Elixir library preserves structure on write.

**How to avoid:**
1. **Narrow-scope rewrite.** Only edit the specific keys we own (`status:`, `denial_reason:`). Everything else in the frontmatter is preserved by string-level substitution.
2. **Atomic temp-file + rename.** Never leave a half-written file visible to Watcher.
3. **Re-parse after write.** If parse fails, roll back (restore original from the temp copy) and emit `approval.write_failed` audit.

**Warning signs:** Task files losing comments; frontmatter indentation drifting; Gate emits `approval.parse_error` after a write.

### Pitfall 6: Burrito release doesn't ship `priv/static/assets/`

**What goes wrong:** `mix release` skips `priv/static/assets/` because Phase 1 stripped esbuild and the asset manifest. Built binary serves 404 on `/assets/app.js`.

**Why it happens:** Phase 1's `01-03` plan deliberately removed `mix assets.deploy` from CI; the release step no longer builds assets.

**How to avoid:** (a) Reinstate `"assets.deploy": ["esbuild glorbo --minify", "phx.digest"]` in `mix.exs` aliases; (b) CI must run `mix assets.deploy` BEFORE `mix release`; (c) verify `priv/static/assets/` exists and is included — `mix phx.digest` generates `cache_manifest.json` which Phoenix static plug needs.

**Warning signs:** Built binary's dashboard renders with no CSS / no JS; browser console shows 404 for `/assets/app.js`.

### Pitfall 7: Company-scoped LV receives events for other companies

**What goes wrong:** A subtle copy-paste bug subscribes to `"company:*:audit"` instead of `"company:#{co}:audit"`. Director browsing acme sees sidehustle's audit events.

**Why it happens:** PubSub topic is a string; typos slip through.

**How to avoid:** Build topics through helpers in a single module (`Glorbo.PubSub.Topics`) and assert in tests that mismatched events are dropped in `handle_info`. Phase 3's Watcher already scopes by company; keep that contract.

**Warning signs:** Cross-company data leaks in audit / chat / approvals views.

---

## Code Examples

### StdoutStreamer (gap 3 — concrete implementation)

```elixir
# lib/glorbo_web/stdout_streamer.ex
# Source: idiomatic Elixir file-tail pattern (not from a single URL; composed
# from File.open/2 docs + Process.send_after docs + Phoenix.PubSub docs).
defmodule GlorboWeb.StdoutStreamer do
  @moduledoc """
  Per-agent-page file-tail poller. Started from AgentLive.mount/3 under a
  DynamicSupervisor; monitored by the LV so crashes are survivable.

  Opens `stdout.log` at current EOF, then every 300ms:
    1. :file.position(io, :cur)      — current offset
    2. :file.read(io, 64_000)        — read up to 64KB of new bytes
    3. Split on "\\n", broadcast each line as {:stdout_line, co, ag, line}

  64KB cap prevents a runaway agent from blocking the scheduler on a single
  read. Remaining bytes are picked up on the next 300ms poll.
  """
  use GenServer
  require Logger

  @poll_ms 300
  @read_chunk 64_000

  def start(company, agent, opts \\ []) do
    DynamicSupervisor.start_child(
      GlorboWeb.StdoutStreamer.Supervisor,
      {__MODULE__, Keyword.merge(opts, company: company, agent: agent)}
    )
  end

  def stop(pid), do: GenServer.stop(pid, :normal)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    agent = Keyword.fetch!(opts, :agent)
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    path = Path.join([base, "companies", company, "agents", agent, "stdout.log"])

    with {:ok, io} <- File.open(path, [:read, :binary, :raw]),
         {:ok, _} <- :file.position(io, :eof) do
      Process.send_after(self(), :poll, @poll_ms)
      {:ok, %{io: io, path: path, company: company, agent: agent,
              pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
              buf: ""}}
    else
      {:error, :enoent} ->
        # stdout.log not yet created — poll and open lazily
        Process.send_after(self(), :open_retry, @poll_ms)
        {:ok, %{io: nil, path: path, company: company, agent: agent,
                pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub), buf: ""}}
    end
  end

  @impl true
  def handle_info(:poll, %{io: nil} = state), do: handle_info(:open_retry, state)

  def handle_info(:poll, state) do
    case :file.read(state.io, @read_chunk) do
      {:ok, bytes} ->
        state = flush_lines(state.buf <> bytes, state)
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, state}
      :eof ->
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, state}
      {:error, reason} ->
        Logger.warning("[stdout_streamer] read failed: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}
    end
  end

  def handle_info(:open_retry, state) do
    case File.open(state.path, [:read, :binary, :raw]) do
      {:ok, io} ->
        {:ok, _} = :file.position(io, :eof)
        Process.send_after(self(), :poll, @poll_ms)
        {:noreply, %{state | io: io}}
      {:error, _} ->
        Process.send_after(self(), :open_retry, @poll_ms)
        {:noreply, state}
    end
  end

  defp flush_lines(bytes, state) do
    # Split on newlines; keep trailing partial-line in buffer for next poll.
    parts = String.split(bytes, "\n")
    {complete, [tail]} = Enum.split(parts, -1)

    Enum.each(complete, fn line ->
      line = strip_ansi(line)  # regex: ~r/\x1B\[[0-9;]*[a-zA-Z]/
      Phoenix.PubSub.broadcast(
        state.pubsub,
        "company:#{state.company}:agents:#{state.agent}:stdout",
        {:stdout_line, state.company, state.agent, %{id: make_id(), body: line}}
      )
    end)

    %{state | buf: tail}
  end

  defp make_id, do: System.unique_integer([:positive, :monotonic])
  defp strip_ansi(s), do: Regex.replace(~r/\x1B\[[0-9;]*[a-zA-Z]/, s, "")

  @impl true
  def terminate(_reason, %{io: io}) when not is_nil(io), do: File.close(io)
  def terminate(_, _), do: :ok
end
```

Add to `Glorbo.Application.start_supervision_tree/0`:

```elixir
{DynamicSupervisor, name: GlorboWeb.StdoutStreamer.Supervisor, strategy: :one_for_one},
```

### TaskDefinition.write/2 (gap 4 — atomic frontmatter mutation)

```elixir
# Extension to lib/glorbo/task_definition.ex
# Source: atomic-rename pattern (File.rename/2 docs) + Frontmatter safe-loader.
# Narrow scope: ONLY overwrites status + denial_reason keys; preserves everything
# else in the original file verbatim via line-by-line substitution.

@doc """
Atomically write `updates` (map of frontmatter keys → values) to `file_path`.

Only `:status` and `:denial_reason` are supported; any other key returns
`{:error, {:unsupported_key, k}}`. This keeps the round-trip safe — we
don't claim to be a general-purpose YAML writer.

Atomicity: writes to `<path>.tmp`, then `File.rename/2` — same filesystem,
atomic on all POSIX kernels. Watcher sees exactly one :modified event for
the final path; no partial-read window.
"""
@spec write(Path.t(), map()) :: :ok | {:error, term()}
def write(file_path, updates) when is_binary(file_path) and is_map(updates) do
  with :ok <- validate_keys(updates),
       {:ok, content} <- File.read(file_path),
       {:ok, new_content} <- substitute_frontmatter(content, updates) do
    tmp = file_path <> ".tmp"
    with :ok <- File.write(tmp, new_content, [:sync]),
         :ok <- File.rename(tmp, file_path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end
end

@supported_keys [:status, :denial_reason, "status", "denial_reason"]
defp validate_keys(updates) do
  case Enum.find(Map.keys(updates), fn k -> k not in @supported_keys end) do
    nil -> :ok
    bad -> {:error, {:unsupported_key, bad}}
  end
end

# Line-level substitution. Finds the opening `---\n`, reads until the
# closing `---\n`, rewrites matching keys in place, preserves order +
# comments + indentation of untouched lines.
defp substitute_frontmatter(content, updates) do
  normalized_updates =
    Map.new(updates, fn {k, v} -> {to_string(k), v} end)

  case String.split(content, ~r/\A---\n|\n---\n/, parts: 3) do
    ["", fm, body] ->
      new_fm = Enum.map_join(String.split(fm, "\n"), "\n", fn line ->
        rewrite_line(line, normalized_updates)
      end)
      {:ok, "---\n" <> new_fm <> "\n---\n" <> body}
    _ ->
      {:error, :no_frontmatter}
  end
end

defp rewrite_line(line, updates) do
  case Regex.run(~r/\A(\s*)(\w+)\s*:\s*(.*)\z/, line) do
    [_, indent, key, _value] when is_map_key(updates, key) ->
      # Preserve indent; yamerl will quote on re-read if needed
      new_value = updates[key] |> to_string() |> yaml_scalar()
      "#{indent}#{key}: #{new_value}"
    _ ->
      line
  end
end

# Quote values that could be ambiguous (spaces, leading #, reserved words).
defp yaml_scalar(nil), do: "null"
defp yaml_scalar(v) when is_binary(v) do
  if v =~ ~r/[\s#:\[\]\{\},&\*!\|>'"%@`]|\A(true|false|null|yes|no)\z/ do
    ~s("#{String.replace(v, ~s("), ~s(\\"))}")
  else
    v
  end
end
```

### Watcher PubSub extension (gap 2 + 5 — new topic classes + state/ routing)

```elixir
# Extension to lib/glorbo/filesystem/watcher.ex — diff on dispatch_by_prefix
# and pubsub_topic_for/1. Additive only; Phase 3 test compatibility preserved.

# In classify/1, add new clause BEFORE the catch-all:
defp classify(rel) do
  cond do
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") -> :inbox
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") -> :outbox
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/stdout.log") -> :stdout
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/state/wake-request") -> :wake
    String.starts_with?(rel, "audit/") -> :audit
    String.starts_with?(rel, "channels/") -> :channels
    String.starts_with?(rel, "projects/") -> :projects
    String.starts_with?(rel, "alerts/") -> :alerts  # Phase 3 budget alerts
    true -> :other
  end
end

# In pubsub_topic_for/1, extend with new topic mappings:
defp pubsub_topic_for(rel) do
  cond do
    String.starts_with?(rel, "audit/") -> nil  # unchanged; no broadcast
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") -> "inbox"
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/outbox/") -> "outbox"
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/stdout.log") ->
      # Extract agent slug: "agents/<slug>/stdout.log"
      ["agents", slug, "stdout.log"] = Path.split(rel)
      "agents:#{slug}:stdout"
    String.starts_with?(rel, "agents/") and String.contains?(rel, "/state/wake-request") ->
      ["agents", slug, "state", _] = Path.split(rel)
      "agents:#{slug}:wake"
    String.starts_with?(rel, "projects/") -> "projects"
    String.starts_with?(rel, "channels/") ->
      ["channels", file] = Path.split(rel)
      channel_slug = Path.basename(file, ".md")
      "channels:#{channel_slug}"
    String.starts_with?(rel, "alerts/") -> "approvals"  # Phase 3 publishes alerts here
    true -> nil
  end
end
```

**Phase 3 test-compat note:** Keep the existing broadcast shapes (`{:file_event, rel_path, events}` on the same topic family) — Phase 3's Approvals.Gate subscribes to `company:<co>:projects`; that topic + payload are unchanged. The new topics are additive.

**ChannelLive subscribes to:** `"company:<co>:channels:<channel_slug>"` (new per-channel topic). A separate `"company:<co>:channels"` roll-up topic would be useful for CompanyLive's "channel list" — add it as a second broadcast from the same event (broadcast twice is cheap; both topic classes fire in parallel).

### Director Actions module (gaps 4, 5)

```elixir
# lib/glorbo_web/actions.ex
defmodule GlorboWeb.Actions do
  @moduledoc """
  Director write-actions. Every call: (a) writes file first (filesystem
  is source of truth), (b) emits audit event with actor: director, (c)
  returns :ok | {:error, reason} — Watcher event drives the UI refresh.
  """
  alias Glorbo.Company.AuditLog
  alias Glorbo.TaskDefinition

  @type ok_or_err :: :ok | {:error, term()}

  @spec post_message(String.t(), String.t(), String.t(), keyword()) :: ok_or_err
  def post_message(company, channel, body, opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    path = Path.join([base, "companies", company, "channels", "#{channel}.md"])
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = "\n## #{ts} | Director\n#{body}\n"

    with :ok <- File.write(path, entry, [:append, :sync]) do
      AuditLog.append(%{
        company: company,
        actor: "director",
        action: "chat.post",
        target: "channels/#{channel}.md",
        channel: channel
      })
      :ok
    end
  end

  @spec set_approval(String.t(), String.t(), :approved | :denied, keyword()) :: ok_or_err
  def set_approval(company, task_path, decision, opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    abs = Path.join([base, "companies", company, task_path])
    status = to_string(decision)

    with :ok <- TaskDefinition.write(abs, %{status: status}) do
      AuditLog.append(%{
        company: company,
        actor: "director",
        action: "approval.#{decision}",
        target: task_path
      })
      :ok
    end
  end

  @spec wake_agent(String.t(), String.t(), String.t() | nil, keyword()) :: ok_or_err
  def wake_agent(company, agent, reason, opts \\ []) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    path = Path.join([base, "companies", company, "agents", agent, "state", "wake-request.md"])
    File.mkdir_p!(Path.dirname(path))
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    body = """
    ---
    requested_at: "#{ts}"
    reason: #{reason || ""}
    ---

    Director wake request.
    """

    with :ok <- File.write(path, body, [:sync]) do
      AuditLog.append(%{
        company: company,
        actor: "director",
        action: "agent.wake_request",
        target: "agents/#{agent}",
        reason: reason
      })
      :ok
    end
  end
end
```

### esbuild reintroduction (gap 6)

```elixir
# config/config.exs — add after existing Endpoint config:
config :esbuild,
  version: "0.21.5",  # [ASSUMED] verify latest compatible with Phoenix 1.8
  glorbo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets
         --loader:.css=css),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# config/dev.exs — add `watchers:`:
config :glorbo, GlorboWeb.Endpoint,
  watchers: [esbuild: {Esbuild, :install_and_run, [:glorbo, ~w(--sourcemap=inline --watch)]}]
```

```elixir
# mix.exs — add aliases:
defp aliases do
  [
    ...,
    "assets.setup": ["esbuild.install --if-missing"],
    "assets.build": ["esbuild glorbo"],
    "assets.deploy": ["esbuild glorbo --minify", "phx.digest"]
  ]
end
```

```javascript
// assets/js/app.js — minimal LiveView boot
// Source: https://hexdocs.pm/phoenix_live_view/js-interop.html
import "../css/app.css"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken}
  // Hooks added here later (e.g., ScrollAnchor for chat + stdout auto-pin)
})
liveSocket.connect()
window.liveSocket = liveSocket
```

**CI + release note:** Burrito packaging includes `priv/static/` by default — running `mix assets.deploy` before `mix release` is sufficient. Add to `.github/workflows/release.yml` the step `mix assets.deploy` between `mix deps.get` and `mix release`. Phase 1's CI stripped this; Phase 4 re-adds.

### Router wiring

```elixir
# lib/glorbo_web/router.ex
defmodule GlorboWeb.Router do
  use GlorboWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {GlorboWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug GlorboWeb.Plugs.DashboardToken  # new plug — checks optional config.md token
  end

  scope "/", GlorboWeb do
    pipe_through :browser

    get "/", PageController, :redirect_to_companies
    live "/companies", OverviewLive
    live "/companies/:company", CompanyLive
    live "/companies/:company/kanban", KanbanLive
    live "/companies/:company/agents/:agent", AgentLive
    live "/companies/:company/channels/:channel", ChannelLive
    live "/companies/:company/approvals", ApprovalQueueLive
    live "/companies/:company/audit", AuditLive
    live "/health", HealthLive
  end
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `phx-update="append"` with manual list management | `Phoenix.LiveView.stream/4` with `limit: -N` | LV 0.18 (stream API shipped); mature by LV 1.0 | Streams are the canonical way to do rolling lists; assign-based lists are for bounded small collections. |
| LiveComponent for widget encapsulation | `Phoenix.Component` function components | LV 0.17+ | Function components are cheaper and render alongside the parent LV; reserve LiveComponent for widgets with their own server state. |
| Explicit esbuild via npm `package.json` | `esbuild` Hex wrapper auto-downloads | Phoenix 1.6+ | No Node dependency; single `mix assets.build` command. |
| `Phoenix.LiveView.async/1` manual Task spawning | `start_async/3` + `handle_async/3` OR `assign_async/3` + `AsyncResult` | LV 0.20+ | Built-in process linking + cleanup; don't hand-roll Tasks. |
| Heroicons SVG sprite | Hand-written inline SVG `<.icon>` component | (Glorbo-specific — D-03) | 9 glyphs fit in ~3KB; no network / no build-step icon injection. |

**Deprecated/outdated:**
- Phoenix 1.7 `phx.gen.live` generators — still work but Phoenix 1.8 changed defaults (no Tailwind, colocated hooks). Don't blindly copy 1.7-era tutorials.
- `Phoenix.Endpoint`'s `url` config as compile-time only — in Phoenix 1.8, `runtime.exs` is the blessed place for URL + host config.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `earmark` 1.4.x stable is preferable to 1.5.0-pre1 | Standard Stack | Low — 1.4.46 is battle-tested; if user prefers latest, pin 1.5.0-pre1. Verify with `mix hex.info earmark` during Wave 0. |
| A2 | `esbuild` Hex wrapper version 0.10.0 is compatible with Phoenix 1.8.5 | Code Examples, esbuild config | Low — Phoenix 1.8 uses the same `watchers:` contract since 1.6. If incompatible, pin to whatever `mix phx.new` would generate today. |
| A3 | `html_sanitize_ex.markdown_html/1` allows the tag set UI-SPEC requires (`p`, `code`, `pre`, `strong`, `em`, `a[href]`, `ul`, `ol`, `li`, `blockquote`) | Chat markdown rendering | Medium — `markdown_html` is the closest preset; if it's over-permissive (allows images, tables) or under-permissive (strips `<code>`), fall back to `HtmlSanitizeEx.strip_tags/1` + a custom Floki walker, OR use `HtmlSanitizeEx.Scrubber` subclass. Verify during Wave 0 with a test against UI-SPEC's allowlist. |
| A4 | LiveView's `terminate/2` is reliable enough for StdoutStreamer cleanup when `Process.flag(:trap_exit, true)` is set | StdoutStreamer pattern | Low-Medium — docs say `terminate/2` only fires when trapping exits. **Mitigation** (pitfall 4) layers a `DynamicSupervisor` + `Process.monitor` so cleanup is not solely dependent on `terminate/2`. |
| A5 | Burrito release picks up `priv/static/assets/` automatically when `mix assets.deploy` runs before `mix release` | Pitfall 6 | Medium — Phase 1 plan 03 stripped assets from the release flow. **Action:** Wave 0 plan must add a `mix assets.deploy` step to CI before `mix release`, and a smoke test that `curl http://localhost:4000/assets/app.js` from the release binary returns 200. |
| A6 | The optional `dashboard_token:` in `config.md` is a simple string compared against query-param `?token=...` (not a hashed comparison) | D-06 interpretation | Low — trust model is loopback-bind; the token is defense-in-depth for LAN exposure. Constant-time comparison is still advisable (`Plug.Crypto.secure_compare/2`). |
| A7 | Phoenix.Presence on `dashboard:*` is "low priority defer" — not in scope for Wave 1 unless trivial | D-13 | Low — deferring is consistent with "pragmatic-fast" user profile; skip unless ~30 min effort. |
| A8 | 3 plans (Wave 0 foundation; 2 parallel Wave 1 plans + verify) is the right shape | Plan Decomposition | Medium — the alternative is 4 plans (Wave 0 + 3 parallel). With 8 LVs + 9 components + asset pipeline + Watcher extension, 3 plans is a bit tight; 4 gives breathing room. **Recommend 3 as default, readjust to 4 if Wave 1 plans each exceed 5 tasks.** |

---

## Open Questions

1. **Should `GlorboWeb.StdoutStreamer` live under `GlorboWeb.*` or `Glorbo.*`?**
   - What we know: it's UI-driven (per-LV-mount lifecycle) but it reads from the company filesystem.
   - What's unclear: Phase 5's `glorbo logs` CLI might want to tail the same file — if so, a shared `Glorbo.Stdout.Tail` core with `GlorboWeb.StdoutStreamer` as a thin PubSub adapter is cleaner.
   - Recommendation: start under `GlorboWeb`; refactor to `Glorbo.*` in Phase 5 if needed.

2. **Does the `channels/<c>.md` sole-writer contract hold under concurrent Director posts?**
   - What we know: `File.open!(path, [:append, :sync])` is atomic per-write on POSIX up to `PIPE_BUF` (typically 4KB). Multi-line messages could interleave.
   - What's unclear: is the Director multi-tabbed (one Elixir node, multiple LV processes racing)? Probably yes (D-13 Presence implies multi-tab).
   - Recommendation: route all `post_message` calls through a per-company `GenServer` (could be Phase 3's existing `Glorbo.Company.Router` with a new `:post_channel` cast, or a thin `ChannelWriter` sibling). Single serialization point eliminates the race.

3. **How does Watcher handle stdout.log being a high-volume write stream?**
   - What we know: inotify emits `:modified` per write. An agent emitting 100 lines/s means 100 events/s into the Watcher's 100ms debouncer — all collapsed to 1 :flush, which broadcasts once.
   - What's unclear: is a single `:file_event` enough for `StdoutStreamer` to react in time? Yes, but the consumer (`StdoutStreamer`) already polls every 300ms independently of inotify — inotify is redundant for stdout.
   - Recommendation: `StdoutStreamer` can ignore `:file_event` and rely solely on its 300ms poll. Simpler, and avoids double-read.

4. **Do we need a `dashboard:connected` PubSub topic for cross-LV coordination?**
   - What we know: D-13 hints at Presence but marks it low-priority.
   - What's unclear: does OverviewLive need to know when CompanyLive is open to avoid redundant re-renders? No — PubSub broadcasts are cheap; each LV filters its own events.
   - Recommendation: skip Presence entirely in v0.0.1. Revisit if concurrent Directors become a real use case.

5. **Earmark + `html_sanitize_ex.markdown_html` allowlist match UI-SPEC's strict set?**
   - See Assumption A3 — verify empirically in Wave 0.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|-------------|-----------|---------|----------|
| Elixir | Compilation | ✓ | 1.18.4-otp-28 (pinned) | — |
| Erlang | Compilation / runtime | ✓ | 28.0.2 (pinned) | — |
| `mix` | Build | ✓ | bundled with Elixir | — |
| `esbuild` binary | Asset build | ✗ (esbuild Hex wrapper auto-downloads on first `mix assets.setup`) | 0.21.x after install | Hex wrapper handles download per-platform; no system install needed |
| Node.js / npm | None (esbuild Hex wrapper operates sans npm) | N/A | — | — |
| `file_system` inotify backend | Watcher | ✓ (Linux kernel inotify subsystem) | — | — |
| `~/.glorbo/` dir | Dashboard reads live data | ✓ (Phase 2 `glorbo init` creates it) | — | — |
| Browser (for manual testing) | Development | Assumed | — | — |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | `ExUnit` + `Phoenix.LiveViewTest` (built-in), `Floki` 0.37 for HTML assertions, `Phoenix.LiveView.Test` module |
| Config file | `test/test_helper.exs` (existing), `config/test.exs` (existing) |
| Quick run command | `mix test --stale` (runs only tests affected by file changes) |
| Full suite command | `mix test` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| UI-01 | OverviewLive renders all companies from SQLite | unit (LiveViewTest) | `mix test test/glorbo_web/live/overview_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | CompanyLive renders tabs + agent grid | unit | `mix test test/glorbo_web/live/company_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | KanbanLive groups tasks by status | unit | `mix test test/glorbo_web/live/kanban_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | AgentLive renders header + stdout + permissions | unit | `mix test test/glorbo_web/live/agent_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | ChannelLive renders earmark-rendered markdown | unit | `mix test test/glorbo_web/live/channel_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | ApprovalQueueLive renders pending sentinels | unit | `mix test test/glorbo_web/live/approval_queue_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | AuditLive renders last 500 entries | unit | `mix test test/glorbo_web/live/audit_live_test.exs -x` | ❌ Wave 0 |
| UI-01 | HealthLive renders supervisor tree | unit | `mix test test/glorbo_web/live/health_live_test.exs -x` | ❌ Wave 0 |
| UI-02 | Watcher broadcasts on new `stdout.log` topic | integration | `mix test test/glorbo/filesystem/watcher_test.exs:stdout_topic -x` | ❌ (extend existing) |
| UI-02 | StdoutStreamer opens at EOF, polls, broadcasts lines | unit | `mix test test/glorbo_web/stdout_streamer_test.exs -x` | ❌ Wave 0 |
| UI-02 | AgentLive consumes stdout PubSub and stream_inserts with limit | integration | `mix test test/glorbo_web/live/agent_live_integration_test.exs -x` | ❌ Wave 0 |
| UI-02 | File change under `~/.glorbo/companies/acme/projects/` → Kanban repaints within 1s | integration (fixture) | `mix test test/glorbo_web/live/kanban_realtime_test.exs -x` | ❌ Wave 0 |
| UI-03 | `Actions.post_message` appends to channels/*.md with [:append, :sync] | unit | `mix test test/glorbo_web/actions_test.exs:post_message -x` | ❌ Wave 0 |
| UI-03 | Elixir is sole writer: agent sandbox cannot write to channels/ (already covered by bwrap ro-bind — assert in existing Phase 3 sandbox test) | integration | Existing Phase 3 test | ✅ |
| UI-03 | `@mention` in channel wakes the agent via Phase 3 Router | integration | `mix test test/glorbo/company/router_test.exs:mention_fanout -x` | ✅ (existing) |
| UI-03 | Approve click → `TaskDefinition.write` → Gate fires → agent wakes | integration | `mix test test/glorbo_web/live/approval_queue_integration_test.exs -x` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `mix test --stale` (affected tests only; < 10s usually)
- **Per wave merge:** `mix test` (full suite, ~30-60s with Phase 3 integration tests)
- **Phase gate:** Full suite green + Playwright `:e2e` smoke test (if not deferred per D-37) before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `test/glorbo_web/live/overview_live_test.exs` — covers UI-01 (overview)
- [ ] `test/glorbo_web/live/company_live_test.exs` — covers UI-01 (company)
- [ ] `test/glorbo_web/live/kanban_live_test.exs` — covers UI-01 (kanban)
- [ ] `test/glorbo_web/live/agent_live_test.exs` — covers UI-01 (agent)
- [ ] `test/glorbo_web/live/channel_live_test.exs` — covers UI-01 (channel) + UI-03 (sole writer)
- [ ] `test/glorbo_web/live/approval_queue_live_test.exs` — covers UI-01 (approvals)
- [ ] `test/glorbo_web/live/audit_live_test.exs` — covers UI-01 (audit)
- [ ] `test/glorbo_web/live/health_live_test.exs` — covers UI-01 (health)
- [ ] `test/glorbo_web/live/kanban_realtime_test.exs` — covers UI-02 (sub-second)
- [ ] `test/glorbo_web/stdout_streamer_test.exs` — covers UI-02 (stdout)
- [ ] `test/glorbo_web/actions_test.exs` — covers UI-03 (Director write-actions)
- [ ] `test/glorbo/task_definition_write_test.exs` — covers TaskDefinition.write/2 atomicity
- [ ] `test/support/glorbo_fixtures.ex` — shared fixture for seeded acme company (used by every integration test)
- [ ] `test/glorbo/filesystem/watcher_test.exs` — **extend** existing with stdout / wake / channel topic cases
- [ ] Framework install: `{:floki, ">= 0.37.0", only: :test}` already in mix.exs — no install gap.

---

## Security Domain

> Phase 4 is a Director-only UI behind a loopback bind. Threat model is narrow: (a) XSS from user-typed channel markdown, (b) CSRF on POST /live, (c) LAN exposure when Director opts into `0.0.0.0` bind + dashboard_token.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | Partial | Loopback bind (kernel-level auth by host-user ownership) + optional dashboard_token (bearer in query string) per D-06. No login form. |
| V3 Session Management | Yes | Phoenix signed session cookie via `:secret_key_base` from `config.md` per D-07. `same_site: "Lax"` on cookie (already in endpoint.ex). |
| V4 Access Control | Partial | Director has full access — single operator trust model. Each LV rejects events not scoped to its `:company` assign (company-isolation defense). |
| V5 Input Validation | Yes | `earmark` + `html_sanitize_ex.markdown_html/1` for user-typed channel markdown. `TaskDefinition.write/2` validates key allowlist. `Actions.post_message` rejects empty / huge body (cap 10KB, mirrors Frontmatter cap). |
| V6 Cryptography | Yes | `secret_key_base` generated via `:crypto.strong_rand_bytes(64) \|> Base.encode64()` on first boot — never hand-rolled. `Plug.Crypto.secure_compare/2` for dashboard_token comparison. |
| V7 Error Handling | Yes | Don't leak filesystem paths in error templates; `config.md` contents (including the token) never reach HTML. |
| V13 API / Web Service | Yes | LiveView is WebSocket; `protect_from_forgery` + CSRF token passed through `LiveSocket` params (already wired in Phoenix 1.8 default layout). |
| V14 Configuration | Yes | `~/.glorbo/config.md` is 0600 (Director-only read); never world-readable. |

### Known Threat Patterns for {stack}

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Channel markdown contains `<script>` tag | Tampering / Info-Disclosure | `html_sanitize_ex.markdown_html/1` strips non-allowlisted tags; CSP header (`script-src 'self'`) as defense-in-depth. |
| CSRF on post_message WebSocket | Spoofing | Phoenix LiveView CSRF token (default, already wired). |
| Dashboard token leak in referrer / logs | Info-Disclosure | Use `POST /login` + session cookie instead? **Out of scope v0.0.1** (D-06 locks no login page). Mitigate by recommending operators NOT paste dashboard URLs into chat apps. Document. |
| Symlink attack on `channels/<ch>.md` (agent replaces channel file with a symlink to `/etc/passwd`) | Tampering | `Actions.post_message` opens with `[:append, :sync]` — on POSIX, `:append` mode follows symlinks. **Mitigation:** before open, assert `File.lstat!/1` regular file; reject otherwise. Add defense-in-depth bwrap bind of `channels/` as ro inside agent sandbox (already Phase 3 behavior — agents can't write there). |
| Agent writes to `~/.glorbo/companies/<co>/agents/<ag>/state/wake-request.md` to bypass auth | Spoofing | `state/` dir is NOT in agent's bwrap mount set (Phase 3 bwrap argv); agent cannot write it. Verify the wake-request prefix is excluded from agent mounts. |
| Path traversal in channel name (`../../etc/passwd`) | Tampering | `Actions.post_message` validates `channel` matches `~r/\A[a-z0-9-]+\z/`; reject otherwise. |
| YAML bomb / billion-laughs in TaskDefinition.write | DoS | Already covered by Phase 2 Frontmatter 10MB cap + yamerl safe-loader; `write/2` re-reads via `parse_file/2` post-write. |
| Stdout tail exhausts memory on runaway log | DoS | `StdoutStreamer` 64KB read chunk + 300ms poll + LV stream `limit: -1000` bound memory. Oldest lines pruned client-side. |
| XSS in agent name / company name (rendered in card) | XSS | HEEx auto-escapes all `{@foo}` interpolations by default. Verify no `{raw ...}` usage on untrusted fields. |

---

## Plan Decomposition (gap 11)

Given: 8 LVs + 9 components + asset pipeline reintroduction + Watcher extension + TaskDefinition.write + StdoutStreamer + Director Actions + Burrito smoke test. Estimated ~2500 LOC Elixir + ~500 LOC CSS + ~40 LOC JS.

**Recommended shape: 3 plans, 2 waves.**

### Wave 0 — Foundation (1 plan)

**04-01-PLAN.md — Foundation: asset pipeline + infrastructure extensions + test fixtures**

Scope:
1. Add `esbuild`, `earmark`, `html_sanitize_ex` to `mix.exs` + `mix.lock`.
2. Reintroduce `assets/js/app.js` + `assets/css/app.css` (empty scaffolds + CSS variables).
3. Configure `config :esbuild` + `config :glorbo, GlorboWeb.Endpoint, watchers: [...]`.
4. Extend `Glorbo.Filesystem.Watcher` — new classify cases + pubsub_topic_for cases (stdout, wake, per-channel topics).
5. Add `Glorbo.TaskDefinition.write/2` with atomic temp-file + rename + frontmatter key allowlist.
6. Add `GlorboWeb.StdoutStreamer` + `DynamicSupervisor` child in Application.
7. Add `GlorboWeb.Actions` module (post_message, set_approval, wake_agent).
8. Wire `/assets` static serving + CSRF token meta tag in `root.html.heex`.
9. Add `test/support/glorbo_fixtures.ex` with a seeded acme company under a tmp dir.
10. Add tests for Watcher extensions, TaskDefinition.write, StdoutStreamer (unit), Actions (unit).
11. Add `mix assets.setup` / `assets.build` / `assets.deploy` aliases to `mix.exs`.
12. Update CI workflow: add `mix assets.deploy` before `mix release` in Phase 1's workflow file.

Tasks: ~5-6. Duration estimate: ~25-35 min based on Phase 1-03 velocity (35 min / 3 tasks with similar scope).

### Wave 1 — Dashboard implementation (2 parallel plans)

**04-02-PLAN.md — "Company-scope LVs + components" (parallel to 04-03)**

Scope:
- `OverviewLive`, `CompanyLive`, `KanbanLive`, `AgentLive`, `ApprovalQueueLive`.
- Components: `CompanyCard`, `AgentCard`, `TaskCard`, `ApprovalCard`, `BudgetRing`, `StdoutTail`, `Icon`.
- Router wiring for these 5 routes.
- Unit tests per LV + integration test for Kanban real-time (UI-02 verification).
- Integration test for Approval end-to-end (Actions.set_approval → Gate → agent wake).

**04-03-PLAN.md — "Content-scope LVs + markdown + global chrome" (parallel to 04-02)**

Scope:
- `ChannelLive`, `AuditLive`, `HealthLive`.
- Components: `ChannelMessage`, `AuditEntry`, `HealthDot`, `TabBar`, `Sidebar` (shared layout).
- `app.html.heex` layout with sidebar + main-pane grid.
- Full `app.css` (~500 LOC with all variables + component styles).
- Earmark + sanitizer wiring for ChannelMessage.
- Router wiring for these 3 routes + `/` redirect + `/health` and dashboard_token plug.
- Unit tests per LV + integration test for Channel post/render cycle (UI-03 verification).
- Visual smoke test via Playwright if not deferred (optional per D-37).

Merge + integration verification is handled by `/gsd-verify-work` after both plans ship.

**Rationale for 2 parallel plans (not 3):** 
- Wave 0 is a single serialized plan because everything depends on it.
- Splitting Wave 1 into 3 parallel plans (Company, Content, Global chrome) creates merge-conflict risk on `router.ex` + `app.css` + `core_components.ex` — each touched by all three. Splitting into 2 with a natural seam (company-scope vs channel/audit/health) minimizes overlap.
- Integration-test plan as a separate plan is not needed; each parallel plan owns its own integration tests. The verifier handles cross-plan verification.

### Alternative: 4-plan shape

If the project profile prefers smaller plans:

- 04-01 Foundation (as above)
- 04-02 Overview + Company + Kanban + components
- 04-03 Agent + StdoutStreamer integration + Approval + Chat
- 04-04 Audit + Health + asset pipeline final + Director Actions integration tests

This adds an extra wave boundary and roughly doubles coordination overhead. **Recommend 3 plans unless user specifies finer granularity.**

---

## Sources

### Primary (HIGH confidence)

- `https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html` — lifecycle callbacks, `connected?/1`, `stream/4`, `assign_async/3`, `start_async/3`
- `https://hexdocs.pm/phoenix_live_view/Phoenix.LiveView.html#stream/4` — rolling list with `limit: -N` pattern
- `https://hexdocs.pm/phoenix_live_view/js-interop.html` — minimal app.js + LiveSocket + CSRF token
- `https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html` — `attr/3`, `slot/3`, function-component organization
- `https://hexdocs.pm/phoenix/asset_management.html` — esbuild aliases, no-npm setup
- `https://hexdocs.pm/esbuild/Esbuild.html` — Hex wrapper auto-download, profile config
- `https://hexdocs.pm/earmark/Earmark.html` — `as_html/2` + explicit sanitization warning
- `https://github.com/rrrene/html_sanitize_ex` — `markdown_html/1`, version 1.5.0 (2026-03-29)
- `hex.pm` API (verified 2026-04-16): `phoenix_live_view` 1.1.28, `earmark` 1.5.0-pre1, `esbuild` 0.10.0, `html_sanitize_ex` 1.5.0
- Glorbo repo — `lib/glorbo/filesystem/watcher.ex`, `lib/glorbo/approvals/gate.ex`, `lib/glorbo/task_definition.ex`, `lib/glorbo/company/supervisor.ex`, `lib/glorbo/agent/server.ex`, `lib/glorbo_web/endpoint.ex`, `mix.exs`, `mix.lock`, `config/*.exs` (all read 2026-04-16)

### Secondary (MEDIUM confidence)

- `04-CONTEXT.md` (37 decisions D-01..D-37) — locked user decisions
- `04-UI-SPEC.md` — design-system tokens, component inventory, ANSI strip, copy inventory, color allowlist
- `DESIGN.md` §6 (communication), §8.2 (approval gates), §8.3 (audit log), §9 (7 dashboard views), §10 (CLI + `glorbo serve`)
- Phase 3 artifacts: `03-CONTEXT.md`, `AUDIT_EVENTS.md`, `Glorbo.Approvals.Gate` module docs

### Tertiary (LOW confidence)

- `earmark` 1.5.0-pre1 vs 1.4.x stable choice — ASSUMED 1.4.x is current stable; verify with `mix hex.info earmark`
- `esbuild` binary version 0.21.x — ASSUMED compatible with Phoenix 1.8.5; verify with `mix phx.new --version` reference
- `html_sanitize_ex.markdown_html/1` allowlist matches UI-SPEC's specific tag set — need empirical Wave 0 test

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all libraries verified via hex.pm + mix.lock + official docs.
- Architecture / LV patterns: HIGH — verified via LiveView 1.1.28 docs.
- Watcher extension + StdoutStreamer + TaskDefinition.write: HIGH (design), MEDIUM (exact code — written from first principles, not copy-pasted).
- Markdown sanitization: MEDIUM — library choice verified; tag-allowlist match needs empirical test (A3).
- Plan decomposition: MEDIUM — 3 vs 4 plan shape is judgment-based; recommend 3 with fallback to 4.
- Burrito asset shipping: MEDIUM — verified conceptually, needs smoke test (A5).

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (30 days — Phoenix/LV major versions stable; LV 1.1 line has been stable 6+ months)
