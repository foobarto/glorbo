---
phase: 05
fixed_at: 2026-04-16
review_path: .planning/phases/05-cli-completeness-backup-restore-portability/05-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 5: Code Review Fix Report

**Fixed at:** 2026-04-16
**Source review:** `.planning/phases/05-cli-completeness-backup-restore-portability/05-REVIEW.md`
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (all Warning; 0 Critical)
- Fixed: 9
- Skipped: 0

Full `mix test` run post-fix: **582 tests, 0 failures** (70 excluded tags: `:inotify`, `:integration`, `:pending`).

## Fixed Issues

### WR-01: `glorbo logs` breaks the pure-dispatch contract by printing directly

**Files modified:** `lib/glorbo/cli/logs.ex`, `test/glorbo/cli/logs_test.exs`
**Commit:** `6a3911e`
**Applied fix:** Rewrote `tail_audit/2` and `tail_stdout/3` to build the output string in memory and return it in the `{:logs, 0, output}` tuple. `--follow` mode still emits backfill live via `IO.write/1` then streams ongoing events (documented behaviour: only `--follow` needs live IO). Updated `logs_test.exs` to assert directly on the tuple output and dropped the `import ExUnit.CaptureIO` / `capture_io/1` wrappers.

### WR-02: `Logs.follow_inotify` pattern match assumes absolute paths

**Files modified:** `lib/glorbo/cli/logs.ex`
**Commit:** `81d7298`
**Applied fix:** Added `Path.expand/1` at entry of `follow_inotify/2` to normalize the watch target to absolute before `FileSystem.start_link/1`, matching the absolute paths the `file_system` library emits in `{:file_event, _, {path, events}}` messages. The `listen_loop` pattern `{^path, events}` now fires regardless of whether `GLORBO_HOME` is relative (`./.glorbo`) or absolute.

### WR-03: `Logs.handle_modification` races `File.stat!` against file rotation

**Files modified:** `lib/glorbo/cli/logs.ex`
**Commit:** `180f80c`
**Applied fix:** Rewrote `handle_modification/3` with `File.stat/1` (non-bang) guarded on both calls. Introduced `handle_rotation/2` helper that re-resolves the audit path (month rollover) on `:enoent`. Other `{:error, _}` cases loop back with the previous `last_size` to be resilient to transient FS errors.

### WR-04: `Up.start_daemon` orphans the daemon if `Pidfile.write!` fails

**Files modified:** `lib/glorbo/cli/lifecycle/up.ex`
**Commit:** `5859b0a`
**Applied fix:** Wrapped `Pidfile.write!/2` in `safe_pidfile_write/2`, which catches any raise and returns `{:error, {:pidfile_write, os_pid, reason}}`. Added a dedicated `else` arm that SIGKILLs the orphaned setsid-child pid and returns `{:up, 2, _}` with a clear message naming the remediation. The normal `{:error, reason}` branch is preserved for all other failure modes.

### WR-05: `Daemon.spawn_detached` does not validate the binary exists or is executable

**Files modified:** `lib/glorbo/cli/lifecycle/daemon.ex`
**Commit:** `3699f7a`
**Applied fix:** Added `validate_binary/1` at entry of `spawn_detached/2` — checks `File.exists?/1`, then a `File.stat/1` guard with a `Bitwise.band(mode, 0o111)` exec-bit check. Returns `{:error, :binary_not_found | :binary_not_executable}` instead of handing a bogus path to `setsid`'s `execve`. Refactored the setsid lookup into `find_setsid/0` so the `with` chain reads cleanly.

### WR-06: `Down.stop_running` can SIGKILL a wrong pid after PID reuse

**Files modified:** `lib/glorbo/cli/lifecycle/down.ex`
**Commit:** `5984d1f`
**Applied fix:** Before escalating to SIGKILL after the 10s SIGTERM grace, re-read the pidfile via `Pidfile.status/1` + `Pidfile.read!/1` and only kill if the pidfile still exists AND still holds the same pid we initially targeted. If the pidfile changed mid-shutdown (PID reuse scenario), treat it as "already stopped" and exit 0 with a "pidfile changed during shutdown; not escalating" note.

### WR-07: `Config.write_default!` and `erl_cookie/1` write-then-chmod race

**Files modified:** `lib/glorbo/config.ex`
**Commit:** `ddecdf8`
**Applied fix:** Extracted `atomic_write_secret!/2` helper that writes to `<path>.tmp`, chmods the tmp to `0600`, then atomically renames into place — the rename preserves the tmp's mode so the final file is `0600` from the moment it exists. Both `write_default!/1` and `write_cookie!/5` now delegate to this helper, eliminating the window where `secret_key_base` / `erl_cookie` sat at umask-default `0644`/`0664`. Matches the pattern already used in `Pidfile.write!/2`.

### WR-08: `Config.erl_cookie` file-absent race between `File.exists?` and `File.read`

**Files modified:** `lib/glorbo/config.ex`
**Commit:** `5718077`
**Applied fix:** Refactored `erl_cookie/1` to drop the `unless File.exists?(path), do: write_default!(path)` + `File.read(path)` TOCTOU pair. Switched to `case File.read(path)` with explicit `:enoent` handling that calls `write_default!/1` and recurses once (guarded by a `retried?` boolean to prevent loops on unrelated I/O failures). Extracted `handle_cookie/4` for clarity.

### WR-09: `rel/vm.args.eex` — `-sname glorbo@127.0.0.1` is likely malformed

**Files modified:** `rel/vm.args.eex`
**Commit:** `f22995a`
**Applied fix:** Changed `-sname glorbo@127.0.0.1` to `-name glorbo@127.0.0.1` (long-name distribution) to match the `iex --name console@127.0.0.1 --remsh glorbo@127.0.0.1` invocation documented in `Console.help_text/0`. BEAM requires the two ends of a distribution link to use the same name class. Added inline comment explaining the `-sname` vs `-name` distinction and the manual verification procedure.

**Note:** WR-09 is a release-binary concern — the change is inert under `mix test` / dev BEAM (which uses its own boot flags). Manual verification required post-Burrito-rebuild:
```
glorbo up
iex --name console@127.0.0.1 --cookie <cookie-from-~/.glorbo/config.md> --remsh glorbo@127.0.0.1
```

## Skipped Issues

None — all in-scope findings were fixed cleanly.

## Info Findings Not Addressed (out of scope)

IN-01 through IN-07 were flagged as `info` severity and left for a later pass:
- IN-01: `run_cli_and_halt/1` ignores verb atom — minor telemetry omission
- IN-02: `Down.wait_for_exit` dead `escalated?` tuple element — API hygiene
- IN-03: `Config.write_cookie!/5` unused `_body` parameter — API bloat
- IN-04: `resolve_audit_path_for_follow(path, :audit)` only uses dirname — naming
- IN-05: Scaffold modules echo unsanitized user slug in error messages — use `inspect/1`
- IN-06: Wave-0 stub modules lack `@behaviour` — documentation-only
- IN-07: `CLI.result()` type narrow on `init` exit codes — dialyzer-only

These can be addressed in a follow-up pass or deferred to later phases.

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
