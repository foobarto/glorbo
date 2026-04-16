---
phase: 05-cli-completeness-backup-restore-portability
verified: 2026-04-16T17:00:00Z
status: gaps_found
score: 2/4
overrides_applied: 0
gaps:
  - truth: "All CLI verbs from the spec are implemented (not stubs): backup, restore, console, migrate, doctor --fix"
    status: failed
    reason: "backup, restore, console, migrate, and doctor --fix remain Wave-0 stubs returning 'not implemented in Wave 0 (Plan 03 fills)'. Plan 03 was never written."
    artifacts:
      - path: "lib/glorbo/backup.ex"
        issue: "run_cli/1 returns stub tuple; run/1 returns {:error, :not_implemented}"
      - path: "lib/glorbo/restore.ex"
        issue: "run_cli/1 returns stub tuple; run/2 returns {:error, :not_implemented}"
      - path: "lib/glorbo/cli/console.ex"
        issue: "run/1 returns stub tuple — no iex --remsh implementation"
      - path: "lib/glorbo/cli/migrate.ex"
        issue: "run/1 returns stub tuple — no Ecto.Migrator call"
      - path: "lib/glorbo/cli/doctor_fix.ex"
        issue: "run/1 returns stub tuple; Glorbo.Doctor.Fixer has empty @fixers map"
      - path: "lib/glorbo/doctor/fixer.ex"
        issue: "@fixers map is empty; all fixer functions are TODO(plan-03) markers"
    missing:
      - "Implement Glorbo.Backup.run/1 with :erl_tar.create, WAL checkpoint, pidfile guard"
      - "Implement Glorbo.Restore.run_cli/1 with :erl_tar.extract, traversal guard, migrate+reindex+doctor --fix chain"
      - "Implement Glorbo.CLI.Console.run/1 with iex --remsh spawn via Port.open"
      - "Implement Glorbo.CLI.Migrate.run/1 with Ecto.Migrator.run(:up, all: true)"
      - "Populate Glorbo.Doctor.Fixer @fixers map with glorbo_dir, audit_dir, sockets_dir, podman, ollama, runtime_image, bwrap fixers"
  - truth: "glorbo backup produces a tar.gz; glorbo restore extracts + reindexes; install left usable"
    status: failed
    reason: "Both Backup.run_cli/1 and Restore.run_cli/1 are stubs. No archive is produced or consumed."
    artifacts:
      - path: "lib/glorbo/backup.ex"
        issue: "STUB — returns {:backup, 0, 'not implemented in Wave 0'}"
      - path: "lib/glorbo/restore.ex"
        issue: "STUB — returns {:restore, 0, 'not implemented in Wave 0'}"
    missing:
      - "Plan 03 (never written) that implements backup/restore/console/migrate/doctor --fix"
  - truth: "End-to-end portability: backup on machine A, scp, restore + doctor --fix + up on machine B; agent executes task"
    status: failed
    reason: "Depends on backup and restore implementations that are stubs. Cannot be end-to-end verified."
    artifacts:
      - path: "test/integration/portability_test.exs"
        issue: "@moduletag :pending — test scaffold exists but never toggled live"
      - path: "test/integration/backup_restore_roundtrip_test.exs"
        issue: "@moduletag :pending — test scaffold exists but never toggled live"
      - path: "test/integration/doctor_fix_test.exs"
        issue: "@moduletag :pending — test scaffold exists but never toggled live"
    missing:
      - "Plan 03 implementation before these integration tests can be activated"
human_verification:
  - test: "glorbo console remote shell"
    expected: "iex --remsh glorbo@127.0.0.1 connects to a running daemon; Glorbo.Doctor.run_checks() returns same data as main node"
    why_human: "Requires glorbo up in one terminal, glorbo console in another; cannot verify remsh without running release"
  - test: "glorbo up / status / down smoke test against compiled burrito binary"
    expected: "up exits 0 + pidfile appears; status exits 0 once port 4000 listening; down exits 0; status exits 3 after stop"
    why_human: "test/integration/up_down_status_test.exs is live but skips gracefully when _build/prod/rel/glorbo/glorbo is absent; no burrito binary in CI unless 'mix release --overwrite' runs first"
  - test: "glorbo vm.args node distribution: -name vs -sname"
    expected: "iex --name console@127.0.0.1 --cookie <cookie> --remsh glorbo@127.0.0.1 connects; Plan 01 must_have specified -sname but implementation uses -name (WR-09 deviation)"
    why_human: "Correction from -sname to -name is documented in rel/vm.args.eex comments as WR-09; functional correctness requires a running release to verify"
---

# Phase 05: CLI Completeness + Backup/Restore/Portability — Verification Report

**Phase Goal:** Every CLI verb from DESIGN.md §10 works, and the portability story — `backup` on machine A, `scp` to machine B, `restore` + `doctor --fix`, everything functional — is end-to-end verified on a fresh host.
**Verified:** 2026-04-16T17:00:00Z
**Status:** gaps_found
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | All CLI verbs from the spec are implemented (init, up, down, status, serve, run, new company/agent/project, logs, doctor, doctor --fix, reindex, migrate, backup, restore, console) | FAILED | backup, restore, console, migrate, doctor --fix are Wave-0 stubs; Plan 03 never written |
| 2 | `glorbo backup` produces a tar.gz; `glorbo restore <archive>` extracts, reindexes, leaves install usable | FAILED | Both are stubs returning "not implemented in Wave 0 (Plan 03 fills)" |
| 3 | End-to-end portability: backup → scp → restore + doctor --fix + up → agent executes task on fresh host | FAILED | Blocked by stubs in backup, restore, doctor --fix; integration tests remain :pending |
| 4 | `glorbo console` remsh, `glorbo logs` tails correct files, `glorbo migrate` applies Ecto migrations in-place | PARTIAL | logs: VERIFIED (real inotify + poll implementation, 333 lines); console: STUB; migrate: STUB |

**Score:** 0/4 truths fully verified (lifecycle + scaffolding + logs are working; the four roadmap success criteria each require backup/restore/console/migrate/doctor --fix)

Note: The phase delivered strong partial results. Lifecycle verbs (up, down, status, serve, run), scaffolding verbs (new company, new agent, new project), and logs are fully implemented and tested. The gap is entirely concentrated in the unwritten Plan 03 scope.

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/glorbo/cli.ex` | Extended dispatch with all Phase-5 verbs | VERIFIED | 13 new dispatch clauses; all DESIGN.md §10 verbs routable |
| `lib/glorbo/cli/lifecycle/pidfile.ex` | Atomic pidfile with status/write!/read!/rm | VERIFIED | 4 public functions; temp+rename atomic write; kill -0 liveness probe |
| `lib/glorbo/cli/lifecycle/up.ex` | D-07 pidfile-guarded background daemon launch | VERIFIED | 133 lines; Port.open + setsid + RELEASE_COOKIE + pidfile write |
| `lib/glorbo/cli/lifecycle/down.ex` | D-08 SIGTERM + poll + SIGKILL fallback | VERIFIED | 142 lines; SIGTERM + 10s poll + SIGKILL + pidfile cleanup |
| `lib/glorbo/cli/lifecycle/status.ex` | D-09 pidfile + TCP probe + --json | VERIFIED | 116 lines; :gen_tcp.connect probe; Jason output for --json |
| `lib/glorbo/cli/lifecycle/serve.ex` | D-06 foreground tree + Process.sleep(:infinity) | VERIFIED | Process.sleep(:infinity) present; --exit-after test knob |
| `lib/glorbo/cli/lifecycle/run.ex` | D-10 one-shot Dispatch.execute/3 | VERIFIED | Glorbo.Agent.Dispatch.execute wired |
| `lib/glorbo/cli/lifecycle/daemon.ex` | spawn_detached/2 via setsid + Port.open | VERIFIED | Port.open + setsid present; 104+ lines |
| `lib/glorbo/cli/scaffold/company.ex` | D-11 slug-validated, idempotent | VERIFIED | 90 lines; slug regex + idempotency marker; audit events |
| `lib/glorbo/cli/scaffold/agent.ex` | D-12 canonical frontmatter defaults | VERIFIED | 146 lines; provider: claude-code, network: api-only, monthly_usd: 10.00 |
| `lib/glorbo/cli/scaffold/project.ex` | D-13 project README.md scaffold | VERIFIED | README.md created; project.md frontmatter |
| `lib/glorbo/cli/logs.ex` | D-14/D-15 tail with --lines/--follow | VERIFIED | 333 lines; FileSystem.subscribe; inotify + poll fallback |
| `lib/glorbo/cli/audit.ex` | cli.<verb>.<phase> audit helper | VERIFIED | Exists; try/rescue/catch pattern |
| `lib/glorbo/config.ex` | erl_cookie/1 generates + persists 24-byte cookie | VERIFIED | :crypto.strong_rand_bytes(24); line-level rewrite |
| `lib/glorbo/filesystem/hierarchy.ex` | run/ directory in @dirs (chmod 0700) | VERIFIED | "run" present; chmod reference in pidfile.ex |
| `rel/vm.args.eex` | Distribution flags (plan said -sname; impl uses -name per WR-09) | PARTIAL | File exists; uses -name glorbo@127.0.0.1 (WR-09 deviation from plan's -sname requirement; documented as intentional correction) |
| `lib/glorbo/backup.ex` | tar.gz archive with WAL checkpoint | STUB | run_cli/1 returns "not implemented in Wave 0"; run/1 returns {:error, :not_implemented} |
| `lib/glorbo/restore.ex` | Extract + migrate + reindex + doctor --fix chain | STUB | run_cli/1 returns "not implemented in Wave 0"; run/2 returns {:error, :not_implemented} |
| `lib/glorbo/cli/console.ex` | iex --remsh via Port.open | STUB | Returns "not implemented in Wave 0" |
| `lib/glorbo/cli/migrate.ex` | Ecto.Migrator.run(:up, all: true) | STUB | Returns "not implemented in Wave 0" |
| `lib/glorbo/cli/doctor_fix.ex` | Routes to Glorbo.Doctor.Fixer | STUB | Delegates to Fixer.run/1; Fixer has empty @fixers map |
| `lib/glorbo/doctor/fixer.ex` | @fixers map with 7 fixer functions | STUB | @fixers map is a comment marker; no actual fixers registered |
| `test/support/cli_case.ex` | GlorboTest.CLICase with GLORBO_HOME isolation | VERIFIED | defmodule GlorboTest.CLICase; per-test GLORBO_HOME env override |
| `test/support/portability_fixtures.ex` | write_minimal_company/3 + stage_host/1 | VERIFIED | Both functions present |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `lib/glorbo/cli.ex` | `lib/glorbo/cli/lifecycle/*.ex, scaffold/*.ex, {logs,migrate,console,doctor_fix}.ex, {backup,restore}.ex` | dispatch/1 alias + pattern-match | WIRED | alias Glorbo.CLI.{Lifecycle, Scaffold, Logs, Migrate, Console, DoctorFix}; all verbs dispatch |
| `lib/glorbo/cli/lifecycle/up.ex` | pidfile.ex + config.ex | Pidfile.write! + Config.erl_cookie/1 | WIRED | Both calls present in up.ex |
| `lib/glorbo/cli/lifecycle/up.ex` | child subprocess | Port.open via Daemon.spawn_detached + RELEASE_COOKIE env | WIRED | RELEASE_COOKIE in env charlist |
| `lib/glorbo/cli/lifecycle/down.ex` | OS process | System.cmd("kill", ["-TERM", ...]) | WIRED | SIGTERM + SIGKILL both present |
| `lib/glorbo/cli/lifecycle/status.ex` | Bandit endpoint on port 4000 | :gen_tcp.connect(127.0.0.1, 4000) | WIRED | :gen_tcp.connect present |
| `lib/glorbo/cli/logs.ex` | filesystem inotify | FileSystem.start_link + FileSystem.subscribe | WIRED | FileSystem.subscribe on line 127 |
| `lib/glorbo/cli/scaffold/*` | Glorbo.CLI.Audit | Audit.emit/3 calls | WIRED | All three scaffold modules use Audit.emit |
| `lib/glorbo/backup.ex` | tar.gz archive | :erl_tar.create (Plan 03) | NOT_WIRED | STUB — no implementation |
| `lib/glorbo/restore.ex` | extract + migrate + reindex chain | :erl_tar.extract + chain (Plan 03) | NOT_WIRED | STUB — no implementation |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `lib/glorbo/cli/lifecycle/status.ex` | running?, pid, port_listening? | Pidfile.status/1 + kill -0 + :gen_tcp.connect | Yes — real OS checks | FLOWING |
| `lib/glorbo/cli/logs.ex` | lines backfill | File.stream! on audit JSONL / stdout.log | Yes — real file reads | FLOWING |
| `lib/glorbo/backup.ex` | archive path | none (stub) | No | DISCONNECTED |
| `lib/glorbo/restore.ex` | extraction result | none (stub) | No | DISCONNECTED |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| dispatch("up") routes to Lifecycle.Up | Confirmed via grep of dispatch/1 + module existence | Routing confirmed; behavior gated on GLORBO_BINARY_PATH | PASS |
| dispatch("backup") routes to Backup.run_cli | dispatch(["backup" | rest]), do: Backup.run_cli(rest) confirmed | Returns stub tuple — not an error, by design | PASS (routing) |
| dispatch("restore") routes to Restore.run_cli | dispatch(["restore" | rest]), do: Restore.run_cli(rest) confirmed | Returns stub tuple — by design | PASS (routing) |
| glorbo logs produces real file reads | FileSystem.subscribe wired; File.stream! confirmed | Real tail implementation, not stub | PASS |
| backup/restore produce actual archives | lib/glorbo/backup.ex run_cli/1 | Returns "not implemented in Wave 0" | FAIL |

Step 7b SKIPPED for backup/restore/console/migrate — no runnable entry points for these verbs (stubs exit immediately).

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|----------|
| CLI-01 | 05-01, 05-02 | Every CLI verb works | BLOCKED | backup, restore, console, migrate, doctor --fix are stubs; 11/16 verbs implemented |
| CLI-03 | 05-01 | backup + scp + restore + doctor --fix + up reproduces functional install on fresh host | BLOCKED | backup and restore stubs; doctor --fix has empty @fixers map; portability tests remain :pending |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/glorbo/backup.ex` | 26 | `"backup: not implemented in Wave 0 (Plan 03 fills)\n"` stub | BLOCKER | backup verb non-functional |
| `lib/glorbo/restore.ex` | 24 | `"restore: not implemented in Wave 0 (Plan 03 fills)\n"` stub | BLOCKER | restore verb non-functional |
| `lib/glorbo/cli/console.ex` | 11 | `"console: not implemented in Wave 0 (Plan 03 fills)\n"` stub | BLOCKER | console verb non-functional |
| `lib/glorbo/cli/migrate.ex` | 11 | `"migrate: not implemented in Wave 0 (Plan 03 fills)\n"` stub | BLOCKER | migrate verb non-functional |
| `lib/glorbo/cli/doctor_fix.ex` | 13 | `"doctor --fix: not implemented in Wave 0 (Plan 03 fills)\n"` stub | BLOCKER | doctor --fix non-functional |
| `lib/glorbo/doctor/fixer.ex` | all | `@fixers` map is a comment marker only; no actual fixer functions | BLOCKER | doctor --fix does nothing even once routing is wired |
| `rel/vm.args.eex` | 27 | Uses `-name glorbo@127.0.0.1` but plan must_have specified `-sname glorbo@127.0.0.1` | WARNING | WR-09 deviation intentional and documented in file; -name is correct for full-name distribution; functionally correct but deviates from plan contract |
| `test/integration/portability_test.exs` | module | `@moduletag :pending` | BLOCKER | Portability scenario never exercised |
| `test/integration/backup_restore_roundtrip_test.exs` | module | `@moduletag :pending` | BLOCKER | Same-host roundtrip never exercised |
| `test/integration/doctor_fix_test.exs` | module | `@moduletag :pending` | BLOCKER | doctor --fix integration never exercised |

### Human Verification Required

#### 1. glorbo console remote shell

**Test:** With `glorbo up` running in terminal 1, run `glorbo console` in terminal 2. Execute `Glorbo.Doctor.run_checks()` in the remote shell.
**Expected:** iex --remsh connects to glorbo@127.0.0.1; doctor output matches what the main node reports.
**Why human:** Requires a compiled Burrito release and a running daemon; cannot be scripted hermetically.

#### 2. glorbo up / status / down smoke test

**Test:** Build with `mix release --overwrite`. Run `./glorbo up`, poll `./glorbo status` until exit 0, run `./glorbo down`, confirm `./glorbo status` exits 3.
**Expected:** Full lifecycle round-trip; pidfile appears and disappears; port 4000 binds and unbinds.
**Why human:** `test/integration/up_down_status_test.exs` skips gracefully without the binary; CI must build first. User confirmed 582/582 tests pass but integration binary-dependent test is always skipped in that count.

#### 3. vm.args -name vs -sname (WR-09)

**Test:** Run `./glorbo up`; inspect the BEAM node name with `Node.self()` from `./glorbo console`.
**Expected:** Node name is `glorbo@127.0.0.1` (long-name -name form, not sname+hostname concatenation). Plan 01 must_have required `-sname glorbo@127.0.0.1` but the implementation uses `-name glorbo@127.0.0.1` per WR-09 correction. Verify the console connection works.
**Why human:** Node distribution correctness requires a running release; cannot verify statically.

---

## Gaps Summary

Phase 05 delivered two of its three planned waves. Plan 01 (Wave 0 scaffolding) and Plan 02 (lifecycle + scaffolding + logs) are complete: 11 of the 16 DESIGN.md §10 verbs are fully implemented with real logic, 52 new test assertions, and the test harness (CLICase + PortabilityFixtures) is in place.

**Plan 03 was never written.** The five verbs it was supposed to fill — `backup`, `restore`, `console`, `migrate`, and `doctor --fix` — remain Wave-0 stubs. This directly blocks both roadmap success criteria (CLI-01 requires all verbs; CLI-03 requires backup + restore + doctor --fix end-to-end). The portability integration tests (`portability_test.exs`, `backup_restore_roundtrip_test.exs`, `doctor_fix_test.exs`) are scaffolded but remain `:pending`.

The vm.args.eex deviation from `-sname` to `-name` (WR-09) is intentional and documented in the file; it improves correctness (short-name + hostname concatenation is wrong for a fixed loopback node) and is not a blocker, but requires human verification to confirm the console connection works.

**Root cause of all gaps:** Missing Plan 03. A single plan covering backup/restore (`:erl_tar`), restore chain (migrate + reindex + doctor --fix), console (remsh Port.open), migrate (Ecto.Migrator), and the Fixer registry would close all 3 failed truths.

---

_Verified: 2026-04-16T17:00:00Z_
_Verifier: Claude (gsd-verifier)_
