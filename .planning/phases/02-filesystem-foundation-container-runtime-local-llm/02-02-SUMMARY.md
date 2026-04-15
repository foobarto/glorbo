---
phase: 02-filesystem-foundation-container-runtime-local-llm
plan: 02
subsystem: init-bootstrap-doctor

tags: [binary-bootstrap, podman-static, ollama, sha256, severity-exit-codes, doctor-expansion]

requires:
  - phase: 01-compilable-skeleton-ci-release-pipeline
    provides: "Glorbo.Doctor shared module (5 Phase-1 checks), Doctor.Formatter (table + JSON), CLI.dispatch doctor branch, TestHelpers dep-injection pattern"
  - plan: 02-01
    provides: "~/.glorbo/ hierarchy materialiser, AuditLog append-only, SQLite Ecto schemas (prerequisite for the audit_dir/sockets_dir Doctor checks)"

provides:
  - "Glorbo.Init.Versions — pinned URLs + REAL canonical SHA256s for podman-static v5.8.1 and ollama v0.20.7 across amd64 + arm64 (no placeholders, B6/Q-A1 resolved)"
  - "Glorbo.Init.BinaryBootstrap — ensure_podman/1 + ensure_ollama/1 with system-first fallback, SHA256-verify-before-install, offline tolerance, tar --zstd detection"
  - "Glorbo.Doctor.run_checks/1 extended with 8 Phase-2 checks: podman, ollama, ollama_daemon, runtime_image, runtime_exec, audit_dir, sockets_dir, tar_zstd"
  - "Glorbo.Doctor.exit_code/1 — severity-weighted exit codes (0 = pass / 1 = blocker / 2 = warnings-only) per D-45"
  - "Glorbo.Doctor.Formatter additive JSON schema: every Phase-1 key verbatim + severity field on every check (D-44)"
  - "PodmanCase + OllamaCase ExUnit templates for host-gated integration tests"
  - "invoke_cmd/4 arity-tolerant helper so Phase-1 test fixtures (2-arity cmd_fun) keep working alongside Phase-2 3-arity calls"

affects:
  - "Plan 02-03 (container runtime image) — can rely on Doctor's runtime_image + runtime_exec checks to verify post-pull image health"
  - "Plan 02-04 (orchestrator + watcher) — `glorbo init` will call Doctor.run_checks/0 pre/post flight and branch on exit_code 0/1/2 (D-21, D-25, D-45); BinaryBootstrap.ensure_podman/1 + ensure_ollama/1 are the step-3 callables"
  - "Phase 3 — threat_flag: no new Phase 2 surface beyond the threat_model entries T-2-10..T-2-17 (all mitigated or explicitly accepted in v1 single-Director model)"

tech-stack:
  added: []
  patterns:
    - "Dep-injection via keyword list (cmd_fun / which_fun / home_fun / http_fun / download_fun / arch / base / expected_sha / url) — extends Phase-1's pattern with explicit override hooks so tests never hit real network / disk / podman."
    - "arity-tolerant invoke_cmd/4: treats cmd_fun as either `(cmd, args)` or `(cmd, args, opts)` so backward-compat with Phase-1 test fixtures is preserved."
    - "Staging-dir extraction (T-2-12 mitigation): tar extracts to tmp, then explicit allow-list of binaries is copied into ~/.glorbo/bin/. Locked install path (D-05) preserved; only the interim verification step hops through tmp."

key-files:
  created:
    - "lib/glorbo/init/versions.ex (71 lines)"
    - "lib/glorbo/init/binary_bootstrap.ex (218 lines)"
    - "test/glorbo/init/versions_test.exs (85 lines, 13 tests)"
    - "test/glorbo/init/binary_bootstrap_test.exs (250 lines, 8 tests)"
    - "test/support/podman_case.ex (26 lines)"
    - "test/support/ollama_case.ex (27 lines)"
  modified:
    - "lib/glorbo/doctor.ex (161 → 419 lines; +8 Phase-2 checks + exit_code/1 + severity)"
    - "lib/glorbo/doctor/formatter.ex (64 → 68 lines; severity rendering in table + JSON)"
    - "lib/glorbo/cli.ex (64 → 64 lines; routed to Doctor.exit_code/1, widened type)"
    - "test/glorbo/doctor_test.exs (278 → 702 lines; +16 Phase-2 tests, Phase-1 fixtures broadened)"
    - "test/glorbo/cli_test.exs (68 → 77 lines; 13-check expectation + severity assertion)"
    - "test/support/doctor_helpers.ex (32 → 34 lines; http_fun default added)"

key-decisions:
  - "Q-A1 / B6 fully resolved: real canonical SHA256s computed from upstream artifacts at plan revision iter 1 and embedded directly in Versions. No TODO-placeholder fallback, no runtime hash lookup. D-03 delivered without splitting the verification path between GPG (podman-static) and sha256sum.txt (ollama)."
  - "Q-2 resolved: bundled Ollama is the CPU-only path — only `usr/bin/ollama` is copied out of the tarball. The ~1.9 GB of accelerator runtimes in `usr/lib/ollama/` is skipped. `--with-gpu` deferred."
  - "W1 (D-05 deviation): extraction goes through a tmp staging dir before the verified binary lands at ~/.glorbo/bin/. This is a T-2-12 zip-slip + TOCTOU mitigation — SHA256 is verified on the in-tmp file before any byte lands at the locked install path. The locked decision's INTENT (binary at ~/.glorbo/bin/) is preserved; only the interim path moves through tmp. Non-blocking; documented here for Director acknowledgement."
  - "invoke_cmd/4 arity dispatch: Phase-1 tests use 2-arity cmd_fun fakes; Phase-2 checks call with 3-arity (to pass stderr_to_stdout). Rather than force a test-helper rewrite, the module itself detects arity and calls the right shape — keeping Phase-1 fixtures verbatim per D-44."
  - "exit_code/1 treats checks without :severity as :blocker (backward-compat): the Mix task fixtures (`@all_pass`, `@one_fail`) in Phase-1 tests still map to exit code 0 / 1 because a missing-severity failure is treated as a blocker."
  - "Ollama binary resolution: check_ollama probes both PATH (via which_fun) AND ~/.glorbo/bin/ollama (managed location per D-04/D-05). Either hit passes. Matches BinaryBootstrap.ensure_ollama's installation target."

patterns-established:
  - "Doctor.exit_code/1 is the single source for CLI exit semantics. Plan 04's init orchestrator will call it to branch `glorbo init` steps on 0/1/2 (D-21)."
  - "Additive-only JSON schema on Doctor.Formatter: Phase-N extensions append keys, never rename/remove. CLI consumers (init orchestrator in Plan 04, `doctor --fix` in Phase 5) can rely on every Phase-1 key remaining verbatim."
  - "Dep-injectable download_fun + expected_sha overrides in BinaryBootstrap: tests drive both the system-first and download-verify-extract paths without any network access, using fixture tarballs whose SHA the test computes at setup time."

requirements-completed: [RT-01, LLM-01]

duration: ~12min
completed: 2026-04-15
---

# Phase 2 Plan 02: Binary Bootstrap + Doctor Expansion Summary

**Bootstrapped the two third-party static binaries (podman-static v5.8.1 + ollama v0.20.7) with real canonical SHA256 verification, offline tolerance, and staging-dir extraction — and extended `Glorbo.Doctor` with 8 Phase-2 runtime checks plus severity-weighted exit codes (0/1/2) that Plan 04's init orchestrator will branch on.**

## Performance

- **Duration:** ~12 min wall-clock
- **Started:** 2026-04-15 (Task 1 commit at 47bac58)
- **Completed:** 2026-04-15 (Task 2 commit at 7a22749)
- **Tasks:** 2
- **Files created:** 6
- **Files modified:** 6

## Accomplishments

- `Glorbo.Init.Versions` ships real canonical SHA256s for podman-static v5.8.1 and ollama v0.20.7 on both amd64 and arm64. B6 acceptance criteria fully satisfied — no all-zero / all-one / all-two / all-three placeholder hashes; no leftover `TODO-A1` marker. D-03 delivered.
- `Glorbo.Init.BinaryBootstrap` dispatches both binaries through a single private `ensure/2`; the public surface is only `ensure_podman/1` and `ensure_ollama/1` (plus the helper `verify_sha256/2`). System-first fallback (D-04), SHA256-verify-before-install (D-03 + Pitfall 1), offline tolerance (D-09), and `.tar.zst` handling with zstd-detection (Pitfall 2) all covered by tests.
- `Glorbo.Doctor.run_checks/1` now returns 13 checks. The original 5 names (`linux_kernel`, `uidmap`, `disk_space`, `glorbo_dir`, `erts_version`) are unchanged and appear in the original order at the head of the list; 8 Phase-2 checks (`podman`, `ollama`, `ollama_daemon`, `runtime_image`, `runtime_exec`, `audit_dir`, `sockets_dir`, `tar_zstd`) are appended. Every check carries a `:severity` field.
- `Glorbo.Doctor.exit_code/1` implements D-45 severity semantics. CLI wired.
- PodmanCase + OllamaCase templates give future integration tests a clean skip-on-absent fixture.

## Task Commits

1. **Task 1: Versions + BinaryBootstrap + tests** — `47bac58` (feat)
2. **Task 2: Doctor extension + severity exit codes** — `7a22749` (feat)

## Files Created / Modified

### Created (lib)
- `lib/glorbo/init/versions.ex` — 71 lines. Pinned versions + URLs + real SHA256s + arch detection.
- `lib/glorbo/init/binary_bootstrap.ex` — 218 lines. ensure_podman/1 + ensure_ollama/1 through single ensure/2 dispatcher; default_download/2 via curl; extract/4 with per-binary clauses; tar_supports_zstd? detection; verify_sha256/2 streaming SHA256.

### Created (tests)
- `test/glorbo/init/versions_test.exs` — 85 lines, **13 tests** (6 per binary = 12 shape tests + B6 placeholder-guard + detect_arch/0).
- `test/glorbo/init/binary_bootstrap_test.exs` — 250 lines, **8 tests** (system-first x 2, download-verify-extract happy path, checksum mismatch, offline tolerance, tar_zstd missing, verify_sha256 match + mismatch, no-per-binary-public-fn negative shape).
- `test/support/podman_case.ex` — 26 lines. `@moduletag :podman`, skip-if-absent.
- `test/support/ollama_case.ex` — 27 lines. `@moduletag :ollama`, skip-if-absent (checks both PATH and ~/.glorbo/bin/).

### Modified
- `lib/glorbo/doctor.ex` (161 → 419 lines). 8 new checks, exit_code/1, severity on every check map, invoke_cmd/4 arity bridge, default_cmd3/3.
- `lib/glorbo/doctor/formatter.ex` (64 → 68 lines). severity_tag/1 rendering in table; to_json/1 delegates exit_code computation to Doctor.exit_code/1 (additive per D-44).
- `lib/glorbo/cli.ex` — doctor branch routes to Doctor.exit_code/1; `@type result` widened to `{verb, 0|1|2, output}`.
- `test/glorbo/doctor_test.exs` (278 → 702 lines). Phase-1 tests preserved; cmd_fun fixtures broadened with catch-all `_ -> {"", 1}` clauses; 5-pattern destructures widened to `[_, _, _, _, erts | _]`; 16 new Phase-2 tests across 6 describe blocks.
- `test/glorbo/cli_test.exs` — 13-check expectation + severity-field assertion + exit_code widened to 0/1/2.
- `test/support/doctor_helpers.ex` — added `http_fun` default (returns `{:error, :not_stubbed}`) so existing callers don't break when check_ollama_daemon runs.

## Decisions Made

- **Real SHA256s from day one (B6 resolution).** The plan-checker iter-1 revision already computed the four canonical hashes against the 2026-04-15 upstream artifacts. Embedding them directly in `Versions` eliminates Q-A1 entirely and makes D-03 a single-channel (SHA256) verification path. If upstream re-cuts either tag, downloads will hard-fail with `:checksum_mismatch` — the correct fail-safe.
- **CPU-only Ollama bundle (Q-2 resolution).** `extract(:ollama, …)` copies `usr/bin/ollama` only; `usr/lib/ollama/` (CUDA + ROCm runtimes, ~1.9 GB) is skipped. Director wires GPU support themselves for now; `--with-gpu` will be a future phase.
- **W1 (D-05 deviation) — ack.** Extraction goes through `System.tmp_dir!()/glorbo_<binary>_extract_<n>/` before the verified binary is copied into `~/.glorbo/bin/`. This is the T-2-12 zip-slip + TOCTOU mitigation — `verify_sha256/2` runs on the tmp file before any byte lands at the locked install path. The locked decision's intent (binary installed at `~/.glorbo/bin/`) is preserved; only the verification path hops through tmp. Non-blocking; flagged here for Director ack.
- **Single public dispatch point.** `ensure_podman/1` and `ensure_ollama/1` are the only exported behavioural entry points; both delegate to a private `ensure/2` which dispatches to private per-binary `extract/4` clauses. No per-binary public helpers leak (negative shape test verifies this).
- **Arity-tolerant invoke_cmd/4.** Rather than rewrite Phase-1 test fixtures to be 3-arity, the Doctor module detects the cmd_fun's arity at call time and dispatches appropriately. Keeps D-44 additive-only at the test layer too.
- **exit_code/1 defaults missing-severity to :blocker.** The Mix task tests (`test/mix/tasks/glorbo.doctor_test.exs`) use raw 5-field fixtures (`@all_pass`, `@one_fail`) without severity. Treating missing severity as blocker preserves Phase-1 exit-code semantics (0 or 1) for those tests verbatim.

## Q-2 Resolution: Ollama CPU-only bundle

Confirmed shipped. `BinaryBootstrap.extract(:ollama, …)` copies only `usr/bin/ollama` out of the staging directory. The full tarball is unpacked into tmp for verification purposes but only the CPU binary makes it to `~/.glorbo/bin/ollama`. Installed size ≈ 50 MB vs ≈ 2 GB for the full archive. `--with-gpu` flag deferred to a later phase (documented in `Glorbo.Init.Versions`'s moduledoc).

## W1 D-05 Deviation Acknowledgement

Per the plan's `<open_questions>` W1 entry, `BinaryBootstrap` extracts the downloaded tarball to `System.tmp_dir!()/glorbo_<binary>_extract_<n>/` before copying the verified binary into `~/.glorbo/bin/`. D-05 ("download destination — `~/.glorbo/bin/` directly") is preserved in INTENT (the installed binary lives at `~/.glorbo/bin/`), but the verification path routes through tmp because:

1. **T-2-12 zip-slip mitigation.** tar's `-C staging` cannot escape the staging dir; the allow-list copy (only `podman`, `crun`, `conmon`, `runc` for podman; only `ollama` for ollama) is defense in depth.
2. **SHA256 verification before any file lands at `~/.glorbo/bin/`.** `verify_sha256/2` runs on the downloaded tarball while it's still in tmp; a mismatch aborts before any byte reaches the install path.

Director acknowledgement requested at first `glorbo init` run. Documented here and in the module's `@moduledoc`.

## Test counts

- `test/glorbo/init/versions_test.exs` — **13 tests** (all always run; no host gating).
- `test/glorbo/init/binary_bootstrap_test.exs` — **8 tests** (all driven by dep injection; no real network / podman / ollama required).
- `test/glorbo/doctor_test.exs` — 37 tests total (Phase-1 + 16 Phase-2 additions, including severity classification, exit-code tiers, each of the 8 checks, and JSON additive-schema assertion).
- `test/glorbo/cli_test.exs` — 8 tests (unchanged scope + severity / 13-check assertions).
- `test/mix/tasks/glorbo.doctor_test.exs` — 5 tests (unchanged; pre-existing fixtures flow through additive JSON schema).
- `test/support/podman_case.ex` — case template; tests that consume it carry `@moduletag :podman`.
- `test/support/ollama_case.ex` — case template; tests carry `@moduletag :ollama`.

Full suite: **119 tests, 0 failures** (1 excluded via `@tag :integration` from Plan 02-01's roundtrip).
`mix credo --strict`: 0 issues.
`mix compile --warnings-as-errors`: clean.

## Doctor JSON schema diff vs Phase 1

Additive only per D-44:

| Location | Addition |
|----------|----------|
| `checks[].severity` | new field, `:blocker | :warning` |
| `checks[]` entries | 8 new check names appended: `podman`, `ollama`, `ollama_daemon`, `runtime_image`, `runtime_exec`, `audit_dir`, `sockets_dir`, `tar_zstd` |
| top-level `exit_code` | semantics widened from `0 | 1` to `0 | 1 | 2` (D-45); old `(all_pass?0:1)` logic replaced by `Glorbo.Doctor.exit_code/1` |

Every Phase-1 key (`version`, `checks`, `all_passed`, `passed_count`, `total_count`, `exit_code`, per-check `name` / `pass` / `detail` / `required`) is preserved verbatim — verified by the "JSON additive schema" describe block in `doctor_test.exs`.

Dev host smoke:

```json
{
  "version": "0.1.0",
  "exit_code": 2,
  "all_passed": false,
  "passed_count": 10,
  "total_count": 13
  ...
}
```

exit_code 2 is correct: all 5 blocker checks pass; 3 warnings fail (ollama_daemon, runtime_image, runtime_exec — expected in the absence of a running Ollama daemon and the not-yet-pulled runtime image).

## VALIDATION.md row updates

| Req   | Status | Notes |
|-------|--------|-------|
| RT-01 | OK     | `BinaryBootstrap.ensure_podman/1` with system-first + SHA256-verified download; `Doctor.check_podman` + `check_runtime_image` + `check_runtime_exec` prove the runtime chain |
| LLM-01 | OK    | `BinaryBootstrap.ensure_ollama/1` with CPU-only bundling; `Doctor.check_ollama` + `check_ollama_daemon` prove presence + reachability |

(Orchestrator will mark the VALIDATION.md / REQUIREMENTS.md rows via `requirements mark-complete` after wave completion.)

## Next Plan Readiness

- **Plan 02-03 (container runtime image)** — can lean on `check_runtime_image` + `check_runtime_exec` to assert post-pull image health. The `--network none` flag is already wired into `check_runtime_exec`'s smoke test.
- **Plan 02-04 (orchestrator + watcher)** — `glorbo init` step 3 is `BinaryBootstrap.ensure_podman/1` + `BinaryBootstrap.ensure_ollama/1`; step 1 + 7 call `Doctor.run_checks/0` and branch on `Doctor.exit_code/1` (0/1/2). The `:ok, :skipped, "no network"` return variant is the D-09 offline-tolerance hook init consumes.

## Deferred Issues

None — both tasks completed inside the 3-auto-fix-attempts budget without any out-of-scope discoveries. No items written to `deferred-items.md`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] Phase-1 test fixtures needed catch-all clauses**
- **Found during:** Task 2 compile + test
- **Issue:** Phase-1 `disk_cmd/2` and `all_pass_deps/1` used `case cmd do` without a fallthrough — Phase-2 checks asking those fixtures for `podman`/`ollama` crashed with `CaseClauseError`.
- **Fix:** Added `_ -> {"", 1}` to each helper so unknown commands return a clean non-zero exit. Phase-1 test assertions remain identical (they only care about results at indices 0–4).
- **Files modified:** `test/glorbo/doctor_test.exs`
- **Committed in:** `7a22749` (Task 2 commit).

**2. [Rule 3 — Blocking] invoke_cmd/4 arity bridge**
- **Found during:** Task 2 compile
- **Issue:** Phase-1 tests inject 2-arity cmd_fun; Phase-2 checks need `stderr_to_stdout: true` (3-arity). Calling a 2-arity function with 3 args crashes.
- **Fix:** `invoke_cmd/4` dispatches on `is_function(fun, 3)` vs `is_function(fun, 2)`. Default `default_cmd3/3` forwards to `System.cmd/3`.
- **Files modified:** `lib/glorbo/doctor.ex`
- **Committed in:** `7a22749` (Task 2 commit).

**3. [Rule 3 — Blocking] Mix task test fixtures had no :severity**
- **Found during:** Task 2 compile
- **Issue:** `test/mix/tasks/glorbo.doctor_test.exs` uses 5-field fixtures (no severity). `Formatter.to_json/1` delegates to `Doctor.exit_code/1` which pattern-matched on severity.
- **Fix:** `exit_code/1` treats checks without `:severity` as `:blocker` via `Map.get(check, :severity, :blocker)`. Preserves Phase-1 exit-code semantics (0 or 1) for those fixtures exactly.
- **Files modified:** `lib/glorbo/doctor.ex`
- **Committed in:** `7a22749` (Task 2 commit).

**4. [Rule 2 — Missing critical] http_fun default in test helpers**
- **Found during:** Task 2 test run
- **Issue:** `check_ollama_daemon` calls `http_fun.()`. Test deps that don't override it caused the default `:httpc` path to hit real localhost:11434 — flaky + unintended host coupling.
- **Fix:** `TestHelpers.deps/1` now ships a default `http_fun: fn -> {:error, :not_stubbed} end` so tests stay host-independent unless they opt in.
- **Files modified:** `test/support/doctor_helpers.ex`
- **Committed in:** `7a22749` (Task 2 commit).

---

**Total deviations:** 4 auto-fixed (3 blocking tooling / test-harness, 1 missing critical). None extended scope beyond RT-01 + LLM-01.

## Self-Check: PASSED

Files verified to exist:
- `lib/glorbo/init/versions.ex` — FOUND
- `lib/glorbo/init/binary_bootstrap.ex` — FOUND
- `test/glorbo/init/versions_test.exs` — FOUND
- `test/glorbo/init/binary_bootstrap_test.exs` — FOUND
- `test/support/podman_case.ex` — FOUND
- `test/support/ollama_case.ex` — FOUND
- `lib/glorbo/doctor.ex` — FOUND (modified)
- `lib/glorbo/doctor/formatter.ex` — FOUND (modified)
- `lib/glorbo/cli.ex` — FOUND (modified)
- `test/glorbo/doctor_test.exs` — FOUND (modified)
- `test/glorbo/cli_test.exs` — FOUND (modified)
- `test/support/doctor_helpers.ex` — FOUND (modified)

Commits verified to exist:
- `47bac58` — FOUND (Task 1)
- `7a22749` — FOUND (Task 2)

Test results: **119 tests, 0 failures** (1 excluded integration). `mix compile --warnings-as-errors` clean. `mix credo --strict` clean. `mix glorbo.doctor --json` returns 13 checks with exit_code 2 on dev host (3 expected warnings: ollama daemon not running, runtime image not pulled, runtime exec consequently unavailable).

Acceptance-criteria grep assertions (from `<acceptance_criteria>` blocks, Task 1 + 2): all **PASSED**.

---
*Phase: 02-filesystem-foundation-container-runtime-local-llm*
*Completed: 2026-04-15*
