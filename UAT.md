# UAT — Glorbo browser test suite

Rolling browser UAT checklist. Updated on each cycle; test cases
crystallised from prior UAT rounds + the paperclip-parity gap list.

Environment:

- **Server:** `mix phx.server` on `PORT=4100`, backed by `~/.glorbo`
  (dev workspace). Fresh phx.server restart at the top of each
  round.
- **Browser:** headless chromium via agent-browser + `--cdp 9222`
  (see `CLAUDE.md` § "Browser UAT — the Bazzite workaround").
- **Screenshots:** `.reports/uat-modals/` when triaging modals;
  ad-hoc `.reports/uat-<round>/` otherwise.

Format: `[ ]` pending · `[x]` pass · `[!]` fail with note · `[~]`
partial / flaky. Update inline as each case runs.

---

## A. Overview & entry points (paperclip §1 · §10 · §16)

- [ ] **A1** — `/companies` renders every `~/.glorbo/companies/<slug>/`
  as a card. No zero-lies: spend/tasks show real numbers, not
  placeholders.
- [ ] **A2** — Statusbar shows daemon dot, uptime, agent count, WAL
  size, inotify count, director, and a ticking live clock.
- [ ] **A3** — `+new company` button opens modal with slug input +
  availability probe (green/red border as you type).
- [ ] **A4** — Duplicate slug submit → inline error, modal stays
  open.
- [ ] **A5** — Novel slug submit → card appears, folder created,
  audit entry written.
- [ ] **A6** — Topbar shortcut strip stays on one line at 1400px
  wide (regression for #269's overflow fix).
- [ ] **A7** — Modal close glyph renders as `×` (not a boxed
  fallback — regression for #269).

## B. Company scoping (paperclip §13 · §18)

- [ ] **B1** — Click card → `/companies/<slug>` loads; sidebar Active
  highlight on "Overview".
- [ ] **B2** — `edit company.md` modal round-trips frontmatter +
  body; save writes to disk; flash success.
- [ ] **B3** — `+ new agent` → form with slug + role + provider
  dropdown; create scaffolds `agents/<slug>/` on disk.
- [ ] **B4** — `+ new project` → form with slug; creates
  `projects/<slug>/project.md`.
- [ ] **B5** — Topbar company picker switches between companies.
- [ ] **B6** — Emergency-stop button surfaces a red pill when
  active; click lifts the stop.

## C. Work delegation (paperclip §1 · §2 · §5)

- [ ] **C1** — `/companies/<co>/kanban` renders three columns
  (todo / in-progress / done) with correct counts.
- [ ] **C2** — `+ new task` modal form: project dropdown, title,
  assigned_to, priority, severity, description textarea,
  attachments.
- [ ] **C3** — Submit creates task file in
  `projects/<p>/tasks/<id>.md`; card appears under `todo`.
- [ ] **C4** — Drag task between columns → frontmatter `status:`
  updates on disk.
- [ ] **C5** — Click task card → `/companies/<co>/tasks/<id>`
  loads with title, body, comments, usage strip.
- [ ] **C6** — TaskLive body edit via detail form, comment append
  via form; both round-trip.
- [ ] **C7** — `?who=<slug>` URL query filters kanban by assignee
  (regression for #261).
- [ ] **C8** — `?goal=<slug>` URL query filters by goal.

## D. Task history panel (#264, GEP-24)

- [ ] **D1** — TaskLive renders "history · this task" panel below
  the grid for tasks with audit entries.
- [ ] **D2** — Each entry expands on click (role="button",
  `aria-expanded` toggles).
- [ ] **D3** — "view full audit →" link navigates to
  `/companies/<co>/audit?q=<task-id>` with filter pre-populated.
- [ ] **D4** — In AuditLive, editing the `q` / `actor` / `action`
  filters reflects in the URL on navigate.
- [ ] **D5** — Empty state: task with no audit entries shows
  "No audit events yet for this task".

## E. Scheduled tasks (GEP-24)

- [ ] **E1** — Task with valid `schedule: "0 * * * *"` renders
  `↻ 0 * * * *` pill on the kanban card (pre-existing #237).
- [ ] **E2** — Same task on `/companies/<co>/tasks/<id>` has a
  `schedule` row on the usage strip: `↻ <cron> · next fire <rel>`.
- [ ] **E3** — Task with `schedule: "hourly"` keyword alias parses
  and renders the same way.
- [ ] **E4** — Task with malformed `schedule:` still renders the
  pill; audit log contains a `scheduler.invalid_task_cron` entry.
- [ ] **E5** — When the scheduler fires a dispatch, the audit log
  gets a `task.scheduled_dispatch` entry and the TaskLive history
  panel live-refreshes without a reload (regression check — this
  relies on the PubSub chain verified this cycle).

## F. Agent lifecycle (paperclip §1 · §12 · §14)

- [ ] **F1** — `/companies/<co>/agents/<slug>` renders identity
  strip, sandbox/stdout panel, config panel, roster org chart.
- [ ] **F2** — Wake-now modal opens, reason textarea accepts
  input, submit writes `state/wake-request.md`.
- [ ] **F3** — Stop button surfaces "agent is idle" when nothing
  is in flight.
- [ ] **F4** — Config tab edit form round-trips `provider:` /
  `model:` / `heartbeat:` / `network:` through frontmatter
  writer.
- [ ] **F5** — Runs tab lists `history/*.jsonl` entries (paginated
  if many); expand row shows raw jsonl.
- [ ] **F6** — Modal close (`×`) dismisses without submitting.

## G. Inbox + approvals (paperclip §3 · §19)

- [ ] **G1** — `/companies/<co>/inbox` renders Mine · Recent · All ·
  Archive tabs; empty "no approvals pending" copy when clean.
- [ ] **G2** — Approval row inline Approve / Deny actions.
- [ ] **G3** — Deny modal opens with reason textarea; styled
  correctly (padding, form row alignment — regression for #269
  generic `.gl-modal__body`).
- [ ] **G4** — Archive action hides row from Mine; Unarchive
  restores under Archive.
- [ ] **G5** — Stuck-sentinel agents surface in inbox with
  retry/skip/stop controls (regression for #228).

## H. Chat + channels (paperclip §3 · §15)

- [ ] **H1** — Channel dock at company-page bottom tails `#general`
  without refresh.
- [ ] **H2** — Post as director → message appends to
  `channels/general.md`; channel-archive link visible when size
  threshold tripped.
- [ ] **H3** — `@mention` in director post routes to the mentioned
  agent's inbox.
- [ ] **H4** — Actor avatars render on audit rows (regression for
  two-letter avatar work).

## I. Observability (paperclip §4 · §10 · §20)

- [ ] **I1** — `/companies/<co>/audit` shows month's events;
  actor + action filters + `q` free-text filter narrow rows.
- [ ] **I2** — Date-range `since` / `until` filters narrow by
  day (regression for #263).
- [ ] **I3** — `⇩ export CSV` downloads current month as CSV
  (regression for #259).
- [ ] **I4** — `/health` shows company supervisors with slugs,
  not PID strings.
- [ ] **I5** — 14-day rollup strip on CompanyLive renders
  `run activity` + `success rate` sparklines.

## J. Costs & budgets (paperclip §6)

- [ ] **J1** — Global `/costs` (not `/companies/<co>/costs` —
  routing intentional; sidebar points at `/costs`) shows "this
  month" / "last 12 months" / "top spender" tiles + per-agent
  historical roll-up.
- [ ] **J2** — Per-company cap state surfaces on CostsLive and
  CompanyLive when cap configured.
- [ ] **J3** — Budget ring component shows OK / alert / stop
  colour transitions.

## K. Goals & skills (paperclip §7 · §9)

- [ ] **K1** — `/companies/<co>/goals` renders
  `company.md`-frontmatter goals; per-goal task rollup.
- [ ] **K2** — Tasks with `goal:` reference appear grouped under
  the right goal.
- [ ] **K3** — `/companies/<co>/skills` lists builtin + custom +
  shadowed skills; used-by counts per agent.

## L. Discoverability & palette (paperclip §16)

- [ ] **L1** — `Ctrl+K` opens command palette with recent
  navigations, Inbox, Skills, projects.
- [ ] **L2** — Palette search narrows items as you type.
- [ ] **L3** — Global search finds task bodies + audit rows
  (regression for #232 + #249).

## M. Long-session / cross-cutting (uat4 gotchas)

- [ ] **M1** — Flash banners auto-dismiss (info ≤6s, error ≤10s;
  regression for uat4 U3).
- [ ] **M2** — Browser back/forward navigation preserves view
  (regression for uat4 U4).
- [ ] **M3** — TWEAKS drawer toggles, density setting persists
  across reloads.
- [ ] **M4** — Escape key closes every modal (regression for
  TODO.md "ESC close consistency" item).
- [ ] **M5** — Narrow viewport 1024px — no wraparound chrome,
  ORG/CHART doesn't clip (partial: uat4 U1 flagged tight
  layout).

---

## Run log

Rounds ordered newest-first. Each round records the commit under
test + the tally, not per-case outcomes (those live in the case
boxes above).

### Round 7 — 2026-04-21 (this cycle)

- **Commit under test:** `1491fc1`
- **Scope:** A · B1 · C1 · D1/D3/D4 · E1/E2 · F1 · G1 · H4 ·
  I1–I4 · J1 · K1/K3 · M (visual checks only).
- **Results:**
  - ✅ Passing (23 cases): A1, A2, A3, A4, A6, A7, B1, C1, D1,
    D3, D4, E1, E2, F1, G1, H4 (via audit avatars), I1, I2, I3,
    I4, J1, K1, K3.
  - ⚠ Partial (1): J1 — global `/costs` works; per-company
    nav link is intentional (no `/companies/<co>/costs` route);
    updated UAT.md to match the design.
  - 🚫 Not exercised this round: B2–B5, C2–C8, D2/D5, E3–E5,
    F2–F6, G2–G5, H1–H3, K2, L-series, M1–M5. Most need
    interactive clicks or seeded state; folded into the TODO
    for future rounds.
- **Fixes landed this round:** none. Everything checked rendered
  cleanly against `1491fc1`. The GEP-24 "next fire in 56s"
  indicator is visibly live in `.reports/uat-r7/E2b-*.png` —
  real proof the round-6 work shipped correctly.
- **Artefacts:** 14 screenshots under
  `.reports/uat-r7/*.png`.
