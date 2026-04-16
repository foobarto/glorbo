---
phase: 4
slug: liveview-dashboard-real-time-channels
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-16
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir built-in) + `Phoenix.LiveViewTest` (LiveView 1.1.28) |
| **Config file** | `test/test_helper.exs`, `mix.exs` `aliases` |
| **Quick run command** | `mix test --stale` |
| **Full suite command** | `mix test --include integration` (includes LiveViewTest integration + Wave-0 fixture-driven) |
| **Estimated runtime** | ~10 seconds (unit), ~60 seconds (with LiveView integration + file-event assertions) |

---

## Sampling Rate

- **After every task commit:** `mix test --stale` (runs only files touched since last green — typical <5 s)
- **After every plan wave:** `mix test --include integration` (full LiveViewTest suite + Watcher inotify integration)
- **Before `/gsd-verify-work`:** Full suite green + gsd-browser UI review
- **Max feedback latency:** 60 seconds full suite

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 4-01-* | 01 (foundation) | 0 | UI-01, UI-02 | — | Watcher extension preserves Phase 3 invariants | unit + integration | `mix test test/glorbo/filesystem/watcher_test.exs test/glorbo_web/actions_test.exs` | ❌ W0 creates | ⬜ pending |
| 4-02-* | 02 (company-scope LVs) | 1 | UI-01, UI-02, UI-03 | — | Director actions resolve to file writes | LiveViewTest | `mix test test/glorbo_web/live/` | ❌ W0 creates | ⬜ pending |
| 4-03-* | 03 (content-scope LVs + chrome) | 1 | UI-01, UI-02, UI-03 | — | Append-only channels; mention triggers wake | LiveViewTest + integration | `mix test test/glorbo_web/live/ test/integration/dashboard_e2e_test.exs` | ❌ W0 creates | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Plan counts and exact task IDs will be finalized by the planner in `/gsd-plan-phase`. Rows above reflect the 3-plan / 2-wave shape from RESEARCH.md §Plan Decomposition.*

---

## Wave 0 Requirements

- [ ] `test/glorbo_web/actions_test.exs` — `GlorboWeb.Actions.post_message/4`, `set_approval/4`, `wake_agent/3` unit tests
- [ ] `test/glorbo/task_definition_write_test.exs` — atomic temp+rename frontmatter mutation
- [ ] `test/glorbo_web/live/live_case.ex` — shared `Phoenix.LiveViewTest` helper + fixture-seed-acme seeded `~/.glorbo/companies/acme/`
- [ ] `test/integration/dashboard_e2e_test.exs` — inotify → PubSub → LiveView propagation (<1s)
- [ ] `test/support/stdout_streamer_fixtures.ex` — a throwaway stdout.log generator for streamer tests
- [ ] `esbuild` Hex dep added to `mix.exs`; `assets/js/app.js` + `assets/css/app.css` seeded; `mix assets.setup` / `mix assets.build` aliases wired; `priv/static/assets/` reachable under `mix release`

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Director loads `http://localhost:4000` and renders 7 views without JS errors | UI-01 | Cross-browser rendering, live stdout tail smoothness, keyboard focus flow — best observed by a human; in autonomous mode substitute `gsd-browser` automation | `mix phx.server` → navigate each of the 8 routes → gsd-browser screenshot each → visual audit via `/gsd-ui-review` |
| Sub-second filesystem-to-dashboard propagation feel | UI-02 | Perceived latency. LiveViewTest asserts the message ordering and PubSub fire but not the wall-clock "feel". gsd-browser can measure `page.waitForSelector` timing. | gsd-browser: write a fixture task, measure time to kanban column repaint; assert <1000 ms |
| Director posts `@agent` in `#general` and sees agent wake visible on AgentLive | UI-03 | End-to-end: chat compose → Router mention → Agent.Server → stdout updates. Involves real bwrap + real CLI adapter. Costs tokens. | Bundle with phase 3 deferred UAT (claude-code round-trip) in a single demo-time validation |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references above
- [ ] No watch-mode flags (no `--watch`)
- [ ] Feedback latency <60 s full suite
- [ ] `nyquist_compliant: true` set in frontmatter after gsd-planner fills the task IDs

**Approval:** pending (planner fills task IDs, then executor marks `nyquist_compliant: true` after Wave 0 lands)
