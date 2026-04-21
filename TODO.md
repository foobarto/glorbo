# TODO — running punch list

Rolling list of noticed-but-not-yet-shipped items. Updated at the end
of every working cycle.

- **What lives here:** observations, follow-ups, visual polish, small
  UX tweaks, and deferred sub-tasks that don't warrant a GEP.
- **What doesn't:** architectural decisions (→ GEP), shipped work
  (→ CHANGELOG), autonomous-session review notes (→ user.md), OTP /
  filesystem invariants (→ CLAUDE.md or GEP-2).

Format: one bullet per item. Check `[x]` when shipped; delete once
it's been in CHANGELOG for a cycle.

---

## P0 — actively wrong (broken/lying/crashy)

*(empty — knock on wood)*

## P1 — next cycle

- [ ] **TaskScheduler retrofit GEP (Informational).** Part A shipped
  as `053fc84` without a GEP; worth a short Informational GEP
  capturing the design decisions (inbox-write vs Router.route,
  no-state-file, alias table, audit-log-is-truth). Matches the
  decision I recorded in user.md.
- [ ] **Visual "next fire at" indicator on TaskLive** for tasks with
  a `schedule:`. Scheduler has the data — just needs rendering. Pairs
  nicely with the history panel #264 already shows.
- [ ] **Scheduler fire audit needs a PubSub broadcast.** Today the
  `task.scheduled_dispatch` event hits the audit JSONL but TaskLive
  only refreshes on `company:<co>:audit` if the audit log also
  broadcasts. Verify the path end-to-end with a seeded task; if the
  broadcast is missing, add it in AuditLog.append.
- [ ] **Modal ESC close consistency.** Most modals wire `phx-window-
  keydown="<cancel>" phx-key="Escape"`; a couple (verify
  agent file-edit, company.md edit) use click-away only. Make ESC
  universal so keyboard users never lose state.
- [ ] **Scheduler rescan is O(projects × tasks) every 60s.** Fine for
  v0.0.3's single-digit task counts, but watch it past 1000 tasks.
  If it becomes hot, cache mtime like Search.scan_tasks already
  does.

## P2 — nice to have

- [ ] **Modal body `gl-form__row` in narrow viewport.** The 140px
  label column truncates awkwardly under 600px. Two options: (a) let
  labels wrap above the input below some breakpoint, (b) cap label
  width by `ch` instead of `px`. Revisit once the UI gets real
  narrow-screen testing.
- [ ] **Close button `×` hover affordance.** Subtle — nothing
  indicates the glyph is a button. Consider a tiny
  background-on-hover or a box so first-time users see it as
  clickable.
- [ ] **Scheduler aliases list is closed.** `hourly`/`daily`/...
  cover 90% but not `every 5 minutes` or `Mon-Fri 9am`. Can add a
  naive-language parser if users ask — not yet.
- [ ] **Topbar shortcuts truncate on narrow windows.** Current
  behaviour: `g k kanban · …`. Consider collapsing to a single
  "⌨ shortcuts" popover below some breakpoint instead of
  ellipsis.

## P3 — thinking out loud

- [ ] **Global search should include scheduled-task tags.** Right now
  `schedule:` is searchable only via audit (via `task.scheduled_
  dispatch`). A `schedule:daily` query should find all daily tasks.
- [ ] **Visual regression tests.** We'd catch the topbar wrap /
  modal-body-unstyled class of bugs earlier with a
  screenshot-baseline test per LV. Baseline sprint: pick
  agent-browser via CDP (CLAUDE.md pattern) + diff screenshots,
  store baselines in `test/fixtures/ui-baselines/`.

---

## Shipped this cycle (2026-04-21)

- [x] #264 TaskLive history panel + AuditLive ?q= deep-link
- [x] #268 TaskScheduler fires scheduled dispatches
- [x] #269 UI pass: modal __body CSS, topbar overflow, `×` glyph
- [x] CLAUDE.md: agent-browser Bazzite workaround documented
