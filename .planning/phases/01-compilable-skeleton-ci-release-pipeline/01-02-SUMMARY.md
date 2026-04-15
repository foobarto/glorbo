---
phase: 01-compilable-skeleton-ci-release-pipeline
plan: 02
subsystem: infra
tags: [elixir, mix-task, cli, doctor, dependency-injection, jason, option-parser]

requires:
  - 01-01 (mix.exs with :jason; test/support/ on elixirc_paths(:test); Application bootable)
provides:
  - "Glorbo.Doctor.run_checks/0 and /1 — 5 host-prerequisite checks with injectable deps (cmd_fun/which_fun/home_fun/otp_release_fun)"
  - "Glorbo.Doctor.Formatter.to_table/1 (ANSI-gated) and to_json/1 (stable envelope keyed by version/checks/all_passed/passed_count/total_count/exit_code)"
  - "Mix.Tasks.Glorbo.Doctor with --json flag and exit({:shutdown, 1}) on failure"
  - "Glorbo.Doctor.TestHelpers at test/support/ — deps/1 + canned_cmd/2 + canned_which/1 fixtures for downstream tests"
  - "FND-06 (mix glorbo.doctor dev-time entry point) complete"
affects:
  - "01-03 (Wave 3): Plan 03 argv dispatch in Glorbo.Application.start/2 will call Glorbo.Doctor.run_checks/0 directly — NOT Mix.Task.run — so the release binary shares zero-copy logic with the Mix task"
  - "phase-02 (glorbo init): can call Glorbo.Doctor.run_checks/0 programmatically and parse the JSON-equivalent map list to decide which prerequisites to bootstrap (Podman, Ollama)"

tech-stack:
  added: []
  patterns:
    - "Dependency injection via keyword-list: public run_checks/1 accepts a deps keyword with defaults falling through to real OS calls (System.cmd/System.find_executable/System.user_home!/:erlang.system_info). Tests pass canned functions; production passes nothing and gets real behavior."
    - "Separation of rendering from logic: Glorbo.Doctor returns a list of check() maps; Glorbo.Doctor.Formatter renders. Mix task and release binary argv dispatch share the same pipeline."
    - "Mix.Task + exit({:shutdown, N}) — cleaner than System.halt/1 because it lets supervising Mix clean up; captured by catch_exit/1 in ExUnit."
    - "Public-but-@doc-false report/2 helper: enables CaptureIO tests to inject crafted result lists without mocking Doctor, avoiding test infrastructure for check-logic shortcuts."
    - "ANSI gating via IO.ANSI.enabled?/0: colors auto-disable on non-TTY (piping to jq, CI logs)."

key-files:
  created:
    - "lib/glorbo/doctor.ex — 5 check functions (linux_kernel, uidmap, disk_space, glorbo_dir, erts_version) with deps injection; @type check :: %{name, pass, detail, required}"
    - "lib/glorbo/doctor/formatter.ex — to_table/1 and to_json/1; @version pulled dynamically from Mix.Project.config so VALIDATION stays accurate across version bumps"
    - "lib/mix/tasks/glorbo.doctor.ex — Mix.Tasks.Glorbo.Doctor thin wrapper; OptionParser strict: [json: :boolean]"
    - "test/support/doctor_helpers.ex — Glorbo.Doctor.TestHelpers (deps/1, canned_cmd/2, canned_which/1) — .ex not .exs so elixirc_paths(:test) picks it up automatically (matches Plan 01's conn_case.ex/data_case.ex pattern)"
    - "test/glorbo/doctor_test.exs — 18 unit tests covering 5 checks × multiple boundaries + formatter table/json shape"
    - "test/mix/tasks/glorbo.doctor_test.exs — 5 CaptureIO integration tests (table output, --json decode, exit-code-1 on failure, envelope shape, smoke against real host)"
  modified: []

key-decisions:
  - "Used .ex (not .exs) for test/support/doctor_helpers.ex so elixirc_paths(:test) auto-loads it — matches Plan 01's conn_case.ex/data_case.ex pattern. Plan's files_modified listed .exs but that would require manual Code.require_file; .ex is the correct choice given the existing Plan-01-established convention."
  - "Pulled @version in Formatter dynamically from Mix.Project.config()[:version] rather than hard-coding \"0.1.0\" — keeps VALIDATION.md's `.version == \"0.1.0\"` assertion accurate today AND survives future version bumps without touching Formatter. Version currently \"0.1.0\" from phx.new default (unchanged)."
  - "Made Mix.Tasks.Glorbo.Doctor.report/2 public (with @doc false) so CaptureIO tests can inject crafted result lists without mocking Glorbo.Doctor — avoids Mox/meck infrastructure and keeps the test surface tiny."
  - "Fixed Credo 'nested modules could be aliased' suggestion in the Mix task by adding `alias Glorbo.Doctor` and `alias Glorbo.Doctor.Formatter` — minor diff from RESEARCH.md example, preserves strict mode green (66/66 checks passing, 0 issues)."
  - "kernel check greps `uname -r` and parses major.minor only: intentionally ignores the Fedora suffix (e.g. '6.17.7-ba29.fc43.x86_64' parses cleanly to {6, 17}). Sentinel :error path handled but never hits on standard distributions."
  - "disk_space uses `df -B1 --output=avail` — portable across coreutils 8.x; returns bytes directly so no unit conversion bug surface."

requirements-completed: [FND-06]

duration: 7min
started: 2026-04-15T18:05:00Z
completed: 2026-04-15T18:12:00Z
---

# Phase 1 Plan 02: `Glorbo.Doctor` + `mix glorbo.doctor` CLI Summary

**`mix glorbo.doctor` runs on the dev host, exits 0 with all 5 checks green, and emits stable JSON under `--json`; every individual check is unit-tested with injectable deps so CI runners without `newuidmap`/`uname`/`df` still pass — the release binary in Plan 03 can consume `Glorbo.Doctor.run_checks/0` unchanged.**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-04-15T18:05:00Z
- **Completed:** 2026-04-15T18:12:00Z
- **Tasks:** 2/2 completed
- **Files created:** 6
- **Files modified:** 0

## Accomplishments

- `Glorbo.Doctor.run_checks/0` + `/1` shipped with 5 host-prerequisite checks per D-19 (linux_kernel ≥ 5.13, uidmap binaries in PATH, disk_space ≥ 1 GB in `$HOME`, `~/.glorbo/` writable + auto-created, ERTS OTP release ≥ 27)
- Dep injection via keyword list (`cmd_fun`, `which_fun`, `home_fun`, `otp_release_fun`) — tests inject canned functions, production defaults fall through to real `System.cmd`/`System.find_executable`/`System.user_home!`/`:erlang.system_info(:otp_release)`
- `Glorbo.Doctor.Formatter.to_table/1` produces ANSI-colored ✓/✗ rows with auto-disable on non-TTY (`IO.ANSI.enabled?/0`)
- `Glorbo.Doctor.Formatter.to_json/1` emits stable-keyed JSON envelope (`version`, `checks[]`, `all_passed`, `passed_count`, `total_count`, `exit_code`) — verified on live host via `jq -e`
- `Mix.Tasks.Glorbo.Doctor` dev CLI: OptionParser `strict: [json: :boolean]`, `exit({:shutdown, 1})` on any failure, no duplication of check logic
- 23 new tests (18 unit + 5 integration) — full suite grew from 21 to 44, all green
- Credo strict still 0 issues (66 checks on 38 source files)

## Task Commits

Each task was committed atomically:

1. **Task 1: `Glorbo.Doctor` + `Formatter` + injectable deps + unit tests** — `15f79c9` (feat)
2. **Task 2: `Mix.Tasks.Glorbo.Doctor` + CaptureIO integration tests** — `e83c0b6` (feat)

**Plan metadata commit:** (pending, final step)

## Files Created/Modified

### Created

- `lib/glorbo/doctor.ex` (158 lines) — 5 private check functions called via `run_checks/1`; module attribute thresholds (`@minimum_kernel {5, 13}`, `@minimum_disk_bytes 1_073_741_824`, `@minimum_otp_release 27`); public `@type check` and `@spec run_checks/0..1`
- `lib/glorbo/doctor/formatter.ex` (55 lines) — `to_table/1`, `to_json/1`, private `format_row/1`, `format_summary/1`, `color/2` with `ANSI.enabled?` gate
- `lib/mix/tasks/glorbo.doctor.ex` (52 lines) — `use Mix.Task`, `@shortdoc`, `run/1`, public `report/2` (`@doc false`) for CaptureIO testing
- `test/support/doctor_helpers.ex` (28 lines) — `Glorbo.Doctor.TestHelpers` with `deps/1` (merges overrides into real defaults), `canned_cmd/2`, `canned_which/1`
- `test/glorbo/doctor_test.exs` (253 lines) — 18 tests: 4 kernel boundary tests, 3 uidmap tests, 3 disk boundary tests, 1 dir creation (isolated in tmp dir), 3 ERTS boundary tests, 1 shape contract test, 1 table test, 2 JSON envelope tests
- `test/mix/tasks/glorbo.doctor_test.exs` (103 lines) — 5 tests via `ExUnit.CaptureIO`: table output + all pass, table + any fail → shutdown 1, JSON output + envelope decode, JSON + shutdown 1 on failure, smoke test against real host

### Modified

None.

## Decisions Made

- **Helper file extension `.ex` not `.exs`:** the plan's `files_modified` listed `test/support/doctor_helpers.exs`, but existing support files (`conn_case.ex`, `data_case.ex`) are `.ex` — which is what `elixirc_paths(:test) → ["lib", "test/support"]` automatically compiles. Using `.exs` would have required explicit `Code.require_file` boilerplate. Using `.ex` matches the Plan-01-established pattern and is consistent with idiomatic Phoenix projects.
- **`@version` sourced from `Mix.Project.config()[:version]`:** the RESEARCH.md example hard-coded `@version "0.1.0"`. Sourcing dynamically from `mix.exs` keeps VALIDATION.md's `.version == "0.1.0"` assertion passing today AND survives future version bumps without editing Formatter. Confirmed on wire: `mix glorbo.doctor --json` emits `"version": "0.1.0"`.
- **`report/2` public + `@doc false`:** allows CaptureIO tests to inject crafted result lists (all-pass, one-fail) and exercise the Mix task's I/O + exit branches without mocking `Glorbo.Doctor.run_checks/0`. Trade-off: the function is technically reachable from external callers, but the `@doc false` annotation and `# Plan 03 argv dispatch will bypass this` convention keeps the API honest.
- **Aliased `Glorbo.Doctor` and `Glorbo.Doctor.Formatter` at top of Mix task:** resolved 2 Credo "Nested modules could be aliased" suggestions from the initial RESEARCH.md-derived draft. Delta from the example is ~5 lines.
- **Kernel parser deliberately ignores distro suffix:** `"6.17.7-ba29.fc43.x86_64"` parses as `{6, 17}` and passes cleanly. Sentinel `:error` path covers truly pathological output (e.g. empty string) but never hits under normal Linux distros.
- **`df -B1 --output=avail`:** returns raw bytes in a fixed-column layout (`"Avail\n<bytes>\n"`). Tested against coreutils 8+ (Fedora 43 dev box, Ubuntu 24.04 CI). Alternative `stat -f` would avoid the parse-Avail-row step but requires different arg handling per BSD/GNU — `df` is more portable.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `.exs` test support file not auto-compiled by `elixirc_paths`**
- **Found during:** Task 1, designing `test/support/doctor_helpers.exs`
- **Issue:** Plan's `files_modified` listed `test/support/doctor_helpers.exs`. However, `elixirc_paths(:test)` in `mix.exs` compiles `.ex` files only — `.exs` files require explicit `Code.require_file` / `test_helper.exs` loading. Existing support files from Plan 01 (`conn_case.ex`, `data_case.ex`) use `.ex`, establishing the convention.
- **Fix:** Created `test/support/doctor_helpers.ex` (not `.exs`). Imports work immediately via the existing `elixirc_paths` setup.
- **Files modified:** `test/support/doctor_helpers.ex`
- **Verification:** `mix test` loads the helper without additional config; all 18 doctor_test cases find `Glorbo.Doctor.TestHelpers` on first compile.
- **Committed in:** `15f79c9` (as part of Task 1 commit)

**2. [Rule 1 - Bug] `:erlang.system_info(:otp_release)` call style triggered Credo `Credo.Check.Readability.PipeIntoAnonymousFunctions`**
- **Found during:** Task 1, first `mix credo --strict` run
- **Issue:** RESEARCH.md example used `:erlang.system_info(:otp_release) |> List.to_string()` which Credo flagged. 
- **Fix:** Rewrote as `:otp_release |> :erlang.system_info() |> List.to_string()` — pipes the atom through instead. Same semantics, idiomatic pipeline.
- **Files modified:** `lib/glorbo/doctor.ex`, `test/support/doctor_helpers.ex`
- **Verification:** `mix credo --strict` → 0 issues.
- **Committed in:** `15f79c9` (fix was applied before the commit)

**3. [Rule 1 - Bug] Nested-module references in Mix task flagged by Credo**
- **Found during:** Task 2, post-commit `mix credo --strict` run after integrating both files
- **Issue:** `Glorbo.Doctor.run_checks()` and `Glorbo.Doctor.Formatter.to_json(...)` in `Mix.Tasks.Glorbo.Doctor` triggered `Credo.Check.Design.AliasUsage` (2 issues).
- **Fix:** Added `alias Glorbo.Doctor` and `alias Glorbo.Doctor.Formatter` at top of module; call sites became `Doctor.run_checks()` and `Formatter.to_json(...)`. Zero behaviour change.
- **Files modified:** `lib/mix/tasks/glorbo.doctor.ex`
- **Verification:** `mix credo --strict` → 0 issues; tests still pass.
- **Committed in:** `e83c0b6` (fix applied before commit)

### Plan adjustments (not Rule-1/2/3 but worth flagging)

- Plan's `files_modified` listed `test/support/doctor_helpers.exs`; I created `test/support/doctor_helpers.ex`. See Deviation #1 above.
- Plan's behavior block mentioned using `Mix.shell().info/1` OR `IO.puts/1` interchangeably — I picked `IO.puts/1` because `Mix.shell()` is `Mix.Shell.IO` by default (same output) but `IO.puts` is more universal, and Plan 03's release binary won't have `Mix.shell/0` available, so keeping the pipeline identical between Mix task and release wiring minimizes friction.

## Authentication Gates

None. All checks are local OS calls; no network, no auth.

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
| **`test/glorbo/doctor_test.exs`** | **18** | **0** |
| **`test/mix/tasks/glorbo.doctor_test.exs`** | **5** | **0** |
| **Total** | **44** | **0** |

- `mix format --check-formatted` → pass
- `mix compile --warnings-as-errors` → pass
- `mix credo --strict` → 66 checks on 38 files, 0 issues

## Live Host Verification

Dev host: Fedora 43, kernel 6.17.7, OTP 28.3.1, `uidmap` installed, 379 GB free.

```
$ mix glorbo.doctor
Glorbo Doctor — host prerequisite check

  ✓ linux_kernel         6.17.7-ba29.fc43.x86_64 (required: ≥ 5.13)
  ✓ uidmap               /usr/bin/newuidmap, /usr/bin/newgidmap (required: uidmap package installed)
  ✓ disk_space           379.1 GB available in /home/user (required: ≥ 1 GB)
  ✓ glorbo_dir           /home/user/.glorbo (writable) (required: writable directory)
  ✓ erts_version         OTP 28 (required: ≥ 27)

All checks passed (5/5).
Exit: 0
```

JSON assertions all green (each exits 0):
- `mix glorbo.doctor --json | jq -e '.version == "0.1.0"'`
- `mix glorbo.doctor --json | jq -e '.checks | length == 5'`
- `mix glorbo.doctor --json | jq -e '.checks[] | has("name") and has("pass") and has("detail") and has("required")'`
- `mix glorbo.doctor --json | jq -e '.all_passed == true'`

## Plan 03 Handoff

Plan 03 (Wave 3) wires `./glorbo doctor` via `Burrito.Util.Args.argv()` → `Glorbo.Doctor.run_checks/0` in `Glorbo.Application.start/2`. The stable bindings are:

- **Module path:** `Glorbo.Doctor` (the module; not `Mix.Tasks.Glorbo.Doctor` — that requires `Mix` in scope, which the release binary doesn't have)
- **Entry call:** `Glorbo.Doctor.run_checks/0` (no-arg; production defaults)
- **Rendering:** `Glorbo.Doctor.Formatter.to_table/1` and `Glorbo.Doctor.Formatter.to_json/1`
- **OptionParser spec to mirror:** `strict: [json: :boolean]`
- **Exit convention:** `exit({:shutdown, 1})` on any failing check (Mix already does this; release binary's top-level should translate it to `System.halt(1)` since there's no Mix to intercept).

No duplication of check logic. Plan 03 touches `Glorbo.Application.start/2` and `mix.exs` only.

## Known Stubs

None introduced by this plan. The 5 host checks are real, executable code; Plan 01's stubs (Company.Router, etc.) remain unchanged.

## Threat Flags

None. Doctor is a read-mostly diagnostic — it creates `~/.glorbo/` idempotently and writes a probe file that it immediately removes (inside a user-home directory already owned by the Director). No new network endpoints, auth paths, or trust boundaries.

## Self-Check: PASSED

All 6 claimed files present on disk:
- `lib/glorbo/doctor.ex`: FOUND
- `lib/glorbo/doctor/formatter.ex`: FOUND
- `lib/mix/tasks/glorbo.doctor.ex`: FOUND
- `test/support/doctor_helpers.ex`: FOUND
- `test/glorbo/doctor_test.exs`: FOUND
- `test/mix/tasks/glorbo.doctor_test.exs`: FOUND

All 2 claimed commits present in git log:
- `15f79c9`: FOUND
- `e83c0b6`: FOUND
