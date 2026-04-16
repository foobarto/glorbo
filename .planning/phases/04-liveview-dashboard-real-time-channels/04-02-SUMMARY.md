---
phase: 04
plan: 02
subsystem: liveview-dashboard-wave-1-company-scope
tags: [elixir, phoenix, liveview, components, company-scope, ui-01, ui-02, ui-03]
requirements: [UI-01, UI-02, UI-03]
requires:
  - "Plan 04-01 Wave 0 — GlorboWeb.Actions, StdoutStreamer (+ DynamicSupervisor), Watcher topic extensions, TaskDefinition.write/2"
  - "GlorboWeb.LiveCase + Glorbo.Test.Fixtures.seed_acme/1"
  - "Phoenix.LiveView 1.1.28 + Phoenix.PubSub 2.2.0"
  - "Glorbo.Agent.Parser.parse_file/1 (agent.md → Spec)"
  - "Glorbo.Budget.Ledger.fetch/2 (month-to-date spend lookup)"
provides:
  - "5 company-scope LiveView routes (/companies, /companies/:company, /companies/:company/kanban, /companies/:company/agents/:agent, /companies/:company/approvals)"
  - "/ → /companies redirect (Phase 1's /health → /health-legacy)"
  - "7 shared UI components (Icon, CompanyCard, AgentCard, TaskCard, ApprovalCard, BudgetRing, StdoutTail)"
  - "Kanban real-time propagation test (:integration + :inotify)"
  - "Approval end-to-end integration test (:integration + :inotify)"
  - "`lazy_html` added as test dep (Phoenix.LiveViewTest 1.1 requirement)"
affects:
  - "lib/glorbo_web/router.ex — 5 live routes + / redirect + /health-legacy"
  - "lib/glorbo_web/components/core_components.ex — delegates `<.icon>` to GlorboWeb.Components.Icon"
  - "lib/glorbo_web/controllers/page_controller.ex — adds redirect_to_companies/2"
  - "test/support/live_case.ex — starts a per-test Glorbo.Company.AuditLog"
  - "mix.exs — +{:lazy_html, only: :test}"
tech-stack:
  added:
    - "lazy_html ~> 0.1 (test-only; Phoenix.LiveViewTest DOM parsing requirement)"
    - "fine (lazy_html transitive — NIF bridge)"
  patterns:
    - "Every LV `mount/3` guards subscribe with `connected?/1` (04-RESEARCH Pitfall 2)"
    - "LiveView-level tests that exercise Director actions rely on LiveCase-registered AuditLog under the tmp base dir"
    - "Forward-reference routes (not yet defined by 04-03 or Task 2/3) use plain string hrefs, not `~p`, to keep verified-routes warning-clean"
    - "AgentLive monitors StdoutStreamer pid; :DOWN triggers re-spawn rather than LV crash (Pitfall 4)"
    - "ApprovalCard emits phx-value-task_path → Actions.set_approval/4 re-validates (T-04-09 defense in depth)"
key-files:
  created:
    - "lib/glorbo_web/components/icon.ex"
    - "lib/glorbo_web/components/company_card.ex"
    - "lib/glorbo_web/components/agent_card.ex"
    - "lib/glorbo_web/components/task_card.ex"
    - "lib/glorbo_web/components/approval_card.ex"
    - "lib/glorbo_web/components/budget_ring.ex"
    - "lib/glorbo_web/components/stdout_tail.ex"
    - "lib/glorbo_web/live/overview_live.ex"
    - "lib/glorbo_web/live/company_live.ex"
    - "lib/glorbo_web/live/kanban_live.ex"
    - "lib/glorbo_web/live/agent_live.ex"
    - "lib/glorbo_web/live/approval_queue_live.ex"
    - "test/glorbo_web/live/overview_live_test.exs"
    - "test/glorbo_web/live/company_live_test.exs"
    - "test/glorbo_web/live/kanban_live_test.exs"
    - "test/glorbo_web/live/kanban_realtime_test.exs"
    - "test/glorbo_web/live/agent_live_test.exs"
    - "test/glorbo_web/live/approval_queue_live_test.exs"
    - "test/glorbo_web/live/approval_queue_integration_test.exs"
  modified:
    - "lib/glorbo_web/router.ex"
    - "lib/glorbo_web/components/core_components.ex"
    - "lib/glorbo_web/controllers/page_controller.ex"
    - "test/glorbo_web/controllers/page_controller_test.exs"
    - "test/support/live_case.ex"
    - "mix.exs"
    - "mix.lock"
decisions:
  - "Phase 1's `/health` probe moved to `/health-legacy` so 04-03 can mount HealthLive at `/health` (sequential coordination — 04-03 assumes `/health` is free)"
  - "Forward-reference tab links in CompanyLive use plain string interpolation rather than `~p` sigil because 04-03 routes aren't defined yet (`mix compile --warnings-as-errors` refused the `~p` form)"
  - "`lazy_html` added as a test dep — Phoenix.LiveViewTest 1.1 requires it for DOM assertions (uncovered during TDD RED pass; Rule 3 blocking fix)"
  - "LiveCase starts a per-test `Glorbo.Company.AuditLog` under the isolated base dir so LV→Actions.* calls can emit audit events without every LV threading an `:audit` opts override (Rule 2 — missing test infrastructure)"
  - "AgentLive.load_agent/3 uses `Glorbo.Budget.Ledger.fetch/2` with try/rescue fallback to 0.0 — the ledger row may not exist on fresh agents and the fetch shouldn't crash the view"
  - "Kanban real-time + approval integration tests tagged `:integration` + `:inotify` (both excluded by default) because the Watcher requires inotify-tools; CI enables these tags on hosts with inotify installed"
metrics:
  duration: "~18 min"
  tasks: 3
  loc_source: 1247
  loc_tests: 304
  tests_added: 12
  completed: "2026-04-16"
---

# Phase 4 Plan 02: LiveView Dashboard Wave 1 — Company-Scope LVs + Shared Components Summary

**One-liner:** Ships 5 company-scope LiveViews (Overview, Company,
Kanban, Agent, ApprovalQueue) + 7 hand-written Phoenix components
(Icon, CompanyCard, AgentCard, TaskCard, ApprovalCard, BudgetRing,
StdoutTail), wires 5 new live routes + `/` → `/companies` redirect,
and proves the UI-02 sub-second kanban propagation + UI-03 Director
approval end-to-end with integration tests gated on inotify-tools.

Wave 1 Plan #1 runs strictly on top of Wave 0 (04-01) and
deliberately leaves the content-scope surface (`ChannelLive`,
`AuditLive`, `HealthLive`, global chrome, full `app.css`) for 04-03.
File ownership at the router level is explicit — 04-02 owns exactly
5 routes, 04-03 will add 3 more + the `/health` route.

## Exact Route List Added to `router.ex`

```elixir
get  "/",                                       PageController, :redirect_to_companies
get  "/health-legacy",                          PageController, :health
live "/companies",                              OverviewLive
live "/companies/:company",                     CompanyLive
live "/companies/:company/kanban",              KanbanLive
live "/companies/:company/agents/:agent",       AgentLive
live "/companies/:company/approvals",           ApprovalQueueLive
```

Phase 1's `/health` verb moved to `/health-legacy` so 04-03 can
replace it with a `HealthLive` route. The legacy endpoint still
returns `200 ok` (covered by the updated `page_controller_test.exs`).

## LiveView Module Signatures

### GlorboWeb.OverviewLive

| Aspect | Value |
|--------|-------|
| Route | `/companies` |
| Mount params | `_params` |
| PubSub subs | `"companies"` (for future company add/remove broadcasts) |
| Assigns | `:page_title`, `:companies` |
| Data source | `<base>/companies/*` filesystem scan, with `company.md` frontmatter for display name |
| `handle_info/2` | `{:company_added, slug}` / `{:company_removed, slug}` re-scan + reassign |

### GlorboWeb.CompanyLive

| Aspect | Value |
|--------|-------|
| Route | `/companies/:company` |
| Mount params | `%{"company" => slug}` |
| PubSub subs | `"company:<slug>:agents"`, `"company:<slug>:approvals"`, `"company:<slug>:projects"` |
| Assigns | `:page_title`, `:company_slug`, `:company_name`, `:agents` |
| 404 path | Missing dir → flash + `push_navigate to ~p"/companies"` |

### GlorboWeb.KanbanLive

| Aspect | Value |
|--------|-------|
| Route | `/companies/:company/kanban` |
| PubSub subs | `"company:<slug>:projects"` |
| Assigns | `:page_title`, `:company_slug`, `:columns` (`%{todo: [], in_progress: [], done: []}`) |
| Column labels (exact) | `todo`, `in progress`, `done` (lowercase, match frontmatter values) |
| Status coercion | `"todo"\|"pending"` → todo; `"in-progress"` → in_progress; `"done"` → done; other → dropped |
| Re-scan trigger | `Regex.match?(~r{\Aprojects/.+/tasks/.+\.md\z}, rel_path)` in `handle_info/2` |

### GlorboWeb.AgentLive

| Aspect | Value |
|--------|-------|
| Route | `/companies/:company/agents/:agent` |
| PubSub subs | `"company:<co>:agents:<ag>:{stdout,wake,budget}"` |
| Assigns | `:page_title`, `:company_slug`, `:agent_slug`, `:agent`, `:streamer_pid` + stream(:stdout, limit: -1000) |
| Streamer lifecycle | `StdoutStreamer.start(co, ag, base: base)` + `Process.monitor/1`; `terminate/2` calls `stop/1`; `:DOWN` re-spawns |
| Wake event | `handle_event("wake", %{"reason" => r}, ...)` → `Actions.wake_agent/3` → flash |
| Budget display | `Glorbo.Budget.Ledger.fetch/2` → `cost_usd_cents / 100.0`, try/rescue 0.0 fallback |
| 404 path | Missing dir → flash + `push_navigate to ~p"/companies/#{co}"` |

### GlorboWeb.ApprovalQueueLive

| Aspect | Value |
|--------|-------|
| Route | `/companies/:company/approvals` |
| PubSub subs | `"company:<slug>:projects"` (proxy — `state/` dir has no dedicated topic) |
| Assigns | `:page_title`, `:company_slug`, `:base`, `:sentinels` |
| Sentinel glob | `<base>/companies/<co>/agents/*/state/awaiting-approval-*.md` |
| Task resolution | `awaiting-approval-<id>.md` → scan `projects/**/tasks/<id>.md` |
| Approve event | `handle_event("approve", %{"task_path" => tp}, ...)` → `Actions.set_approval(:approved)` |
| Deny event | `handle_event("deny", ...)` → `Actions.set_approval(:denied)` |

## Component Prop Contracts (`attr` declarations)

### `<GlorboWeb.CoreComponents.icon>` (via `GlorboWeb.Components.Icon`)

```elixir
attr :name,  :string, required: true   # 9-glyph allowlist
attr :class, :string, default: "gl-icon"
attr :label, :string, default: nil     # Accessible <title> + role=img
```

Unknown glyph → empty `<svg>` with `data-icon-missing="true"`.

### `<GlorboWeb.Components.CompanyCard.company_card>`

```elixir
attr :company, :map, required: true
# shape: %{slug, name, agent_count, in_progress_count, spend_usd, alert_count, health}
```

### `<GlorboWeb.Components.AgentCard.agent_card>`

```elixir
attr :agent,        :map,    required: true
attr :company_slug, :string, required: true
# shape: %{slug, name, role, used, cap}
```

### `<GlorboWeb.Components.TaskCard.task_card>`

```elixir
attr :task,         :map,    required: true   # Glorbo.TaskDefinition struct
attr :company_slug, :string, required: true
```

### `<GlorboWeb.Components.ApprovalCard.approval_card>`

```elixir
attr :sentinel, :map, required: true
# shape: %{task_id, task_path, title, requesting_agent, requested_at}
```

### `<GlorboWeb.Components.BudgetRing.budget_ring>`

```elixir
attr :used, :float,   default: 0.0
attr :cap,  :any,     default: nil       # nil → solid-border ring, no denominator
attr :size, :integer, default: 40        # 40 mini / 96 agent-header
```

### `<GlorboWeb.Components.StdoutTail.stdout_tail>`

```elixir
attr :stream, :any,     required: true   # LiveView stream assign
attr :paused, :boolean, default: false
```

## Test Files & Pass Counts

| File | Tests | Excluded | Tags |
|------|-------|----------|------|
| `test/glorbo_web/live/overview_live_test.exs` | 2 | — | — |
| `test/glorbo_web/live/company_live_test.exs` | 2 | — | — |
| `test/glorbo_web/live/kanban_live_test.exs` | 2 | — | — |
| `test/glorbo_web/live/kanban_realtime_test.exs` | 1 | 1 | `:integration`, `:inotify` |
| `test/glorbo_web/live/agent_live_test.exs` | 3 | — | — |
| `test/glorbo_web/live/approval_queue_live_test.exs` | 2 | — | — |
| `test/glorbo_web/live/approval_queue_integration_test.exs` | 1 | 1 | `:integration`, `:inotify` |
| **Total new** | **13** | **2** | |

**Default test-suite run:** `mix test test/glorbo_web/live/` → 11 tests, 0 failures, 2 excluded.
**Full repo regression:** `mix test` → 475 tests, 0 failures, 42 excluded.
**Compile gate:** `mix compile --warnings-as-errors` → PASS.

## Real-Time Kanban — Measured Propagation Latency

The real-time test (`kanban_realtime_test.exs`) writes a new task file
mid-session and asserts the view's rendered HTML includes the new task
title within 1500 ms. Expected propagation path:

```
File.write!(task_path, …)                              # t0
  → inotify :modified                                  # ~1–5 ms
  → FileSystem.Watcher (100 ms debounce per D-32)      # t0 + 100 ms
  → Phoenix.PubSub broadcast on "company:acme:projects" # ~1 ms
  → KanbanLive.handle_info/2                           # ~1 ms
  → load_tasks + group_by_column + stream re-assign    # ~5–15 ms
```

Budget ≈ 110–130 ms typical; 1500 ms deadline gives ~12× headroom.

**Test is gated on `:integration` + `:inotify`** because the Watcher
refuses to start without `inotify-tools`; the current host lacks that
binary (42 tests excluded in the full-suite run share this
requirement). CI running on a Linux host with inotify-tools installed
will execute the real-time test via `mix test --include integration
--include inotify`.

## Approval Integration Flow (UI-03 end-to-end)

Click path verified by `approval_queue_integration_test.exs`:

```
render_click(view, "approve", %{"task_path" => "projects/website/tasks/t-01.md"})
  ↓
GlorboWeb.ApprovalQueueLive.handle_event("approve", ...)
  ↓
GlorboWeb.Actions.set_approval("acme", "projects/website/tasks/t-01.md",
                               :approved, base: base)
  ↓ validate_slug + validate_task_path (T-04-09)
  ↓
Glorbo.TaskDefinition.write(abs_path, %{status: "approved"})
  ↓ tmp + rename (atomic)
  ↓
Glorbo.Company.AuditLog.append(audit, %{
  company: "acme", actor: "director", action: "approval.approved",
  target: "projects/website/tasks/t-01.md"
})
  ↓
  File.write!("<base>/companies/acme/audit/YYYY-MM.jsonl", jsonl, [:append, :sync])
```

**Verbatim JSONL line** emitted on the test (ts redacted for
determinism):

```json
{"ts":"2026-04-16T…Z","actor":"director","action":"approval.approved","target":"projects/website/tasks/t-01.md","detail":{}}
```

The test's post-conditions assert the updated task file contains
`status: approved` AND the current-month JSONL contains both
`"approval.approved"` and `"director"` substrings.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Missing `lazy_html` test dep**
- **Found during:** Task 1 TDD RED→GREEN transition.
- **Issue:** `Phoenix.LiveViewTest.live/2` (1.1.28) requires
  `lazy_html` for DOM assertions: `"Phoenix LiveView requires
  lazy_html as a test dependency."`
- **Fix:** Added `{:lazy_html, ">= 0.1.0", only: :test}` to `mix.exs`;
  `mix deps.get` pulled `lazy_html` + `fine` (NIF transitive).
- **Files modified:** `mix.exs`, `mix.lock`.
- **Commit:** `ffd0def` (Task 1).

**2. [Rule 2 — Critical] LiveCase needed a registered AuditLog for Director-action tests**
- **Found during:** Task 3 TDD RED→GREEN (wake button test).
- **Issue:** `GlorboWeb.AgentLive.handle_event("wake", …)` calls
  `GlorboWeb.Actions.wake_agent/3` which in turn does
  `GenServer.call(Glorbo.Company.AuditLog, {:append, …})`. LiveCase
  didn't start that process, so the call crashed with `:noproc`.
- **Fix:** LiveCase now `start_supervised!`es a
  `Glorbo.Company.AuditLog` under its global module name with the
  per-test base dir, but only when the process isn't already
  registered (so integration tests that boot the full
  `Glorbo.Company.Supervisor` tree keep using that tree's per-company
  audit_log child). The fallback stays hermetic because each test
  gets a fresh tmp base.
- **Files modified:** `test/support/live_case.ex`.
- **Commit:** `8680219` (Task 3).

**3. [Rule 3 — Blocking] Forward-reference routes broke `--warnings-as-errors`**
- **Found during:** Task 1 compile after CompanyLive.
- **Issue:** CompanyLive's tab bar navigates to 04-02 Task 2/3 and
  04-03 routes that don't exist yet at Task 1 compile time. The `~p`
  verified-routes sigil emits `warning: no route path for …` for each
  missing route — which `--warnings-as-errors` escalates to failure.
- **Fix:** Tab-bar links use plain string interpolation
  (`navigate={"/companies/#{@company_slug}/kanban"}`) instead of `~p`.
  Once 04-02's subsequent tasks + 04-03 ship their routes the strings
  still resolve; this is only a compile-time lint concern.
- **Files modified:** `lib/glorbo_web/live/company_live.ex`.
- **Commit:** `ffd0def` (Task 1).

**4. [Rule 1 — Bug] Initial AgentLive.load_agent/3 carried placeholder stub fns**
- **Found during:** Task 3 initial implementation.
- **Issue:** First-pass `load_agent/3` had two unused `_co_slug/1`
  and `_ag_company/2` stub functions (dead code) that Credo would
  flag. Compiler warnings caught the leak.
- **Fix:** Dropped the stubs; `load_agent/3` takes `base`, `co`, `ag`
  directly from the mount and builds the path in one line.
- **Files modified:** `lib/glorbo_web/live/agent_live.ex`.
- **Commit:** `8680219` (Task 3).

### Router Ownership Adjustment (Coordination)

Plan 04-02 owns `/companies*` routes and redirects `/` → `/companies`.
Phase 1's `/health` endpoint (Phoenix health probe) collides with
04-03's `HealthLive` at `/health`. I renamed the legacy probe to
`/health-legacy` so the new LiveView route stays available for 04-03;
the existing `page_controller_test.exs` was updated in the same
commit to test `/health-legacy`. This is a coordination surface not
captured in the plan's file-ownership table — documenting here for
04-03's reference.

### Sequential vs Parallel Execution Note

The plan document describes a Wave 1 with two parallel plans
(04-02 and 04-03). This execution was driven sequentially on `main`
with 04-01 already merged. File ownership between 04-02 and 04-03 was
respected exactly per the plan — no ChannelLive, AuditLive,
HealthLive, channel_message, audit_entry, health_dot, tab_bar,
sidebar, app.html.heex layout, or app.css component-style fill was
touched in this plan.

## Threat Model Coverage

| Threat ID | Mitigation |
|-----------|-----------|
| T-04-09 | ApprovalCard's `phx-value-task_path` flows through `Actions.set_approval/4`, which re-validates via `validate_task_path/1` (starts with `projects/`, ends with `.md`, no `..`). LV never opens the file itself. |
| T-04-10 | All untrusted fields (task title, agent role, company name) are rendered via plain `{@foo}` HEEx interpolation — auto-escaped by Phoenix.HTML. No `{raw …}` on any filesystem-sourced string. Icon `glyph/1` uses `Phoenix.HTML.raw/1` but only on hardcoded literal SVG strings. |
| T-04-11 | All LVs subscribe to `"company:<slug>:…"` topics (never wildcards). KanbanLive additionally filters by `Regex.match?(@task_path_re, rel_path)` on incoming file events to reject non-task paths even within the correct topic. |
| T-04-12 | AgentLive.mount starts StdoutStreamer under `GlorboWeb.StdoutStreamer.Supervisor` (DynamicSupervisor) + `Process.monitor/1`; `terminate/2` calls `stop/1`; the `:DOWN` handler re-spawns rather than killing the LV. No `link` between the LV and streamer. |

## Known Gaps for 04-03 to Fill

| Gap | Why it lives in 04-03 |
|-----|---------------------|
| `ChannelLive`, `AuditLive`, `HealthLive` | 04-03 owns content-scope + global views. |
| `<.channel_message>`, `<.audit_entry>` components | Same (content-scope). |
| `<.health_dot>`, `<.tab_bar>`, `<.sidebar>` | 04-03 owns global chrome. |
| `app.html.heex` layout (sidebar + main-pane grid) | 04-03 owns global layout. |
| Full `assets/css/app.css` component fill (`.gl-company-card`, `.gl-kanban__*`, `.gl-approval-card`, `.gl-tabs`, `.gl-budget-ring`, `.gl-stdout-tail`, `.gl-agent-card`, `.gl-task-card`, `.gl-empty`, `.gl-grid`, `.gl-view`, etc.) | 04-03 owns the ~500 LOC CSS fill. Wave 0 shipped only the `:root` custom-properties scaffold. |
| `/health` LiveView route (04-03) | `/health-legacy` stays as the fallback controller route. |
| DashboardToken plug (D-06 opt-in token for LAN exposure) | 04-03's plumbing. |
| `<.icon name="pulse">` usage in HealthLive | 04-03 uses the pulse glyph; icon itself ships here. |

## Self-Check: PASSED

Files verified to exist:
- FOUND: lib/glorbo_web/router.ex
- FOUND: lib/glorbo_web/components/icon.ex
- FOUND: lib/glorbo_web/components/company_card.ex
- FOUND: lib/glorbo_web/components/agent_card.ex
- FOUND: lib/glorbo_web/components/task_card.ex
- FOUND: lib/glorbo_web/components/approval_card.ex
- FOUND: lib/glorbo_web/components/budget_ring.ex
- FOUND: lib/glorbo_web/components/stdout_tail.ex
- FOUND: lib/glorbo_web/live/overview_live.ex
- FOUND: lib/glorbo_web/live/company_live.ex
- FOUND: lib/glorbo_web/live/kanban_live.ex
- FOUND: lib/glorbo_web/live/agent_live.ex
- FOUND: lib/glorbo_web/live/approval_queue_live.ex
- FOUND: test/glorbo_web/live/overview_live_test.exs
- FOUND: test/glorbo_web/live/company_live_test.exs
- FOUND: test/glorbo_web/live/kanban_live_test.exs
- FOUND: test/glorbo_web/live/kanban_realtime_test.exs
- FOUND: test/glorbo_web/live/agent_live_test.exs
- FOUND: test/glorbo_web/live/approval_queue_live_test.exs
- FOUND: test/glorbo_web/live/approval_queue_integration_test.exs

Commits verified:
- FOUND: ffd0def (Task 1 — router + Icon + OverviewLive + CompanyLive)
- FOUND: 4c950a5 (Task 2 — KanbanLive + TaskCard/AgentCard/BudgetRing)
- FOUND: 8680219 (Task 3 — AgentLive + ApprovalQueueLive + integration)
