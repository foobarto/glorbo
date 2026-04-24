# 2026-04-24 — autonomous session log

User instruction (verbatim):

> I'm going to go to sleep for a while and would like you to continue
> fully autonomously for now. Any decisions you make you think I
> should at least be aware of or review later save in the
> `docs/sessions/2026-04-24-autonomous-round.md` — do not wait for my
> input, based on previous decisions made take best educated guess
> and go with it. Prefer "proper" and "secure" solutions rather than
> temporary or evolutionary solutions. We are pre-1.0 still, no
> users, no kid gloves. Let's make hard choices and do things
> correctly.

This file is the review log for the autonomous /loop session of
2026-04-24. Ordered newest-last. Each entry is either a decision
taken alone (with rationale) or a question I'd normally surface
but am answering myself.

## Session scope

Drafting **GEP-37** (`glorbo tui` — interactive terminal client for
the Director) and reserving **GEP-38** (frontend adapter contracts)
as a Placeholder, via the `glorbo-new-gep` skill. Q1–Q6 were
answered live before you went to sleep; Q7–Q13 design questions
are resolved autonomously below with rationale.

## Decisions taken without asking

### Q7 — TUI library

**Decided:** **Custom TUI runtime under `lib/glorbo/tui/`, built on
`owl` primitives (tables, prompts, styling).** No `ratatouille`
vendoring, no Rust NIF via `ratatui`, no sidecar port to
`bubbletea`.

**Why:** User criteria were "looks better" and "easier to theme and
modify." Ratatouille is stale (last release ~2021) and its Elm-
style render loop imposes opinions on pane shape and keybindings
we'd end up fighting. Owl alone is a styled-output toolkit, not a
full-screen TUI framework — no persistent panes. Writing a small
runtime (GenServer + render loop + input reader) on top of Owl's
primitives inherits Owl's maintained styling layer while giving us
full control over pane model, theme tokens, keybindings, and
render diffing. Pure Elixir, zero new hex deps beyond `owl`, no
impact on the Burrito single-binary story.

**Tradeoff accepted:** more code to maintain than adopting a
framework. Estimated ~500-800 LoC for the runtime. Below the
carrying cost of vendoring Ratatouille and fixing its OTP-28
warnings forever.

### Q8 — Runtime mode: `glorbo tui` is a third top-level command

**Decided:** `glorbo tui` is a **sibling** to `glorbo run` and
`glorbo serve`. It boots the Glorbo core (companies supervisor,
router, PubSub, filesystem watchers, SQLite) and starts the TUI
supervisor. It does **not** start Phoenix.

**Why:** Matches GEP-2 / GEP-6 D4 / GEP-29 D8 — each top-level
command selects the surface set it runs. `run` = core only,
`serve` = core + Phoenix, `tui` = core + TUI. The filesystem +
SQLite lock on `~/.glorbo` prevents multiple surfaces against the
same home simultaneously, which is already the expected mode.

**Explicit non-goal (captured in the GEP):** "attach TUI to
already-running `serve` instance." That needs IPC, which the user
explicitly rejected as overkill for v1. Flagged as a future GEP if
demand materialises.

### Q9 — Layout shape

**Decided:** Classic IRC layout:

- **Left sidebar** (18–22 cols): company tree with agents + project
  buckets, acts as channel list.
- **Main pane** (remainder): context-dependent view, one of:
  Overview, Tasks (kanban-as-table), AgentDetail, Chat, Approvals,
  Audit, Health.
- **Status bar** (1 row): `director@<company>:<view>` prompt-style
  context + unread counts + health glyph.
- **Composer** (1–3 rows, expandable): input box for chat messages
  + slash commands (`/dispatch`, `/approve`, `/deny`, `/skill`,
  `/wake`, `/new-task`, `/trash`).

Navigation:
- **`g<letter>`** (vim-style) for view-switch: `go` overview, `gt`
  tasks, `ga` agents, `gc` chat, `gp` approvals, `gh` health, `gu`
  audit.
- **`j/k`** move cursor in lists; **`y/n`** approve/deny (already
  used in `ApprovalQueueLive`); **Enter** opens detail.
- **`:`** enters composer (one-shot command mode, à la vim).
- **`?`** opens keys help overlay (parity with GEP-30 `keys_overlay`).

**Why:** Drop-in parity with web requires all 7 GEP-6 canonical
views + the GEP-20 additions. IRC sidebar + main pane maps
cleanly. Vim keybindings match the existing `ApprovalQueueLive`
shortcuts (`j/k/y/n`) and the developer audience's muscle memory.

### Q10 — Mutation seam: carve `Glorbo.Actions` out of `GlorboWeb.Actions`

**Decided:** GEP-37 ships a new `Glorbo.Actions` module in core
(`lib/glorbo/actions.ex`) that exposes every mutation the TUI
needs. `GlorboWeb.Actions` becomes a thin Phoenix-facing facade
that delegates to `Glorbo.Actions`. The TUI depends on
`Glorbo.Actions` directly, not on `glorbo_web`.

Functions to extract/create in `Glorbo.Actions` as part of GEP-37:

- `post_message/4` (already exists in `GlorboWeb.Actions`, move)
- `post_task_comment/4` (already exists, move)
- `set_approval/4` (already exists, move)
- `wake_agent/4` (already exists, move)
- `create_task/3` (new — extract from `KanbanLive`)
- `move_task/3` (new — extract from `KanbanLive`)
- `trash_task/2` (new — extract from `TaskLive`)
- `dispatch_task/2` (new — extract from `KanbanLive` / `TaskLive`)
- `create_project/3` (new — extract from dashboard handlers)
- `create_agent/3` (new — extract from wizard handlers)

Everything above goes through the same Elixir code paths MCP and
LV already use (GEP-29 D3 rule). Audit + permission enforcement
centralised at the `Glorbo.Actions` boundary.

**Why:** User's directive ("proper and secure solutions, not
temporary/evolutionary"). Having the TUI depend on `glorbo_web` is
an inversion of the module graph — `glorbo_web` is a frontend,
core should not depend on frontends. Extracting to core is the
correct architectural fix and what GEP-36 would eventually do
anyway. The scope of extraction here is bounded: only the
operations the TUI needs. Residual LV-direct `File.*!` writes that
the TUI does not exercise stay for GEP-36 to clean up.

**GEP-36 impact:** Its Placeholder scope narrows. GEP-37 will
complete most of the write-seam extraction; GEP-36 remaining
scope becomes "gate LV handlers from writing directly via Credo
rule + sweep remaining raw writes that GEP-37 did not touch."
I'll note this in GEP-36's open questions without editing its
decisions (it's Placeholder — no decisions to invalidate).

### Q11 — Supervision tree shape

**Decided:** `Glorbo.Tui.Supervisor` (`:rest_for_one`) as a child
of `Glorbo.Application` supervisor, conditionally started when
`Application.get_env(:glorbo, :surface) == :tui`. Children:

1. `Glorbo.Tui.EventBus` — subscribes to `company:<co>:*` PubSub
   topics; buffers events.
2. `Glorbo.Tui.InputReader` — GenServer reading stdin escape
   sequences via `IO` with raw-mode termcap setup.
3. `Glorbo.Tui.Runtime` — GenServer holding render state, reduces
   EventBus events + InputReader events into frames, writes to
   stdout.

Crash semantics: a Runtime crash restarts Runtime + InputReader
(downstream of EventBus); an InputReader crash restarts just
itself; EventBus crash restarts the whole subtree. Agents + core
are unaffected by any TUI crash (sibling subtree under root
supervisor).

**Why:** Matches Glorbo's OTP-supervision invariant (GEP-2 D2 —
let-it-crash with bounded blast radius). Input reading and render
loops are distinct concerns and belong in distinct processes.

### Q12 — Testing strategy

**Decided:**

1. **Unit tests** for the pure reducer: `state + event → state`.
   No I/O. Fast, deterministic.
2. **Render-as-string tests**: given a fixture state, assert the
   rendered frame (ANSI-stripped) matches a golden string. Catches
   layout regressions.
3. **Integration tests** with `:io` mocked: spawn the TUI
   supervisor against a fake IO device, feed synthetic input
   events, assert on rendered output.
4. **E2E test** that spawns `glorbo tui` against a fixture
   `~/.glorbo/` workspace via `:exec` (or `:erlang.open_port` with
   `{:spawn, "..."}` and pty), feeds input, captures stdout, and
   asserts IRC-sidebar contents match expected companies. Honours
   user memory directive "ship E2E tests alongside features."

No attempt at screen-diffing terminals in CI; the render-as-string
tests plus E2E structural assertions are sufficient.

**Why:** Three-layer testing matches the existing web test
architecture (unit + LiveView render tests + Playwright E2E).
Standard Elixir shapes.

### Q13 — Rollout / feature gating

**Decided:** **No feature flag.** `glorbo tui` ships enabled in
the first release that includes it. `glorbo --help` marks the
command as `[alpha]` until it's proven stable (a full release
cycle of user testing). No dual-build, no opt-in env var.

**Why:** User directive — "pre-1.0, no kid gloves, atomic cuts."
User memory: `feedback_pre_1_0_no_kid_gloves.md`.

### GEP-38 title and scope

**Decided:** **GEP-38: "Frontend adapter contracts — one internal
service layer, N frontends"** (Placeholder). Scope is the
architectural *rule* that every Director-facing capability lives
in a single internal `Glorbo.Actions` / `Glorbo.Queries` module,
and frontends (web LV, TUI, MCP) are thin adapters. GEP-35 (read
seam) and GEP-36 (write seam) are the concrete sub-proposals;
GEP-38 is the principle that makes both necessary and forbids
future frontends from bypassing either.

**Why:** User coined the idea in the session and suggested it
deserves its own GEP. Reserving number 38 as a Placeholder
captures intent without blocking GEP-37. GEP-37 can `see-also` it.

### Not committed, not pushed

GEP drafts (37, 38), README index update, and GEP-30 back-link
will be committed locally but **not pushed**. User memory
(`feedback_codex_review_before_commit.md`,
`feedback_update_docs_with_feature.md`) + GEP-1 convention says
GEPs are reviewed before landing. The user should review the
drafts on waking, then approve the push.

## Open questions parked for user review

- **Keybinding bikeshed.** `g<letter>` view-switch prefixes are my
  guess; happy to switch to `<Ctrl-n>/<Ctrl-p>` tab cycling or a
  `command_palette`-first interaction if you prefer.
- **Owl version pinning.** Not yet checked; will add `{:owl,
  "~> 0.12"}` or equivalent when implementation lands. Version is
  placeholder in the GEP.
- **`glorbo tui --no-core`.** Should there be a future mode where
  `tui` attaches to a running `serve` via MCP client? GEP-37
  explicitly defers this; GEP-38 may resurface it.
- **Theming hook.** GEP-30 introduced phosphor tokens for web CSS.
  GEP-37 should consume them for colour parity. Mechanism TBD
  (config file? compile-time macro?) — flagged as an open question
  in the GEP body.

## Next — auto wakeup

Scheduling a safety wakeup so if this turn drops I pick up from
wherever I left off (validate, commit, handoff).
