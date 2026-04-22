> **ARCHIVED — 2026-04-21.** This review captured the codebase state at
> v0.0.3 (2026-04-18). Many findings were addressed in subsequent
> releases (v0.0.4). Kept for historical reference.

# Glorbo Code Quality Review

**Date:** 2026-04-18
**Version:** 0.0.3
**Scope:** Full codebase — `lib/`, `test/`, configuration

---

## Overall Assessment: Strong

The codebase is well-structured with excellent documentation, clean linting, and comprehensive test coverage for core domain logic.

---

## Metrics

| Metric | Result |
|--------|--------|
| **Credo --strict** | 0 issues |
| **Compile --warnings-as-errors** | Clean |
| **Tests** | 872 run, 1 failure (871 passing) |
| **Test files** | 102 test files + 14 integration tests |
| **Modules** | 126 total, 97% have `@moduledoc` |
| **Code size** | ~725 KB across 99 source files |

---

## Failing Test

`GlorboWeb.StdoutStreamerTest` — `StdoutStreamer.Supervisor` never starts in the test environment. Likely a missing DynamicSupervisor child spec in the application tree. Low severity (test infrastructure issue, not a runtime bug).

---

## Strengths

1. **Zero lint warnings** — Credo strict passes clean; compile with `--warnings-as-errors` passes
2. **Documentation** — 97% `@moduledoc` coverage, 100% `@doc` on all core domain public functions
3. **Typespecs on domain logic** — `agent/server.ex`, `company/router.ex`, `sandbox/bwrap.ex`, `task_definition.ex` all have full `@spec` coverage
4. **No god modules** — Largest module (`cli.ex`) has 28 public functions, under the 30-function threshold
5. **No oversized functions** — No non-render function exceeds 50 lines
6. **Strong integration tests** — 14 e2e tests covering crash isolation, sandbox, approval gates, backup/restore
7. **Good dependency discipline** — Well-scoped deps (`only: :test`, `runtime: Mix.env() == :dev`)
8. **Consistent error tuples in domain layer** — Core modules uniformly use `{:ok, _} | {:error, _}`

---

## Issues

### High Priority (low effort, high impact)

#### 1. Duplicated `base_dir/0`

8 identical copies across LiveView files. Move to a shared helper or import from `Glorbo.Filesystem.Hierarchy`.

| File | Line |
|------|------|
| `lib/glorbo_web/live/agent_live.ex` | 1217 |
| `lib/glorbo_web/live/company_live.ex` | 884 |
| `lib/glorbo_web/live/kanban_live.ex` | 787 |
| `lib/glorbo_web/live/project_live.ex` | 440 |
| `lib/glorbo_web/live/audit_live.ex` | 336 |
| `lib/glorbo_web/live/channel_live.ex` | 285 |
| `lib/glorbo_web/live/approval_queue_live.ex` | 301 |
| `lib/glorbo_web/live/overview_live.ex` | 231 |

All are identical: `defp base_dir, do: Glorbo.Filesystem.Hierarchy.default_root()`

#### 2. Duplicated `current_year_month/0`

4 identical copies.

| File | Line |
|------|------|
| `lib/glorbo_web/live/audit_live.ex` | 258 |
| `lib/glorbo_web/live/company_live.ex` | 879 |
| `lib/glorbo_web/live/agent_live.ex` | 1206 |
| `lib/glorbo_web/live/overview_live.ex` | 206 |

#### 3. Duplicated budget classification logic

`budget_classify/2` (`company_live.ex:547`) and `classify_budget/2` (`agent_live.ex:863`) are near-identical. Same 80/90 threshold magic numbers duplicated across 6+ locations.

| File | Line |
|------|------|
| `lib/glorbo_web/live/company_live.ex` | 554-555 |
| `lib/glorbo_web/live/agent_live.ex` | 868-869 |
| `lib/glorbo_web/live/company_live.ex` | 136, 138 |
| `lib/glorbo_web/live/agent_live.ex` | 695, 698 |

#### 4. Duplicated float formatters

Identical implementations with different names in 2 files.

| File | Line | Functions |
|------|------|-----------|
| `lib/glorbo_web/live/company_live.ex` | 873-877 | `two_dp/1`, `zero_dp/1` |
| `lib/glorbo_web/live/agent_live.ex` | 1211-1215 | `dp2/1`, `dp0/1` |

#### 5. Repeated `File.ls` + `.md` filter pattern

`File.ls(dir) |> Enum.filter(&String.ends_with?(&1, ".md"))` appears in 10+ files. Extract to a shared helper in `Glorbo.Filesystem`.

Affected files: `kanban_live.ex:755`, `project_live.ex:370`, `company_live.ex:580,746`, `overview_live.ex:162`, `channel_live.ex:213`, `agent_live.ex:1046`, `agent/server.ex:724`, `company/budget_tracker.ex:147`, `cli/scaffold/template_registry.ex:80`.

### Medium Priority

#### 6. Inconsistent error handling in CLI layer

CLI lifecycle modules use `raise` while the rest of the codebase uses `{:ok, _} | {:error, _}`.

| File | Line | Pattern |
|------|------|---------|
| `lib/glorbo/init/orchestrator.ex` | 176 | `raise "AuditLog start failed"` |
| `lib/glorbo/sandbox/bwrap.ex` | 151 | `raise "bwrap not found in PATH"` |
| `lib/glorbo/sandbox/bwrap.ex` | 303 | `raise ArgumentError, "unsafe env var"` |
| `lib/glorbo/cli/registry/loader.ex` | 44 | `raise ArgumentError, format_error(reason)` |
| `lib/glorbo/cli/path_transforms.ex` | 23 | `raise ArgumentError, "unknown path_transform"` |
| `lib/glorbo/budget/ledger.ex` | 126 | `raise Ecto.InvalidChangesetError` |
| `lib/glorbo/cli/lifecycle/pidfile.ex` | 59 | `raise "unparseable pidfile"` |
| `lib/glorbo/cli/lifecycle/pidfile.ex` | 89 | `raise "cannot remove pidfile"` |
| `lib/glorbo/cli/lifecycle/daemon.ex` | 126 | `raise "Cannot locate Glorbo binary"` |
| `lib/glorbo/cli/lifecycle/serve.ex` | 53 | `raise "start_supervision_tree_for_serve failed"` |

Consider standardizing to error tuples, or document the convention that CLI commands raise (since they terminate the process anyway).

#### 7. No typespecs on presentation layer

All 11 LiveView files and 16 component files have zero `@spec` annotations. Not uncommon in Phoenix, but these are the largest files by line count.

Untyped files:
- All `lib/glorbo_web/live/*.ex` (11 files)
- All `lib/glorbo_web/components/*.ex` (16 files)
- `lib/glorbo_web.ex`, `lib/glorbo_web/router.ex`, `lib/glorbo_web/endpoint.ex`, `lib/glorbo_web/telemetry.ex`
- `lib/glorbo/repo.ex`
- `lib/mix/tasks/*.ex` (3 files)
- `lib/glorbo_web/plugs/dashboard_token.ex`

#### 8. Untested modules

47 modules have no direct test file. Many are exercised indirectly through integration tests, but notable gaps exist.

**`lib/glorbo/` — 28 untested modules:**

| Module | Risk |
|--------|------|
| `lib/glorbo/cli/lifecycle/daemon.ex` | Medium |
| `lib/glorbo/cli/lifecycle/down.ex` | Medium |
| `lib/glorbo/cli/lifecycle/pidfile.ex` | Medium |
| `lib/glorbo/cli/lifecycle/run.ex` | Medium |
| `lib/glorbo/cli/lifecycle/serve.ex` | Medium |
| `lib/glorbo/cli/lifecycle/status.ex` | Medium |
| `lib/glorbo/cli/lifecycle/up.ex` | Medium |
| `lib/glorbo/cli/scaffold/agent.ex` | Medium |
| `lib/glorbo/cli/scaffold/company.ex` | Medium |
| `lib/glorbo/cli/scaffold/project.ex` | Low |
| `lib/glorbo/cli/scaffold/skill.ex` | Low |
| `lib/glorbo/cli/scaffold/system_prompt.ex` | Low |
| `lib/glorbo/cli/scaffold/renderer.ex` | Low |
| `lib/glorbo/cli/scaffold/template_registry.ex` | Low |
| `lib/glorbo/cli/scaffold/templates_verb.ex` | Low |
| `lib/glorbo/doctor/formatter.ex` | Low |
| `lib/glorbo/company_boot.ex` | Medium |
| `lib/glorbo/filesystem/reindex_state.ex` | Low |
| `lib/glorbo/cli/parsers/none.ex` | Low |
| `lib/glorbo/cli/registry/provider.ex` | Low |
| `lib/glorbo/agent/file_layout.ex` | Low |
| `lib/glorbo/agent/spec.ex` | Low |
| `lib/glorbo/agent.ex` | Low (Ecto schema) |
| `lib/glorbo/audit_event.ex` | Low (Ecto schema) |
| `lib/glorbo/budget.ex` | Low (Ecto schema) |
| `lib/glorbo/company.ex` | Low (Ecto schema) |
| `lib/glorbo/release.ex` | Low |
| `lib/glorbo/repo.ex` | Low (Ecto config) |

**`lib/glorbo_web/` — 19 untested modules:**

All 16 component modules plus `endpoint.ex`, `router.ex`, `slug.ex`, `telemetry.ex`. Component testing in LiveView is often done through parent LiveView tests rather than isolation.

#### 9. Failing test — StdoutStreamerTest

`test/glorbo_web/stdout_streamer_test.exs:182` — `StdoutStreamer.Supervisor` never started. The test setup at line 65 (`wait_for_supervisor!/1`) times out because the supervisor is not in the application tree for the test environment.

### Low Priority

#### 10. `do_execute/4` approaching line limit

`lib/glorbo/agent/dispatch.ex:83` — 47 lines, 12-step `with` chain. Only non-render function approaching the 50-line threshold. Acceptable but worth watching if it grows.

#### 11. `erl_crash.dump` in repo root

A crash dump file exists at the repo root. Should be `.gitignore`d if not already, and investigated if it represents a recent crash.

#### 12. Hardcoded `~/.glorbo` paths in code

While most references are in documentation strings (acceptable), a few are in code logic:

| File | Line |
|------|------|
| `lib/glorbo/filesystem/hierarchy.ex` | 63 |
| `lib/glorbo/doctor/fixer.ex` | 215, 225 |
| `lib/glorbo/cli/registry/loader.ex` | 436 |
| `lib/glorbo/cli/scaffold/template_registry.ex` | 73-74 |

These should use `Hierarchy.default_root()` instead of hardcoding.

---

## Architecture Notes

The codebase follows its stated invariants well:

- **Filesystem as source of truth** — `~/.glorbo/companies/` is user data; SQLite is derived and rebuildable via `reindex`
- **One-way inbox/outbox flow** — enforced at the Router level
- **Company isolation** — via bwrap mount namespaces
- **Crash isolation** — OTP supervision tree preserves per-agent/per-company boundaries

The `company/router.ex` moduledoc explicitly documents its scaling tradeoffs and future split path — good engineering discipline.

---

## Recommended Actions

1. Extract `base_dir/0`, `current_year_month/0`, and budget threshold constants to `GlorboWeb.Helpers` or similar shared module
2. Fix `StdoutStreamerTest` by wiring the supervisor into the test application tree
3. Add tests for `cli/lifecycle/*` commands — these are user-facing and high-risk
4. Consider adding `@spec` to at least the larger LiveView modules for type documentation
