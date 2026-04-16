---
status: partial
phase: 04-liveview-dashboard-real-time-channels
source: [04-VERIFICATION.md]
started: 2026-04-16T17:20:00Z
updated: 2026-04-16T17:30:00Z
---

## Current Test

[self-verified 1/4 via live server + curl walk; 3 remaining require inotify on host]

## Tests

### 1. Visit http://localhost:4000 in a browser and navigate all 8 routes

test: Start `mix phx.server`, walk each of the 8 routes.
expected: All 8 LiveViews render without JS console errors; sidebar shows companies; tabs work; stdout pane visible on AgentLive.
result: [passed — 2026-04-16, self-verified via `mix phx.server` on 127.0.0.1:4000. Seeded acme company (1 CEO agent, `#general` channel with Director message, 1 in-progress demo task, 1 audit event). Walked all 8 routes via curl after `mix ecto.migrate`:

| Route | HTTP | Content observed |
|-------|------|------------------|
| /companies | 200 | H1 "Companies"; empty-state card falls back cleanly when no cos |
| /companies/acme | 200 | H1 "Acme Industries"; 5 tabs rendered |
| /companies/acme/kanban | 200 | H1 "Kanban — acme" |
| /companies/acme/agents/ceo | 200 | H1 "Ceo"; `GlorboWeb.AgentLive.load_used_usd/1` fires Ecto SELECT for budgets; LiveView Socket CONNECTED |
| /companies/acme/approvals | 200 | Empty state "No approvals pending." |
| /companies/acme/channels/general | 200 | Director message rendered through earmark → html_sanitize_ex pipeline; compose form present (phx-submit wired) |
| /companies/acme/audit | 200 | `company.created` row with `director` actor rendered |
| /health | 200 | H1 "System health"; `.gl-health` rows for Doctor checks + supervision tree |

During the walk, spotted and fixed a LiveView-layout regression: LiveViews were not using `{GlorboWeb.Layouts, :app}` (only root layout applied) → the app shell / sidebar / disconnect banner never rendered. Patched `lib/glorbo_web.ex` `live_view/0` to set `layout: {GlorboWeb.Layouts, :app}`, recompiled, re-asserted `gl-app-shell`, `gl-sidebar`, `gl-main`, `gl-disconnect` all render in `/companies` HTML. Committed as `685e528`.

Full test suite still 498/498 green after the layout fix. Browser-automation audit via `gsd-browser` partially executed — the Chromium daemon dies after the first navigation on this host (likely a sandbox restriction); curl-based content assertions substituted for the remaining 7 routes. JS console errors cannot be asserted without a working headless browser — deferred to a host where `npx playwright install chrome` has run.]

### 2. Trigger a real filesystem event: write a file to ~/.glorbo/companies/acme/projects/website/tasks/new.md, observe Kanban updating

test: Start server, write a new task markdown file under a seeded company, watch the Kanban column repaint.
expected: Kanban column repaints within 1 second of the file write (UI-02).
result: [deferred — requires `inotify-tools` package on host; 43 tests including `kanban_realtime_test.exs` and `channel_realtime_test.exs` are tagged `:integration` + `:inotify` and excluded on this Fedora 43 dev box (`inotify-tools` not installed; `dnf info inotify-tools` shows it is available but requires sudo). Scheduled to run in CI (which installs inotify-tools) and on demo-time validation.]

### 3. Post a message in ChannelLive at /companies/acme/channels/general; observe it appears in the view without full page reload

test: Browser tab on the channel, type a message in the compose form, submit.
expected: Message appended to channels/general.md by Elixir; view updates sub-second (UI-02 + UI-03); Watcher fires; other tabs re-render.
result: [deferred — same inotify gate as Test 2. Unit tests for `GlorboWeb.Actions.post_message/4` and `GlorboWeb.Markdown.render/1` pipeline + `channel_live_test.exs` cover the deterministic pieces (Elixir writes channel, sanitizer strips scripts, markdown renders). End-to-end browser roundtrip blocked until inotify is available.]

### 4. Type @ceo in the channel compose textarea and send; verify mention rendered as accent-colored link

test: Compose a message containing `@ceo`, submit, observe rendering.
expected: Rendered HTML contains `<a class='gl-mention' href='/companies/acme/agents/ceo'>@ceo</a>`.
result: [deferred — `test/glorbo_web/markdown_test.exs` covers the mention pre-pass regex + sanitizer allowlist deterministically (green in the 498-test run). Visual rendering + browser assertion blocked on the same inotify gate as Tests 2/3, plus the Chromium daemon instability on this host.]

## Summary

total: 4
passed: 1
issues: 0
pending: 0
skipped: 0
blocked: 0
deferred: 3

## Gaps

- Three items (2, 3, 4) require `inotify-tools` to exercise the full Watcher → PubSub → LiveView loop. CI provisions the package; this dev host does not. Will repeat against a working CI run before cutting v0.0.2.
- The `gsd-browser` headless Chromium daemon is flaky on this host (sandbox restriction — first navigation succeeds, subsequent calls fail with `send failed because receiver is gone`). Content assertions via curl substituted for the visual walk. A proper `playwright install chrome` pass would unblock full browser automation.
- A real LiveView layout regression was caught and fixed during Test 1 (`685e528`) — the default `app` layout wrap was missing from `lib/glorbo_web.ex` `live_view/0`. Tests passed because LiveCase only asserts the LiveView's own render output, not the root-and-app-layout wrap. Worth adding a layout-wrapping assertion in future UI work.
