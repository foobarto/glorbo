---
phase: 01-compilable-skeleton-ci-release-pipeline
plan: 01
subsystem: infra
tags: [elixir, phoenix, otp, sqlite, ecto, wal, supervision-tree, credo, stubs]

requires: []
provides:
  - Phoenix 1.8 / Elixir 1.18+ compilable project skeleton at repo root
  - SQLite WAL journal_mode active in dev, test, and runtime (prod) configs
  - Domain-nested §4.1 module layout under lib/glorbo/
  - Full Glorbo.Application supervision tree (Repo, DNSCluster, PubSub, Telemetry, ContainerManager, CompanySupervisor DynamicSupervisor, Endpoint)
  - Per-company Supervisor with 5 GenServer siblings (FileWatcher, Router, Scheduler, BudgetTracker, AuditLog)
  - AuditLog append-only surface (no update/delete/edit) enforced by test
  - Credo strict mode tuned for stub-heavy Phase 1
  - Wave 0 test suite: config_test, application_test, stubs_test, repo_wal_test
affects:
  - 01-02 (needs mix.exs deps + Glorbo.CLI module reachable for Mix task)
  - 01-03 (needs mix.exs + Application boot clean for Burrito wrap + CI builds)
  - phase-02 (needs Glorbo.CompanySupervisor DynamicSupervisor for `glorbo new company`)
  - phase-03 (needs §4.1 shape so permission enforcement and agent runtime wire without renaming)
  - phase-04 (needs GlorboWeb.Endpoint + PubSub mounted so LiveView routes attach)

tech-stack:
  added:
    - phoenix 1.8.5
    - phoenix_ecto 4.7.0
    - ecto_sqlite3 0.22+
    - phoenix_live_view 1.1.28 (kept for Phase 4 dashboard)
    - bandit 1.6 (HTTP adapter)
    - telemetry_metrics, telemetry_poller
    - file_system 1.0 (Phase 2 will use for inotify)
    - credo 1.7 (strict mode, dev/test only)
    - floki (test only, HTML parsing)
  patterns:
    - "OTP supervision tree: DynamicSupervisor for per-company isolation, Supervisor for per-company siblings — crash isolation follows tree shape (CLAUDE.md invariant)"
    - "Stub GenServer template: start_link/1 with required :name key, init/1 with company scope, handle_* returns {:error, :not_implemented}"
    - "Single public verb per domain module: route/2, watch/2, trigger/2, record_usage/2, append/2, wake/2 — LOAD-BEARING names across phases"
    - "Append-only surface enforcement via negative test assertions (refute function_exported?/3 for update/delete/edit)"
    - "SQLite WAL via Repo config in every env (journal_mode: :wal) — grep-verifiable + PRAGMA-verified"

key-files:
  created:
    - ".tool-versions"
    - ".credo.exs"
    - "mix.exs"
    - "config/config.exs, dev.exs, test.exs, prod.exs, runtime.exs"
    - "lib/glorbo.ex, lib/glorbo/application.ex, lib/glorbo/repo.ex"
    - "lib/glorbo/container_manager.ex, lib/glorbo/company_supervisor.ex"
    - "lib/glorbo/company/{supervisor,file_watcher,router,scheduler,budget_tracker,audit_log}.ex"
    - "lib/glorbo/agent/server.ex"
    - "lib/glorbo_web.ex, lib/glorbo_web/{endpoint,router,telemetry}.ex"
    - "lib/glorbo_web/components/{core_components,layouts}.ex"
    - "lib/glorbo_web/components/layouts/root.html.heex"
    - "lib/glorbo_web/controllers/{page_controller,error_html,error_json}.ex"
    - "test/config_test.exs"
    - "test/glorbo/{application_test,stubs_test,repo_wal_test}.exs"
    - "test/support/{conn_case,data_case}.ex"
    - "rel/overlays/bin/{server,migrate}(.bat)"
  modified:
    - ".gitignore (merged phx.new defaults with pre-existing GSD/editor entries)"

key-decisions:
  - "Pinned toolchain via .tool-versions (elixir 1.18.4-otp-28, erlang 28.0.2) to match planned Burrito v1.5.0 bundled ERTS; dev host runs 1.19.5/OTP 28 — acceptable drift, CI will enforce the pin"
  - "Removed esbuild, tailwind, heroicons, daisyUI from deps and dropped generated asset scaffolding — Phase 4 will re-introduce any asset pipeline it actually needs; Phase 1 serves /health as plain text only"
  - "Removed Ecto.Migrator child from Application supervision tree (no migrations exist in Phase 1)"
  - "Used default Credo gen.config as base (66 checks enabled under strict mode) instead of plan's empty-enabled config which disabled everything; set TagTODO, AliasOrder, ModuleDoc to false explicitly"
  - "AuditLog append-only enforced structurally: module source simply has no update/delete/edit defs; stubs_test refutes each with function_exported?/3 after force-loading"
  - "Phoenix LiveView dep kept (per D-02) but core_components.ex trimmed to bare `use Phoenix.Component` — Phase 4 will populate"

patterns-established:
  - "Stub-template GenServer: use GenServer + start_link/1 requiring :name in opts + init/1 reads :company + handle_call returns {:reply, {:error, :not_implemented}, state} + handle_cast/info noop — replicated across 6 domain modules"
  - "DynamicSupervisor registration via inline child spec in Application.start/2 with explicit name: atom (not via a dedicated DynamicSupervisor module); companion helper module Glorbo.CompanySupervisor exists only for typed start_child/1 API"
  - "Per-company process naming scheme: String.to_atom(\"#{company}_#{role}\") — deterministic, guessable, introspectable via :observer"

requirements-completed: [FND-01, FND-02]

duration: 9min
started: 2026-04-15T17:52:35Z
completed: 2026-04-15T18:02:00Z
---

# Phase 1 Plan 01: Phoenix Skeleton + SQLite WAL + §4.1 Supervision Tree Summary

**Fresh checkout now compiles with a full Phoenix 1.8 skeleton, SQLite WAL active in every env, the complete `DESIGN.md` §4.1 module layout stubbed under `lib/glorbo/`, and an OTP supervision tree that boots all 7 top-level children cleanly — verified by 21 Wave 0 tests green.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-04-15T17:52:35Z
- **Completed:** 2026-04-15T18:02:00Z
- **Tasks:** 2/2 completed
- **Files created:** 42 (incl. rel/ overlays and priv/ statics)
- **Files modified:** 1 (.gitignore merged)

## Accomplishments
- Phoenix skeleton generated and reshaped to §4.1 domain-nested layout without renaming later required by Phases 2–5
- Full supervision tree wired: `Glorbo.Repo → DNSCluster → Phoenix.PubSub (as Glorbo.PubSub) → GlorboWeb.Telemetry → Glorbo.ContainerManager → Glorbo.CompanySupervisor (DynamicSupervisor) → GlorboWeb.Endpoint`
- SQLite WAL journal_mode active in dev/test/runtime AND verified at runtime via `PRAGMA journal_mode` returning `"wal"` on the test Repo
- Per-company Supervisor with 5 siblings compiles and can be dynamically started under `Glorbo.CompanySupervisor` (verified by `test/glorbo/application_test.exs`)
- `Glorbo.Company.AuditLog` exposes ONLY `append/2` — no `update`/`delete`/`edit` (append-only invariant from CLAUDE.md, enforced by negative test)
- Credo strict mode (66 checks) passes on all 32 source files with 0 issues

## Task Commits

Each task was committed atomically:

1. **Task 1: Phoenix skeleton + toolchain pin + WAL config + Wave 0 test stubs** - `5b05e9e` (feat)
2. **Task 2: §4.1 module stubs + supervision tree wiring** - `804651f` (feat)
3. **Rule 1 auto-fix: flaky function_exported? assertion** - `a80c783` (fix)

**Plan metadata:** (final commit pending)

## Files Created/Modified

### Created

- `.tool-versions` — pins elixir 1.18.4-otp-28, erlang 28.0.2
- `.credo.exs` — strict mode, disables TagTODO/AliasOrder/ModuleDoc
- `mix.exs` — deps: phoenix 1.8, ecto_sqlite3, phoenix_live_view, bandit, credo, file_system (no esbuild/tailwind/heroicons, no Burrito yet)
- `config/{config,dev,test,prod,runtime}.exs` — SQLite WAL in dev/test/runtime
- `lib/glorbo.ex` — top-level namespace docstring
- `lib/glorbo/application.ex` — OTP entry point with 7 children
- `lib/glorbo/repo.ex` — Ecto SQLite3 Repo (phx.new-generated, unchanged)
- `lib/glorbo/container_manager.ex` — stub GenServer, ensure_image/1 placeholder
- `lib/glorbo/company_supervisor.ex` — wrapper helper module (DynamicSupervisor registered inline in Application)
- `lib/glorbo/company/supervisor.ex` — per-company Supervisor (one_for_one), starts 5 siblings with atom-based child names
- `lib/glorbo/company/{file_watcher,router,scheduler,budget_tracker,audit_log}.ex` — 5 stub GenServers with single "real work" verb each returning `{:error, :not_implemented}`
- `lib/glorbo/agent/server.ex` — Phase-3-dynamic agent stub (not started in Phase 1)
- `lib/glorbo_web/*` — Phoenix endpoint, router (GET /health), telemetry, minimal layouts/components
- `test/config_test.exs` — grep assertion that journal_mode: :wal is in dev/test/runtime
- `test/glorbo/application_test.exs` — supervision tree boot + empty CompanySupervisor + Company.Supervisor startable with 5 children
- `test/glorbo/stubs_test.exs` — every §4.1 module loaded + exports start_link/1 + AuditLog append-only refutation
- `test/glorbo/repo_wal_test.exs` — PRAGMA journal_mode returns "wal" on live test Repo
- `test/support/{conn_case,data_case}.ex` — phx.new scaffold, AliasUsage-fixed
- `rel/overlays/bin/{server,migrate}(.bat)` — phx.gen.release scaffold

### Modified

- `.gitignore` — merged phx.new defaults (`/_build/`, `/deps/`, `*.db`, etc.) with pre-existing entries (`.bg-shell/`, editor files, etc.)

## Decisions Made

- **Toolchain version drift:** dev host has Elixir 1.19.5 / OTP 28.3.1 installed; `.tool-versions` pins 1.18.4-otp-28 / 28.0.2 per plan. No asdf/mise installed on dev box to auto-switch. All tests/credo/compile pass under 1.19.5 — CI will enforce the pin via `erlef/setup-beam@v1`.
- **Phoenix generator version:** phx.new 1.8.5 was current at impl time (plan expected ~1.8). No Phoenix 1.9 migration needed.
- **Asset pipeline stripped:** Phoenix 1.8 generates a daisyUI/tailwind/esbuild asset pipeline with heroicons SVG sprite. Phase 1 has no UI, so I removed those deps, deleted `assets/{css,js,vendor,tsconfig.json}`, and trimmed `core_components.ex` and `layouts.ex` to bare stubs. `assets/index.html` (pre-existing marketing page) was preserved. Phase 4 will re-introduce only the pipeline it actually needs.
- **Ecto.Migrator removed from supervision tree:** phx.new added `{Ecto.Migrator, repos: ..., skip: skip_migrations?()}` to the tree. Phase 1 has no migrations; the migrator was spamming start-up "skip: true" without value. Removed; Phase 2 can re-add when real migrations land.
- **Credo config rewritten:** the plan's research-sourced `.credo.exs` used `enabled: []` which disabled ALL checks (strict mode alone doesn't imply "enable all"). Re-generated from `mix credo gen.config` and flipped `strict: true`, set TagTODO/AliasOrder/ModuleDoc to `false`. Now running 66 checks, all passing.
- **Route:** GET / replaced with GET /health returning plain "ok" (per plan), not a full home page.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Flaky `function_exported?/3` assertion on unloaded module**
- **Found during:** Task 2 verification (3rd run of full test suite)
- **Issue:** `test/glorbo/stubs_test.exs` asserted `function_exported?(Glorbo.Company.AuditLog, :append, 2)` without first ensuring the module was loaded. `function_exported?/3` returns `false` for not-yet-loaded modules; under `async: true` this was non-deterministic.
- **Fix:** Added `Code.ensure_loaded!(Glorbo.Company.AuditLog)` before the assertions in that one test.
- **Files modified:** `test/glorbo/stubs_test.exs`
- **Verification:** Ran full `mix test` 3 times in a row — all 21 tests pass each time, deterministic.
- **Committed in:** `a80c783`

**2. [Rule 2 - Missing tooling] Credo `enabled: []` disables all checks**
- **Found during:** Task 1 (after writing the initial `.credo.exs` from plan research)
- **Issue:** `mix credo --strict` reported "running 0 checks on 23 files" — the plan's literal config had `enabled: []` which means zero checks. Strict mode does not imply "enable all"; it just lowers the severity threshold.
- **Fix:** Regenerated via `mix credo gen.config`, flipped `strict: true`, set `TagTODO`, `AliasOrder`, `ModuleDoc` to `false`. Now running 66 checks.
- **Files modified:** `.credo.exs`
- **Verification:** `mix credo --strict` reports `running 66 checks on 32 files` → `found no issues`.
- **Committed in:** `5b05e9e` (as part of Task 1 commit — fix was applied before the commit)

**3. [Rule 3 - Unblocking] Removed Ecto.Migrator from supervision tree**
- **Found during:** Task 2
- **Issue:** phx.new added an `{Ecto.Migrator, skip: true}` child. Phase 1 has no migrations so it was dead weight and confused the stubs_test expectations about child count.
- **Fix:** Removed from `Glorbo.Application.start/2` children list.
- **Files modified:** `lib/glorbo/application.ex`
- **Verification:** `mix test test/glorbo/application_test.exs` passes 3 tests; tree boots clean.
- **Committed in:** `804651f`

### Plan adjustments (not Rule-1/2/3 but worth flagging)

- Plan Task 1 §Step 1.4 instructed `cross-check Phoenix version ranges from generator output, do not downgrade` — I kept phx.new-generated 1.8.5 but overwrote the entire deps list to plan's canonical set. No downgrade occurred.
- Plan Task 1 §Step 1.7 said to "Delete `page_html.ex`" which I did (along with the template directory); tests for PageController updated to hit `/health` instead of `/` with HTML assertion.

## Test Status (Final)

| Test File | Tests | Failures |
|-----------|-------|----------|
| `test/config_test.exs` | 3 | 0 |
| `test/glorbo/application_test.exs` | 3 | 0 |
| `test/glorbo/stubs_test.exs` | 9 | 0 |
| `test/glorbo/repo_wal_test.exs` | 1 | 0 |
| `test/glorbo_web/controllers/error_html_test.exs` | 2 | 0 |
| `test/glorbo_web/controllers/error_json_test.exs` | 2 | 0 |
| `test/glorbo_web/controllers/page_controller_test.exs` | 1 | 0 |
| **Total** | **21** | **0** |

- `mix format --check-formatted` → pass
- `mix compile --warnings-as-errors` → pass
- `mix credo --strict` → 66 checks on 32 files, 0 issues
- `grep -l 'journal_mode: :wal' config/{dev,test,runtime}.exs | wc -l` → 3

## Wave 0 Test File Status

| File | Exists | Passing |
|------|--------|---------|
| `test/glorbo/application_test.exs` | yes | yes (3 tests) |
| `test/glorbo/stubs_test.exs` | yes | yes (9 tests) |
| `test/glorbo/repo_wal_test.exs` | yes | yes (1 test) |
| `test/config_test.exs` | yes | yes (3 tests) |

## Next Plan

- **01-02** (Plan B) — `mix glorbo.doctor` CLI with 5 host checks (kernel, uidmap, disk, $HOME, ERTS) + JSON output mode. Depends only on files this plan created (`mix.exs` deps, `Glorbo.Application` bootable) — ready to execute in Wave 2.

## Known Stubs

Every §4.1 module other than `Glorbo.Repo` is a stub returning `{:error, :not_implemented}`. This is **intentional** per the plan's scope — Phase 1 proves the build contract, not the runtime contract. Each stub's owning phase:

| Module | Owning Phase |
|--------|--------------|
| `Glorbo.ContainerManager` | Phase 2 (Podman CLI calls) |
| `Glorbo.CompanySupervisor.start_child/1` | Phase 2 (`glorbo new company`) |
| `Glorbo.Company.FileWatcher` | Phase 2 (`file_system` wiring) |
| `Glorbo.Company.Router` | Phase 3 (permission enforcement) |
| `Glorbo.Company.Scheduler` | Phase 3 (heartbeat loop) |
| `Glorbo.Company.BudgetTracker` | Phase 3 (SQLite persistence) |
| `Glorbo.Company.AuditLog` | Phase 3 (JSONL append + index) |
| `Glorbo.Agent.Server` | Phase 3 (dynamic child under Company.Supervisor) |

No stubs are render-layer UI stubs — the `/health` endpoint returns real plain text, not placeholder copy.

## Self-Check: PASSED

All 21 claimed files present on disk; all 3 claimed commits (5b05e9e, 804651f, a80c783) present in git log.
