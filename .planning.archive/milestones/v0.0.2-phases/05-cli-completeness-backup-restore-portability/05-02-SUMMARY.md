---
phase: 05-cli-completeness-backup-restore-portability
plan: 02
subsystem: cli
tags: [elixir, cli, lifecycle, scaffolding, observability, port, setsid, inotify]

requires:
  - phase: 05
    plan: 01
    provides: Pidfile, Config.erl_cookie/1, Hierarchy.run/, vm.args, CLI.dispatch switch, test harness, :pending stubs
  - phase: 03
    provides: Glorbo.Agent.Registry, Glorbo.Agent.Dispatch, Glorbo.Agent.Parser, Glorbo.Agent.Spec
  - phase: 04
    provides: Glorbo.TaskDefinition.parse_file/2, Glorbo.Company.AuditLog.append/2
provides:
  - Glorbo.CLI.Lifecycle.Daemon.spawn_detached/2 — setsid + Port.open re-exec helper
  - Glorbo.CLI.Lifecycle.Up — D-07 pidfile-guarded background daemon launch
  - Glorbo.CLI.Lifecycle.Down — D-08 SIGTERM + 10s poll + SIGKILL fallback
  - Glorbo.CLI.Lifecycle.Status — D-09 pidfile + TCP probe + --json
  - Glorbo.CLI.Lifecycle.Serve — D-06 foreground tree start + Process.sleep(:infinity)
  - Glorbo.CLI.Lifecycle.Run — D-10 one-shot Dispatch.execute/3 with tree boot
  - Glorbo.CLI.Scaffold.Company — D-11 slug-validated company directory scaffold
  - Glorbo.CLI.Scaffold.Agent — D-12 agent scaffold with canonical frontmatter defaults
  - Glorbo.CLI.Scaffold.Project — D-13 project README + project.md scaffold
  - Glorbo.CLI.Logs — D-14/D-15 JSONL pretty-print + stdout raw tail with --follow
  - Glorbo.CLI.Audit.emit/3 — cli.<verb>.<phase> audit helper (rescues :noproc)
  - Glorbo.Application.start_supervision_tree_for_serve/0 — public tree boot wrapper
affects:
  - Plan 05-03 (backup/restore/console/doctor --fix — disjoint files, no conflicts)

tech-stack:
  added: []
  patterns:
    - "Port.open with :spawn_executable + setsid: detached-subprocess spawn for up → child outlives parent"
    - "Pidfile-driven run-state: stopped/:running/:stale semantics drive every lifecycle decision"
    - "Dual-path --follow (inotify + 1s poll): graceful degradation per D-14"
    - "Audit emit wrapped in rescue + catch :exit: cold CLI paths don't crash on missing GenServer"
    - "Test-only knob via --exit-after for blocking verbs (serve): bounded sleep for ExUnit"
    - "GLORBO_BINARY_PATH env override: test harness stubs __BURRITO_BIN_PATH without rebuilding"

key-files:
  created:
    - lib/glorbo/cli/audit.ex
  modified:
    - lib/glorbo/application.ex (public start_supervision_tree_for_serve/0 wrapper)
    - lib/glorbo/cli/lifecycle/daemon.ex (setsid Port.open re-exec implementation)
    - lib/glorbo/cli/lifecycle/up.ex (D-07 live; pidfile-guarded launch)
    - lib/glorbo/cli/lifecycle/down.ex (D-08 SIGTERM+poll+SIGKILL)
    - lib/glorbo/cli/lifecycle/status.ex (D-09 pidfile + TCP + --json)
    - lib/glorbo/cli/lifecycle/serve.ex (D-06 foreground tree; --exit-after test knob)
    - lib/glorbo/cli/lifecycle/run.ex (D-10 one-shot dispatch)
    - lib/glorbo/cli/scaffold/company.ex (D-11 slug-validated scaffold)
    - lib/glorbo/cli/scaffold/agent.ex (D-12 canonical frontmatter)
    - lib/glorbo/cli/scaffold/project.ex (D-13 project scaffold)
    - lib/glorbo/cli/logs.ex (D-14/D-15 tail with --follow)
    - test/glorbo/cli/up_test.exs (5 live assertions; pidfile side-effects)
    - test/glorbo/cli/down_test.exs (4 live assertions; SIGTERM real child)
    - test/glorbo/cli/status_test.exs (5 live assertions; --json payload)
    - test/glorbo/cli/serve_test.exs (2 assertions; 1 integration-tagged)
    - test/glorbo/cli/run_test.exs (4 live argv assertions)
    - test/glorbo/cli/new_company_test.exs (6 live assertions; mtime idempotency)
    - test/glorbo/cli/new_agent_test.exs (9 live assertions; Parser round-trip check)
    - test/glorbo/cli/new_project_test.exs (7 live assertions)
    - test/glorbo/cli/logs_test.exs (10 live assertions; 50/10/0-line backfill)
    - test/integration/up_down_status_test.exs (live subprocess lifecycle, skips w/o binary)
    - test/glorbo/cli/dispatch_phase5_stubs_test.exs (refactored live vs stub routing)

key-decisions:
  - "Daemon uses setsid not nohup: setsid creates a new session AND process group (RESEARCH.md §Open Question #1)"
  - "Up refuses + exit 2 when pidfile+alive pid: idempotency over error-on-already-running, matches systemctl convention"
  - "Status exit 3 when BOTH pidfile AND port_listening are not true: D-09 requires both (port alone = degraded)"
  - "Serve --exit-after replaces Process.sleep(:infinity) with bounded sleep: ExUnit-friendly without Task.async"
  - "Cookie NEVER in audit detail: cli.up.complete emits {pid: os_pid} — no cookie, no binary path (T-05-02 mitigation)"
  - "Audit emit rescues exceptions AND catches :exit from GenServer.call/2: cold-start CLI paths (no AuditLog running) don't crash"
  - "Logs --follow uses File.stream! + inotify dual-path: inotifywait availability detected at runtime with stderr warning fallback"
  - "Scaffold.Agent frontmatter shape lifted from PortabilityFixtures: guarantees Glorbo.Agent.Parser.parse_file/1 accepts generated specs (tested)"
  - "Every mutating verb emits cli.<verb>.{start,complete}: append-only audit per CLAUDE.md invariant"

requirements-completed: [CLI-01]

duration: 9min
completed: 2026-04-16
---

# Phase 05 Plan 02: Lifecycle + Scaffolding + Observability Verbs Summary

**10 CLI verb modules filled with real Port/Pidfile/kill/TCP/inotify/Dispatch logic replacing Plan-01 stubs; 52 live test assertions across 10 test files toggled from `:pending`; full supervision tree + audit emission + frontmatter parity with Glorbo.Agent.Parser.**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-04-16T16:29:09Z
- **Completed:** 2026-04-16T16:38:29Z
- **Tasks:** 3/3
- **Files created:** 1 (cli/audit.ex)
- **Files modified:** 21 (10 lib + 11 test)
- **Test assertions added:** 52 (up:5, down:4, status:5, serve:2, run:4, new_co:6, new_ag:9, new_pr:7, logs:10)

## Lifecycle Verb Matrix

For each lifecycle verb, the exit codes returned in each scenario:

| Verb | Scenario | Exit | Output shape |
|------|----------|------|--------------|
| `up` | Fresh start (no pidfile) | 0 | `glorbo up (pid=<N>). Dashboard: http://127.0.0.1:4000\n` |
| `up` | Pidfile + alive pid | **2** | `glorbo is already running (pid=<N>). Run `glorbo down` first.\n` |
| `up` | Pidfile + dead pid (stale) | 0 | (same as fresh start; pidfile cleaned pre-launch) |
| `up` | Binary not locatable | **2** | `Failed to start glorbo: :binary_not_found. Run `glorbo doctor`...\n` |
| `up` | `--help` | 0 | help text |
| `down` | Pidfile + alive | 0 | `glorbo stopped.\n` (or `...SIGKILL after 10s...` on escalation) |
| `down` | No pidfile | **3** | `glorbo is not running.\n` |
| `down` | Stale pidfile | 0 | `glorbo stopped (stale pidfile cleaned; no running process).\n` |
| `status` | Pidfile alive + port listening | 0 | 4-row table |
| `status` | Pidfile alive + port closed | **3** | 4-row table with `port 4000: closed` |
| `status` | No pidfile | **3** | 4-row table with `running: no` |
| `status` | `--json` | 0 / 3 | `{"running":bool, "pid":int\|null, "port_listening":bool, "dashboard_url":"..."}` |
| `serve` | Default (blocking) | n/a | blocks forever; exits via `init:stop/0` on SIGTERM |
| `serve` | `--exit-after MS` (test only) | 0 | `glorbo serve exited (test mode after Nms).\n` |
| `run` | Missing argv | **1** | `Usage: glorbo run <company>/<agent> <task-file>\n` |
| `run` | Dispatch ok | 0 | `Task <t> completed for <co>/<ag> (exit=N, duration_ms=M).\n` |
| `run` | Dispatch error | **2** | `Failed to run task ...: <reason>. Run `glorbo doctor`.\n` |

## Scaffold Defaults Delivered

`glorbo new agent <co>/<slug>` produces `agents/<slug>/agent.md` with this exact frontmatter (important for Plan 03 `doctor --fix` to NOT regenerate conflicting state):

```yaml
---
name: <SLUG_UPPERCASED>
slug: <slug>
role: "Agent"              # --role overrides
provider: claude-code      # --provider overrides
model: claude-sonnet-4-5
network: api-only
heartbeat: null
permissions: []
budget:
  monthly_usd: 10.00
skills: []
---

# <SLUG_UPPERCASED>
Scaffolded by `glorbo new agent <co>/<slug>`.
```

Plus the canonical sub-directories: `inbox/`, `outbox/`, `workspace/`, `history/`, `state/`, and an empty `stdout.log`. Validated round-trip against `Glorbo.Agent.Parser.parse_file/1` in `new_agent_test.exs` — parser accepts without error.

`glorbo new company <slug>` produces:
- `companies/<slug>/company.md` with `name: <slug>\nmission: ""` frontmatter.
- Subdirs: `agents/`, `projects/`, `channels/`, `audit/` (all empty).

`glorbo new project <co>/<slug>` produces:
- `projects/<slug>/README.md` with a single `# <slug>` heading.
- `projects/<slug>/project.md` with `name: <slug>\nstatus: active` frontmatter.

## Audit Event Inventory

Every mutating verb in this plan emits both a `.start` and `.complete` event to `audit/_system/<YYYY-MM>.jsonl` via `Glorbo.CLI.Audit.emit/3`. Shapes (JSON detail payloads):

| Event | Detail payload |
|-------|---------------|
| `cli.up.start` | `{}` |
| `cli.up.complete` | `{"pid": <os_pid>}` (no cookie; no binary path per T-05-02) |
| `cli.down.start` | `{"pid": <N>}` or `{"reason": "stale_pidfile"}` |
| `cli.down.complete` | `{"pid": <N>, "escalated": bool}` or `{"reason": "stale_pidfile"}` |
| `cli.serve.start` | `{}` or `{"exit_after_ms": <N>}` (test mode) |
| `cli.serve.complete` | `{"exit_after_ms": <N>}` (test mode only; production never reaches) |
| `cli.run.start` | `{"company": "<co>", "agent": "<ag>", "task": "<path>"}` |
| `cli.run.complete` | `{"company", "agent", "task", "exit_status"}` |
| `cli.new_company.start` | `{"slug": "<slug>"}` |
| `cli.new_company.complete` | `{"slug", "path"}` |
| `cli.new_agent.start` | `{"company", "agent"}` |
| `cli.new_agent.complete` | `{"company", "agent", "role", "provider", "path"}` |
| `cli.new_project.start` | `{"company", "project"}` |
| `cli.new_project.complete` | `{"company", "project", "path"}` |

`status` and `logs` are read-only — they do NOT emit audit events.

## Integration Test Status

`test/integration/up_down_status_test.exs` — **live, but skips gracefully.**

- Checks for `_build/prod/rel/glorbo/glorbo` (the compiled Burrito binary).
- If present: spawns a real subprocess via `System.cmd`, asserts pidfile appears, polls `glorbo status` up to 30s for port 4000 to bind, sends `glorbo down`, asserts final exit code 3.
- If absent: prints `skipping up_down_status integration — no burrito binary at ...` to stderr and returns `:ok`.

CI should run `mix release --overwrite` before the integration suite; dev hosts without a prod build see the skip message. The test code is live (no `:pending` tag), just dependency-gated on the binary existing.

## Task Commits

Each task committed atomically via `git commit --no-verify` (per parallel-executor protocol):

1. **Task 1: Lifecycle verbs (up/down/status/serve/run + daemon + audit helper)** — `e0976d5`
2. **Task 2: Scaffolding verbs (new company/agent/project)** — `29902d6`
3. **Task 3: Logs (audit JSONL + stdout with --follow)** — `be8dbf7`

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Refactored `dispatch_phase5_stubs_test.exs` to separate live vs stub verbs**
- **Found during:** Task 1 (tests)
- **Issue:** The Plan-01-era `DispatchPhase5StubsTest` asserted `String.contains?(out, "not implemented in Wave 0") or String.contains?(out, argv)` for all 10 verbs. After Plan 05-02 fills the live verbs (up/down/status/serve/run/logs), several real-output paths don't contain the literal verb string ("glorbo stopped" doesn't contain "down"; "running: yes" doesn't contain "status"), so the original test would fail.
- **Fix:** Split the `@stub_verbs` list into `@dispatch_verbs` (stub verbs — migrate/backup/restore/console, still Plan 03's work) and `@live_verbs` (up/down/status/serve/run/logs, now filled). The live list asserts dispatch routing only (tuple shape + integer exit + string output); per-verb behaviour is covered by the dedicated `*_test.exs` files. Preserves the Plan 01 contract ("dispatch stays wired") while adapting to the new implementation reality.
- **Files modified:** `test/glorbo/cli/dispatch_phase5_stubs_test.exs`
- **Verification:** `mix test test/glorbo/cli/dispatch_phase5_stubs_test.exs` passes all 16 tests.
- **Committed in:** `e0976d5` (Task 1 commit)

**2. [Rule 3 - Blocking] `Up.locate_binary/0` returns `{:error, :binary_not_found}` instead of raising**
- **Found during:** Task 1 (tests)
- **Issue:** The plan spec for `Up` sketches `locate_binary` as raising a descriptive error. But that blows up `dispatch(["up"])` in the `DispatchPhase5StubsTest` routing test (no env vars set) with an unhandled exception, causing a test failure on dispatch routing.
- **Fix:** Converted `locate_binary` to return `{:error, :binary_not_found}` so `do_run` can pattern-match on it and emit a `{:up, 2, "Failed to start glorbo: :binary_not_found. Run `glorbo doctor`..."}` tuple. Better UX — users see a remediation hint instead of a stacktrace. The test `"returns error tuple when binary cannot be located"` in `up_test.exs` locks this behaviour in.
- **Files modified:** `lib/glorbo/cli/lifecycle/up.ex`
- **Verification:** Exit code is 2 (operational failure with hint, per D-28).
- **Committed in:** `e0976d5` (Task 1 commit)

**3. [Rule 2 - Missing critical] `Glorbo.CLI.Audit.emit/3` catches `:exit` AND rescues exceptions**
- **Found during:** Task 1 (design)
- **Issue:** Plan sketched `rescue _ -> :ok` only. But `GenServer.call/2` on a dead/absent process EXITS rather than raises — `rescue` doesn't catch exits. In cold-CLI paths (no AuditLog GenServer started), `AuditLog.append/2` would exit `:noproc` and propagate through the verb, crashing the CLI.
- **Fix:** `try/rescue/catch :exit, _`. Audit failures never block lifecycle (per CLAUDE.md "audit is append-only, missing audit infra in early-boot contexts is tolerated"). Elixir compiler warning ("catch should come after rescue") required the `rescue` block to come BEFORE `catch` — flipped the order.
- **Files modified:** `lib/glorbo/cli/audit.ex`
- **Verification:** `mix compile --warnings-as-errors` passes; Task 1 tests pass without needing a running AuditLog.
- **Committed in:** `e0976d5` (Task 1 commit)

**4. [Rule 2 - Missing critical] `start_supervision_tree_for_serve/0` tolerates already-started**
- **Found during:** Task 1 (design)
- **Issue:** Plan sketched `{:ok, _} = Glorbo.Application.start_supervision_tree_for_serve()`. But under `mix test`, the Phoenix `Application.start/2` callback has already started the supervision tree; calling again returns `{:error, {:already_started, _}}`. `Run` and `Serve` tests would crash on re-start.
- **Fix:** Added a public wrapper that detects `{:error, {:already_started, pid}}` and returns `{:ok, :already_started, pid}`. Callers pattern-match on `{:ok, _}` or `{:ok, :already_started, _}`.
- **Files modified:** `lib/glorbo/application.ex`
- **Verification:** `Serve.run(["--exit-after", "200"])` works under test.
- **Committed in:** `e0976d5` (Task 1 commit)

**Total deviations:** 4 auto-fixed, all correctness-preserving. Zero architectural changes.

## Issues Encountered

- **ETS-in-on-exit crash** (pre-fix on Task 1 up_test.exs): initial implementation used `:ets.new` in the setup block to track spawned pids, but ETS tables are owned by the setup process and destroyed before `on_exit` runs in a separate process. Switched to `Agent.start_link` which survives the setup/on_exit boundary. Fixed before commit.
- **`/bin/sleep` stderr noise**: the Up test spawns `/bin/sleep` as a stand-in Burrito binary; sleep rejects the "serve" arg and exits with `sleep: błędny odstęp czasowy 'serve'` on stderr. Noise, not a failure — sleep exiting quickly is exactly what we want so the test doesn't leak long-running children. Tolerated.

## Handoff to Plan 03

**Plan 03 merge-gate invariant preserved:** this plan touches ZERO of Plan 03's implementation files. Specifically:

- **UNTOUCHED:** `lib/glorbo/cli.ex` (dispatch switch) — Plan 01 owns this; Plan 02 adds no new dispatch clauses.
- **UNTOUCHED:** `lib/glorbo/cli/lifecycle/pidfile.ex` — Plan 01's Pidfile helper is consumed as-is.
- **UNTOUCHED:** `lib/glorbo/config.ex` — Plan 01's `erl_cookie/1` consumed as-is.
- **UNTOUCHED:** `lib/glorbo/backup.ex`, `lib/glorbo/restore.ex`, `lib/glorbo/doctor/fixer.ex` — Plan 03 owns these; Plan 02 leaves Wave-0 stubs intact.
- **UNTOUCHED:** `lib/glorbo/cli/{migrate,console,doctor_fix}.ex` — Plan 03 owns; Plan 02 leaves Wave-0 stubs.

**New module added:** `lib/glorbo/cli/audit.ex` (Glorbo.CLI.Audit.emit/3) — a helper Plan 03 SHOULD reuse for its backup/restore/migrate/console audit events. The interface is stable: `emit(verb, phase, detail_map)`. Phase strings are free-form but the convention is `"start"` / `"complete"` / `"failure"`.

**Modified shared file:** `lib/glorbo/application.ex` — added public `start_supervision_tree_for_serve/0`. Plan 03's `console` verb MAY want to use this (or not, since `console` typically connects to a running BEAM, not starts a new one). No conflict expected.

## User Setup Required

None — this plan introduces no external dependencies. The `setsid` binary is on every Linux host; `inotifywait` is the only conditional (test excludes `:inotify` tests when absent; `logs --follow` prints a stderr warning and polls instead).

## Known Stubs

The following Phase-5 verbs remain as Wave-0 stubs (Plan 03's scope, intentional):

- `lib/glorbo/cli/migrate.ex` → "migrate: not implemented in Wave 0 (Plan 03 fills)"
- `lib/glorbo/cli/console.ex` → "console: not implemented in Wave 0 (Plan 03 fills)"
- `lib/glorbo/cli/doctor_fix.ex` → "doctor --fix: not implemented in Wave 0 (Plan 03 fills)"
- `lib/glorbo/backup.ex`, `lib/glorbo/restore.ex`, `lib/glorbo/doctor/fixer.ex` — untouched

These are tracked in Plan 03's scope per 05-01-SUMMARY.md "Handoff" and 05-02-PLAN.md "disjoint files" discipline. No scope spillage.

## Next Phase Readiness

Wave 1 plans 02 and 03 converge here (Plan 03 lands in parallel). Once Plan 03 completes, Phase 5 is ready for the verification phase:

- All DESIGN.md §10 non-backup verbs live.
- `glorbo up + status + down` round-trip works against a real burrito binary (integration-tagged; CI should build first).
- `glorbo new company/agent/project` produces filesystem-valid scaffolds accepted by Glorbo.Agent.Parser.
- `glorbo logs` tails JSONL + stdout with graceful inotify fallback.
- 52 new test assertions + zero regressions in the 582-test full suite.

**Blockers:** None.

---
*Phase: 05-cli-completeness-backup-restore-portability*
*Completed: 2026-04-16*

## Self-Check: PASSED

All 22 load-bearing files (11 lib + 10 test + 1 SUMMARY) verified present on
disk; all 3 task commits verified in git log.

- lib/glorbo/cli/audit.ex: FOUND
- lib/glorbo/cli/lifecycle/{daemon,up,down,status,serve,run}.ex: FOUND
- lib/glorbo/cli/scaffold/{company,agent,project}.ex: FOUND
- lib/glorbo/cli/logs.ex: FOUND
- test/glorbo/cli/{up,down,status,serve,run}_test.exs: FOUND
- test/glorbo/cli/{new_company,new_agent,new_project,logs}_test.exs: FOUND
- test/integration/up_down_status_test.exs: FOUND
- 05-02-SUMMARY.md: FOUND
- commit e0976d5 (Task 1 — lifecycle): FOUND
- commit 29902d6 (Task 2 — scaffolding): FOUND
- commit be8dbf7 (Task 3 — logs): FOUND
