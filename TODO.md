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
- [x] **Scheduler aliases list is closed.** Shipped `Glorbo.ScheduleNL`
  (#280) — handles `every morning`, `every weekday at 9am`,
  `every 5 minutes`, weekday names, etc.
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
- [x] #274 Round 10: TaskLive stuck-on banner
- [x] #275 Round 11: Kanban filter chip bar (project/goal/who)
- [x] #276 Round 12: Task-ID autolinking in comments
- [x] #277 Round 13: Heartbeat cron validation on agent config save
- [x] #278 Round 14: E2E scheduled-task dispatch test (was partial — lacked live E2E proof)
- [x] #279 Round 15: E2E LoopDetector sentinel emission test (was partial — fs_fun stubbed)
- [x] #280 Round 16: NL schedule parser (was partial — display accepted NL but firing needed cron)
- [x] #281 Round 17: GEP-21 memory reading MVP (read path only; write path is R17b)
- [x] #284 R17b: GEP-21 memory write path (outbox routing + Router classifier + atomic write + MEMORY.md upsert + audit)
- [x] #284 R17b UI: Memory tab on AgentLive detail page
- [x] #285 R17c: E2E memory — real qwen agent reads AND writes memory via live opencode dispatch
- [x] #286 E2E backfill: NL schedule fire + kanban chips navigate + task-ID autolink resolve
- [x] #283 R19a: GEP-23 per-agent network_allow extensions (company-coarsened; per-requester is R19b)
- [x] #288 R20: memory-count sidebar badge (✎ N next to slug when ≥1 memory file)
- [x] #289 R21: unified loop-detector resolution (single LoopDetector.resolve/5 entry; apply_resolution_files/3 honours documented file-drop protocol)
- [x] #290 R22: sidebar memory badge — fa-brain icon + aria-label singular/plural + 3 regex test cases
- [x] #291 R23: R21 audit-row regression fix (nil audit_fun coercion + catch :exit + per-company Registry resolution)
- [x] #292 R24: truthful Inbox header ("N approval · M stuck" / "(empty)") + relative last-failure timestamp on stuck rows
- [x] v0.0.4 shipped — release tagged, GitHub Release live with Burrito binaries
- [x] #294 R25: goal `name:` accepts as title fallback (GoalsLive + CompanyLive); UAT pass on Skills/Costs/Goals/BrainDump clean
- [x] #295 GEP-25 drafted: file format specs + `glorbo validate` + `glorbo fmt` + `kind:` discriminator (k8s-inspired) + atomic cut plan
- [x] #296 R26.1: FileSpec behaviour + 15 per-kind spec modules (company/agent/project/task/heartbeat/soul/memory-index/memory-entry/sentinel-approval/sentinel-stuck/sentinel-resolution/braindump/channel-log/audit-event/inbox-archive — all `/v1`); 28 tests; no writer changes yet
- [x] #298 R27: FileSpec.Validator + `glorbo validate` CLI (read-only; 10 check codes; NDJSON output; verified 27 missing_kind errors against pre-cut r22 workspace)
- [x] #299 R28: TaskMd regex widened (now matches `*.md` under `tasks/` like the real parser) + `skill/v1` FileSpec module + `:non_canonical_task_filename` info finding; 16 kinds total
- [x] #300 R29: Homebrew tap at foobarto/homebrew-tap (`brew install foobarto/tap/glorbo`) + `mix glorbo.release_formula` auto-regen task
- [x] R30.1: macOS build plumbing — Burrito darwin targets + GHA `build-macos` matrix job + `Sandbox.Bwrap.availability/0` probe + formula renders `on_macos do` block
- [x] #302 R30.2: `Glorbo.Sandbox.Unsandboxed.start/2` + Dispatch fallback + per-company once `agent.sandbox_unavailable` audit + Doctor reclassification (linux-only checks → `:info` severity on darwin); macOS binaries now functional in degraded mode
- [ ] After R30.2 ships green: full browser E2E functionality test (new chore from user)
- [ ] #297 R26.2b: atomic `kind:` cut — add `kind:` to every writer + fixture + template; parser enforcement; delete soft-migration readers; ship FileSpec.Formatter + `glorbo fmt` + `mix glorbo.docs.file_formats`; precommit wiring. Estimated 50+ files; best done in a fresh focused session
