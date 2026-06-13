---
gep: 6
title: Phoenix LiveView + Channels for the Dashboard
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-17
implemented-in: v0.0.2
requires: [2]
see-also: [3, 7, 32]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit from DESIGN.md §9.
  - date: 2026-04-17
    status: Accepted
    note: Canonical record of the LiveView dashboard decision; dashboard shipped in v0.0.2.
  - date: 2026-04-17
    status: Implemented
    version: v0.0.2
    note: Dashboard shipped with v0.0.2 (OverviewLive, KanbanLive, AgentLive, ChatLive, ApprovalQueueLive, AuditLive, HealthLive).
---

# GEP-6: Phoenix LiveView + Channels for the Dashboard

## Purpose

Glorbo's dashboard is a Phoenix LiveView application served on
`localhost:4000` by the same Elixir release that runs the
orchestrator. This GEP records why the dashboard is server-rendered
LiveView + Channels instead of a separate SPA, and what that choice
buys (and costs) Glorbo.

This is Informational — the choice was made in v0.0.1 and shipped in
v0.0.2; this GEP documents the rationale so future feature work
doesn't accidentally regress the reasoning behind it.

## Shape of the dashboard

The dashboard serves the Director. Agents and companies don't use it
directly — they interact via the filesystem, with the dashboard as a
Director-side observability and control surface.

Key views (from `DESIGN.md` §9):

- **Overview.** Companies, agents, tasks, budget burn, recent
  activity.
- **Kanban.** Tasks across projects, drag-and-drop, filterable.
- **Agent detail.** Config, current task, live stdout stream,
  inbox/outbox.
- **Chat.** Real-time channel view. Director can read all, post to
  any.
- **Approvals.** Pending approvals with one-click decide.
- **Audit.** Searchable event history.
- **Health.** Container status, resource usage, process tree.

Every view is LiveView; Phoenix Channels provide streaming for stdout
and chat. No separate frontend tree, no SPA bundle, no API layer
between the browser and the orchestrator.

## Why LiveView instead of an SPA

### 1. One application, one deployment surface

Glorbo ships as a single Elixir release (`mix release` + Burrito-
wrapped into a single binary). A separate SPA adds:

- A second build (webpack/vite/whatever).
- A second dep tree (npm/yarn).
- A release pipeline for the frontend.
- An API contract between frontend and backend that has to evolve in
  lockstep.
- A second auth story for frontend → backend calls.

LiveView collapses all of this. The "frontend" is ERB-like templates
living next to the backend code; the "API" is function calls; auth is
implicit (already in the LiveView session).

For a single-host app with a single operator (the Director), this
matches the product's philosophy of minimal moving parts.

### 2. Real-time without custom plumbing

PubSub subscriptions flow naturally in LiveView — the dashboard can
subscribe to `company:<slug>` topics and broadcast inbox/outbox
changes, budget ticks, audit events, stdout chunks directly from the
inotify file watchers. No WebSocket protocol to design, no
reconnection logic, no state reconciliation — Phoenix does it.

Contrast: an SPA would need a websocket API, a message schema, a
state store (Redux/Zustand/Pinia), reconciliation on reconnect, and
an auth-token refresh dance. Tens of thousands of lines of work,
most of it scaffolding for someone else's framework.

### 3. Fits the Director's mental model

The Director is already comfortable editing markdown files. LiveView
renders state directly from those files (plus the SQLite index, itself
rebuilt from files). When a file changes, the dashboard updates. The
abstraction distance between "what's on disk" and "what's on screen"
is minimal — a principle that composes with GEP-3's filesystem-as-
truth invariant.

### 4. No separate auth model

Dashboard auth is local-only: the dashboard listens on `localhost` by
default. The Director is whoever can connect to the socket, which is
by definition someone on the host. No login, no tokens, no RBAC for
the single-operator case. v0.0.3+ considerations for multi-user /
remote access exist but are out of scope for this GEP.

### 5. Reduced npm/node dependency surface

Glorbo ships **no Node.js** on the host. Assets are built via
[esbuild through the Hex wrapper](https://hexdocs.pm/esbuild/), which
auto-downloads a platform binary on first `mix assets.setup` —
zero `npm install`, zero `package.json`, zero Node on the install
host. This keeps the single-binary distribution story real.

## Why Phoenix Channels alongside LiveView

LiveView is optimised for rendering state snapshots with incremental
diffs. For **streaming** data — CLI stdout, chat messages arriving
mid-turn — Phoenix Channels are the better primitive. They provide
bidirectional message passing over the same websocket LiveView
already uses, without having to force streaming data through
LiveView's assign/render cycle.

In Glorbo:

- **LiveView** renders views: budget cards, kanban boards, audit
  tables. Updates triggered by PubSub events invalidate assigns and
  re-render.
- **Channels** carry streams: stdout tail (per agent), chat channel
  messages (per channel), budget tick updates when higher-frequency
  than LiveView's render cadence makes sense.

Both share the same Phoenix endpoint and authentication (such as it
is, on `localhost`). This is the idiomatic Phoenix shape and keeps
the implementation simple.

## Costs and accepted tradeoffs

### 1. Network-requiring browser

LiveView requires a websocket connection. The dashboard doesn't work
offline or in exotic browser environments (text-mode browsers,
browsers without JS). Mitigation: the dashboard is optional. Glorbo
runs headless via `glorbo run`; filesystem inspection (`ls`, `cat`,
`grep`) remains the always-available control surface.

### 2. Scale limits

LiveView + Phoenix on a single BEAM node scales to high tens of
thousands of concurrent users. Single-Director use case is fine. If
Glorbo ever grows a multi-user remote-dashboard story, it'll still
handle hundreds of operators without strain — no architectural
change needed.

### 3. HTML-as-UI

Server-rendered HTML + JS glue (via LiveView) is less visually
sophisticated than modern SPA frameworks by default. Glorbo's
dashboard aims for function over visual polish — agent status, task
progress, budget burn, audit trails. The Tailwind + esbuild pipeline
is enough. This tracks the Director's pragmatic UX profile.

### 4. Browser-back and deep-linking quirks

LiveView has solved most deep-linking pain but it's still subtly
different from a true URL-driven SPA. For Glorbo's use cases
(operator flipping between views, not deep-link-sharing), this is
invisible.

### 5. Tight coupling between orchestrator and UI

The dashboard is part of the same release as the orchestrator. You
can't upgrade one without the other. This is *intended* — the
dashboard is "the orchestrator's eyes and hands," not a separately-
versioned product.

## Real-time update flow

A concrete example: the CEO agent appends a message to the outbox.

```
1. CEO agent writes  <co>/agents/ceo/outbox/task-reply-abc.md
2. inotify fires     → Glorbo.Company.FileWatcher GenServer
3. Watcher broadcasts → PubSub topic "company:acme"
4. Router moves file  → <co>/agents/engineer/inbox/task-abc.md
5. Watcher fires again on the inbox write
6. PubSub broadcast   → "company:acme" topic
7. Kanban LiveView    → assigns updated, diff sent to browser
8. Browser re-renders → task card moves from CEO to Engineer lane
```

No API call, no manual state reconciliation, no polling. The
filesystem event drives the UI update directly.

## What about a headless mode?

`glorbo run` starts orchestration without the Phoenix endpoint. Used
in production deployments where the Director is operating via SSH +
filesystem only. The dashboard is a first-class but optional
component: Phoenix is a supervised child that can be omitted, and
agents + routing + audit continue unaffected.

This confirms the dashboard's role as a *Director convenience layer*,
not a core part of orchestration.

## Decision log

### D1. LiveView, not a separate SPA

- **Decided:** the dashboard is server-rendered LiveView with Phoenix
  Channels for streams. No React/Vue/Svelte app.
- **Alternatives:** SPA over REST/GraphQL API; hybrid (server pages
  with some SPA islands); htmx; pure Phoenix + ERB.
- **Why:** a single-host, single-operator product benefits most from
  the minimum moving parts. LiveView delivers real-time UI with one
  build, one release, no API contract to maintain, and no Node on
  the host. An SPA would be a second product to maintain for no
  user-visible benefit. Pure ERB would miss the real-time story.
  htmx is close but less Phoenix-native.

### D2. No Node.js on the host — esbuild via Hex wrapper

- **Decided:** asset pipeline uses `esbuild` Hex package, which
  auto-downloads a platform binary into `_build/`. No `npm install`,
  no `package.json`, no Node dependency for users or contributors.
- **Alternatives:** standard Node/npm frontend tooling; use webpack;
  serve pre-bundled assets from a CDN.
- **Why:** Glorbo's distribution story is "single binary + a
  directory." Adding Node to that makes install harder on
  Silverblue-style atomic systems and inflates the tech-stack
  surface. Hex-wrapper esbuild keeps Elixir as the only build
  dependency.

### D3. Phoenix Channels alongside LiveView for streams

- **Decided:** use LiveView for state views, Channels for streaming
  data (stdout, chat).
- **Alternatives:** force everything through LiveView; build a
  dedicated WebSocket protocol.
- **Why:** idiomatic Phoenix — LiveView and Channels share
  infrastructure and auth. Forcing stdout chunks through LiveView's
  assign/render cycle adds latency and memory overhead when a direct
  channel push works better. Custom WS reinvents Phoenix.

### D4. Dashboard is optional; `glorbo run` is headless

- **Decided:** `glorbo run` starts orchestration without the Phoenix
  endpoint. `glorbo serve` starts both.
- **Alternatives:** always start the dashboard; require a CLI flag to
  disable it.
- **Why:** server deployments don't need the UI. Starting the
  Phoenix endpoint adds port binding and memory overhead that's
  wasted in headless runs. The split also emphasises that the
  dashboard is a convenience layer, not a core dependency.

### D5. Local-only by default, no auth

- **Decided:** the dashboard binds to `localhost:4000` by default;
  anyone on the host can access it without login.
- **Alternatives:** require auth from day one; bind to 0.0.0.0 with
  token auth; UNIX socket access only.
- **Why:** single-operator on their own host needs no auth — the
  threat model is "trusted user on trusted machine." Adding auth
  complicates setup for zero benefit in the default case. Remote /
  multi-user scenarios are a separate future GEP that can layer auth
  in without changing the default.

### D6. One-way data flow: files → PubSub → LiveView

- **Decided:** LiveView reads state from the filesystem + SQLite
  (via Ecto); updates flow from inotify → PubSub → LiveView. No
  direct browser → file writes.
- **Alternatives:** allow the dashboard to write files directly;
  dual-write (file and DB) on user actions.
- **Why:** keeps the filesystem-as-source-of-truth invariant intact
  (GEP-3). All mutations funnel through the same Elixir code paths
  that agents use — no "dashboard-only" shortcut that could bypass
  audit, permission checks, or budget tracking. The LiveView button
  that "approves a task" calls the same `Approvals.approve/1`
  function an agent's message would.

## Related

- **GEP-2** — architectural overview.
- **GEP-3** — filesystem as source of truth (dashboard observes,
  doesn't mutate directly).
- **GEP-7** — SQLite as derived data (how the dashboard does fast
  queries without violating the truth invariant).
- `DESIGN.md` §9 (Dashboard).
- `lib/glorbo_web/` — LiveView implementations.

## Implementation reconciliation (2026-06-14)

This is an append-only record (GEP-1: an Accepted/Implemented GEP's body above is not rewritten; deviations from it are recorded here instead).

- **"Phoenix Channels" streaming claim (title, thesis, §"Why Phoenix Channels alongside LiveView", D3) — as-shipped (body is stale).** The GEP repeatedly makes Phoenix Channels load-bearing for stdout/chat streaming (line 57, lines 120–140, D3 at lines 239–248). The code uses no Phoenix Channels: the only `Phoenix.Channel` reference is the unused boilerplate `def channel` macro the Phoenix generator emits in `lib/glorbo_web.ex:33–35`. There is no `UserSocket`, no `socket` route, and no `channel "..."` definition anywhere in `lib/`. All streaming is LiveView `stream/3` plus `Phoenix.PubSub` — e.g. `GlorboWeb.StdoutStreamer` tails `agents/<slug>/stdout.log` and broadcasts `{:stdout_line, company, agent, %{...}}` over the PubSub topic `company:<co>:agents:<ag>:stdout` (`lib/glorbo_web/stdout_streamer.ex:1–24`), which the LiveViews consume via `subscribe`/`stream_insert`. The architectural decision (LiveView, no SPA, no Node, PubSub-driven real-time, files→PubSub→LiveView one-way flow) all holds; only the "Channels" mechanism named in the title and D3 was never built — streams + PubSub replaced it. The GEP title "Phoenix LiveView + Channels" should read "Phoenix LiveView" / "LiveView streams + PubSub."

- **D4 / §"What about a headless mode?" — `glorbo run` omits the Endpoint — corrected-ref (mechanism wrong; reconcile to GEP-37).** D4 (lines 250–259) and line 202 say "`glorbo run` starts orchestration without the Phoenix endpoint" while "`glorbo serve` starts both." In the code `run` does not omit the Endpoint: `lib/glorbo/cli/lifecycle/run.ex:1–22` documents it as a one-shot, non-interactive "cron + CI" dispatcher that exits when the dispatch finishes, and it boots the tree via the *same* `Glorbo.Application.start_supervision_tree_for_serve/0` that `serve` uses (`run.ex` `ensure_tree_started/0`), which includes `GlorboWeb.Endpoint` under the default `:web` surface (`lib/glorbo/application.ex:140`). Endpoint omission is now governed by the GEP-37 `:surface` selector — `apply_surface/2` reads `Application.get_env(:glorbo, :surface, :web)` and strips `GlorboWeb.Endpoint` only for `:tui` and `:headless` (`lib/glorbo/application.ex:157–195`; GEP-37 lines 86–89). So `run` is a one-shot dispatcher (not a long-running headless orchestrator), and the headless/Endpoint-less surface is the GEP-37 `:headless` selector, not a property of the `run` verb.
