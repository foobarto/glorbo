---
phase: 05
iteration: 2
review_path: .planning/phases/05-cli-completeness-backup-restore-portability/05-REVIEW.md
fixed_at: 2026-04-16
findings_in_scope: 8
fixed: 8
skipped: 0
deferred: [IN-01, IN-02, IN-03, IN-04, IN-05]
status: all_fixed
---

# Phase 5: Code Review Fix Report — Iteration 2

**Source review:** `05-REVIEW.md` (Plans 05-03 / 05-04 gap closure)
**Scope:** Critical + Warning (1 CR + 7 WR). Info (5) deferred.
**Prior iteration 1 report:** covered plans 05-01/02 WR-01..WR-09 — superseded.

## Summary

All 8 in-scope findings fixed across 6 commits. `mix compile --warnings-as-errors`
passes; full `mix test` remains **621/621**. Touched `restore.ex`, `backup.ex`,
`doctor.ex`, `doctor/fixer.ex`, and updated one stale test assertion
(`doctor_fix_test.exs:30` — `code in [0, 1]` → `[0, 1, 2]`) whose
pre-fix expectation contradicted the WR-05 severity-weighted exit code.

## Fixed Issues

### CR-01 + WR-03: Symlink link-target bypass + archive-bomb guard
**Files:** `lib/glorbo/restore.ex`  **Commit:** `ae7e3fc`
Verbose `:erl_tar.table` now surfaces entry sizes (uncompressed cap default 10 GiB). Post-extract walks base, resolves every symlink via `:file.read_link/1`, rejects any target escaping base, and wipes the partial extract. New CLI lines for `:unsafe_archive_symlinks` and `:archive_too_large`.

### WR-01: `Restore.maybe_migrate` `catch :exit`
**Files:** `lib/glorbo/restore.ex`  **Commit:** `c250209`
Mirrored `Migrate`'s pattern — `catch :exit, reason -> {:error, {:migrate_failed, inspect(reason)}}`.

### WR-02: `Fixer.safe_apply` `catch :exit`
**Files:** `lib/glorbo/doctor/fixer.ex`  **Commit:** `d2ed6bc`
Added `catch :exit, reason -> {:error, {:exited, inspect(reason)}}`.

### WR-04: Pidfile TOCTOU in `Backup.run`
**Files:** `lib/glorbo/backup.ex`  **Commit:** `bf68bde`
New `recheck_down/2` runs between checkpoint and `write_archive`; returns `:glorbo_started_during_backup` on mismatch. `--force-live` skips both checks.

### WR-05 + WR-06 + WR-08: Exit-code, recheck, buffered output
**Files:** `lib/glorbo/doctor.ex`, `lib/glorbo/doctor/fixer.ex`, `test/glorbo/cli/doctor_fix_test.exs`  **Commit:** `15e3191`
- WR-05: `Fixer.run/1` derives post-repair exit via `Doctor.exit_code(Doctor.run_checks())`. Unregistered blockers now leak to non-zero.
- WR-06: new `Doctor.recheck(name)`. `run_fixer` promotes `{:ok, _}` to `repaired` only when the fresh check passes; otherwise `failed` with descriptive reason.
- WR-08: all six `IO.puts` calls removed from `handle_check`/`run_fixer`; lines buffered into `acc.lines` and rendered via `format_summary/1`.

### WR-07: `Restore.maybe_fixer` structured Logger warnings
**Files:** `lib/glorbo/restore.ex`  **Commit:** `f418311`
Branches on fixer return tuple and emits `Logger.warning/1` for non-zero exit, raised exceptions, and `:exit`. Preserves `:ok` contract (post-extract fixer is advisory).

## Skipped Issues

None.

## Info Findings Deferred

IN-01 (Console double `find_executable`), IN-02 (Console receive no timeout), IN-03 (Restore migrations_path missing), IN-04 (Backup filename microseconds), IN-05 (Fixer summary omits `skipped` count). Low severity, addressable in a follow-up pass.

## Verification

- `mix compile --warnings-as-errors` → exit 0
- Focused tests (6 files) → 39/39 pass
- Full `mix test` → 621/621 pass (no regression from baseline)

---

_Fixed: 2026-04-16_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 2_
