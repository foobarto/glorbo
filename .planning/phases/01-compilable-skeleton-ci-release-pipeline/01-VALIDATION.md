---
phase: 01
slug: compilable-skeleton-ci-release-pipeline
status: ready
nyquist_compliant: true
wave_0_complete: false
created: 2026-04-15
updated: 2026-04-15
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (stdlib, Elixir 1.18.4) + Credo 1.7+ (strict) |
| **Config file** | `test/test_helper.exs`, `.credo.exs` |
| **Quick run command** | `mix test --stale && mix credo --strict` |
| **Full suite command** | `mix test && mix credo --strict && mix format --check-formatted && mix compile --warnings-as-errors` |
| **Estimated runtime** | Quick: 5–15s · Full: ~30s · Release build (CI only): ~8–12 min |

---

## Sampling Rate

- **After every task commit:** `mix test --stale && mix credo --strict` (< 15s)
- **After every plan wave:** Full suite command (< 30s)
- **Before `/gsd-verify-work`:** Full suite green + CI workflow dry-run on a feature branch PR confirms multi-arch build succeeds
- **Phase gate:** Manual `cosign verify-blob` on a tagged pre-release (e.g., `v0.0.1-rc1`) confirms signing chain works end-to-end
- **Max feedback latency:** 30 seconds (task + wave); ~12 minutes (CI release build)

---

## Per-Task Verification Map

> Task IDs are bound to plans `01-01` (Plan A), `01-02` (Plan B), `01-03` (Plan C).
> Format: `{plan}-T{task}` — e.g. `01-01-T1` = Plan 01, Task 1.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 01-01-T1 | 01 | 1 | FND-01, FND-02 | — | Fresh checkout compiles with phx.new skeleton + Credo strict + format pass; Wave 0 test files exist (red until T2) | smoke | `mix compile --warnings-as-errors && mix credo --strict && mix format --check-formatted && mix test test/config_test.exs` | ✅ after T1 runs | ✅ green |
| 01-01-T1 | 01 | 1 | FND-02 | — | WAL config is grep-visible in every env config | static | `grep -l 'journal_mode: :wal' config/dev.exs config/test.exs config/runtime.exs \| wc -l` → 3 | ✅ after T1 | ✅ green |
| 01-01-T2 | 01 | 1 | FND-01 | — | `Glorbo.Application` supervision tree starts cleanly; all §4.1 children boot | unit | `mix test test/glorbo/application_test.exs` | ✅ after T2 | ✅ green |
| 01-01-T2 | 01 | 1 | FND-01 | — | Every §4.1 stub module exists, exposes `start_link/1`, returns `{:error, :not_implemented}`; AuditLog lacks `update`/`delete`/`edit` (append-only per CLAUDE.md) | unit | `mix test test/glorbo/stubs_test.exs` | ✅ after T2 | ✅ green |
| 01-01-T2 | 01 | 1 | FND-02 | — | SQLite WAL active at runtime on the test repo | integration | `mix test test/glorbo/repo_wal_test.exs` (asserts `PRAGMA journal_mode` returns `"wal"`) | ✅ after T2 | ✅ green |
| 01-02-T1 | 02 | 2 | FND-06 | — | `Glorbo.Doctor.run_checks/1` — each of 5 checks unit-tested via injected `cmd_fun`/`which_fun`/`home_fun`/`otp_release_fun` so tests don't require `newuidmap`, `uname`, or `df` on the runner | unit | `mix test test/glorbo/doctor_test.exs` | ✅ after T1 | ✅ green |
| 01-02-T1 | 02 | 2 | FND-06 | — | `Glorbo.Doctor.Formatter.to_json/1` emits stable-keyed JSON envelope (`all_passed`, `checks[]`, `name`, `pass`, `detail`, `required`, `version`, `exit_code`) | unit | same file, JSON shape tests | ✅ after T1 | ✅ green |
| 01-02-T2 | 02 | 2 | FND-06 | — | `mix glorbo.doctor` runs all 5 checks, prints human table; `mix glorbo.doctor --json \| jq -e '.version == "0.1.0"'` exits 0 | integration | `mix test test/mix/tasks/glorbo.doctor_test.exs && mix glorbo.doctor --json \| jq -e '.checks \| length == 5'` | ✅ after T2 | ✅ green |
| 01-03-T1 | 03 | 3 | FND-03 | — | Burrito dep + releases block wired in `mix.exs`; `Glorbo.CLI.dispatch/1` pure-function tested | unit | `mix test test/glorbo/cli_test.exs && grep -q '&Burrito.wrap/1' mix.exs` | ✅ after T1 | ✅ green |
| 01-03-T1 | 03 | 3 | FND-03 | — | `Glorbo.Application.start/2` argv branch is inert under ExUnit (Plan 01's application_test.exs stays green) | regression | `mix test test/glorbo/application_test.exs` (must pass unchanged) | ✅ after T1 | ✅ green |
| 01-03-T2 | 03 | 3 | FND-03 | — | Local `MIX_ENV=prod mix release` produces executable `burrito_out/glorbo_linux_x86_64` | integration | `test -x burrito_out/glorbo_linux_x86_64 && file burrito_out/glorbo_linux_x86_64 \| grep -q 'ELF 64-bit'` | ✅ after T2 | ✅ green |
| 01-03-T2 | 03 | 3 | FND-03 | — | `./glorbo doctor --json` works on binary (argv dispatch end-to-end local smoke) | integration | `./burrito_out/glorbo_linux_x86_64 doctor --json \| jq -e '.version == "0.1.0"'` | ✅ after T2 | ✅ green |
| 01-03-T2 | 03 | 3 | FND-03 | — | Binary runs on host with no Erlang installed (clean Ubuntu 24.04 container smoke) | smoke | `podman run --rm -v $PWD/burrito_out:/b:ro ubuntu:24.04 /b/glorbo_linux_x86_64 doctor --json \| jq .version` → `"0.1.0"` | ✅ after T2 | ✅ green |
| 01-03-T2 | 03 | 3 | FND-06 | — | No-arg `./glorbo` prints help + exits 0 (confirmed A6) | integration | CI smoke step + local: `./burrito_out/glorbo_linux_x86_64 \| grep -q USAGE` | ✅ after T2 | ✅ green |
| 01-03-T3 | 03 | 3 | FND-04 | — | Both x86_64 and aarch64 artifacts produced and uploaded in CI; hyphenated names per A9 | CI matrix | `gh run view --log` shows both matrix legs succeed; artifacts named `glorbo-linux-x86_64` AND `glorbo-linux-aarch64` | ✅ after T3 PR push | ⬜ pending feature-branch push |
| 01-03-T3 | 03 | 3 | FND-05 | — | CI compiles, tests, and uploads dev artifact on push to `main` (unsigned per D-17) | CI workflow | `gh run list --workflow=ci.yml --branch=main` shows success | ✅ after merge to main | ⬜ pending merge to main |
| 01-03-T3 | 03 | 3 | FND-05 | — | `.github/workflows/ci.yml` parses and contains all load-bearing steps (matrix, setup-beam pinned, setup-zig 0.15.2, cosign v3.0.6, rename, smoke-test, tag-gated release) | static | YAML parse + 13 grep checks per Plan 03 Task 3 `<automated>` block | ✅ after T3 authored | ✅ green |
| 01-03-T3 | 03 | 3 | FND-05 | — | Tagged release (`v*.*.*`) produces signed binaries + `SHA256SUMS.sig`; `cosign verify-blob` passes with canonical identity regex | CI + manual | On pre-release tag (`v0.0.1-rc1`): `cosign verify-blob --certificate-identity-regexp='^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' --bundle SHA256SUMS.sig SHA256SUMS` → exit 0 | ⬜ manual (see Manual-Only Verifications) | ⬜ manual (pending v0.0.1-rc1 tag) |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Test files + CI artifacts that must be created before Phase 1 verification can proceed. All absent at phase start (greenfield).

**Plan 01 (Task 1) creates (red until Plan 01 Task 2):**
- [ ] `test/glorbo/application_test.exs` — supervision tree boots with all expected children + CompanySupervisor empty + Company.Supervisor startable
- [ ] `test/glorbo/stubs_test.exs` — each §4.1 module loaded + exports `start_link/1` + AuditLog append-only refutation (no `update`/`delete`/`edit`)
- [ ] `test/glorbo/repo_wal_test.exs` — `PRAGMA journal_mode` returns `"wal"` on live test Repo
- [ ] `test/config_test.exs` — grep-level WAL assertion across `config/dev.exs`, `config/test.exs`, `config/runtime.exs`

**Plan 02 (Task 1) creates:**
- [ ] `test/glorbo/doctor_test.exs` — each of 5 checks unit-tested with injected deps; Formatter table + JSON shape tests
- [ ] `test/support/doctor_helpers.exs` — shared fixture module (`Glorbo.Doctor.TestHelpers`) for canned cmd/which/home/otp functions

**Plan 02 (Task 2) creates:**
- [ ] `test/mix/tasks/glorbo.doctor_test.exs` — CaptureIO + exit-shutdown integration tests for the Mix task + `--json` flag

**Plan 03 (Task 1) creates:**
- [ ] `test/glorbo/cli_test.exs` — pure-function tests for `Glorbo.CLI.dispatch/1` (help, doctor, doctor --json, unknown command)

**Plan 03 (Task 3) creates:**
- [ ] `.github/workflows/ci.yml` — the CI workflow (validated by `python3 -c "import yaml; yaml.safe_load(...)"` and real first-push to a feature branch)
- [ ] `VERIFY.md` — end-user cosign verify recipe with `foobarto/glorbo`-bound identity regex

**Framework install:** ExUnit ships with Elixir; no install needed. Credo is added via `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` in `mix.exs` (Plan 01 Task 1).

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cosign signature verifies end-to-end | FND-05 | Requires a real published tag with a Sigstore-signed artifact; OIDC flow cannot be unit-tested | 1. Tag pre-release after Plan 03 merges to main: `git tag v0.0.1-rc1 && git push origin v0.0.1-rc1`. 2. Wait for release workflow. 3. Download `glorbo-linux-x86_64`, `SHA256SUMS`, `SHA256SUMS.sig` from the release page. 4. Run `cosign verify-blob --bundle SHA256SUMS.sig --certificate-identity-regexp='^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' SHA256SUMS` → exit 0. 5. `sha256sum -c SHA256SUMS --ignore-missing` → all OK. |
| aarch64 binary boots on real aarch64 host | FND-04 | No aarch64 hardware on dev machine; CI proves build but not field runtime | Copy `glorbo-linux-aarch64` to a Raspberry Pi / aarch64 VM / cloud aarch64 instance. Run `./glorbo-linux-aarch64 doctor`. Document exit code and table output. |
| Release signing identity cannot be spoofed | FND-05 | Negative test — verifies regex excludes tampered signatures | Attempt verification against a hand-crafted signature from a different repo workflow → `cosign verify-blob` must fail with "no matching signatures". Confirms the identity regex actually binds to `foobarto/glorbo`. |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify commands referencing concrete test files OR Wave 0 test files the plan creates first
- [x] Sampling continuity: no 3 consecutive tasks without automated verify (7 tasks total, each has automated verify)
- [x] Wave 0 covers all MISSING references (9 test/artifact files across 3 plans)
- [x] No watch-mode flags (CI-compatible commands only)
- [x] Feedback latency < 30s for task+wave sampling; release-build step ~10 min only in CI
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** planner-bound to plans `01-01`, `01-02`, `01-03`. Ready for execution.
