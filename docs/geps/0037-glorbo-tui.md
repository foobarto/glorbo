---
gep: 0037
title: "`glorbo tui` — interactive terminal client for the Director"
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Draft
    note: Initial draft.
  - date: 2026-04-24
    status: Draft
    note: |
      Keybinding revision — flipped from vim to Emacs conventions
      (mode-less, Ctrl/Alt chords, C-x / C-c prefixes, M-x command
      palette, C-g cancel). D10 updated with the new rationale.
      Director is an Emacs user; the earlier vim-inspired set was
      a wrong default. Web UI's existing `j/k/y/n` stays as legacy
      (not this GEP's scope).
requires: [2]
extended-by: [39]
see-also: [6, 29, 30, 35, 36, 38]
---

# GEP-37: `glorbo tui` — interactive terminal client for the Director

## Problem

Glorbo today has two Director-facing surfaces:

- **`glorbo_web`** — the Phoenix LiveView dashboard, the primary
  human UI, recently restyled with a terminal-phosphor aesthetic
  (GEP-30).
- **`glorbo_web/mcp`** — the localhost MCP endpoint, exposing the
  same capabilities as a tool surface for external LLM clients
  (GEP-29).

Both require `glorbo serve` to be running and a browser (for the
LiveView surface) or an MCP-capable agent (for the MCP surface)
to reach them. The Director is assumed to have a browser handy.

That assumption misses a meaningful slice of how a single-operator
product gets used in practice: the operator is already sitting in
a terminal running agents (`glorbo run`), has tmux or a plain
shell open, and context-switching to the browser just to approve a
pending task or post a channel message is friction that adds up.

There is no terminal-native way to drive the Director today.
`glorbo serve` with the browser is it.

Additionally, GEP-30's "TUI Redesign" is a *web UI with a TUI
aesthetic* — hairline panels, IRC-style shell-prompt composer,
quake-console drawer. The visual direction exists; the actual
terminal surface does not. This GEP adds the terminal surface.

## Goals

- Introduce a new top-level subcommand `glorbo tui` that launches
  a real terminal UI inside the existing `glorbo` binary. Single
  binary, single Elixir release, no new runtime dependencies.
- Achieve **drop-in replacement parity with the Phoenix dashboard**
  — every Director workflow the web UI exposes (the seven
  GEP-6 canonical views + the ~11 GEP-20 additions) is reachable
  from the TUI, adapted per medium (kanban board becomes a
  navigable task table, rich charts become sparklines/stats, etc.).
- IRC-inspired layout for conversational surfaces (chat,
  approvals, inbox, activity feed): sidebar + main pane + status
  bar + composer, slash commands, per-channel scrollback.
- Every mutation the TUI performs routes through the same
  internal action layer MCP and LiveView use. No parallel write
  paths, no audit/permission bypass.
- Carve `Glorbo.Actions` out of `GlorboWeb.Actions` as a side
  deliverable so the TUI can call mutations without depending on
  `glorbo_web`. The TUI sits strictly above `glorbo` core, not
  above `glorbo_web`.
- Ship a complete test pyramid: unit tests on the pure reducer,
  render-as-string snapshot tests on frames, integration tests
  against a mocked IO device, and at least one pty-backed E2E.

## Non-goals

- **Not a remote client.** `glorbo tui` runs in-process in the
  same `glorbo` binary against the same `~/.glorbo` home
  directory. No networked client mode in v1. (Future GEP may
  revisit; explicitly out of scope here.)
- **Not the service-seam generalization itself.** GEP-38
  (frontend adapter contracts) captures the broader principle;
  GEP-35 (agent-writable-file read seam) and GEP-36 (LV
  write-path cleanup) are the concrete sibling proposals. GEP-37
  borrows from the write-seam work (by extracting `Glorbo.Actions`
  for its own needs) but does not complete either GEP-35 or
  GEP-36.
- **Not an agent-facing surface.** Agents talk to Glorbo through
  their sandboxed filesystem (inbox/outbox/memory). The TUI is a
  human surface for the Director; agents do not see it.
- **Not a replacement for `glorbo serve`.** `glorbo serve` remains
  the default deployment when the Director wants the web UI. The
  TUI is a sibling surface, not a successor.

## Design

### Command surface

A new top-level subcommand alongside `run` and `serve`:

```
glorbo run            # headless — core only, no UI surface
glorbo serve          # core + Phoenix (LiveView + MCP + channels)
glorbo tui            # core + TUI, no Phoenix  ← new in GEP-37
```

All three acquire the same single-node lock on `~/.glorbo`. You
cannot run two of them against the same home simultaneously; this
is already enforced by the existing lock semantics (GEP-2 D1 —
single Elixir node per host).

`glorbo tui --help` marks the command `[alpha]` until stability
is demonstrated across a full release cycle.

### Runtime shape

`glorbo tui` boots the full Glorbo core — `Glorbo.Application`
supervisor starts with its normal children (`CompaniesSupervisor`,
`Router`, `Audit`, `Budget`, filesystem watchers, PubSub, SQLite
connection pool). It does **not** start `GlorboWeb.Endpoint`; no
Phoenix, no MCP HTTP listener.

A new surface-selection config key determines which top-level
supervisor children to start:

```elixir
# config/runtime.exs or set by CLI entrypoint before Application boot
config :glorbo, :surface, :tui   # :headless | :web | :tui
```

`Glorbo.Application` conditionally adds either `GlorboWeb.Endpoint`
or `Glorbo.Tui.Supervisor` to its children list based on this
key. Headless mode adds neither.

### Supervision tree under `Glorbo.Tui.Supervisor`

`:rest_for_one` strategy, three children in order:

1. **`Glorbo.Tui.EventBus`** (`GenServer`)
   Subscribes to `company:<co>:projects`, `company:<co>:channels`,
   `company:<co>:agents`, `company:<co>:audit`, `company:<co>:
   approvals`, and cross-company `glorbo:companies` topics via
   `Phoenix.PubSub`. Buffers events and serves them as a push
   stream to the Runtime. A crash restarts EventBus and everything
   downstream of it.

2. **`Glorbo.Tui.InputReader`** (`GenServer`)
   Owns stdin in raw/cbreak mode. Parses ANSI escape sequences for
   arrow keys, function keys, resize signals (`SIGWINCH`), and
   mouse events (initially unused). Pushes decoded input events
   to the Runtime. A crash restarts just itself and the Runtime.

3. **`Glorbo.Tui.Runtime`** (`GenServer`)
   Holds render state. Reduces `(state, event) -> state` for
   EventBus and InputReader events. Emits frame diffs to stdout
   via `Glorbo.Tui.Renderer`. A crash restarts just the Runtime.

TUI crashes do not kill agents, the router, PubSub, or any core
service — that is enforced by `Glorbo.Tui.Supervisor` being a
*sibling* subtree under `Glorbo.Application`'s root supervisor,
not a parent of core services.

### TUI runtime library — pure-Elixir custom on top of `owl`

The TUI framework is a small custom runtime under
`lib/glorbo/tui/runtime/`, built on `owl` for styling and
primitives (tables, prompts, progress indicators).

**Not using Ratatouille** — the canonical Elixir TUI framework is
effectively unmaintained (last meaningful release ~2021) and
imposes Elm-style render-loop opinions we would fight when
matching GEP-30's theme tokens and the IRC keybinding model.
Vendoring + maintaining would be a net-negative trade vs. writing
~500–800 lines of render/input loop against Owl.

**Not adding a Rust NIF (ratatui, bubbletea port)** — the Burrito
single-binary story is the load-bearing distribution invariant;
a Rust NIF complicates cross-compilation (Linux + macOS via
GEP-R30) for no gain over pure Elixir at our scope.

Runtime responsibilities:

- **Pane model** — windowed regions with independent content and
  redraw. Three permanent panes: `Sidebar`, `Main`, `Status+Composer`.
- **Render diffing** — compute cell-level diff between last frame
  and next frame; write only changed cells. Avoids full-screen
  repaints on every keystroke.
- **Layout primitives** — horizontal/vertical splits with fixed
  or flex dimensions.
- **Theme tokens** — Elixir module `Glorbo.Tui.Theme` exposing
  colour/border constants that mirror GEP-30's phosphor web
  tokens (terminal-friendly approximations of the CSS palette).
  Read at compile time into the renderer.
- **Input mapping** — `Glorbo.Tui.Keybindings` maps raw key
  events to logical actions. Swappable per-view.

### Views (drop-in parity checklist)

Every GEP-6 canonical view + GEP-20 addition mapped to a TUI view:

| Web view / feature | TUI view | Adaptation |
|---|---|---|
| Overview (company list, rollups) | `Tui.View.Overview` | Company list in sidebar; right pane shows 14-day rollup tiles as text tables (GEP-20) + recent-activity scrollback. |
| Kanban | `Tui.View.Tasks` | Filterable task table with columns `Status / Project / Task / Assignee / Priority`. Swim-lane grouping available via `gs` to group-by status. No drag-and-drop; keyboard moves via `/move <status>` slash-command. |
| Agent detail | `Tui.View.Agent` | Agent config header + tabs: `Config` (editable fields per GEP-20 AgentLive form), `Stdout` (live tail via existing `stdout_streamer`), `Inbox`, `Outbox`, `Runs`. |
| Chat | `Tui.View.Chat` | Classic IRC view. Channel list in sidebar; main pane scrollback; composer supports plain messages and slash commands. |
| Approvals | `Tui.View.Approvals` | Dired-style list; `C-n`/`C-p` cursor, `C-c C-y` / `C-c C-n` approve/deny. |
| Audit | `Tui.View.Audit` | Searchable log with `/<query>` incremental filter + column filters (`actor=`, `action=`, `since=`). |
| Health | `Tui.View.Health` | Process tree + container status + resource usage; reuses the GEP-20 health data. |
| Skills (GEP-20) | `Tui.View.Skills` | Builtin/custom/shadowed classification; used-by counts. |
| Goals (GEP-20) | `Tui.View.Goals` | Tasks bucketed by `goal:` frontmatter. |
| Inbox (GEP-20) | `Tui.View.Inbox` | Active + archived tabs. |
| Command palette (GEP-20) | `Tui.Overlay.CommandPalette` | Overlay invoked with `/` or `Ctrl-k`. |
| Keys help (GEP-30) | `Tui.Overlay.KeysHelp` | `?` opens; reuses GEP-30's keymap content. |

"Drop-in parity" is judged by capability, not pixel fidelity.
File upload becomes a path prompt; rich charts become sparklines
and text summaries; drag-and-drop becomes slash commands.

### Layout

```
┌─ sidebar (18 cols) ─┐┌──── main pane ────────────────────────────┐
│ ▾ acme              ││ Tasks · acme · @everyone                  │
│   ▸ #general        ││  ┌─┬─────────┬────────────┬────────────┐  │
│   ▸ #ops            ││  │ │ Task    │ Assignee   │ Status     │  │
│   ▾ agents          ││  ├─┼─────────┼────────────┼────────────┤  │
│     · builder       ││  │▸│ GRB-42  │ builder    │ in-flight  │  │
│     · tester        ││  │ │ GRB-43  │ tester     │ pending    │  │
│   ▾ projects        ││  └─┴─────────┴────────────┴────────────┘  │
│     · core          ││                                           │
├─────────────────────┤│                                           │
│ ▾ beta-co           ││                                           │
│   ▸ #general        ││                                           │
└─────────────────────┘└───────────────────────────────────────────┘
director@acme:tasks   [3 pending]  [4 agents]  ● ●
> /dispatch GRB-42
```

### Keybindings (v1)

**Emacs-flavoured.** Mode-less — single-letter keys are always
text input when a composer or prompt has focus. Commands go
through chord bindings (`Ctrl-`, `Alt-`/`M-`, `C-x`, `C-c`).

View switching (`C-c` is the Emacs "mode-specific binding"
prefix — TUI-wide commands all live under it):

| Key | Action |
|---|---|
| `C-c o` | Overview |
| `C-c t` | Tasks |
| `C-c a` | Agents |
| `C-c c` | Chat |
| `C-c p` | Approvals (permission gate) |
| `C-c h` | Health |
| `C-c u` | aUdit |
| `C-c s` / `C-c S` | Switch company forward / back in sidebar |

Navigation (standard Emacs motion — works everywhere, including
inside composer buffers):

| Key | Action |
|---|---|
| `C-n` / `C-p` / `↓` / `↑` | Next / previous line |
| `C-f` / `C-b` / `→` / `←` | Forward / back (char in composer, tree node in sidebar) |
| `C-v` / `M-v` | Page down / up |
| `M-<` / `M->` | Beginning / end of buffer |
| `TAB` / `S-TAB` | Next / previous focusable region (pane cycle) |
| `RET` | Open detail for highlighted item / submit single-line composer |
| `C-j` | Submit multi-line composer |

Commands:

| Key | Action |
|---|---|
| `M-x` | Command palette — invokes any bound action by name |
| `/` | Open composer with `/` already inserted (IRC slash-command convention; composer is still a regular text buffer — `C-g` cancels without submitting) |
| `C-g` | Universal cancel — closes overlay, discards composer input, aborts prompt |
| `C-x C-c` | Quit Glorbo TUI (with confirmation) |
| `?` | Keys help overlay |
| `C-l` | Redraw the screen |

Approvals view (dired-style — the list is the focus, not a
composer; dispatch-style single-letter bindings are safe here
because nothing is typing into a buffer):

| Key | Action |
|---|---|
| `C-c C-y` | Approve highlighted request |
| `C-c C-n` | Deny highlighted request (prompts for reason) |
| `C-c C-a` | Archive |

All keybindings live in `Glorbo.Tui.Keybindings` as a single
source of truth. Per-view overrides are supported but rare —
the TUI prefers a consistent global vocabulary so muscle memory
carries between views.

**Out of scope:** vim-mode opt-in. GEP-37 ships one keybinding
scheme, Emacs-flavoured. If there's demand for a vim-mode
emulation later, it's a future GEP, not a compile-time option
inside this one.

### Slash commands (composer)

Mirror the MCP tool surface from GEP-29 where they make sense at
the per-view level. In the Chat view composer: `/dispatch`,
`/approve`, `/deny`, `/skill`, `/wake`, `/new-task`,
`/trash`, `/pin`. In the Tasks view composer: `/move <status>`,
`/assign <agent>`, `/priority <level>`.

### Mutation seam — `Glorbo.Actions`

`GlorboWeb.Actions` currently has four public functions
(`post_message`, `post_task_comment`, `set_approval`,
`wake_agent`); task creation, move, trash, and dispatch live
inline in LiveView handlers via raw `File.*!` calls — an
architectural violation already identified in GEP-36.

The TUI cannot reach into `glorbo_web` without inverting the
module graph (core depending on a frontend). GEP-37 therefore
includes a focused extraction:

1. Create `Glorbo.Actions` (`lib/glorbo/actions.ex`) in core.
2. Move `post_message/4`, `post_task_comment/4`, `set_approval/4`,
   `wake_agent/4` from `GlorboWeb.Actions` to `Glorbo.Actions`.
3. Make `GlorboWeb.Actions` a thin facade — each function
   delegates to `Glorbo.Actions.<same_name>`.
4. Add to `Glorbo.Actions`: `create_task/3`, `move_task/3`,
   `trash_task/2`, `dispatch_task/2`, `create_project/3`,
   `create_agent/3`. Each extraction pulls the current LV
   handler's raw `File.*!` calls into the shared module, with
   consistent audit emission and permission checks.
5. LiveView handlers that previously did raw writes are
   refactored to call `Glorbo.Actions.<op>` via the existing
   `GlorboWeb.Actions` facade.
6. The TUI depends on `Glorbo.Actions` directly.

This overlaps with GEP-36's scope. The split: GEP-37 extracts the
operations the TUI needs (plus any LV handlers that block
extraction correctness); GEP-36's remaining scope is the Credo
gate and any LV raw-write sites GEP-37 did not touch. GEP-36's
Placeholder will be updated with a note that GEP-37 completed the
majority of the write-seam extraction.

### Read paths

For v1, the TUI reads from the same sources LiveView does:

- `SQLite` via `Ecto` for index-style lookups (task lists, agent
  lists, audit queries).
- `File.read!` / `File.stream!` for markdown and comment files.
- `Phoenix.PubSub` subscriptions for reactive updates.

This mirrors the web surface. GEP-35's `AgentWritableFile` seam is
not required for the TUI — when that seam lands, the TUI adopts
it in the same pass that updates `GlorboWeb`.

### Rendering cadence

Frames are emitted on:

1. A dirty-flag tick: when EventBus pushes a state-relevant event,
   or InputReader pushes a key event, the reducer runs and the
   renderer produces a new frame if the computed frame differs
   from the last frame.
2. A `SIGWINCH` terminal-resize signal.
3. An explicit redraw request (`Ctrl-l`).

No free-running timer. The terminal is idle when nothing is
happening.

## Migration / rollout

**Pre-1.0, atomic cut.** No feature flag. `glorbo tui` ships
enabled in the first release that includes it.

- `glorbo --help` marks the command `[alpha]` in the command
  listing until a release cycle completes without major bugs.
- No dual-build, no opt-in env var, no gradual rollout.
- The write-seam extraction (§"Mutation seam") is shipped in the
  same release. After this release, raw `File.*!` calls for
  covered operations in `glorbo_web/live/` are gone; Credo check
  enforcing this is tracked in GEP-36.
- CHANGELOG + README update describing the new command and its
  scope. UAT checklist (`docs/testing/uat.md`) gets a new
  §"TUI" section.

Downstream effects:

- Existing `glorbo run` / `glorbo serve` behaviour is unchanged.
- Existing `GlorboWeb.Actions` call sites continue to work
  (delegation is transparent).
- No on-disk format changes. No new FileSpec kinds.
- No new hex dependencies beyond `owl` (~100 kB compiled).

## Failure modes

| Mode | Surface | Handling |
|---|---|---|
| Terminal doesn't support ANSI | `glorbo tui` start | Detect via `$TERM` on boot; print error and exit with `EX_CONFIG` code, pointing at documentation. |
| Terminal too small | Live | `Glorbo.Tui.Renderer` detects `<80 cols` or `<24 rows` and renders a "resize-to-at-least-80x24" placeholder frame. |
| Stdin is not a TTY (piped/redirected) | Start | Refuse to launch; suggest `glorbo run` for non-interactive use. |
| Render diff bug produces corrupted screen | Live | `Ctrl-l` triggers a full repaint; documented. |
| Runtime GenServer crash | Live | Supervisor restarts; last frame is re-rendered from persisted state. A redraw loses at most one keystroke. |
| Single-node lock held by `glorbo serve` | Start | Print "another `glorbo` is already running against this home" and exit non-zero. |
| Mutation attempted before core ready | Start window | `Glorbo.Actions` calls return `{:error, :core_not_ready}`; composer shows the error in status bar. |
| Theme palette mismatch (low-colour terminal) | Live | `Glorbo.Tui.Theme` falls back to 16-colour on `$TERM` match; layout integrity preserved, aesthetic reduced. |

## Test strategy

Four layers, matching the web surface's test architecture.

**Unit tests — pure reducer.** `Glorbo.Tui.Runtime.reduce/2` is a
pure `(state, event) -> state` function. Comprehensive table
tests: every event type × relevant state shape. Fast,
deterministic, no I/O.

**Render snapshot tests.** `Glorbo.Tui.Renderer.frame/1` is pure:
state → list of cells. Tests build a fixture state, render, strip
ANSI escapes, and assert the textual shape matches a golden
string. Layout regressions show up immediately.

**Integration tests.** `Glorbo.Tui.Runtime` running against a fake
IO device (`ExUnit.CaptureIO` + a synthetic InputReader that
pushes a scripted sequence of events). Assert on the captured
output after each step.

**E2E.** One pty-backed test per major view that spawns `glorbo
tui` against a fixture `~/.glorbo/` (per user memory directive on
temp workspaces). Uses `:exec` or `:erlang.open_port` with a pty.
Feeds a sequence of key events; asserts on the rendered ANSI
output after ignoring theme-dependent escape codes. Runs under
the existing E2E tag, not on the default `mix test` run.

**Coverage floor.** Unit + snapshot tests: 100% line coverage on
`Glorbo.Tui.{Runtime, Renderer, View.*}`. Integration tests:
at least one per view. E2E: at least one per view for v1;
expanded in follow-up releases.

## Open questions

- **Keybinding configuration.** v1 ships with the hardcoded map
  above. User-configurable rebinds via a TOML/YAML file is likely
  future work; may be a small follow-up GEP, or folded into the
  general preferences surface when that lands.
- **Theming mechanism.** GEP-30 introduced CSS custom properties
  for phosphor tokens. The TUI wants colour parity. Options:
  (a) hardcode a terminal-approximation palette in
  `Glorbo.Tui.Theme`; (b) read a `theme.toml` alongside the
  GEP-30 tokens for single source of truth; (c) compile-time
  extraction from the CSS tokens at release build. Leaning (a)
  for v1 with (b) as future work.
- **"Attach to running `serve`" mode.** Deferred to a future GEP;
  see "Non-goals." Shape TBD — MCP client? Direct Erlang
  distribution? UNIX socket?
- **Mouse support.** Input reader parses mouse events but none
  are bound in v1. Opt-in via a keybinding; scope deferred.
- **Accessibility.** Screen-reader compatibility across terminal
  emulators is inconsistent; the TUI inherits whatever the host
  terminal provides. Not a v1 consideration.
- **GEP-36 convergence.** GEP-36's Placeholder needs an update to
  reflect that GEP-37 takes on most of the write-seam extraction.
  Planned as a same-PR frontmatter note in GEP-36, not a scope
  rewrite.

## Decision log

### D1. In-process surface, not a remote client

- **Decided:** `glorbo tui` runs inside the same `glorbo` binary,
  against the same `~/.glorbo` home. No networked client, no
  attach-to-running-instance.
- **Alternatives:** MCP-client TUI over HTTP-SSE (GEP-29); custom
  Erlang distribution attach; UNIX-socket JSON-RPC.
- **Why:** The user's threat model and deployment model (GEP-6 D5
  — "single operator on their own host") make IPC unnecessary for
  the primary use case. Adding IPC in v1 would introduce auth,
  reconnection semantics, and framing overhead solely for a
  stretch-goal ergonomics feature. Deferred to a future GEP if
  demand materialises.

### D2. Custom pure-Elixir runtime on `owl`, not Ratatouille or a Rust NIF

- **Decided:** Write a small (~500–800 LoC) custom render + input
  runtime under `lib/glorbo/tui/runtime/`, using `owl` for
  primitives (tables, styled output, prompts).
- **Alternatives:** vendor Ratatouille; depend on Ratatouille as
  hex; Rust NIF to `ratatui`; sidecar port to `bubbletea`.
- **Why:** Ratatouille is effectively unmaintained and its
  Elm-style render loop imposes opinions that fight the
  GEP-30 theme-token parity goal. A Rust NIF breaks the Burrito
  single-binary story for cross-compilation targets (Linux +
  GEP-R30 macOS). A custom runtime over Owl keeps the distribution
  invariant intact, gives full control over theme/keybinding/pane
  shape, and is smaller than the Ratatouille fork-and-fix
  carrying cost.

### D3. Third top-level command, sibling to `run` / `serve`

- **Decided:** `glorbo tui` is its own subcommand. It boots core
  + TUI, not Phoenix. Single-node lock enforces mutual exclusion
  with `glorbo serve`.
- **Alternatives:** `glorbo serve --tui` flag that adds TUI to
  Phoenix; always-launch TUI alongside `serve`.
- **Why:** Each top-level command selects its surface set
  (GEP-2/GEP-6 D4/GEP-29 D8). The surface composition model is
  established. Bundling with `serve` would either block on "which
  one owns stdin" or run the TUI detached from the launch
  terminal — both worse than a clean sibling command.

### D4. Drop-in parity is the goal, not "a terminal subset"

- **Decided:** Every Director workflow the web surface supports
  is reachable from the TUI. Kanban becomes a task table; charts
  become sparklines; file upload becomes a path prompt.
  Capability parity, not pixel parity.
- **Alternatives:** ship a TUI with only chat + approvals (a
  "focused mode"); let the user fall back to the browser for
  anything missing.
- **Why:** User directive (§"pre-1.0, no kid gloves, do things
  correctly"). A TUI the user has to abandon halfway through a
  workflow because it lacks a capability defeats its purpose. The
  adaptation cost per surface is bounded (a table instead of a
  kanban is a few hundred lines; a sparkline instead of a chart is
  a small module).

### D5. Carve `Glorbo.Actions` out of `GlorboWeb.Actions`

- **Decided:** GEP-37 ships a `Glorbo.Actions` module in core
  containing every mutation the TUI needs — including new
  extractions (`create_task`, `move_task`, `trash_task`,
  `dispatch_task`, `create_project`, `create_agent`) that today
  live as raw `File.*!` calls in LiveView handlers.
  `GlorboWeb.Actions` becomes a thin facade delegating to
  `Glorbo.Actions`.
- **Alternatives:** (a) have the TUI depend on `glorbo_web`'s
  `Actions` module directly; (b) wait for GEP-36 to complete the
  seam before shipping the TUI; (c) reimplement mutations inside
  `Glorbo.Tui.*` and dedup later.
- **Why:** (a) inverts the module graph — `glorbo_web` is a
  frontend, core should not depend on frontends. (b) holds the
  TUI hostage to a larger cleanup effort. (c) creates the exact
  parallel-write-path problem GEP-36 exists to prevent. Extracting
  into core is both the architecturally correct fix and the
  minimum change that unblocks the TUI. User directive: "proper
  and secure solutions, not temporary/evolutionary."

### D6. Separate `:rest_for_one` supervisor subtree

- **Decided:** `Glorbo.Tui.Supervisor` is a sibling of
  `CompaniesSupervisor` under `Glorbo.Application`, with
  `:rest_for_one` over `EventBus → InputReader → Runtime`.
- **Alternatives:** single GenServer holding all state; one
  process per view; `:one_for_one` over three peers.
- **Why:** Input reading, event buffering, and rendering are
  distinct concerns and belong in distinct processes (GEP-2 D2).
  `:rest_for_one` is correct because Runtime depends on
  InputReader's TTY setup which depends on EventBus being ready
  to receive events; crash order should restart downstream.
  TUI crashes do not propagate to core because the subtree is a
  sibling of `CompaniesSupervisor`, not a child.

### D7. No feature flag, ship atomic

- **Decided:** No opt-in env var, no `--experimental` gate. The
  command is documented `[alpha]` in `--help` until proven, but
  that is a doc signal only.
- **Alternatives:** `GLORBO_ENABLE_TUI=1`; `--experimental-tui`;
  compile-time flag excluding the Tui module from release by
  default.
- **Why:** Pre-1.0 convention (user memory
  `feedback_pre_1_0_no_kid_gloves.md`). Feature flags for
  pre-release software create two code paths that drift; atomic
  cuts with honest version signalling are cleaner.

### D8. View list matches web surface 1:1

- **Decided:** The seven GEP-6 canonical views + the GEP-20
  additions (Skills, Goals, Inbox-archive, command palette) all
  ship in v1. No "phase 2" slicing.
- **Alternatives:** ship a "minimum viable TUI" with only chat +
  approvals first; add views incrementally over multiple
  releases.
- **Why:** D4 (drop-in parity) demands it. Shipping a partial TUI
  and then releasing incrementally means users adopt, get burned
  by the missing capability, revert to the browser, and don't
  come back. A single release that covers everything is the only
  honest "drop-in replacement" story.

### D9. Read paths copy the web surface for v1

- **Decided:** The TUI reads from the same sources LiveView does
  (SQLite/Ecto, raw `File.read!`, PubSub). It does not wait for
  GEP-35's `AgentWritableFile` seam.
- **Alternatives:** Ship GEP-35 as a precondition; create a
  TUI-specific read layer.
- **Why:** Symmetric with D5's write-seam scope decision — extract
  the write paths because no alternative lets the TUI compile
  cleanly; defer the read seam because the existing LV reads
  compile cleanly and GEP-35 is a separate cleanup. When GEP-35
  lands, the TUI migrates to it in the same pass that updates
  LiveView.

### D10. Emacs-style keybindings, slash commands for context mutations

- **Decided:** Mode-less Emacs conventions. `C-c <letter>`
  prefixed view switch (`C-c o/t/a/c/p/h/u`), `C-n`/`C-p`/arrows
  for list motion, `M-x` for the command palette, `C-g` as
  universal cancel, `C-x C-c` to quit. Approvals view uses
  `C-c C-y` / `C-c C-n` chords so single-letter `y`/`n` stays
  available as text input when the composer is focused. IRC
  slash-command convention preserved (`/` inserts into the
  composer, submission triggers the dispatch). Central
  `Glorbo.Tui.Keybindings` module; per-view overrides are rare.
- **Alternatives:** (a) vim-modal (`j/k/y/n`, `g<letter>`
  prefixes, `:` ex-mode, insert/normal modes); (b) menu-driven
  arrow-key navigation; (c) dual-mode compile-time flag shipping
  both Emacs and vim bindings.
- **Why:** The Director is an Emacs user, and the TUI's primary
  user is the Director. Shipping vim as default would force a
  modal workflow the user doesn't have muscle memory for.
  Mode-less Emacs is also a better fit for "the composer is
  always available" TUI shape — no mode-switching tax when
  typing a chat message. The GEP-19 web-UI `j/k/y/n` shortcuts
  are shipped legacy (Implemented status, content frozen) and
  stay untouched here; if the web UI's keybindings also want
  an Emacs flip, that's a separate GEP against GEP-19/20. The
  dual-mode (c) option was rejected for the pre-1.0 "atomic cut"
  discipline — two keybinding schemes means two test matrices,
  two documentation pages, and continuous drift between them
  for zero current benefit (single known user).

### D11. No hex dependency beyond `owl`

- **Decided:** Add `{:owl, "~> 0.12"}` (or current stable); no
  other TUI-related dep. Custom runtime lives under
  `lib/glorbo/tui/runtime/`.
- **Alternatives:** Ratatouille as hex dep; multiple TUI libs
  (ex_termbox + owl + ...); Rustler NIF.
- **Why:** Burrito single-binary story is load-bearing. Every hex
  dep adds compile + cross-compile cost. Owl is pure Elixir,
  actively maintained, and covers the primitives we need (tables,
  prompts, colour, box-drawing) without imposing a render-loop
  architecture. Custom runtime code ships in-tree where we own
  the maintenance surface.

## Related

- **GEP-2** — architecture overview (`requires`).
- **GEP-6** — Phoenix LiveView dashboard; the surface this TUI
  achieves drop-in parity with.
- **GEP-19** — approval workflow protocol; Approvals view is a
  primary TUI surface.
- **GEP-20** — Director dashboard UX sweep; feature inventory
  that "drop-in parity" refers to.
- **GEP-29** — MCP server; considered and rejected as the TUI's
  IPC mechanism (D1).
- **GEP-30** — Director Dashboard TUI Redesign (V1); the web
  surface's TUI *aesthetic*. GEP-37 is the actual terminal
  surface, architecturally distinct. GEP-30's frontmatter is
  updated in the same PR to add `see-also: [37]`.
- **GEP-35** — AgentWritableFile read seam (Placeholder); TUI
  will adopt when it lands (D9).
- **GEP-36** — Actions write-seam cleanup (Placeholder); GEP-37
  completes the majority of its extraction work (D5).
- **GEP-38** — Frontend adapter contracts (Placeholder); the
  principle that GEP-35/36 and this GEP all express concretely.
