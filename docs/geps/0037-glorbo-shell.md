---
gep: 0037
title: "`glorbo shell` — interactive terminal session for the Director"
author: Glorbo Maintainers <security@example.invalid>
status: Accepted
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
  - date: 2026-04-24
    status: Draft
    note: |
      Two substantive revisions driven by user feedback on the
      initial draft:
      (a) Command renamed `glorbo tui` → `glorbo shell`. "Shell"
      is the right user-facing noun for an interactive session;
      "TUI" is the implementation detail, demoted to docstrings.
      Top-level module also renamed `Glorbo.Tui` → `Glorbo.Shell`
      (flat submodule tree: `Glorbo.Shell.{Supervisor, Runtime,
      EventBus, Views.*}`).
      (b) TUI framework flipped from "custom runtime on `owl`
      primitives" to **pcharbon70/term_ui** (v0.2.0 on hex).
      Actively maintained (439 commits), pure Elixir (preserves
      Burrito), widget set above GEP-37's needs (tables, trees,
      split panes, command palette, supervision-tree viewer — the
      last one a direct fit for the Health view). D2, D6, D11
      updated to reflect both changes.
  - date: 2026-04-24
    status: Accepted
    note: |
      Accepted after maintainer sign-off on D2 (term_ui),
      D4 (drop-in parity), D5 (`Glorbo.Actions` carve-out),
      D8 (ship-everything-at-once view list), and D10 (Emacs
      keybindings default). Implementation will ride alongside
      the GEP-36 `Glorbo.Actions` atomic cut; first release to
      carry the shell will be v0.8.0.
  - date: 2026-04-25
    status: Accepted
    note: |
      Phase 0 scaffold landed in v0.10.0 (later than the
      v0.8.0 target — `Glorbo.Actions` carve-out completed in
      v0.10.0 alongside GEP-33 Phase 2c, which was the gating
      arc): `term_ui ~> 1.0.0-rc` added to mix.exs;
      `lib/glorbo/shell.ex` skeleton with `run/1` entry point;
      `Glorbo.CLI.dispatch(["shell" | rest])` routes to it;
      help-text entry marked `[alpha]`. The verb prints a
      placeholder banner, refuses non-TTY launch, and exits
      cleanly. 4 dispatch tests guard the wiring.

      Pinned to `term_ui ~> 1.0.0-rc` because 0.2.0 fails to
      compile under Elixir 1.18 (regex Reference values can't
      be injected into `@module_attributes`; fixed upstream in
      the rc but not yet released as 1.0.0 stable). Revisit
      once 1.0.0 tags.

      Phase 1 (Supervisor + Runtime + EventBus) and Phase 2
      (first view: Inbox) land in subsequent rounds.
      `Glorbo.Shell` module structure left flat
      (`Glorbo.Shell.{Supervisor, Runtime, EventBus,
      Views.*}`) per D2 in this GEP.
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 1 landed: `Glorbo.Shell.{Supervisor, EventBus,
      Runtime}` modules + `Glorbo.Application`'s conditional
      surface flip. Supervisor uses `:rest_for_one` over two
      children (EventBus → Runtime) per D6. EventBus subscribes
      to per-company PubSub topics (`projects`, `channels`,
      `agents`, `audit`, `approvals`) plus `glorbo:companies`
      and forwards each broadcast to Runtime as a
      `{:shell_event, raw_msg}` cast. Runtime is a minimal
      state holder for Phase 1 — accumulates the most recent
      256 events, exposes `state/1` for tests; Phase 2 turns
      it into the term_ui app module driving the render loop.
      Application gained `apply_surface/2` reading
      `:glorbo, :surface` (`:web` default keeps existing
      Endpoint-only tree; `:tui` swaps Endpoint for Shell.
      Supervisor; `:headless` runs neither). 12 new tests
      across `runtime_test.exs`, `event_bus_test.exs`,
      `supervisor_test.exs` covering init state, event
      accumulation, the @max_events cap, PubSub forwarding,
      `:rest_for_one` restart semantics (Runtime crash
      restarts only Runtime; EventBus crash restarts both),
      and a Runtime-not-alive drop path in EventBus. 2300/2300
      total tests green; mix credo --strict zero findings.
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 2 landed (read-only): `Glorbo.Shell.Views.Inbox`
      implements `TermUI.Elm` for the approvals list, with
      `Glorbo.Shell.Views.Inbox.Data` as the disk-read layer
      mirroring `InboxLive.load_sentinels/2` +
      `sentinel_row/4`. Phase 2 surface:

        * Read-only list of `awaiting-approval-*` sentinels
          per company (sentinel filename → row map).
        * Cursor navigation: arrow keys + `j`/`k`.
        * `q` for quit.
        * Empty-state placeholder when no approvals pending.
        * Sentinel-without-matching-task rows are surfaced
          with `task_path: nil` so the Director can clear
          dangling sentinels (Phase 2b adds the action).

      23 new tests across `views/inbox/data_test.exs` (6) and
      `views/inbox_test.exs` (17). Disk read tested with
      a fixture filesystem; view tested with injected
      `approvals: [...]` opts so no FS dependency. View tests
      flatten the `TermUI.Component.RenderNode` tree into
      content strings to assert on visible text.

      Phase 2 ships READ-ONLY — the Director can navigate but
      not act on approvals from the TUI yet. Phase 2b lands
      the action handlers (approve / deny / archive) on top
      of the wave-31 `(company_slug, task_path)` Gate API;
      Phase 3+ adds the remaining views (overview, kanban,
      audit, channels, agents, costs, providers, health,
      memory, command palette).

      Not yet wired: term_ui's `Runtime.run/1` loop. Phase 1's
      `Glorbo.Shell.Runtime` is still an event-accumulator
      stub; the term_ui app-module integration that drives
      the actual TTY render loop lands when Phase 2 + Phase 2b
      converge into a launchable shell. Today the verb still
      prints the placeholder banner; the Inbox view is unit-
      tested but not yet visible. 2323/2323 tests green.
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 2b landed: approve/deny actions on the wave-31
      `Glorbo.Actions.set_approval/4` API. New keybindings:

        * `a` → approve the cursor row (calls
          `set_approval(co, task_path, :approved, base: base)`).
        * `d` → deny the cursor row (calls
          `set_approval(co, task_path, :denied, base: base)`).
          Phase 2b submits with no `denial_reason:`; the
          deny-reason prompt UX lands in Phase 2c.

      Architecture: `Glorbo.Shell.Views.Inbox.update/2` now
      handles `:approve` / `:deny` synchronously (term_ui's
      `Command` set is small — `:timer`, `:file_read`,
      `:send_after`, etc. — and doesn't cover arbitrary
      Elixir-function calls, so doing the side effect in
      `update/2` is the practical path for v1; the function
      is dependency-injected via `:approve_fn` for tests).
      After a successful action, the approvals list is
      refreshed via `:loader_fn` (defaults to
      `Inbox.Data.load_approvals/2`), and the cursor is
      reclamped within the new bounds. State carries a
      `last_action: {:ok|:error, decision, term()}` slot for
      post-action feedback rendering.

      Defensive arms in `apply_decision/2`:
        * Empty approvals list → `:no_actionable_row`.
        * Cursor row with `task_path: nil` (sentinel without
          a matching task) → `:no_actionable_row`. Phase 2c
          adds a separate "clear dangling sentinel" action
          for those.
        * Missing company / base in state → `:no_actionable_row`.
        * `set_approval` returns `{:error, reason}` →
          `last_action` records the reason; the approvals
          list is NOT refreshed on error.

      8 new tests: approve happy path; deny happy path;
      cursor-1 targets second row; sentinel-without-task
      records error; set_approval error path; empty list
      no-op; cursor reclamping after refresh; the new `a`/`d`
      event_to_msg arms. 2331/2331 total tests green.

      Still not wired: term_ui's `Runtime.run/1`. The Inbox
      view + actions are fully unit-tested but the verb
      still prints the Phase 0 placeholder banner. Phase 2c
      converges Phase 1's supervisor + Phase 2 view + Phase
      2b actions into a launchable shell, plus the
      deny-reason prompt UX.
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 2c landed: deny-reason prompt UX + Launcher wire-up.

      Inbox view: pressing `d` now enters a `:deny_prompt`
      modal — keystrokes accumulate into a buffer rendered
      inline below the approvals list, Enter submits with
      `denial_reason: <buffer>` (nil if empty), Esc cancels
      back to `:list` mode without calling `set_approval`.
      Backspace drops the last char; arrow keys are absorbed
      so they don't leak to list-mode handlers. State gains
      a `mode :: :list | {:deny_prompt, String.t()}` slot.
      View renders the prompt as two extra lines below the
      list ("Deny reason (Enter to submit, Esc to cancel):"
      and a `> <buffer>_` cursor line).

      `Glorbo.Shell.Launcher` is a new module that composes
      `TermUI.Runtime.run/1` inputs from CLI argv + the
      `~/.glorbo` base. Argv shape: `glorbo shell <company>`.
      Validates the company is a valid slug (rejects e.g.
      `"../etc"`, `"Acme"`) and that the company dir exists
      on disk; returns `{:error, :usage | :unknown_company |
      {:invalid_slug, raw}}` on failure with no side
      effects. Production callers use the default
      `runner_fn: &TermUI.Runtime.run/1`; the launcher_test
      passes a recording double so the suite never boots
      term_ui.

      `Glorbo.Shell.run/1` updated: `--help`/`-h` and the
      non-TTY guard remain; the no-argv path now prints a
      placeholder-with-usage banner pointing at the new
      argv shape; the with-argv path delegates to
      `Glorbo.Shell.Launcher.run/2` and surfaces its
      error tuples as `{:shell, 2, ...}` with operator-
      friendly messages.

      Tests: 31 Inbox tests (was 25; 6 new Phase-2c arms
      covering Esc cancel, backspace, empty-buffer Enter,
      modal event_to_msg routing, view overlay rendering,
      and the deny-prompt → input → submit happy path).
      11 Launcher tests covering parse_argv (5), validate
      (2), build (1), and run/2 (3 — happy + 3 error
      paths). 2348/2348 total tests green; mix credo
      --strict zero findings.

      Production launch path remains TTY-bound; `glorbo
      shell acme` (when run from a real terminal) now
      composes opts and invokes `TermUI.Runtime.run/1` for
      the first time. Phase 3 widens to multi-view
      (overview, kanban, audit, channels, agents, costs,
      providers, health, memory, command palette).
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 3a landed: `Glorbo.Shell.AppRoot` view-manager +
      `C-c <letter>` chord-prefix dispatcher per D10's
      keybinding table. AppRoot wraps the per-view
      `TermUI.Elm` modules and owns the chord state
      (`:idle | :c_c`); Ctrl+c flips into chord mode, the
      next keystroke selects a view, Esc cancels. Unknown
      chords surface a `chord_hint` footer line; chord
      letters mapped to Phase-3b+ views (h, o, t, a, c, u)
      surface a "view not yet implemented (Phase 3b+)"
      hint while keeping the current view active. Only `p`
      (Approvals = Inbox) actually routes through in
      Phase 3a — the chord scaffold is exercised end-to-end
      with one view, and Phase 3b adds the second view as
      the actual swap target.

      Launcher updated: `build_runner_opts/2` now uses
      `Glorbo.Shell.AppRoot` as the root view instead of
      `Glorbo.Shell.Views.Inbox` directly. AppRoot's
      `init/1` forwards opts to its initial sub-view (Inbox)
      so the Phase 2c launch contract is preserved.

      18 new tests across `app_root_test.exs`: init shape,
      Ctrl+c → chord_start_c_c, plain `c` propagates,
      single-key in :c_c → chord_select, Esc → chord_cancel,
      non-Ctrl+c events propagate, chord_start clears prior
      hint, chord_cancel returns to :idle + clears hint,
      `p` routes to :approvals, unknown chord surfaces
      hint, not-implemented chord (h) surfaces Phase-3b+
      hint without changing view, sub-view delegation
      (cursor_down passes through to Inbox), :noreply
      propagates back unchanged, view rendering empty +
      with chord active + with hint set. 2366/2366 total
      tests green; mix credo --strict zero findings.

      Phase 3b adds the second view (Health, the simplest
      one — read-only supervision-tree snapshot per D10's
      "C-c h" mapping); that's the bounded chunk where the
      actual chord-driven view swap becomes visible.
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 3b landed: read-only Health view + chord-driven
      swap from the Inbox.

      `Glorbo.Shell.Views.Health` mirrors the surface of
      `glorbo doctor` (without the JSON formatter): one line
      per check, each tagged with a pass/fail glyph
      (`✓`/`✗`) + severity in brackets (`[blocker]` /
      `[warning]` / `[info]`). Cursor navigation via arrows
      + j/k; `r` re-runs `Doctor.run_checks/0` for live
      reload (Phase 3c will add periodic auto-refresh once
      the term_ui timer-Command surface is wired); `q`
      quits. The checks-fn is dependency-injected for
      testability; production passes through to
      `&Glorbo.Doctor.run_checks/0`.

      AppRoot updates:
        * `view :: :approvals | :health` (was
          `:approvals` only).
        * New `@views_implemented [:approvals, :health]`
          replaces `@views_phase_3a [:approvals]` —
          Phase 3+ views are added here as they ship.
        * `init/1` accepts `:initial_view` opt to start
          in a non-default view (handy for tests + future
          deep-link launches like `glorbo shell acme
          --view health`).
        * Chord swap (`C-c h` / `C-c p`) calls
          `forward_opts/1` to carry `:base` + `:company`
          from the current sub_state to the new view's
          init/1, so per-view setup keeps working across
          swaps without re-passing argv.

      `view_module/1` arms expanded:
        * `:approvals` → `Glorbo.Shell.Views.Inbox`
        * `:health` → `Glorbo.Shell.Views.Health`
        * fallback still maps to Inbox (unreachable in
          practice — `chord_select` filters via
          `@views_implemented`).

      Tests: 16 new across `views/health_test.exs` (13)
      and `app_root_test.exs` (3 — chord-h-routes-health,
      chord-o-still-not-implemented, view-swap-forwards-
      base-company; plus the existing
      `:initial_view` opt test). 2382/2382 total tests
      green; mix credo --strict zero findings.

      End-to-end now visible in a real TTY: `glorbo shell
      acme` boots into the Inbox, `C-c h` swaps to the
      Health view rendering the doctor checks, `C-c p`
      swaps back. Phase 3+ widens to the remaining views
      (overview, tasks, agents, chat, audit) one at a
      time; each is roughly Phase-3b-sized and follows the
      same pattern (Data fetcher + Elm view module +
      register in `view_module/1` + add to
      `@views_implemented`).
  - date: 2026-04-26
    status: Accepted
    note: |
      Phase 3c landed: Overview view (third real view).
      `Glorbo.Shell.Views.Overview` is the cross-company
      workspace list — one row per `companies/<slug>/` dir,
      showing `slug (name) — N agents, M alerts`. Active
      company highlighted with a `*` glyph; cursor lands on
      the active row on first paint. `r` re-runs the loader
      for live reload; `q` quits.

      `Glorbo.Shell.Views.Overview.Data` is the FS-only
      read layer: slug from dirname, name from
      `company.md` frontmatter (falls back to slug), agent
      count from `agents/*/[Aa][Gg][Ee][Nn][Tt].md`
      wildcard, alert count from `alerts/*-budget.md`. No
      Repo dependency — Phase 3d adds the spend / in-progress
      / goals-progress columns the LV Overview shows.

      AppRoot updates: `view :: :approvals | :health |
      :overview`; `@views_implemented` adds `:overview`;
      `view_module/1` arm for `:overview`.

      26 new tests across `views/overview/data_test.exs` (9)
      + `views/overview_test.exs` (16) + AppRoot's swap-
      target test (1, swapped from `:overview` (now real) to
      `:tasks` (still Phase 3+)). 2408/2408 total tests
      green.

      End-to-end visible in a real TTY:

        $ glorbo shell acme         # Inbox
        C-c h                       # → Health
        C-c o                       # → Overview (acme highlighted)
        C-c p                       # → back to Inbox
requires: [2]
extended-by: [39]
see-also: [6, 29, 30, 35, 36, 38]
---

# GEP-37: `glorbo shell` — interactive terminal session for the Director

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

- Introduce a new top-level subcommand `glorbo shell` that launches
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

- **Not a remote client.** `glorbo shell` runs in-process in the
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
glorbo shell            # core + TUI, no Phoenix  ← new in GEP-37
```

All three acquire the same single-node lock on `~/.glorbo`. You
cannot run two of them against the same home simultaneously; this
is already enforced by the existing lock semantics (GEP-2 D1 —
single Elixir node per host).

`glorbo shell --help` marks the command `[alpha]` until stability
is demonstrated across a full release cycle.

### Runtime shape

`glorbo shell` boots the full Glorbo core — `Glorbo.Application`
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
or `Glorbo.Shell.Supervisor` to its children list based on this
key. Headless mode adds neither.

### Supervision tree under `Glorbo.Shell.Supervisor`

`:rest_for_one` strategy, three children in order:

1. **`Glorbo.Shell.EventBus`** (`GenServer`)
   Subscribes to `company:<co>:projects`, `company:<co>:channels`,
   `company:<co>:agents`, `company:<co>:audit`, `company:<co>:
   approvals`, and cross-company `glorbo:companies` topics via
   `Phoenix.PubSub`. Buffers events and serves them as a push
   stream to the Runtime. A crash restarts EventBus and everything
   downstream of it.

2. **`Glorbo.Shell.InputReader`** (`GenServer`)
   Owns stdin in raw/cbreak mode. Parses ANSI escape sequences for
   arrow keys, function keys, resize signals (`SIGWINCH`), and
   mouse events (initially unused). Pushes decoded input events
   to the Runtime. A crash restarts just itself and the Runtime.

3. **`Glorbo.Shell.Runtime`** (`GenServer`)
   Holds render state. Reduces `(state, event) -> state` for
   EventBus and InputReader events. Emits frame diffs to stdout
   via `Glorbo.Shell.Renderer`. A crash restarts just the Runtime.

TUI crashes do not kill agents, the router, PubSub, or any core
service — that is enforced by `Glorbo.Shell.Supervisor` being a
*sibling* subtree under `Glorbo.Application`'s root supervisor,
not a parent of core services.

### TUI framework — [`term_ui`](https://github.com/pcharbon70/term_ui)

The shell is built on `term_ui` (v0.2.x on hex). Pure Elixir,
actively maintained, MIT-licensed. Elm-architecture API
(`init/2`, `event_to_msg/2`, `update/2`, `view/1`) with a
GenServer-backed render loop doing cell-level differential
updates. The widget set covers every surface the shell needs
(tables, trees, split panes, text inputs, command palette,
supervision-tree viewer — the last a direct fit for the Health
view).

**Not using Ratatouille** — the older canonical Elixir TUI
framework is effectively unmaintained (last meaningful release
~2021). term_ui is the active successor in spirit.

**Not writing a custom runtime on `owl`** — the initial draft's
choice. Replaced in the same revision as D2/D11 because term_ui
already does what the custom layer would have done, with
maintenance and tests.

**Not adding a Rust NIF (ratatui, bubbletea port)** — the
Burrito single-binary story is the load-bearing distribution
invariant; a Rust NIF complicates cross-compilation (Linux +
macOS via GEP-R30) for no gain over pure Elixir at our scope.

Shell-side responsibilities (on top of term_ui):

- **View modules** — one per pane under `Glorbo.Shell.Views.*`,
  each implementing term_ui's `init/update/view` callbacks.
  Top-level Runtime composes them into the root view.
- **Theme tokens** — Elixir module `Glorbo.Shell.Theme`
  exposing colour/border constants that mirror GEP-30's
  phosphor web tokens (terminal-friendly approximations of
  the CSS palette). Passed to term_ui widgets at render time.
- **Input mapping** — `Glorbo.Shell.Keybindings` maps term_ui
  input events to logical actions (`view.overview`,
  `list.next`, `composer.submit`, etc.). Per-view overrides
  supported but rare; centralised for consistency.
- **EventBus** — subscribes to PubSub `company:<co>:*` topics,
  forwards as term_ui messages into the Runtime.

### Views (drop-in parity checklist)

Every GEP-6 canonical view + GEP-20 addition mapped to a TUI view:

| Web view / feature | TUI view | Adaptation |
|---|---|---|
| Overview (company list, rollups) | `Shell.Views.Overview` | Company list in sidebar; right pane shows 14-day rollup tiles as text tables (GEP-20) + recent-activity scrollback. |
| Kanban | `Shell.Views.Tasks` | Filterable task table with columns `Status / Project / Task / Assignee / Priority`. Swim-lane grouping available via `gs` to group-by status. No drag-and-drop; keyboard moves via `/move <status>` slash-command. |
| Agent detail | `Shell.Views.Agent` | Agent config header + tabs: `Config` (editable fields per GEP-20 AgentLive form), `Stdout` (live tail via existing `stdout_streamer`), `Inbox`, `Outbox`, `Runs`. |
| Chat | `Shell.Views.Chat` | Classic IRC view. Channel list in sidebar; main pane scrollback; composer supports plain messages and slash commands. |
| Approvals | `Shell.Views.Approvals` | Dired-style list; `C-n`/`C-p` cursor, `C-c C-y` / `C-c C-n` approve/deny. |
| Audit | `Shell.Views.Audit` | Searchable log with `/<query>` incremental filter + column filters (`actor=`, `action=`, `since=`). |
| Health | `Shell.Views.Health` | Process tree + container status + resource usage; reuses the GEP-20 health data. |
| Skills (GEP-20) | `Shell.Views.Skills` | Builtin/custom/shadowed classification; used-by counts. |
| Goals (GEP-20) | `Shell.Views.Goals` | Tasks bucketed by `goal:` frontmatter. |
| Inbox (GEP-20) | `Shell.Views.Inbox` | Active + archived tabs. |
| Command palette (GEP-20) | `Shell.Overlays.CommandPalette` | Overlay invoked with `/` or `Ctrl-k`. |
| Keys help (GEP-30) | `Shell.Overlays.KeysHelp` | `?` opens; reuses GEP-30's keymap content. |

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

All keybindings live in `Glorbo.Shell.Keybindings` as a single
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

**Pre-1.0, atomic cut.** No feature flag. `glorbo shell` ships
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
- One new hex dependency: `term_ui` (~200-300 kB compiled,
  pure Elixir, no native code).

## Failure modes

| Mode | Surface | Handling |
|---|---|---|
| Terminal doesn't support ANSI | `glorbo shell` start | Detect via `$TERM` on boot; print error and exit with `EX_CONFIG` code, pointing at documentation. |
| Terminal too small | Live | `Glorbo.Shell.Renderer` detects `<80 cols` or `<24 rows` and renders a "resize-to-at-least-80x24" placeholder frame. |
| Stdin is not a TTY (piped/redirected) | Start | Refuse to launch; suggest `glorbo run` for non-interactive use. |
| Render diff bug produces corrupted screen | Live | `Ctrl-l` triggers a full repaint; documented. |
| Runtime GenServer crash | Live | Supervisor restarts; last frame is re-rendered from persisted state. A redraw loses at most one keystroke. |
| Single-node lock held by `glorbo serve` | Start | Print "another `glorbo` is already running against this home" and exit non-zero. |
| Mutation attempted before core ready | Start window | `Glorbo.Actions` calls return `{:error, :core_not_ready}`; composer shows the error in status bar. |
| Theme palette mismatch (low-colour terminal) | Live | `Glorbo.Shell.Theme` falls back to 16-colour on `$TERM` match; layout integrity preserved, aesthetic reduced. |

## Test strategy

Four layers, matching the web surface's test architecture.

**Unit tests — pure reducer.** `Glorbo.Shell.Runtime.reduce/2` is a
pure `(state, event) -> state` function. Comprehensive table
tests: every event type × relevant state shape. Fast,
deterministic, no I/O.

**Render snapshot tests.** `Glorbo.Shell.Renderer.frame/1` is pure:
state → list of cells. Tests build a fixture state, render, strip
ANSI escapes, and assert the textual shape matches a golden
string. Layout regressions show up immediately.

**Integration tests.** `Glorbo.Shell.Runtime` running against a fake
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
`Glorbo.Shell.{Runtime, Renderer, View.*}`. Integration tests:
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
  `Glorbo.Shell.Theme`; (b) read a `theme.toml` alongside the
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

- **Decided:** `glorbo shell` runs inside the same `glorbo` binary,
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

### D2. `term_ui` as the TUI framework (pcharbon70/term_ui)

- **Decided:** Adopt [`term_ui`](https://github.com/pcharbon70/term_ui)
  v0.2.x from hex as the TUI framework. Pure Elixir, actively
  maintained (439 commits, 183 stars as of 2026-04), MIT
  licensed. Widget set covers everything GEP-37 needs: tables,
  trees, split panes, text inputs, command palette, and a
  supervision-tree viewer that maps directly onto the Health
  view. Elm-architecture API (`init/2`, `event_to_msg/2`,
  `update/2`, `view/1`) with a GenServer-backed render loop
  doing differential updates.
- **Alternatives:** (a) Custom render + input runtime on `owl`
  primitives (the initial draft's choice); (b) vendor
  Ratatouille; (c) Rust NIF to `ratatui`; (d) sidecar port to
  `bubbletea`.
- **Why:** (a) is reinvention when a viable framework exists;
  the user flagged term_ui mid-review and it's a strictly
  better fit — we were going to write a layer that does what
  term_ui already does, with bugs, without tests. (b)
  Ratatouille is effectively unmaintained. (c) and (d) break
  the Burrito single-binary story for cross-compilation (Linux +
  GEP-R30 macOS). term_ui is pure Elixir, on hex, matches our
  `.tool-versions` floor (Elixir 1.15+ / OTP 28+), and its
  widget set lands above the GEP-37 requirement — we adopt, not
  build. If term_ui's model doesn't cover something exotic
  (unlikely given its breadth), we render custom inside a
  term_ui viewport — contained fallback, not framework
  abandonment.

  This flip replaces the initial draft's "custom on owl"
  decision. The spirit of that decision (pure Elixir, preserve
  Burrito, no NIFs) is retained; the mechanics change.

### D3. Third top-level command, sibling to `run` / `serve`

- **Decided:** `glorbo shell` is its own subcommand. It boots core
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
  `Glorbo.Shell.*` and dedup later.
- **Why:** (a) inverts the module graph — `glorbo_web` is a
  frontend, core should not depend on frontends. (b) holds the
  TUI hostage to a larger cleanup effort. (c) creates the exact
  parallel-write-path problem GEP-36 exists to prevent. Extracting
  into core is both the architecturally correct fix and the
  minimum change that unblocks the TUI. User directive: "proper
  and secure solutions, not temporary/evolutionary."

### D6. Separate supervisor subtree with term_ui as a child

- **Decided:** `Glorbo.Shell.Supervisor` is a sibling of
  `CompaniesSupervisor` under `Glorbo.Application`.
  `:rest_for_one` strategy over two children: `EventBus` →
  `Runtime` (the term_ui app module). `term_ui` handles its
  own input reading internally, so the separate
  `InputReader` process from the initial draft is folded into
  term_ui's runtime.
- **Alternatives:** single GenServer holding all state; one
  process per view; `:one_for_one` over peers.
- **Why:** Event buffering and rendering are still distinct
  concerns — EventBus subscribes to `company:<co>:*` PubSub
  topics, Runtime reduces `(state, msg) → state` per term_ui's
  Elm-architecture. `:rest_for_one` is correct because Runtime
  depends on EventBus being ready to receive events; crash
  order should restart downstream. TUI crashes do not propagate
  to core because the subtree is a sibling of
  `CompaniesSupervisor`, not a child (GEP-2 D2 — bounded blast
  radius).

  This simplifies the initial draft's 3-child tree (EventBus,
  InputReader, Runtime) to a 2-child tree, with term_ui owning
  the TTY surface. Adopted in the same revision as D2's flip
  to term_ui.

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
  `Glorbo.Shell.Keybindings` module; per-view overrides are rare.
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

### D11. Single new hex dependency: `term_ui`

- **Decided:** Add `{:term_ui, "~> 0.2"}` (pcharbon70/term_ui).
  No other TUI-adjacent hex deps. Shell-specific code lives
  under `lib/glorbo/shell/` (the EventBus, Runtime view module,
  and per-view modules).
- **Alternatives:** `owl` as primitives base + custom runtime
  (initial draft); Ratatouille as hex dep; `ex_termbox` plus a
  hand-rolled layout engine; Rustler NIF.
- **Why:** term_ui is pure Elixir (preserves the Burrito
  single-binary story), MIT-licensed (Apache-2.0 compatible),
  and its widget set covers the shell's full surface without
  us writing render/input primitives. The initial draft's
  "custom on owl" was motivated by Ratatouille's stale state,
  but term_ui resolves that concern at the framework layer —
  actively maintained, 439 commits, on hex. Adopting is
  straightforwardly simpler than building.

  Cross-compile cost: term_ui has no native dependencies
  (Erlang `:io.get_chars/2` for input, ANSI for output); should
  flow through Burrito's Zig cross-compile for macOS without
  special handling.

  This flip replaces the initial draft's "no hex dep beyond owl"
  decision. Same spirit (minimise deps, preserve Burrito),
  different mechanics.

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
