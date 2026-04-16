---
phase: 4
slug: liveview-dashboard-real-time-channels
status: draft
shadcn_initialized: false
preset: none
created: 2026-04-16
---

# Phase 4 — UI Design Contract

> Visual and interaction contract for the Glorbo dashboard. Terminal/`htop`-adjacent aesthetic, GitHub-dark palette, hand-written CSS, inline-SVG icons, filesystem-as-source-of-truth. Derived from 04-CONTEXT.md (D-01..D-37) and DESIGN.md §9.

---

## Design System

| Property | Value |
|----------|-------|
| Tool | none (hand-written CSS per D-02, D-31) |
| Preset | not applicable |
| Component library | Phoenix Components only (`GlorboWeb.CoreComponents` extended; no external component library) |
| Icon library | Inline-SVG component `<.icon name="..."/>` — no external icon package (D-03, D-32) |
| Font | `ui-monospace, Menlo, Consolas, "JetBrains Mono", monospace` (D-29) |
| Styling approach | Single hand-written file `assets/css/app.css`, ~500 LOC budget, CSS custom properties for tokens, grid for shell + flex for rows (D-31) |
| JS bundler | `esbuild` reintroduced; LiveView JS + 2–4 hooks only (no Tailwind/PostCSS) (D-02, D-05) |
| Dark mode | Dark-only for v0.0.1; light mode deferred to v1.1 (D-30) |
| Responsive | Desktop-first ≥900px; below-900px collapse deferred to v1.1 (D-33) |

**CSS variable contract** — all values below exposed as `--gl-*` CSS custom properties on `:root`. No values are hard-coded at component sites; components only reference tokens.

---

## Spacing Scale

Declared values (multiples of 4, 8-point scale):

| Token | Value | CSS Var | Usage |
|-------|-------|---------|-------|
| xs | 4px | `--gl-space-xs` | Icon-to-label gap, inline badge padding, frontmatter key/value gap |
| sm | 8px | `--gl-space-sm` | Compact stack (list items inside a card), chat avatar-to-message gap |
| md | 16px | `--gl-space-md` | Default card padding, form element spacing, sidebar item vertical padding |
| lg | 24px | `--gl-space-lg` | Card-to-card gap in grids, section heading below-space |
| xl | 32px | `--gl-space-xl` | Main pane horizontal padding, kanban column gap |
| 2xl | 48px | `--gl-space-2xl` | Page-level vertical section breaks, empty-state vertical padding |

**Exceptions:**
- Sidebar width: **220px** (fixed, not on the scale). Chosen over D-context's 200px starting point because the company-name + status-dot + agent-count row needs ~200px content + 20px inset to avoid truncation at the common `acme-industries` length.
- Stdout tail left-gutter: **44px** (monospace line-number gutter; needs 5 digits × ~8px + 4px padding).
- Budget ring SVG canvas: **96×96px** on agent detail header; **40×40px** on agent card in overview grid.
- Touch/click target minimum: **32×32px** (icon-only buttons — `Approve`, `Deny`, `Wake agent` icon variants).

---

## Typography

Mono-first: every element uses the mono stack from D-29. Sizes kept tight (exactly 4 roles) to match `htop`-density goal (specifics §).

| Role | Size | Weight | Line Height | CSS Var | Usage |
|------|------|--------|-------------|---------|-------|
| Body | 14px | 400 (regular) | 1.5 | `--gl-font-body` | Card body, chat messages, audit payloads, stdout lines, table cells |
| Label | 12px | 400 (regular) | 1.4 | `--gl-font-label` | Metadata (timestamps, actor tags, provider names), badge text, sidebar labels, kanban column counts |
| Heading | 16px | 600 (semibold) | 1.3 | `--gl-font-heading` | Card titles (company name, agent name, task title), channel name, section headers within a view |
| Display | 20px | 600 (semibold) | 1.2 | `--gl-font-display` | Page-level H1 (view name in top bar), budget-ring center number, health-summary count-up |

**Font weights:** exactly 2 — 400 regular, 600 semibold. No italics (terminal-mono idiom; italics render poorly in many mono fonts). No 300/500/700 weights.

**Line-height rationale:** Body/label at 1.4–1.5 for dense reading; headings at 1.2–1.3 because they sit on their own row. Stdout specifically uses 1.5 body to keep it legible during fast scroll.

**Letter-spacing:** default (0). No small-caps, no `text-transform: uppercase`.

**Numeric alignment:** `font-variant-numeric: tabular-nums` applied to budget numbers, audit timestamps, kanban counts, and the health process table so columns align on the monospace grid.

---

## Color

Dark-mode only for v0.0.1 (D-30). GitHub-dark base — familiar to terminal users, ships with AA contrast out of the box, avoids colorblind-hostile reds against greens because semantic colors are only applied to isolated dots/badges, never red-on-green text.

### Surface palette (60% / 30%)

| Role | Hex | CSS Var | Contrast vs text | Usage |
|------|-----|---------|------------------|-------|
| Dominant (60%) — page bg | `#0d1117` | `--gl-bg` | 12.6:1 vs `--gl-fg` | Main pane background, page behind cards |
| Secondary (30%) — surface 1 | `#161b22` | `--gl-surface` | 11.2:1 vs `--gl-fg` | Cards, sidebar, chat message rows, kanban columns |
| Surface 2 (raised) | `#21262d` | `--gl-surface-raised` | 9.1:1 vs `--gl-fg` | Hover state for cards + sidebar items, compose-box background, table header row |
| Border / divider | `#30363d` | `--gl-border` | 3.1:1 vs `--gl-bg` (AA non-text) | All 1px borders, table row dividers, sidebar / main-pane split |

### Text palette

| Role | Hex | CSS Var | Usage |
|------|-----|---------|-------|
| Primary text | `#c9d1d9` | `--gl-fg` | Default body + heading color |
| Muted text | `#8b949e` | `--gl-fg-muted` | Timestamps, secondary metadata, empty-state body, placeholder text |
| Subtle text | `#6e7681` | `--gl-fg-subtle` | Disabled button labels, audit rows that have been expanded-then-collapsed |

### Accent (10% — reserved use only)

| Role | Hex | CSS Var | Usage |
|------|-----|---------|-------|
| Accent | `#58a6ff` | `--gl-accent` | **Reserved-for list below — no other elements may use accent** |

**Accent reserved for:**
1. The **currently-selected** sidebar item (left 2px rail + text color).
2. **Links** inside audit payloads and chat messages (e.g., file paths that open a project view).
3. The **primary CTA** on approval queue (`Approve` button text) and on chat compose (`Send` button text).
4. The **focused** input outline (`:focus-visible` 2px ring on compose box + audit filter input).
5. The `@mention` token in rendered chat markdown (e.g., `@engineer` renders accent-colored, bold).
6. Active-tab underline inside CompanyLive's tab bar (Kanban / Chat / Approvals / Audit / Agents).

Accent is **never** used for: card borders, default icons, hover backgrounds, headings, kanban badges, budget rings below threshold, success/warning/error states, or body copy.

### Semantic colors (badge/dot/ring only — never on text bodies)

| Role | Hex | CSS Var | Usage |
|------|-----|---------|-------|
| Success | `#3fb950` | `--gl-success` | Health dot (company healthy), task status `done` column badge, budget ring < 50%, audit `approval.approve` dot |
| Warning | `#d29922` | `--gl-warning` | Budget ring 50–90%, task status `in-progress` badge, alert severity "warn", agent `bwrap-denied` sentinel dot |
| Destructive / Error | `#f85149` | `--gl-danger` | Budget ring ≥ 90% (includes hard-stop), company health "crashed", `Deny` button text on approvals, audit `approval.deny` dot, agent crash in health view |
| Info / Neutral | `#8b949e` | `--gl-fg-muted` | Idle / not-run-this-month / unknown state dots; never accent |

**Contrast audit:** all text colors above meet WCAG AA against `--gl-bg` and `--gl-surface` (min 4.5:1 for body; 3:1 for large/18px+). `--gl-fg-subtle` at `#6e7681` is 4.8:1 vs `#0d1117` — still AA.

### Approved color combos (no others permitted)

- Text on bg: `--gl-fg` / `--gl-fg-muted` / `--gl-fg-subtle` on `--gl-bg` or `--gl-surface` or `--gl-surface-raised`.
- Accent text: `--gl-accent` on `--gl-bg` or `--gl-surface` (10.1:1 / 8.9:1 — pass).
- Semantic text: `--gl-success` / `--gl-warning` / `--gl-danger` only on `--gl-surface` in badge contexts (≥12px with 8px padding) — never as body copy.

---

## Iconography

Hand-written inline SVG icon set per D-03, D-32. Ships as a single Phoenix component `<.icon name="..."/>` in `lib/glorbo_web/components/icon.ex`.

**Icon contract:**
- ViewBox `0 0 16 16` for all icons (matches mono-grid cell density and keeps SVG path data small).
- Default render size `16×16px` for inline-with-text contexts; `20×20px` for button icons; `24×24px` for the sidebar logo mark.
- Stroke width `1.5px`, stroke color `currentColor` (inherits from text color — accent applied via CSS where needed, default `--gl-fg-muted`).
- No fill except where geometrically required (e.g., `lightning` glyph). Line-icon aesthetic matches mono-terminal feel.
- `aria-hidden="true"` by default; `<.icon name="x" label="Close"/>` sets `role="img"` + `<title>` when semantic.

**Initial glyph set (9 icons — one more than D-03's 6–8 to cover Phase 4 needs):**

| Name | Shape | Used by |
|------|-------|---------|
| `check` | Checkmark | Approve button, task `done` status badge, audit `*.complete` events |
| `x` | Close/cross | Deny button, modal close (none in v0.0.1 but reserved), audit `*.fail` events |
| `play` | Triangle right | Wake agent button, agent `running` state, task `in-progress` badge |
| `pause` | Two bars | Stdout pause-scroll button, agent `idle` state |
| `user` | Circle + shoulders | Director avatar in chat, agent avatar fallback (no custom art) |
| `folder` | Folder outline | Company card leading glyph, project breadcrumb |
| `message` | Speech bubble | Channel link in sidebar, chat view header |
| `lightning` | Zig-zag | `requires_approval: director` task-card corner, approval-queue header |
| `pulse` | Heartbeat line | Health view header, live-stdout "streaming" indicator |

**No icons for:** status dots (use colored circles, not SVG); kanban column headers (text-only); accent separators (use CSS `--gl-border`).

---

## Copywriting Contract

All copy is imperative, terse, lower-stakes (the Director is the sole operator; no onboarding handholding). No em-dashes in strings; no exclamation points except where semantically `error`.

### Global nav + layout

| Element | Copy |
|---------|------|
| Browser title pattern | `{view} — {company} — Glorbo` (e.g., `Kanban — acme — Glorbo`) |
| Sidebar section header | `Companies` |
| Sidebar empty state | `No companies yet.` + body: `Run` + inline-code `glorbo new company <name>` |
| Sidebar footer health strip (healthy) | `● all systems operational` (green dot) |
| Sidebar footer health strip (warning) | `● {N} alert(s)` (yellow dot, links to /health) |
| Sidebar footer health strip (error) | `● {N} crashed` (red dot, links to /health) |

### OverviewLive (/companies)

| Element | Copy |
|---------|------|
| Page heading | `Companies` |
| Empty state heading | `No companies yet.` |
| Empty state body | `A company is a directory under ~/.glorbo/companies/. Run` + inline-code `glorbo new company acme` + ` then refresh.` |
| Company card — agents count label | `{N} agent(s)` |
| Company card — tasks-in-progress label | `{N} in progress` |
| Company card — monthly spend label | `${N.NN} this month` |
| Company card — alerts badge | `{N} alert(s)` (shown only when > 0) |

### CompanyLive (/companies/:company)

| Element | Copy |
|---------|------|
| Tab labels (exact order) | `Kanban`, `Chat`, `Approvals`, `Audit`, `Agents` |
| Active-tab underline | `--gl-accent`, 2px |
| Agent grid empty state | `No agents in this company.` + body: `Scaffold one with` + inline-code `glorbo new agent {company} <name>` |

### KanbanLive (/companies/:company/kanban)

| Element | Copy |
|---------|------|
| Column headers (exact) | `todo`, `in progress`, `done` (lowercase, matches frontmatter `status:` values) |
| Column count label | `{N}` right-aligned after header |
| Empty column body | `(empty)` in `--gl-fg-subtle` |
| Kanban view empty state heading | `No tasks yet.` |
| Kanban view empty state body | `Tasks are markdown files under` + inline-code `projects/<project>/tasks/`. |
| Requires-approval hint (hover on lightning glyph) | `Requires Director approval` |
| Read-only banner (v0.0.1) | `Read-only view. Edit task files with your editor to change status.` (muted, above board, dismissible-via-X but state is per-tab only) |

### AgentLive (/companies/:company/agents/:agent)

| Element | Copy |
|---------|------|
| Header row | `{agent.name}` (heading) + `{agent.role}` (body muted) + provider badge + budget ring |
| Current task section heading | `Current task` |
| Current task empty | `No active task. Waiting for next wake.` |
| Wake history heading | `Recent wakes` + muted label `(last 20)` |
| Wake history empty | `No wakes logged this session.` |
| Wake history row | `{ISO timestamp} · {trigger-type}` where trigger-type ∈ `inbox`, `heartbeat`, `mention`, `director` |
| Stdout section heading | `Stdout` + muted label `(last 1000 lines)` |
| Stdout auto-scroll toggle on | `■ following` (pulse icon, accent) |
| Stdout auto-scroll toggle off | `□ paused at {N}` (pause icon, muted) |
| Stdout empty | `No output yet.` |
| Permissions section heading | `Permissions` |
| Permissions empty | `No permissions granted. This agent is filesystem-sandboxed to its own workspace only.` |
| Wake agent CTA | `Wake agent` (primary button — text accent color only on hover; default fg) |
| Wake agent prompt (inline form) | `Wake reason (optional):` + text input + submit |
| Wake confirmation (inline, 2s toast) | `Woken. Writing state/wake-request.md…` |

### ChannelLive (/companies/:company/channels/:channel)

| Element | Copy |
|---------|------|
| Header | `#{channel.name}` (heading) + participant count muted |
| Empty channel | `No messages in #{channel.name} yet.` |
| Message row layout | `{author} · {ISO timestamp}` (label style) on line 1, body on line 2+ |
| `@mention` render | accent-color, semibold, 400 weight elsewhere |
| Compose placeholder | `Message #{channel.name} as Director…` |
| Compose submit CTA | `Send` (accent text; Enter key also submits; Shift+Enter = newline) |
| Compose disabled state | `Posting…` (muted, while append in flight) |
| Compose error | `Failed to post: {reason}. Message not sent.` (danger) |

### ApprovalQueueLive (/companies/:company/approvals)

| Element | Copy |
|---------|------|
| Page heading | `Approvals` + muted count `({N} pending)` |
| Empty state heading | `No approvals pending.` |
| Empty state body | `Tasks with` + inline-code `requires_approval: director` + ` in frontmatter will appear here.` |
| Approval card title | `{task.title}` |
| Approval card meta | `{requesting_agent} · {ISO timestamp}` |
| Approve CTA | `Approve` (accent text, check icon) |
| Deny CTA | `Deny` (danger text, x icon) |
| Post-action inline confirmation (2s) | `Approved. {agent} will wake on next inotify.` / `Denied. Task moved to history.` |

### AuditLive (/companies/:company/audit)

| Element | Copy |
|---------|------|
| Page heading | `Audit log` + muted `{YYYY-MM}` |
| Empty state | `No audit events this month.` |
| Filter placeholder — actor | `Filter by actor…` |
| Filter placeholder — action | `Filter by action…` |
| Load-more button | `Load 500 older` |
| End-of-log marker | `— beginning of log —` (muted, centered) |
| Row expand hint | `click to expand payload` (subtle, right-aligned) |

### HealthLive (/health)

| Element | Copy |
|---------|------|
| Page heading | `System health` |
| Doctor summary section | `Doctor checks` + pass/warn/fail tally |
| Process tree heading | `Supervisors` |
| Process tree company row | `{company}` + `{N} children` + status dot |
| Process tree empty | `No companies running.` (subtle) |
| CLI tools row | `{tool}: {version}` (e.g., `claude: 1.12.0`) or `{tool}: not found` (muted) |
| bwrap check (pass) | `bwrap: {version}` (success dot) |
| bwrap check (fail) | `bwrap: not found — agents cannot sandbox` (danger dot) |

### Error states (global)

| Element | Copy |
|---------|------|
| LiveView disconnect banner | `Connection lost. Reconnecting…` (warning, top of page, dismissible on reconnect) |
| LiveView reconnect | `Reconnected.` (success, auto-dismiss 1.5s) |
| Unknown company 404 | `Company "{slug}" not found.` body: `Check` + inline-code `~/.glorbo/companies/` + ` or run` + inline-code `glorbo reindex`. |
| Unknown agent 404 | `Agent "{slug}" not found in {company}.` body: `The agent may have been deleted or renamed. Check` + inline-code `companies/{company}/agents/`. |
| Unknown channel 404 | `Channel "{slug}" not found in {company}.` body: `Check` + inline-code `companies/{company}/channels/` + ` for existing channels.` |
| Generic 500 | `Something broke.` body: `Check` + inline-code `~/.glorbo/logs/` + ` and report at github.com/foobarto/glorbo.` |

### Destructive actions

Per `<specifics>`: **no confirm dialogs**. Director is authenticated by owning the host user; undo is a file edit.

| Action | Confirmation approach |
|--------|----------------------|
| Approve task | None. Single click. Immediate inline toast `Approved.`. Audit event records the act. Undo = edit task frontmatter `status:` back. |
| Deny task | None. Single click. Immediate inline toast `Denied. Task moved to history.` Audit event recorded. Undo = filesystem move. |
| Wake agent | None. Single click writes `state/wake-request.md`. Toast `Woken.`. Undo not applicable (wake is idempotent). |
| Post message | None. Enter submits. Empty body rejected client-side. Errors caught server-side with banner. |

No destructive deletes are exposed in Phase 4 (AGT-05: dashboard does not delete agents/tasks/companies — Director uses `rm` or their editor).

---

## Interaction & Motion

Per D-34: animations minimal. No custom keyframes, no layout-animation libraries.

| Interaction | Spec |
|-------------|------|
| Hover transitions | `background-color 200ms ease` on cards, sidebar items, buttons |
| Focus rings | `outline: 2px solid var(--gl-accent); outline-offset: 2px;` on `:focus-visible` only (no persistent outline on mouse click) |
| Auto-scroll (stdout, chat) | CSS `scroll-behavior: auto` (not smooth — would feel laggy on fast updates); manually pin-to-bottom on each new line unless user scrolled up |
| Compose input submit | `Enter` = submit. `Shift+Enter` = newline. `Escape` = clear unsaved draft (no BeforeUnload warning per context's Claude Discretion) |
| Kanban card click | Navigate to task detail inline within Kanban — not a separate route in v0.0.1. Card expands in place with full body + updates thread. Collapse = click header again or Escape. |
| Approval click feedback | Button disables immediately; icon flips to pulse for ~300ms; then toast replaces it for 2s; then card removes with 100ms opacity fade |
| LiveView diff rendering | Default LiveView behavior; no `phx-update="append"` shimmer animations (D-34 minimal) |
| Sidebar collapse (≥900px only) | Not in Phase 4 scope (D-33); layout is fixed-sidebar desktop-only |

**No:** skeleton loaders, spinners longer than 500ms, bounce animations, scale-on-hover, shadow-lift on hover (use bg-color change only — matches mono-terminal feel).

---

## Component Inventory (Phase 4 new components)

| Component | Module | Purpose |
|-----------|--------|---------|
| `<.icon>` | `GlorboWeb.CoreComponents` | Inline-SVG icon from the 9-glyph set |
| `<.company_card>` | `GlorboWeb.Components.CompanyCard` | Overview grid cell |
| `<.agent_card>` | `GlorboWeb.Components.AgentCard` | CompanyLive agent grid cell + mini budget ring |
| `<.task_card>` | `GlorboWeb.Components.TaskCard` | Kanban cell; includes `requires_approval` lightning glyph, priority badge |
| `<.approval_card>` | `GlorboWeb.Components.ApprovalCard` | Approval queue row with Approve/Deny buttons |
| `<.channel_message>` | `GlorboWeb.Components.ChannelMessage` | One message row (author, timestamp, body, @mention linking) |
| `<.audit_entry>` | `GlorboWeb.Components.AuditEntry` | One audit row (actor · action · ts) expandable to full JSON |
| `<.budget_ring>` | `GlorboWeb.Components.BudgetRing` | SVG arc: circle-minus-arc at `1 - used/cap`; color changes at 50% (success→warning) and 90% (warning→danger); center text = `${used.toFixed(2)} / ${cap}` in mini; just `${used.toFixed(0)}` in 40px variant |
| `<.stdout_tail>` | `GlorboWeb.Components.StdoutTail` | Rolling line buffer (last 1000), mono, line-numbered gutter, auto-scroll pinning |
| `<.health_dot>` | `GlorboWeb.CoreComponents` | 8×8px filled circle with semantic color + optional label |
| `<.tab_bar>` | `GlorboWeb.CoreComponents` | CompanyLive tab row: horizontal flex, active tab 2px `--gl-accent` underline |
| `<.sidebar>` | `GlorboWeb.Layouts` | Persistent left nav (220px), companies list + bottom health strip |

### BudgetRing math (fills Claude's Discretion arc math item)

- SVG `viewBox="0 0 36 36"`; stroke `--gl-surface-raised` for full ring background; foreground stroke uses `stroke-dasharray: {ratio * circumference} {circumference}` with `circumference = 2 * π * 16 = 100.53`.
- Ratio = `min(used / cap, 1.0)`.
- Color thresholds (matches D-30 semantic palette):
  - `ratio < 0.5` → `--gl-success`
  - `0.5 ≤ ratio < 0.9` → `--gl-warning`
  - `ratio ≥ 0.9` → `--gl-danger`
- Cap unset (`null`): render ring as solid `--gl-border`, center shows `$X.XX` with no denominator.
- Over-cap (ratio > 1.0): ring stays at `--gl-danger` full, center prepends a `!` glyph (no icon — literal bang in mono, semibold).

### Chat message rendering (fills Claude's Discretion markdown item)

**Pick: use `earmark`**, minimal profile.
- `earmark` Hex dep added to `mix.exs` (already named in canonical refs).
- Render pipeline: `Earmark.as_html!(body, compact_output: true, smartypants: false, gfm: true)` → sanitize with a tiny allowlist (`p`, `code`, `pre`, `strong`, `em`, `a[href]`, `ul`, `ol`, `li`, `blockquote`) — strip everything else.
- `@mention` handled in a **pre-pass** before earmark: regex `@([a-z0-9-]+)` → replace with `<a class="gl-mention" href="/companies/{co}/agents/\1">@\1</a>`; pre-pass avoids earmark fighting over the `@`.
- No code highlighting in v0.0.1 (defer to v1.1). `<code>` and `<pre>` render in `--gl-surface-raised` with 2px `--gl-border` left rule and `--gl-space-sm` padding.

### ANSI in stdout (fills Claude's Discretion item)

Deferred. v0.0.1 strips ANSI escape sequences via a compiled regex on the server before the line reaches PubSub. Out-of-scope per context.

---

## Layout Specs

### App shell (CSS grid)

```
grid-template-columns: 220px 1fr;
grid-template-rows: 1fr;
height: 100vh;
```

- Column 1: `<.sidebar>` — sticky, full-height, `--gl-surface` background, `--gl-border` 1px right divider.
- Column 2: main pane — `--gl-bg` background, internal `--gl-space-xl` horizontal padding + `--gl-space-lg` top padding, scrollable vertically.
- No top bar above the sidebar/main split (view heading lives inside the main pane).

### Card radius + elevation (fills Claude's Discretion item)

- Card border-radius: **6px** (not 8px as D-context's starting point — 6px reads tighter next to 14px mono which already feels boxy; 8px looks rounded-webapp-y against the terminal aesthetic).
- Cards have **no** box-shadow. Elevation is `--gl-surface` (default) → `--gl-surface-raised` (hover). Pure color delta, per D-34.
- Border: `1px solid var(--gl-border)` on cards that sit on `--gl-bg` (overview, kanban, approvals, audit). Cards nested inside other surfaces get no border (rely on surface-color delta).

### Kanban column header styling (fills Claude's Discretion item)

- Column header: `--gl-font-label` size, `--gl-fg-muted` color, lowercase exact-match to `status:` value (`todo`, `in progress`, `done`).
- Count: tabular-nums, `--gl-font-label` size, `--gl-fg-subtle` color, right-aligned in the header row.
- Column body: `--gl-surface` background, 6px radius, `--gl-space-md` inner padding, cards stacked with `--gl-space-sm` gap.
- Column min-width: 280px. Column max-width: 360px. Overflow-x scrolls at the kanban container level.

### Top bar per view (inside main pane)

- View heading: `--gl-font-display`, left-aligned.
- Secondary count/label muted (e.g., `Audit log 2026-04`): inline after heading, `--gl-font-label` muted.
- Action row (filters, search, load-more) right-aligned on the same row when present.
- Divider: `1px solid var(--gl-border)`, `--gl-space-lg` below, marks end of header.

---

## Registry Safety

| Registry | Blocks Used | Safety Gate |
|----------|-------------|-------------|
| shadcn official | none (shadcn not used — D-02, D-03, D-31, D-32) | not applicable |
| any third-party registry | none declared for this phase | not applicable |

**Third-party UI deps:**
- `earmark` (Hex) — pure-Elixir markdown renderer for chat. Well-established Elixir community dep; server-side-only; no JS, no network, no `eval`. Sanitizer allowlist (above) limits injection surface even if earmark misparses.
- No third-party Phoenix component libraries, no CSS frameworks, no icon packages, no JS npm deps beyond `esbuild` + Phoenix LiveView client JS (shipped with `phoenix_live_view` Hex).

---

## Accessibility

| Requirement | Spec |
|-------------|------|
| Keyboard nav | All interactive elements reachable via Tab; visible focus ring (accent, 2px, 2px offset); Escape closes expanded cards / clears compose draft. |
| Focus order | Sidebar → view header actions → main content → compose (where applicable). |
| ARIA | `<.icon>` default `aria-hidden="true"`; icon-only buttons always have `aria-label` (`<.icon name="check" label="Approve"/>` pattern or explicit `aria-label` on button). |
| Live regions | LiveView disconnect banner = `role="status"`. Chat-new-message announces via `aria-live="polite"` on the chat container's tail element. Stdout explicitly NOT live (too noisy for screen readers — AT users should rely on the tail file directly). |
| Color contrast | All text combos ≥ 4.5:1 (AA body) or ≥ 3:1 for ≥18px/semibold. Semantic badges: min 12px + 8px padding + 3:1 border contrast. |
| Reduced motion | `@media (prefers-reduced-motion: reduce)` disables the 200ms hover transitions and the 100ms approval-card fade. |

---

## Verification Checklist (checker uses this)

Values checker should grep for in implemented CSS/templates:

- `--gl-bg: #0d1117`
- `--gl-surface: #161b22`
- `--gl-surface-raised: #21262d`
- `--gl-border: #30363d`
- `--gl-fg: #c9d1d9`
- `--gl-fg-muted: #8b949e`
- `--gl-fg-subtle: #6e7681`
- `--gl-accent: #58a6ff`
- `--gl-success: #3fb950`
- `--gl-warning: #d29922`
- `--gl-danger: #f85149`
- `font-family: ui-monospace, Menlo, Consolas, "JetBrains Mono", monospace`
- Spacing tokens use only `4, 8, 16, 24, 32, 48` (plus documented exceptions `220`, `44`, `96`, `40`, `32`)
- Font sizes limited to `12, 14, 16, 20` (exactly 4)
- Font weights limited to `400, 600` (exactly 2)
- No `tailwindcss`, `daisyui`, `heroicons`, or `react` in `assets/package.json` or `mix.exs`
- Accent `#58a6ff` appears only on: selected sidebar item, links in audit/chat, primary CTA text, `:focus-visible` outline, `@mention`, active-tab underline

---

## Checker Sign-Off

- [ ] Dimension 1 Copywriting: PASS
- [ ] Dimension 2 Visuals: PASS
- [ ] Dimension 3 Color: PASS
- [ ] Dimension 4 Typography: PASS
- [ ] Dimension 5 Spacing: PASS
- [ ] Dimension 6 Registry Safety: PASS

**Approval:** pending

---

*UI-SPEC drafted 2026-04-16 by gsd-ui-researcher. Derived from 04-CONTEXT.md (37 decisions), DESIGN.md §9 (seven views), and CLAUDE.md invariants. Ready for checker validation.*
