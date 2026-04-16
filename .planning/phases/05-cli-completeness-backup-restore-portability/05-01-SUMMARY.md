---
phase: 05-cli-completeness-backup-restore-portability
plan: 01
subsystem: infra
tags: [elixir, cli, burrito, release, scaffolding, pidfile, erl-distribution]

requires:
  - phase: 01-compilable-skeleton-ci-release-pipeline
    provides: Glorbo.CLI.dispatch/1 switch + Burrito release wiring
  - phase: 02-init-subsystem
    provides: Glorbo.Filesystem.Hierarchy, Glorbo.Doctor check registry, Glorbo.Init.Orchestrator
  - phase: 04-liveview-dashboard-real-time-channels
    provides: Glorbo.Config + ~/.glorbo/config.md contract (secret_key_base, host, port, 0600)
provides:
  - Glorbo.CLI.dispatch/1 extended with every Phase-5 verb branch (13 new + 2 nested new-sub handlers)
  - Glorbo.CLI.Lifecycle.Pidfile — atomic temp+rename pidfile helper (0600, kill -0 liveness probe)
  - Glorbo.Config.erl_cookie/1 — D-25 24-byte url-safe cookie with line-level frontmatter rewrite
  - Glorbo.Filesystem.Hierarchy — extended with run/ (chmod 0700)
  - rel/vm.args.eex — -sname glorbo@127.0.0.1 + ephemeral dist port (Burrito bypasses rel/env.sh.eex)
  - 13 Wave-0 module skeletons (lifecycle/, scaffold/, backup, restore, fixer, logs, migrate, console, doctor_fix)
  - GlorboTest.CLICase test-case template with per-test GLORBO_HOME hermetic root
  - Glorbo.Test.PortabilityFixtures with write_minimal_company/3 + stage_host/1
  - 19 :pending test stubs scaffolded for Plans 02 and 03 to toggle live
affects:
  - Plan 05-02 (lifecycle + scaffolding verbs)
  - Plan 05-03 (backup/restore + doctor --fix + console + portability integration)

tech-stack:
  added: []
  patterns:
    - Wave-0 merge gate: skeleton modules + dispatch extension land first so Plans 02/03 edit disjoint files in parallel
    - Verb module contract: run/1 returns {verb_atom, exit_code, output} for unit-testable dispatch (no CaptureIO)
    - Split CLI vs programmatic: Glorbo.Backup.{run/1,run_cli/1} — run/1 for tests/chains, run_cli/1 for argv parse
    - Verb help routing: verb_help_text/1 delegates to each module's help_text/0 (git help <verb> style)
    - Atomic pidfile: temp+rename + File.chmod!(0o600) post-rename (threat T-05-03)
    - Line-level frontmatter rewrite: ~r/^key:.*$/m regex replace preserves other keys + body + 0600 mode

key-files:
  created:
    - lib/glorbo/cli/lifecycle/pidfile.ex
    - lib/glorbo/cli/lifecycle/{up,down,status,serve,run,daemon}.ex
    - lib/glorbo/cli/scaffold/{company,agent,project}.ex
    - lib/glorbo/cli/{logs,migrate,console,doctor_fix}.ex
    - lib/glorbo/{backup,restore}.ex
    - lib/glorbo/doctor/fixer.ex
    - rel/vm.args.eex
    - test/support/cli_case.ex
    - test/support/portability_fixtures.ex
    - test/glorbo/cli/pidfile_test.exs
    - test/glorbo/cli/dispatch_phase5_stubs_test.exs
    - 18 additional Plan 02/03 :pending test stubs
  modified:
    - lib/glorbo/cli.ex (dispatch extended with 13 new verb branches)
    - lib/glorbo/config.ex (erl_cookie/1 + write_default!/1 injects erl_cookie on first boot)
    - lib/glorbo/filesystem/hierarchy.ex (@dirs extended with run/ at chmod 0700)
    - test/glorbo/config_test.exs (erl_cookie describe block: 4 assertions)
    - test/glorbo/cli_test.exs (doctor --fix now asserts DoctorFix stub output, not Phase-4 deferral)
    - test/support/glorbo_fixtures.ex (@doc pointer to PortabilityFixtures)
    - test/test_helper.exs (:pending excluded by default)

key-decisions:
  - rel/vm.args.eex pins -sname glorbo@127.0.0.1 with ephemeral dist listener (loopback-only, single-Director trust model per T-05-04)
  - Cookie returned opaque from Glorbo.Config.erl_cookie/1; never echoed to IO.puts/Logger/audit (T-05-02)
  - Wave-0 stub tuple shape: {verb_atom, 0, "<verb>: not implemented in Wave 0 (Plan 0[23] fills)\n"} so dispatch reachability is provable without implementation
  - doctor --fix now routes through Glorbo.CLI.DoctorFix (Wave-0 stub); replaces the inline Phase-4 "deferred to Phase 5" notice in lib/glorbo/cli.ex
  - Glorbo.Backup and Glorbo.Restore ship a dual-entry API (run/1 programmatic + run_cli/1 argv) — Plan 03 fills both without touching dispatch/1
  - Glorbo.CLI.Lifecycle.Daemon is a helper (not a verb) whose skeleton raises — Plan 02 Port/setsid re-exec work lands here, not in up.ex

patterns-established:
  - Merge-gate plan (01) owns dispatch/1 + module skeletons; parallel plans (02/03) never touch dispatch
  - :pending @moduletag as staged-red test pattern — Plans 02/03 toggle tag removal to light up per-verb tests
  - CLICase with GLORBO_HOME env override for per-test hermetic ~/.glorbo/

requirements-completed: [CLI-01, CLI-03]

duration: 10min
completed: 2026-04-16
---

# Phase 05 Plan 01: Wave-0 CLI Foundation Summary

**13 Phase-5 verb branches wired in Glorbo.CLI.dispatch/1, atomic Pidfile helper + erl_cookie parser + vm.args distribution wiring, and 19 :pending test stubs staged for Plans 02/03 parallel execution**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-04-16T16:13:18Z
- **Completed:** 2026-04-16T16:23:45Z
- **Tasks:** 3/3
- **Files created:** 41
- **Files modified:** 7

## Accomplishments

- `Glorbo.CLI.dispatch/1` extended with 13 Phase-5 verb branches + 2 nested `new <sub>` handlers; every DESIGN.md §10 verb reachable via `./glorbo <verb>` with a Wave-0 stub tuple.
- `Glorbo.CLI.Lifecycle.Pidfile` — atomic temp+rename + mode 0600 + `kill -0` liveness probe (`:stopped | :running | :stale`).
- `Glorbo.Config.erl_cookie/1` — 24-byte url-safe cookie generator with line-level `^erl_cookie:.*$` rewrite preserving other frontmatter lines; reasserts 0600 after write.
- `rel/vm.args.eex` pinning `-sname glorbo@127.0.0.1` with ephemeral distribution port (RESEARCH Critical Finding #1: Burrito bypasses `rel/env.sh.eex`).
- `Glorbo.Filesystem.Hierarchy.@dirs` extended with `run/` (chmod 0700 to match `runtime/sockets/`).
- Test harness: `GlorboTest.CLICase` (per-test `GLORBO_HOME` override) + `Glorbo.Test.PortabilityFixtures.write_minimal_company/3` + `stage_host/1`.
- 19 `:pending` test stubs cataloguing the Plan 02 and Plan 03 contracts; `mix test --exclude integration --exclude pending` stays green at 531/531.

## Task Commits

Each task committed atomically (all with `--no-verify` per parallel-executor protocol):

1. **Task 1: Pidfile + Hierarchy run/ + vm.args + Config.erl_cookie** — `5636dcb` (feat, TDD red → green: 11 new assertions)
2. **Task 2: CLI.dispatch Phase-5 verbs + skeletons** — `f643b60` (feat: 13 branches, 14 new modules, 14 new dispatch tests, 2 refreshed doctor --fix tests)
3. **Task 3: Test-support harness + :pending stubs** — `cbc1608` (test: CLICase, PortabilityFixtures, 19 :pending files)

## Files Created/Modified

### Created

- `lib/glorbo/cli/lifecycle/pidfile.ex` — atomic pidfile with status/write!/read!/rm
- `lib/glorbo/cli/lifecycle/up.ex` — Wave-0 stub (Plan 02 fills Burrito re-exec + daemon)
- `lib/glorbo/cli/lifecycle/down.ex` — Wave-0 stub (Plan 02 fills SIGTERM + grace + pidfile rm)
- `lib/glorbo/cli/lifecycle/status.ex` — Wave-0 stub (Plan 02 fills pidfile probe + port 4000 probe)
- `lib/glorbo/cli/lifecycle/serve.ex` — Wave-0 stub (Plan 02 fills foreground supervision tree boot)
- `lib/glorbo/cli/lifecycle/run.ex` — Wave-0 stub (Plan 02 fills one-shot agent dispatch)
- `lib/glorbo/cli/lifecycle/daemon.ex` — skeleton raise (Plan 02 fills Port+setsid re-exec)
- `lib/glorbo/cli/scaffold/{company,agent,project}.ex` — Wave-0 stubs (Plan 02 fills scaffolds + slug regex)
- `lib/glorbo/cli/logs.ex` — Wave-0 stub (Plan 02 fills audit/stdout tailer)
- `lib/glorbo/cli/migrate.ex` — Wave-0 stub (Plan 03 fills Ecto.Migrator wrapper)
- `lib/glorbo/cli/console.ex` — Wave-0 stub (Plan 03 fills iex --remsh spawn)
- `lib/glorbo/cli/doctor_fix.ex` — Wave-0 stub (Plan 03 fills Fixer routing, takes OptionParser opts)
- `lib/glorbo/backup.ex` — Wave-0 stub with dual run/1 + run_cli/1 entries (Plan 03 fills :erl_tar + WAL checkpoint)
- `lib/glorbo/restore.ex` — Wave-0 stub with dual run/2 + run_cli/1 entries (Plan 03 fills :erl_tar.extract + chain)
- `lib/glorbo/doctor/fixer.ex` — Wave-0 stub with @fixers marker (Plan 03 populates registry)
- `rel/vm.args.eex` — -sname glorbo@127.0.0.1 + ephemeral dist listener
- `test/support/cli_case.ex` — GlorboTest.CLICase template (GLORBO_HOME env override)
- `test/support/portability_fixtures.ex` — write_minimal_company/3 + stage_host/1
- `test/glorbo/cli/pidfile_test.exs` — 10 assertions (status, write!, read!, rm, 0600 mode)
- `test/glorbo/cli/dispatch_phase5_stubs_test.exs` — 20 assertions covering every verb branch + help routing + catch-all
- 18 `:pending` stub files under `test/glorbo/cli/`, `test/glorbo/`, `test/glorbo/doctor/`, `test/integration/`

### Modified

- `lib/glorbo/cli.ex` — 13 new dispatch clauses + `alias` block + `help [verb]` routing + help_text listing every DESIGN.md §10 verb; doctor --fix routes through DoctorFix module.
- `lib/glorbo/config.ex` — `erl_cookie/1` (public) + `generate_cookie/0` (private) + `write_cookie!/5` (line-level rewrite); `write_default!/1` now ships `erl_cookie:` on first boot.
- `lib/glorbo/filesystem/hierarchy.ex` — @dirs extended with `run`; `ensure!/1` chmod 0700 on `run/` (guarded by `File.exists?`).
- `test/glorbo/config_test.exs` — `describe "erl_cookie/1"` with 4 assertions (absent→generate, existing preserved, short replaced, 0600 reasserted).
- `test/glorbo/cli_test.exs` — `doctor --fix` describe block now asserts the DoctorFix Wave-0 stub output (replaces the Phase-4 "Phase 5 deferral" assertion).
- `test/support/glorbo_fixtures.ex` — @doc note pointing future portability tests to PortabilityFixtures.
- `test/test_helper.exs` — `:pending` added to default exclude set.

## Decisions Made

- **Daemon split into helper (not verb):** `Glorbo.CLI.Lifecycle.Daemon` is the Port+setsid re-exec utility that `Glorbo.CLI.Lifecycle.Up` will consume; both are Wave-0 skeletons but Daemon intentionally raises (no stub tuple) because it's not reachable via `./glorbo`.
- **Backup/Restore dual API:** `run/1` (programmatic, keyword opts) for tests and the `restore` internal chain (`extract → migrate → reindex → doctor --fix`); `run_cli/1` (argv) for the CLI branch. Lets Plan 03 unit-test `Backup.run/1` with a `base:` override without threading argv parsing.
- **Cookie contract opaque:** `Glorbo.Config.erl_cookie/1` returns `{:ok, cookie}` with NO callsites that log the value. Plan 03's `Glorbo.CLI.Console` will pass it directly to `Port.open` env vars; never serialized to JSON, never auditable (T-05-02).
- **help_text verb list complete:** All 17 DESIGN.md §10 verbs listed in `help_text/0` even though Wave-0 stubs still print "not implemented"; the Director sees the full surface on `./glorbo` / `./glorbo help` immediately after Plan 01 lands.
- **`:pending` tag semantic:** `mix test --include pending` runs pending tests (they flunk until Plans 02/03 fill), which is stronger TDD signal than skipped counts — the failure message documents the exact `TODO(plan-0X)` expected.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Refreshed `test/glorbo/cli_test.exs` doctor --fix assertions**
- **Found during:** Task 2 (dispatch extension)
- **Issue:** Plan-04 tests asserted the inline "Phase 5 deferred" notice on `doctor --fix`. Task 2 routes `--fix` through `Glorbo.CLI.DoctorFix.run/1` (Wave-0 stub) per the task spec, which makes those tests red. The Plan's acceptance criteria require "Phase 1 CLI tests still pass — zero regressions"; the fix is updating the Plan-04 test to the new contract (the spec itself, not an implementation drift).
- **Fix:** Rewrote `describe "dispatch([\"doctor\", \"--fix\"])"` to assert the DoctorFix stub output (`"doctor --fix"` + `"not implemented in Wave 0"`) under both with/without `--json`.
- **Files modified:** `test/glorbo/cli_test.exs`
- **Verification:** `mix test test/glorbo/cli_test.exs` passes all 14 tests (was 14 with 2 failures before).
- **Committed in:** `f643b60` (Task 2 commit)

**2. [Rule 2 - Missing critical] Added `:dry_run` to `@doctor_switches`**
- **Found during:** Task 2 (dispatch extension)
- **Issue:** Plan describes `doctor --fix --dry-run` (D-17) in the stub's help text, but the existing `@doctor_switches` only had `[json: :boolean, fix: :boolean]`. `OptionParser.parse/2` with `strict:` would reject `--dry-run` with an invalid-arg error before DoctorFix ever saw it.
- **Fix:** Added `dry_run: :boolean` to `@doctor_switches` so the flag parses cleanly and reaches `DoctorFix.run/1` when Plan 03 implements the registry.
- **Files modified:** `lib/glorbo/cli.ex`
- **Verification:** `mix test test/glorbo/cli_test.exs` all green; covered implicitly by the Plan-03 doctor_fix_test.exs `:dry_run` stub.
- **Committed in:** `f643b60` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 bug-fix on test contract, 1 missing OptionParser switch)
**Impact on plan:** Both auto-fixes preserve the Plan's stated contract (doctor --fix routes to a module; --dry-run supported per D-17). No scope creep; both changes consistent with Plan 01's goal of "dispatch reachability without implementation".

## Issues Encountered

- **Worktree base mismatch (pre-work):** Initial worktree HEAD at `970c4fe` was BEHIND the orchestrator-declared expected base `75fa96c`. `git merge-base --is-ancestor` revealed two separate commit chains. Resolved with `git reset --hard 75fa96c` (clean worktree state, no uncommitted work to preserve on the old branch head). Single-time fix before any task work started.
- **Ecto.Adapters.SQL.Sandbox ownership warnings** on the `cli_test.exs` init verb tests — this is pre-existing behaviour from Phase-4 `Glorbo.Init.Orchestrator`'s reindex step (which runs outside the test's Sandbox owner). All tests still pass; the warnings are noise. Deferred — not caused by this plan's changes.

## User Setup Required

None — no external service configuration required for Plan 01. Plans 02 (lifecycle subprocess tests) and 03 (full portability integration) will introduce a live-binary smoke test in their UAT sections.

## Next Phase Readiness

**Plan 05-02 (Plans 02 — lifecycle + scaffolding) can start immediately.** Plan 02 toggles `:pending` to live on:
- `test/glorbo/cli/up_test.exs`
- `test/glorbo/cli/down_test.exs`
- `test/glorbo/cli/status_test.exs`
- `test/glorbo/cli/serve_test.exs`
- `test/glorbo/cli/run_test.exs`
- `test/glorbo/cli/new_company_test.exs`
- `test/glorbo/cli/new_agent_test.exs`
- `test/glorbo/cli/new_project_test.exs`
- `test/glorbo/cli/logs_test.exs`
- `test/integration/up_down_status_test.exs`

Plan 02 owns these implementation files (disjoint from Plan 03):
- `lib/glorbo/cli/lifecycle/{up,down,status,serve,run,daemon}.ex`
- `lib/glorbo/cli/scaffold/{company,agent,project}.ex`
- `lib/glorbo/cli/logs.ex`

**Plan 05-03 (Plans 03 — backup/restore + doctor --fix + console) can start immediately in parallel.** Plan 03 toggles `:pending` to live on:
- `test/glorbo/cli/migrate_test.exs`
- `test/glorbo/cli/console_test.exs`
- `test/glorbo/cli/doctor_fix_test.exs`
- `test/glorbo/backup_test.exs`
- `test/glorbo/restore_test.exs`
- `test/glorbo/doctor/fixer_test.exs`
- `test/integration/backup_restore_roundtrip_test.exs`
- `test/integration/portability_test.exs`
- `test/integration/doctor_fix_test.exs`

Plan 03 owns these implementation files (disjoint from Plan 02):
- `lib/glorbo/backup.ex` + `lib/glorbo/restore.ex`
- `lib/glorbo/doctor/fixer.ex`
- `lib/glorbo/cli/console.ex` + `lib/glorbo/cli/migrate.ex` + `lib/glorbo/cli/doctor_fix.ex`

**Merge-gate invariant established:** Neither Plan 02 nor Plan 03 needs to touch `lib/glorbo/cli.ex` — every Phase-5 dispatch clause already routes to a pre-existing skeleton. Conflict surface is zero for the dispatch switch.

**Blockers:** None.

---
*Phase: 05-cli-completeness-backup-restore-portability*
*Completed: 2026-04-16*

## Self-Check: PASSED

All 12 load-bearing files verified present on disk and all 3 task commits
verified in git log.

- lib/glorbo/cli/lifecycle/pidfile.ex: FOUND
- lib/glorbo/cli/lifecycle/up.ex: FOUND
- lib/glorbo/cli/lifecycle/daemon.ex: FOUND
- lib/glorbo/backup.ex: FOUND
- lib/glorbo/restore.ex: FOUND
- lib/glorbo/doctor/fixer.ex: FOUND
- rel/vm.args.eex: FOUND
- test/support/cli_case.ex: FOUND
- test/support/portability_fixtures.ex: FOUND
- test/glorbo/cli/pidfile_test.exs: FOUND
- test/glorbo/cli/dispatch_phase5_stubs_test.exs: FOUND
- 05-01-SUMMARY.md: FOUND
- commit 5636dcb (Task 1): FOUND
- commit f643b60 (Task 2): FOUND
- commit cbc1608 (Task 3): FOUND
