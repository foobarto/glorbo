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

- [x] **TaskScheduler retrofit GEP (Informational).** Shipped as
  `GEP-0024` with 7-entry decision log; bidirectional links added
  to GEP-2 + GEP-3.
- [x] **Visual "next fire at" indicator on TaskLive** — shipped
  on the usage strip with relative formatter (s / m / h m / d →
  ISO for far-future).
- [x] **Scheduler fire audit PubSub broadcast** — verified:
  `AuditLog.append/2` always broadcasts `{:audit_append,
  record}` on `company:<co>:audit`, and TaskScheduler routes
  through it via `audit_via_registry/2`. End-to-end chain
  intact; TaskLive history panel refreshes live.
- [x] **Modal ESC close consistency.** Fixed this cycle — every
  `.gl-modal` now wires `phx-window-keydown=<cancel> phx-key=Escape`;
  the ApprovalQueueLive deny modal was the only holdout.
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
- [x] **Close button `×` hover affordance.** Fixed in round 9 —
  hover shows a raised-surface background + border; focus-visible
  adds a 2px accent outline.
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
- [x] GEP-24 retrofit + TaskLive next-fire indicator (#270)
- [x] UAT Round 7 — 23 cases green via browser (UAT.md)
- [x] #271 Fix `glorbo up` crash on hosts without EPMD daemon
- [x] #272 UAT Round 8 — interactive (C2/C3/C6, D2/D5, G1–G3, M4) + 3 ships
- [x] Fix sidebar Approvals badge/list parity bug (UAT finding)
- [x] Audit log relative timestamps ("7 min ago" + title tooltip)
- [x] ESC key closes every modal
- [x] #273 UAT Round 9 — E3/E4/L1/L2/L3 green + 2 ships
- [x] Fix scheduler.invalid_task_cron audit flood (UAT finding)
- [x] Modal close-button hover affordance
