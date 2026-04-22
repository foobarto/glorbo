---
gep: 0030
title: Director Dashboard TUI Redesign (V1)
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-22
history:
  - date: 2026-04-22
    status: Draft
    note: |
      Initial draft. Commits to the design handoff at
      .design/design_handoff_glorbo_tui/ as the canonical TUI direction;
      restyle scope, not a rewrite.
  - date: 2026-04-22
    status: Accepted
    note: |
      Accepted after director sign-off. Open questions O1/O2/O3 folded
      into D12/D13/D14. Phase 1 (tokens merge) begins next.
  - date: 2026-04-22
    status: Implemented
    note: |
      Phases 1–8 shipped on main. Tokens merged; chrome restyled
      (quake-console drawer with Ctrl+`, IRC composer, `▟` brand,
      otp-release + MCP endpoint in the version strip); overview +
      channels + audit + kanban + goals/skills/providers sharpened
      (hairline panels, radius 0, dashed row separators, modals
      flattened); task-comments/v1 FileSpec shipped as an atomic
      cut (sibling `.comments.md` thread via `Glorbo.TaskComments`,
      all writers + readers in Actions / Agent.Server / KanbanLive /
      TaskLive routed to the new path). Existing `?` cheatsheet +
      ⌘K palette reused.
requires: [2, 6]
see-also: [11, 15, 20, 25]
---

# GEP-30: Director Dashboard TUI Redesign (V1)

## Problem

The Director-facing LiveView dashboard ships a "terminal phosphor" look
but it's inconsistent across screens: some panels use OKLCH tokens,
some hand-picked hex; chrome (topbar/sidebar/statusbar/chat drawer)
has drifted between LiveViews; keyboard-first navigation is partial;
empty/loading/error states are ad-hoc per-screen; there's no command
palette or keys overlay. GEP-20 shipped the Round 2/3 UX sweep but
predates the "sharpen the terminal identity" direction.

A high-fidelity external handoff now sits under
`.design/design_handoff_glorbo_tui/` — React-via-Babel prototypes plus
exact design tokens, covering 22 screens (chrome, 10 main LiveViews,
edge states, overlays, and the Kanban task drawer + standalone page).
It **sharpens and consolidates** what v0.0.4 already does; it does not
introduce a foreign aesthetic. Commit to it as the canonical UX before
more features (R26.2, GEP-30 macOS targets, approvals power-user
features) layer on and re-fork the chrome.

## Goals

- Consolidate one visual system across every LiveView, driven by the
  `--glorbo-*` token set from the handoff.
- Replace the OKLCH tokens in `assets/css/app.css` with the handoff's
  hex tokens (keeping the existing OKLCH names as aliases only where
  grepped usage is wide enough to be disruptive).
- Restyle each of the ten Director-facing screens + 19 design-bundle
  edge states/overlays listed in the handoff's route→LiveView map.
- Add three missing overlay components: command palette (`⌘K`), keys
  overlay (`?`), destructive confirm with typed-word gate.
- Wire the keyboard shortcut table from the handoff so the TUI is
  keyboard-first, not mouse-first-with-shortcuts.
- Land the Kanban task drawer (new + detail modes) and restyle the
  standalone task page (`/companies/:co/tasks/:task_id`).
- Introduce a new `FileSpec` kind for task comments.

## Non-goals

- **Not a rewrite.** Router, LiveView boundaries, PubSub wiring,
  component file names are preserved. Markup and classes change;
  module structure doesn't. No new LiveView modules except where the
  design adds a surface (`kanban_task_drawer`, overlays).
- **No new routes.** Every screen lands on its existing route. The
  new task drawer and task detail drawer mount on `KanbanLive`.
- **No changes** to permissions, sandboxing, audit format, MCP surface,
  agent runtime, provider registry, or GEP-5's kernel-level isolation.
- **No light mode.** No icon-library adoption. No rounded corners
  outside pills/kbd chips. No drop shadows, glows, gradients.
- **No accessibility audit beyond** the handoff's stated minimums
  (11px minimum text, glyph-not-just-color for status, visible focus
  outlines, keyboard-reachable interactive elements). A broader a11y
  pass is a follow-up GEP.
- Routes the handoff marks as "not covered" (`/health`, `/costs`,
  `/companies/:co/braindump`, `/companies/:co/projects/:project`,
  `/companies/:co/audit.csv`, `/api/search`, `/mcp`) get chrome-only
  updates — no render-body restyle in this GEP.

## Design

### Scope (files touched)

Merge + restyle:

- `assets/css/app.css` — merge `design-tokens.css` under a
  `/* TUI tokens */` heading; update existing rules to the new vars.
- Chrome: `lib/glorbo_web/components/topbar.ex`, `sidebar.ex`,
  `statusbar.ex`, `chat_drawer.ex` (+ `chat_drawer/` subtree).
- Shared components (14): `status_pill`, `stat_card`,
  `stat_breakdown`, `task_card`, `spark`, `audit_entry`,
  `channel_message`, `stdout_tail`, `tab_bar`, `health_dot`,
  `icon` (audit + selective replacement with Unicode glyphs),
  `company_card`, `agent_card`, `task_detail_form`, `budget_ring`.
- LiveViews (11): `overview_live`, `company_live`, `kanban_live`,
  `agent_live`, `inbox_live`, `audit_live`, `goals_live`,
  `skills_live`, `providers_live`, `channel_live`, `task_live`.

New:

- `lib/glorbo_web/components/command_palette.ex` — `⌘K` overlay,
  fuzzy-match over agents/projects/files/goals/skills + recent.
  Backed by existing `/api/search`.
- `lib/glorbo_web/components/keys_overlay.ex` — `?` overlay. Pure
  markup; per-page shortcut tables injected via an assign.
- `lib/glorbo_web/components/confirm_modal.ex` — destructive confirm
  with a typed-word gate. Used by agent SIGKILL, company archive,
  memory wipe, and future destructive actions.
- `lib/glorbo_web/components/kanban_task_drawer.ex` — right-side
  drawer with two modes: `:new` (frontmatter form + body + "on save"
  preview) and `:detail` (editable frontmatter, body, thread,
  approval banner if gated). Composes `task_detail_form` +
  `channel_message` + a comments writer.
- `lib/glorbo/file_specs/task_comments.ex` — new FileSpec kind
  `:task_comments` for `projects/<proj>/tasks/<id>.comments.md`
  (append-only markdown, same header format as channels).
- `assets/js/hooks/keyboard.js` (if not already present) — g-prefix
  state machine + drawer toggle + palette/keys bindings.

### Keyboard bindings

Per the handoff's § Interactions · Shortcuts, plus:

- `` Ctrl+` `` (or `` ⌘` `` on macOS) — toggle chat drawer
  (minimize ↔ expand). Matches VS Code's terminal toggle, which
  is the muscle memory most devs already carry. **Rebindable via
  user pref** stored in `localStorage` under
  `glorbo.kb.drawer_toggle`; the `?` overlay shows the effective
  binding.
- `g`-prefix shortcuts time out at 800ms.
- Any modal consumes all keys and dims the background.

### Data contracts

One new FileSpec kind, nothing else changes:

- **`task_comments`** — one file per task, sibling to the task file:
  `projects/<proj>/tasks/<id>.comments.md`. Append-only markdown
  with the same `## <timestamp> · <author>` header format channels
  use. Authored by both the director (via the comments composer in
  the drawer / task page) and agents (via `glorbo.post_task_comment`
  MCP tool — added in a follow-up to GEP-29, out of scope here; for
  GEP-30 only director-authored comments are writable from the UI).
  Read into the drawer's THREAD section and the task page's THREAD
  section. Never rotates for v1 — tasks close and the file stops
  growing. Rotation (same archive scheme as channels) is a follow-up
  if real usage produces large files.

The task file itself (`projects/<proj>/tasks/<id>.md`) is unchanged
from GEP-25's `task` spec — no frontmatter additions, no body-section
conventions introduced by this GEP.

### Live update routing

Every restyled screen keeps its existing PubSub subscription; no
broadcast topics move. The new drawer subscribes to both
`company:<co>:projects:<proj>:tasks:<id>` (already broadcast by
`Glorbo.Filesystem.Watcher` when the task file changes) and a new
`company:<co>:task_comments:<id>` topic emitted when `<id>.comments.md`
is touched.

## Migration / rollout

Nine phases; each lands behind green `mix test` + `mix credo --strict`
+ `mix precommit` and a browser UAT pass. No cross-phase batching — a
phase commit is a GEP-30 milestone, not a checkpoint. Phases mirror
the handoff's § Implementation order plus the new-task-drawer work.

1. **Tokens.** Merge `design-tokens.css` into `app.css` under
   `/* TUI tokens */`. OKLCH var names kept as aliases where `grep`
   shows ≥5 call-sites; everything else flips to the hex tokens.
   Visual-regression target: pages still render the old look (chrome
   unchanged) — only under-the-surface variable resolution moves.
2. **Chrome.** Topbar, sidebar, statusbar, chat drawer restyled in
   place. Ships together so every LiveView shifts consistently on
   deploy.
3. **CompanyLive.** Validates KPI + roster pattern that repeats.
4. **ChannelLive.** Composer + slash commands + approval cards +
   diff rendering (reused by drawer and task page).
5. **AuditLive.** jsonl-tail pattern (reused by transcript).
6. **KanbanLive / InboxLive / AgentLive.** Focus / keyboard-row-nav
   pattern. **Includes the Kanban task drawer (new + detail modes)
   and the new `task_comments` FileSpec wiring.**
6b. **TaskLive standalone page.** Restyles
   `/companies/:co/tasks/:task_id` with the three-column layout
   from screen §22. Reuses the composer and thread components from
   phases 4 and 6.
7. **GoalsLive / SkillsLive / ProvidersLive.** Reading views.
8. **Edge states.** Empty / loading / 404 / 500. Shared layout wired
   into every LiveView's empty clauses.
9. **Overlays.** `⌘K` palette, `?` overlay, confirm modal. Global
   shortcuts in `assets/js/`.

No data migration is required — the task comments file is lazy-created
on first write; the UI renders an empty THREAD section when absent.

## Failure modes

- **Token drift.** A call-site that references `--glorbo-*-oklch`
  after Phase 1 would break on a deployed v0.1.x. Phase 1 audits with
  `grep -r "oklch" assets/ lib/` and fails the phase if any reference
  survives the alias window.
- **Drawer keyboard collision.** If a future user rebinds the drawer
  toggle to the same chord as a text-input shortcut, the composer
  stops echoing a literal key. Settable via pref UI with "reset to
  default" affordance; handler preventDefault happens only when the
  drawer is blurred.
- **Empty `task_comments` file produced by a rename.** The FileSpec
  validator treats a zero-byte comments file as `valid: empty`, not
  a parse error; the Watcher skips broadcasts for zero-byte files.
- **Palette performance.** Fuzzy-match over a large company
  (thousands of files) may exceed the 16ms frame budget. `⌘K`'s
  backing call is debounced 80ms; `/api/search` already paginates.

## Test strategy

- **Unit:** every new component has a LiveView/ComponentCase render
  test. The `kanban_task_drawer` gets coverage for both modes plus
  the approval-banner branch. `command_palette` has a match-ranking
  unit test.
- **FileSpec:** the `task_comments` kind gets a spec test against
  `test/glorbo/file_specs/` mirroring the channels spec; `mix
  glorbo.validate` covers round-trips.
- **E2E:** Wallaby (browser) test per phase covering the golden path
  of each restyled LiveView. Phase 6 adds a create-task-via-drawer
  flow and an approve-via-drawer flow. Phase 6b covers the standalone
  page composer.
- **Keyboard:** a JS-hook smoke test (Playwright against
  `/companies/acme`) asserts `g o` navigates, `⌘K` opens the palette,
  `?` opens keys, and `` Ctrl+` `` toggles the drawer.
- **Visual-regression:** deferred to a future tooling GEP; for now,
  phase UAT checklist in `docs/testing/uat.md` is the human gate.

## Open questions

None — all initial design questions are resolved in the decision log.

## Decision log

### D1. Merge tokens into `app.css`, don't ship a separate stylesheet

- **Decided:** `.design/design_handoff_glorbo_tui/design-tokens.css`
  is inlined into `assets/css/app.css` under a `/* TUI tokens */`
  heading; we don't ship it as a separate `tokens.css` or as an
  importable Phoenix asset.
- **Alternatives:** separate `tokens.css` imported from `app.css`;
  Phoenix-asset token module; CSS-in-Elixir.
- **Why:** `app.css` is already a single-file-no-build convention;
  adding an import adds a build step for one file.

### D2. Restyle chrome in place — no new topbar/sidebar/statusbar/drawer modules

- **Decided:** Existing `lib/glorbo_web/components/{topbar,sidebar,
  statusbar,chat_drawer}.ex` files are edited in place. No
  parallel "v2" modules, no gradual cutover.
- **Alternatives:** ship `topbar_v2.ex` etc. behind a feature flag
  and swap per-LiveView; deprecate the old modules over two
  releases.
- **Why:** Pre-1.0 — memory rule `feedback_pre_1_0_no_kid_gloves`
  says atomic cuts over soft migrations. Feature-flag chrome is
  expensive state to carry; test surface doubles; every call site
  eventually has to migrate anyway.

### D3. Drawer default: minimized everywhere; expanded only on Company details

- **Decided:** Chat drawer defaults to minimized on every LiveView.
  The one place it renders expanded by default is
  `/companies/:co` → Company details (screen §10). On every other
  page, the user explicitly toggles it.
- **Alternatives:** drawer expanded by default on ChannelLive;
  per-user-preference; last-state-restored.
- **Why:** (OQ1) The drawer is the "quake console" — a peek
  surface, not a workspace. ChannelLive is the full workspace for
  chat. One rule, no per-page branching, no preference state to
  carry.

### D4. Prompt format: IRC/Slack style (`director@uat-demo:#general$`)

- **Decided:** The shell-prompt composer uses IRC/Slack semantics
  for channel identity: `director@uat-demo:#general$ …` (and
  `director@uat-demo:#task-blog-2$ …` on task pages).
- **Alternatives:** filesystem path style
  (`director@uat-demo:~/chat/general$`), plain `>` prompt,
  lowercase-slash-panel style to match the rest of the UI.
- **Why:** (OQ2) `~/chat/general$` misleads users about what `cd`
  would do; this isn't a shell. Channel names are the first-class
  identifier already. The fs-path style is held in reserve for
  404/500 surfaces where we intentionally fake an `ls`.

### D5. Hooks render on Company details page; no `/hooks` route

- **Decided:** Lifecycle hooks (pre-dispatch / post-dispatch /
  on-error / on-approval / nightly) render as a section of the
  Company details view (screen §10). No new `/companies/:co/hooks`
  route.
- **Alternatives:** a dedicated route; a hooks drawer.
- **Why:** (OQ3) Hooks are company configuration. Splitting them
  out adds navigation cost without adding clarity. If hooks grow
  their own editor in a future GEP, promote then.

### D6. Narrow-layout target: 13" laptop, best-effort

- **Decided:** The narrow (640px-wide) layout targets 13" laptops
  and small-window users. Tablets are incidental; phones are out.
  Ship the sidebar-to-top-tab-strip collapse and the 2×2 KPI grid
  from screen §17 as a best-effort; pixel-perfect small-screen UX
  is not a ship blocker.
- **Alternatives:** desktop-only (hard cutoff); full mobile
  responsive including phones.
- **Why:** (OQ4) Glorbo is a Linux/WSL desktop product (GEP-5
  kernel deps). Mobile is architecturally out. 13" laptop and
  half-screen tiling are real UX.

### D7. `/goals` and `/skills` remain standalone routes

- **Decided:** `/companies/:co/goals` and `/companies/:co/skills`
  stay as standalone routes with their own LiveViews.
- **Alternatives:** collapse both into CompanyLive as tabs; collapse
  only one; expose as tabs *and* keep routes.
- **Why:** (OQ5) The handoff shows them as thin pages and raises
  the collapse as a question; collapsing is a user-visible change
  beyond the "restyle" scope of this GEP. If they stay thin after
  real usage, file a follow-up GEP to collapse — pre-1.0 is the
  right time for that, but it's out of scope here.

### D8. Task comments: sibling file, new FileSpec kind

- **Decided:** Task comments live in
  `projects/<proj>/tasks/<id>.comments.md`, append-only markdown,
  one file per task. New FileSpec kind `:task_comments` under
  `lib/glorbo/file_specs/task_comments.ex`. Task file unchanged.
- **Alternatives:** inline the comments as a fenced `## comments`
  block inside the task file; auto-create a `channels/task-<id>.md`
  channel per task.
- **Why:** (OQ6) The handoff's "mirrors channels/task-blog-2.md"
  caption is cosmetic — comments are, conceptually, comments. A
  sibling file keeps `FileSpec(task)` unchanged (GEP-25 contract
  stays stable) and does not create a new channel family the rest
  of the system (Watcher, MCP resources, channel rotation) has to
  learn. One new spec kind, zero changes to existing kinds.

### D9. Drawer toggle: `` Ctrl+` `` (or `` ⌘` ``) default, rebindable

- **Decided:** Default toggle is `` Ctrl+` `` on Linux/WSL and
  `` ⌘` `` on macOS. Rebindable via a single `localStorage` key
  (`glorbo.kb.drawer_toggle`); the `?` overlay shows the effective
  binding, not the default.
- **Alternatives:** bare backtick `` ` `` (Quake console); `` ⌘\ ``
  / `Ctrl+\`; `F12`; `Ctrl+K` (conflicts with palette); hardcoded
  non-rebindable.
- **Why:** (OQ7) Matches VS Code's terminal toggle — muscle memory
  most Glorbo users already carry. Bare backtick would collide with
  markdown inline-code while typing in the composer (the drawer
  would toggle as the user tries to type `` `foo` ``); prefixing
  with `Ctrl` removes the collision. Making it rebindable is cheap
  (one pref) and avoids hard-locking users whose keyboard layouts
  treat `` ` `` as a dead key for diacritics.

### D10. New components: palette, keys, confirm, task drawer

- **Decided:** Four new components ship in this GEP:
  `command_palette`, `keys_overlay`, `confirm_modal`,
  `kanban_task_drawer`. No other new components; everything else
  is an edit to an existing component.
- **Alternatives:** collapse `keys_overlay` into
  `command_palette` (one mega-overlay with a mode); ship the task
  drawer as a KanbanLive inline block rather than a component.
- **Why:** `command_palette` has a backing search and results
  pipeline the keys overlay doesn't; mixing them inflates both.
  The task drawer is reused by the detail mode *and* the new-task
  flow — lifting it to a component makes the two modes share code
  rather than diverge.

### D11. `/companies/:co/tasks/:task_id` restyled (not chrome-only)

- **Decided:** The standalone task page at
  `lib/glorbo_web/live/task_live.ex` is in scope for a full render-
  body restyle per screen §22.
- **Alternatives:** chrome-only update (original handoff text);
  hide the route entirely in favor of the drawer.
- **Why:** The user's follow-up screens (20/21/22) showed the
  standalone page explicitly, indicating it is a supported surface,
  not a legacy route. Removing the route would be a user-breaking
  change beyond this GEP's restyle scope; leaving it chrome-only
  would make task pages feel abandoned next to restyled chrome.

### D12. Drawer-toggle pref storage: `localStorage` only, no UI

- **Decided:** The rebindable drawer toggle is stored in
  `localStorage` under `glorbo.kb.drawer_toggle`. No in-UI editor
  for the value; users rebind via devtools or a future
  preferences page.
- **Alternatives:** ship a `/settings` LiveView in this GEP;
  server-side user prefs persisted to SQLite.
- **Why:** A preferences page is its own GEP-sized surface (schema,
  permissions, sync across tabs). Keeping the pref in
  `localStorage` keeps this GEP a restyle. The pref is power-user
  territory anyway — the default is fine for ≥95% of users.

### D13. Task composer: slash-command subset, not full ChannelLive set

- **Decided:** The task-comment composer supports three slash
  commands: `/assign`, `/approve`, `/pin`. The full ChannelLive
  menu (`/dispatch`, `/skill`, `/diff`) is not exposed in the
  task composer.
- **Alternatives:** full parity with ChannelLive; no slash
  commands at all in the task composer.
- **Why:** The full set is noise in a task-scoped context —
  `/dispatch` and `/skill` live at the company level, not the
  task level. The subset covers the actions a reviewer is
  actually taking on a task. Composer divergence is acceptable;
  both composers share the shell-prompt renderer and the
  slash-menu component — only the menu contents differ.

### D14. No rotation of task-comment files, ever

- **Decided:** `projects/<proj>/tasks/<id>.comments.md` is
  append-only with no rotation policy. Unlike channels (which
  rotate into `channels/archive/…` by size/line thresholds per
  GEP-20), task comment files do not archive.
- **Alternatives:** mirror the channel rotation scheme; rotate
  at a higher threshold (10 MB / 10 000 lines); rotate on task
  closure.
- **Why:** Tasks close and stop growing — the file naturally
  stops accumulating without operator intervention. Rotation
  adds machinery (archive directory, pointer updates, compaction
  cadence) for a usage pattern we don't expect to hit. If a
  future team uses Glorbo for something where comments on a
  single task exceed millions of lines, file a follow-up GEP;
  for the shape Glorbo is designed around (director + agents,
  task lifespan measured in days/weeks), rotation is machinery
  for no benefit.

## Related

- Brief: `.design/design_handoff_glorbo_tui/README.md` + tokens in
  the same directory (checked into the repo).
- GEP-2 — architectural baseline; this GEP respects the LiveView /
  component / PubSub boundaries it lays down.
- GEP-6 — Phoenix LiveView + Channels for the Dashboard. This GEP
  is a restyle on top of GEP-6's infra.
- GEP-11 — Zen of Glorbo. "A terminal phosphor aesthetic" is in
  the Zen; this GEP is its concrete expression.
- GEP-15 — ALLCAPS convention for agent-facing markdown; informs
  role coloring (magenta = human, green = user-prefix, etc).
- GEP-20 — Round 2/3 UX sweep. GEP-30 sharpens and consolidates
  the direction GEP-20 started.
- GEP-25 — on-disk file format specs. GEP-30 adds one new
  `FileSpec` kind (`task_comments`) without modifying existing
  specs.
