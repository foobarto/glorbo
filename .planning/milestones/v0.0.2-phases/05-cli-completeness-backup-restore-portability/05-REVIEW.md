---
status: issues_found
phase: 05
phase_name: cli-completeness-backup-restore-portability
depth: standard
files_reviewed: 6
files_reviewed_list:
  - lib/glorbo/backup.ex
  - lib/glorbo/restore.ex
  - lib/glorbo/cli/console.ex
  - lib/glorbo/cli/migrate.ex
  - lib/glorbo/cli/doctor_fix.ex
  - lib/glorbo/doctor/fixer.ex
reviewed: 2026-04-16
findings:
  critical: 1
  warning: 7
  info: 5
  total: 13
---

# Phase 5 Code Review — Plans 05-03 / 05-04 Gap Closure

**Review mode:** standard
**Scope:** 6 production files landed by Plans 05-03 (Backup/Restore) and 05-04
(Console/Migrate/DoctorFix/Fixer). Prior review findings WR-01..WR-09 (Plans
05-01/02) are excluded from this report.

## Summary

Overall: solid implementation matching the plan summaries. Traversal guard,
WAL checkpointing, pidfile gating, cookie argv-handling (T-05-02), and the
`catch :exit` additions to Migrate are all correctly wired. Audit events
are emitted at every lifecycle boundary and never include secrets.

One **Critical** symlink-target traversal bypass exists in the restore guard
(archive entry names are checked, but `:erl_tar.table` does NOT surface
symlink link-targets — a symlink entry with link-target `../../etc/passwd`
extracts without inspection). Seven **Warnings** cover missing `catch :exit`
in `Restore.maybe_migrate`/`Fixer.safe_apply`, absent archive-bomb limits,
pidfile TOCTOU in backup, missing check→fix→recheck semantics, exit-code
miscount when fixable-but-unregistered blockers fail, silent error-swallow
in `Restore.maybe_fixer`, and `IO.puts` inside dispatch-tree functions.

---

## Critical Issues

### CR-01: Restore traversal guard misses symlink link-targets (T-05-01 bypass)

**File:** `lib/glorbo/restore.ex:129-147`
**Issue:** The guard checks entry *names* via `:erl_tar.table/2` only —
`String.starts_with?(name, "/")` and `".." in String.split(name, "/")`. It
does NOT inspect symbolic-link targets. A malicious archive can contain a
symlink entry with benign name `"foo"` but link-target
`../../../../etc/passwd`; `:erl_tar.extract/2` will create
`<base>/foo -> ../../../../etc/passwd` inside the restore root. A later
`File.read!("<base>/foo")` (e.g., reindex walking `companies/`) follows the
symlink and reads the attacker-chosen path. This is the same T-05-01 class
the guard is advertised to mitigate.
**Fix:** Either (a) pass `:erl_tar.extract` option that rejects symlinks
outright (none exists in stdlib — must walk the table manually with
`:erl_tar.open/2 + :erl_tar.read_header/1` checking `typeflag` and
`linkname`), or (b) post-extract, walk `<base>` and reject any symlink
whose `:file.read_link/1` target `Path.expand`s outside `<base>`. Minimal
patch sketch:

```elixir
defp traversal_guard(archive) do
  {:ok, fd} = :erl_tar.open(String.to_charlist(archive), [:read, :compressed])
  try do
    # Walk each header; reject if name OR linkname escapes.
    dangerous = collect_unsafe_headers(fd, [])
    if dangerous == [], do: :ok, else: {:error, {:unsafe_archive, dangerous}}
  after
    :erl_tar.close(fd)
  end
end
# collect_unsafe_headers inspects {:ok, {:header, %{name: n, linkname: l, ...}}}
```

---

## Warnings

### WR-01: `Restore.maybe_migrate` missing `catch :exit` clause

**File:** `lib/glorbo/restore.ex:174-180`
**Issue:** Only `rescue` is wired. `Ecto.Migrator.run/4` calls down into
`GenServer.call` against the Repo, which **exits** (not raises) on timeout
or `:noproc`. An uncaught exit propagates up through `Restore.run/2`,
bypassing `format_cli_result/2`, and crashes the Burrito process before
the `{:restore, 2, _}` tuple is ever returned. `Glorbo.CLI.Migrate`
(`cli/migrate.ex:45-49`) correctly catches both — this module diverged.
**Fix:** Mirror Migrate's pattern:

```elixir
try do
  _ = Ecto.Migrator.run(repo, migrations_path, :up, all: true)
  :ok
rescue
  e -> {:error, {:migrate_failed, Exception.message(e)}}
catch
  :exit, reason -> {:error, {:migrate_failed, inspect(reason)}}
end
```

### WR-02: `Fixer.safe_apply` missing `catch :exit` — Podman/HTTP exits crash orchestrator

**File:** `lib/glorbo/doctor/fixer.ex:137-141`
**Issue:** `safe_apply/2` only rescues — but `fix_podman`/`fix_ollama` call
`BinaryBootstrap.ensure_*` (shells out to podman/wget) and `fix_runtime_image`
calls `ImagePull.run` (HTTP download via Podman pull). Either can exit via
`System.cmd` crash or `GenServer.call` timeout. A single exit kills the
whole `Enum.reduce` over failing checks — subsequent fixers never run, audit
events never emit, summary never renders.
**Fix:** Add `catch :exit, reason -> {:error, {:exited, reason}}` alongside
the rescue clause. Consistent with `Restore.reindex/1` (which already does
both).

### WR-03: Backup / Restore lack archive-bomb limits

**File:** `lib/glorbo/backup.ex:166, lib/glorbo/restore.ex:149-159`
**Issue:** Neither `:erl_tar.create` nor `:erl_tar.extract` is bounded by
max-bytes or max-entries. A 10 KB tar.gz can unpack into hundreds of
gigabytes (classic zip/tar bomb). Since `glorbo restore <archive>` accepts
an argv-supplied path, a malicious local archive exhausts disk. Deployed
Director persona is root-trusted, so severity is bounded — but defence in
depth is cheap: pre-extract, sum entry sizes from `:erl_tar.table` (second
element of each header tuple) and reject over a configurable cap
(default 10 GiB covers realistic Glorbo state).
**Fix:** After `traversal_guard`, add `size_guard(archive, max: 10 * 1024 * 1024 * 1024)`
iterating `:erl_tar.foldl/3` summing header sizes. Same fold surfaces
symlink linkname targets — kills two birds (CR-01 + WR-03) with one pass.

### WR-04: `Backup.ensure_down` → `write_archive` pidfile TOCTOU

**File:** `lib/glorbo/backup.ex:52-57, 104-110`
**Issue:** `ensure_down/2` checks `Pidfile.status(base)` at step 1 of the
`with` chain. Between that check and `write_archive/2` (typically seconds
later for a cold WAL checkpoint on a multi-gig DB), another process can
`glorbo up` and begin writing. The WAL checkpoint truncates the WAL but
does not block new writers from opening the DB afterwards — the archived
`glorbo.db` then captures a half-written transaction.
**Fix:** Acquire an advisory file lock (`:file.open(pidfile, [:write, :exclusive])`
or `flock(2)` via NIF) for the duration of the archive write, OR re-check
`Pidfile.status(base)` immediately before `write_archive` and fail
`{:error, :glorbo_started_during_backup}` on mismatch. The latter is cheaper
and sufficient for the single-Director trust model.

### WR-05: `Fixer.run/1` exit-code miscount — failed blockers with no registered fixer return 0

**File:** `lib/glorbo/doctor/fixer.ex:65`
**Issue:** `exit_code = if summary.failed > 0, do: 1, else: 0`. But checks
with no registered fixer increment `skipped`, not `failed` — even when they
are `:blocker` severity (e.g., `linux_kernel`, `erts_version`, `uidmap`,
`user_namespaces`). If kernel < 5.13, `glorbo doctor --fix` prints
"no fixer registered for: linux_kernel" and exits 0, implying success.
This contradicts D-28 exit-code semantics: blocker failures must exit
non-zero.
**Fix:** Promote skipped-blocker count to the failed tally, OR preserve
the original `Doctor.exit_code(results)` semantics by re-running
`Doctor.run_checks` after repairs and returning `Doctor.exit_code` on the
fresh results. The latter also closes WR-06 (recheck missing).

### WR-06: Fixer does not implement check→fix→recheck pattern

**File:** `lib/glorbo/doctor/fixer.ex:96-135`
**Issue:** Moduledoc + DoctorFix help text both advertise "re-checks" after
repair. Actual `run_fixer/3` reports `{:ok, msg}` directly from the fixer's
return value with no verification the check now passes. If
`fix_sockets_dir` returns `{:ok, "created ... (mode 0700)"}` but an ACL
from the parent mount still blocks access, the check will fail on the next
Doctor run — yet this one reported success. For idempotent repairs
(mkdir_p, chmod) the risk is low; for `fix_runtime_image` (Podman pull)
it's non-trivial.
**Fix:** After each successful fixer, re-invoke the corresponding check
function and branch on the fresh `pass` flag. Doctor.ex already exposes
the named check functions internally — expose a per-check rechecker
`Doctor.recheck(name)` that calls just that check's fun.

### WR-07: `Restore.maybe_fixer` silently swallows all errors to `:ok`

**File:** `lib/glorbo/restore.ex:195-204`
**Issue:** The try/rescue/catch collapses every failure — including genuine
bugs in `Glorbo.Doctor.Fixer.run/1` — to `:ok`. A restored archive whose
post-extract checks all fail will nevertheless return `:ok` from
`Restore.run/2` and exit 0 from `run_cli/1`. Director sees "✓ restore
complete" and runs `glorbo up` against a broken state.
**Fix:** Return the fixer's exit-code-bearing result as `{:error, {:fixer_failed, result}}`
when `elem(result, 1) != 0` (non-zero exit). Keep the rescue/catch only
for truly exceptional conditions (process exit mid-fix), not for graceful
error tuples.

### WR-08: `Fixer.handle_check` writes to stdout from within dispatch tree

**File:** `lib/glorbo/doctor/fixer.ex:74, 79, 91, 100, 112, 123-124`
**Issue:** Six `IO.puts` calls during `handle_check`/`run_fixer` reuse the
same anti-pattern the prior review flagged (WR-01 for Logs). `Glorbo.CLI`
contract: dispatch returns the output string; `Application.run_cli_and_halt/1`
prints once. Tests must wrap this module in `capture_io` (integration test
already does — `test/integration/doctor_fix_test.exs`). More importantly,
output ordering becomes non-deterministic with audit emission and the
per-line string returned in the summary — the per-line IO.puts stream and
the `{:doctor, code, body}` output can interleave unpredictably if the
caller later wraps output.
**Fix:** Buffer lines into `acc.lines` (already done) and return them via
`format_summary/1` only. Remove the five inline `IO.puts` calls in
`handle_check`/`run_fixer`. Progress UX can be re-added later via a
`:progress` callback opt.

---

## Info

### IN-01: `Console.launch` calls `System.find_executable("iex")` twice

**File:** `lib/glorbo/cli/console.ex:73, 78`
**Issue:** Guard clause checks `is_nil(System.find_executable("iex"))`, then
the `true` branch calls `System.find_executable("iex")` again. `find_executable`
stats every PATH entry — cheap but wasteful. Not a correctness issue.
**Fix:** Bind once at the top of `launch/2`.

### IN-02: `Console.receive` lacks timeout — SIGSTOP'd child hangs forever

**File:** `lib/glorbo/cli/console.ex:86-90`
**Issue:** The `receive do {^port, {:exit_status, code}} -> ...` has no
`after` clause. A SIGSTOP'd `iex` child (or a Port crash that fails to emit
`:exit_status` — rare) deadlocks the console caller. Low severity in
practice.
**Fix:** Add `after :infinity -> ...` explicitly (documents intent) or a
generous timeout (1 hour) that returns `{:console, 124, "iex stalled\n"}`.

### IN-03: `Restore.maybe_migrate` passes `[]` to `Ecto.Migrator.run` when priv_dir missing

**File:** `lib/glorbo/restore.ex:164-175`
**Issue:** `migrations_path` falls back to empty list `[]` when `:code.priv_dir`
fails or `repo/migrations` does not exist. `Ecto.Migrator.run(repo, [], :up, all: true)`
is valid (empty migration list → no-op) but relies on an undocumented
overload. A future Ecto version that tightens the path arg to `binary()`
only would crash silently — and the silent-pass would mask a real
deployment bug (bad priv_dir in the release).
**Fix:** Mirror `Glorbo.CLI.Migrate.migrations_path/0` (cli/migrate.ex:53-62)
— return `{:error, msg}` on missing priv_dir, bubble up as
`{:error, {:migrations_dir_missing, _}}`. Restore should fail loudly, not
skip migrations.

### IN-04: `Backup.default_output_path` uses microsecond-precision timestamp in filename

**File:** `lib/glorbo/backup.ex:191-197`
**Issue:** `DateTime.to_iso8601()` emits microseconds by default
(`2026-04-16T17:19:22.123456Z` → `2026-04-16T17-19-22.123456Z` after
colon replacement). The dot is legal on all target filesystems but the
path has three dots (`.123456.tar.gz`), which surprises shell globbing
(`glorbo-backup-*.tar.gz` still matches, but archive-naming consumers
expecting single-extension semantics can break).
**Fix:** `DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()`.

### IN-05: `Fixer.format_summary` drops `skipped` count from footer

**File:** `lib/glorbo/doctor/fixer.ex:143-156`
**Issue:** Footer renders `attempted=… repaired=… failed=… explained=…`
but omits `skipped=…` even though the accumulator tracks it. Directors
reading `glorbo doctor --fix` output cannot distinguish "no failures" from
"failures present but no fixer registered".
**Fix:** Append ` skipped=#{s}` to the footer format string.

---

_Reviewed: 2026-04-16_
_Reviewer: gsd-code-reviewer_
_Depth: standard_
