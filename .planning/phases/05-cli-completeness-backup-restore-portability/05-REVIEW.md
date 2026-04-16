---
status: issues_found
phase: 05
phase_name: cli-completeness-backup-restore-portability
depth: standard
files_reviewed: 23
reviewed: 2026-04-16
findings:
  critical: 0
  warning: 9
  info: 7
  total: 16
---

# Phase 5 Code Review

**Review mode:** standard
**Files reviewed:** 23 (production) + 20 (tests, scanned)

## Summary

Phase 5 delivers the CLI lifecycle surface (`up`/`down`/`status`/`serve`/`run`/`new`/`logs` live; `migrate`/`backup`/`restore`/`console`/`doctor --fix` are documented Wave-0 stubs). The live verbs are well-tested and the pidfile atomicity (temp+rename+chmod 0600), cookie handling, and setsid detachment are solid. Slug regex guards `new company|agent|project` against path-traversal cleanly.

Key concerns below focus on process lifecycle edge cases (pidfile race after daemon spawn, TOCTOU on `read!`), logs-follow reliability (relative-path binding + double `File.stat!`), and a pure-dispatch contract violation in `glorbo logs`. No hardcoded secrets, injection vectors, or audit-log integrity breaches found. Kernel/filesystem invariants from `CLAUDE.md` are respected.

---

## Warnings

### WR-01: `glorbo logs` breaks the pure-dispatch contract by printing directly

**File:** `lib/glorbo/cli/logs.ex:60-62, 82-84`
**Issue:** `Glorbo.CLI.dispatch/1` is documented as pure (`CLI` moduledoc: *"The caller is responsible for printing `output` and halting"*). `Glorbo.Application.run_cli_and_halt/1` does exactly that: `IO.puts(output)` once. But `tail_audit` / `tail_stdout` iterate `Enum.each(&IO.puts/1)` / `Enum.each(&IO.write/1)` inside the dispatch call, then return `{:logs, 0, ""}`. Tests must wrap in `capture_io/1`.
**Fix:** Build the output string in memory and return it in the tuple. Only `--follow` mode needs live IO.

### WR-02: `Logs.follow_inotify` pattern match assumes absolute paths

**File:** `lib/glorbo/cli/logs.ex:107-115`
**Issue:** `FileSystem.start_link(dirs: [Path.dirname(path)])` — if `GLORBO_HOME` is relative (e.g., `./.glorbo`), `path` is relative, and the `file_system` library emits absolute paths in `{:file_event, _pid, {path, events}}`. The `listen_loop` pattern `{^path, events}` then never matches.
**Fix:** Normalize `path` to absolute with `Path.expand/1` before opening the watcher.

### WR-03: `Logs.handle_modification` races File.stat! against file rotation

**File:** `lib/glorbo/cli/logs.ex:140, 152`
**Issue:** Two unguarded `File.stat!` calls bracket the read. If the audit file rotates (month rollover) between them, the second raises `File.Error`. Under inotify coalescing, `[:modified, :closed]` can arrive in one tick.
**Fix:** Guard both `File.stat!` calls; treat `{:error, :enoent}` as a rotation signal.

### WR-04: `Up.start_daemon` orphans the daemon if Pidfile.write! fails

**File:** `lib/glorbo/cli/lifecycle/up.ex:60-74`
**Issue:** The `with` chain spawns the detached daemon BEFORE writing the pidfile. If `Pidfile.write!/2` raises (disk full, EACCES), the daemon is already running under `setsid` but no pidfile records its pid — hidden orphan BEAM.
**Fix:** `try/rescue` `Pidfile.write!` and SIGKILL the orphaned pid on failure, returning `{:up, 2, _}`.

### WR-05: `Daemon.spawn_detached` does not validate the binary exists or is executable

**File:** `lib/glorbo/cli/lifecycle/daemon.ex:51-78`
**Issue:** `Port.open/2` will pass a non-existent/non-executable `binary_path` through to `setsid`. `setsid` exec-fails silently; `Port.info(port, :os_pid)` still returns the short-lived setsid pid, which gets written to the pidfile.
**Fix:** Guard at entry with `File.exists?/1` + mode-bits check before spawning.

### WR-06: `Down.stop_running` can SIGKILL a wrong pid after PID reuse

**File:** `lib/glorbo/cli/lifecycle/down.ex:58-79`
**Issue:** Between SIGTERM and the 10s SIGKILL escalation, the original pid may exit and the OS may reuse it for an unrelated process. Low probability on Linux (high `pid_max`), but the race exists.
**Fix:** Re-read the pidfile before escalating; skip SIGKILL if pidfile is gone or holds a different pid.

### WR-07: `Config.write_default!` and `erl_cookie/1` write-then-chmod race

**File:** `lib/glorbo/config.ex:126-128, 197-199`
**Issue:** `File.write!` followed by `File.chmod!(path, 0o600)` leaves a window where the file has umask-default mode (0644/0664). A concurrent local user can read `secret_key_base`/`erl_cookie` in that window.
**Fix:** Write to a tmp file, chmod the tmp, then atomic `File.rename!/2` (same pattern as `Pidfile.write!/2`).

### WR-08: `Config.erl_cookie` file-absent race between `File.exists?` and `File.read`

**File:** `lib/glorbo/config.ex:160-177`
**Issue:** Classic TOCTOU — `unless File.exists?(path), do: write_default!(path)` followed by `File.read(path)`. Concurrent `glorbo init --force` removal returns `:enoent` and falls to `{:error, :config_parse}`.
**Fix:** Fold into `with`/`case` that handles `:enoent` explicitly by calling `write_default!/1` and recursing.

### WR-09: `rel/vm.args.eex` — `-sname glorbo@127.0.0.1` is likely malformed

**File:** `rel/vm.args.eex:16`
**Issue:** `-sname` expects an unqualified short name; the BEAM appends the host automatically. `-sname glorbo@127.0.0.1` either gets rejected or creates a node named `glorbo@127.0.0.1@<hostname>`. `Console.help_text/0` expects long-name distribution.
**Fix:** Change to `-name glorbo@127.0.0.1`; verify manually with `iex --name console@127.0.0.1 --cookie <cookie> --remsh glorbo@127.0.0.1` against a running `glorbo up`.

---

## Info

### IN-01: `Glorbo.Application.run_cli_and_halt/1` ignores the verb atom

**File:** `lib/glorbo/application.ex:104`
**Issue:** `{_verb, exit_code, output} = Glorbo.CLI.dispatch(argv)` — verb discarded. Could help debugging via `Logger.debug/1` or telemetry span.

### IN-02: `Down.wait_for_exit` always returns `escalated?: false`

**File:** `lib/glorbo/cli/lifecycle/down.ex:63, 84-95`
**Issue:** The tuple's `escalated?` element is dead state — the `:running` branch re-assigns at call site, other branches always `false`.
**Fix:** Drop the second tuple element; return `:running | :stopped | :stale` directly.

### IN-03: `Config.write_cookie!/5` ignores the `_body` parameter

**File:** `lib/glorbo/config.ex:184`
**Issue:** Minor API bloat — `_body` unused; the function operates on `content` directly.
**Fix:** Drop `meta`/`body`, pass `has_cookie?` boolean.

### IN-04: `Logs.resolve_audit_path_for_follow(path, :audit)` underuses `path`

**File:** `lib/glorbo/cli/logs.ex:203-209`
**Issue:** Only `Path.dirname(path)` is consumed; `:stdout` variant ignores `path` entirely.
**Fix:** Rename or inline the dirname logic.

### IN-05: `Scaffold.Agent` and `Scaffold.Project` echo user slug in error messages

**File:** `lib/glorbo/cli/scaffold/agent.ex:48-50`, `project.ex:29-31`
**Issue:** `"Invalid slug in '#{co_slash_ag}'."` — user input not sanitized. Terminal control sequences would execute on print. Low severity (local attacker with CLI access), but worth sanitizing.
**Fix:** Use `inspect/1` in the message.

### IN-06: Wave-0 stub modules lack `@behaviour` but are consistently tagged

**Files:** `backup.ex`, `restore.ex`, `cli/migrate.ex`, `cli/console.ex`, `cli/doctor_fix.ex`, `doctor/fixer.ex`
**Issue:** Each returns `{verb, 0, "not implemented in Wave 0"}`. Dispatch stub tests assert on this string; Plan 03 (future) must update them when filling modules.
**Fix:** None needed at Wave 0 — documentation for future work.

### IN-07: `CLI.result()` type declares exit codes `0 | 1 | 2 | 3` but `init` passes arbitrary codes

**File:** `lib/glorbo/cli.ex:40, 65`
**Issue:** `@type result :: {verb(), 0 | 1 | 2 | 3, String.t()}` but `dispatch(["init" | rest])` returns `{:init, summary.exit_code, output}` with `summary.exit_code` from `Glorbo.Init.run/1`. Dialyzer warning if Init ever returns 4+.
**Fix:** Widen spec to `non_neg_integer()` or clamp at compile time.

---

_Reviewed: 2026-04-16_
_Reviewer: gsd-code-reviewer (standard depth)_
