---
phase: 01
slug: compilable-skeleton-ci-release-pipeline
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-15
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

> Task IDs are placeholders until plans land. Plan→task bindings are filled in by the planner.
> Format: `{plan}-{task}` (e.g., `A-01`, `B-02`, `C-03`).

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| A-?? | A | 1 | FND-01 | — | Fresh checkout compiles with domain-nested layout + no warnings | smoke | `mix compile --warnings-as-errors` | ✅ | ⬜ pending |
| A-?? | A | 1 | FND-01 | — | `Glorbo.Application` supervision tree starts cleanly; all §4.1 children boot | unit | `mix test test/glorbo/application_test.exs` | ❌ W0 | ⬜ pending |
| A-?? | A | 1 | FND-01 | — | Every §4.1 stub module exists, is addressable, exposes `start_link/1`, returns `{:error, :not_implemented}` for real calls | unit | `mix test test/glorbo/stubs_test.exs` | ❌ W0 | ⬜ pending |
| A-?? | A | 1 | FND-02 | — | SQLite WAL active at runtime on the test repo | integration | `mix test test/glorbo/repo_wal_test.exs` (asserts `PRAGMA journal_mode` returns `"wal"`) | ❌ W0 | ⬜ pending |
| A-?? | A | 1 | FND-02 | — | WAL config is grep-visible in every env config | static | `grep -rn 'journal_mode: :wal' config/ \| wc -l` ≥ 3 | ❌ W0 (shell script test) | ⬜ pending |
| B-?? | B | 2 | FND-06 | — | `mix glorbo.doctor` runs all 5 checks and returns structured results | unit | `mix test test/mix/tasks/glorbo.doctor_test.exs` | ❌ W0 | ⬜ pending |
| B-?? | B | 2 | FND-06 | — | `Glorbo.Doctor.run_checks/0` — each individual check is unit-tested with injected deps | unit | `mix test test/glorbo/doctor_test.exs` | ❌ W0 | ⬜ pending |
| B-?? | B | 2 | FND-06 | — | `mix glorbo.doctor --json` emits valid JSON with stable keys (`all_passed`, `checks[]`, `name`, `pass`, `detail`, `required`) | unit | same file, `--json` case | ❌ W0 | ⬜ pending |
| B-?? | B | 2 | FND-06 | — | No-arg `./glorbo` prints help & exits 0 (confirmed A6) | integration | CI step after release build | ❌ W0 (CI-only) | ⬜ pending |
| C-?? | C | 3 | FND-03 | — | `mix release` produces Burrito binary at expected path | integration | `MIX_ENV=prod mix release && test -x burrito_out/glorbo_linux_x86_64` | ❌ W0 (CI only; ~8 min) | ⬜ pending |
| C-?? | C | 3 | FND-03 | — | Binary runs on host with no Erlang installed | smoke | CI: `docker run --rm -v $PWD/burrito_out:/b ubuntu:24.04 /b/glorbo-linux-x86_64 doctor --json` | ❌ W0 (CI-only) | ⬜ pending |
| C-?? | C | 3 | FND-03 | — | `./glorbo doctor` argv dispatch works (Burrito binary → `Glorbo.Doctor.run_checks/0`) | integration | CI step: `./burrito_out/glorbo-linux-x86_64 doctor --json \| jq -e .all_passed` | ❌ W0 (CI-only) | ⬜ pending |
| C-?? | C | 3 | FND-04 | — | Both x86_64 and aarch64 artifacts produced and uploaded in CI | CI matrix | GitHub Actions run; `gh run view --log` shows both matrix legs succeed | ❌ W0 | ⬜ pending |
| C-?? | C | 3 | FND-04 | — | Output filenames are hyphenated (`glorbo-linux-x86_64`, `glorbo-linux-aarch64`, confirmed A9) | static | CI: `test -f glorbo-linux-x86_64 && test -f glorbo-linux-aarch64` after rename step | ❌ W0 | ⬜ pending |
| C-?? | C | 3 | FND-05 | — | CI compiles, tests, and uploads dev artifact on push to `main` | CI workflow | `gh run list --workflow=ci.yml --branch=main` shows success | ❌ W0 | ⬜ pending |
| C-?? | C | 3 | FND-05 | — | Tagged release (`v*.*.*`) produces signed binaries + `SHA256SUMS.sig`; `cosign verify-blob` passes with canonical identity regex | CI + manual | Local: `cosign verify-blob --certificate-identity-regexp='^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' --bundle glorbo-linux-x86_64.sig glorbo-linux-x86_64` → exit 0 | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

Test files + CI artifacts that must be created before Phase 1 verification can proceed. All absent (greenfield):

- [ ] `test/glorbo/application_test.exs` — asserts supervision tree starts, expected §4.1 children present
- [ ] `test/glorbo/stubs_test.exs` — asserts each §4.1 module exists, has `start_link/1`, returns `{:error, :not_implemented}` for public calls
- [ ] `test/glorbo/repo_wal_test.exs` — runs `Ecto.Adapters.SQL.query!(Glorbo.Repo, "PRAGMA journal_mode;", [])`, asserts `"wal"`
- [ ] `test/mix/tasks/glorbo.doctor_test.exs` — calls `Mix.Tasks.Glorbo.Doctor.run/1` with argv variants; asserts stdout via `ExUnit.CaptureIO`
- [ ] `test/glorbo/doctor_test.exs` — unit-tests each `check_*` function in `Glorbo.Doctor` with dependency injection for `System.cmd`
- [ ] `test/support/doctor_helpers.exs` — shared fixtures for check mocking
- [ ] `.github/workflows/ci.yml` — the CI workflow itself (validated by `action-validator` locally or first push)

**Framework install:** ExUnit ships with Elixir; no install needed. Credo is added via `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` in `mix.exs`.

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Cosign signature verifies end-to-end | FND-05 | Requires a real published tag with a Sigstore-signed artifact; OIDC flow cannot be unit-tested | 1. Tag pre-release: `git tag v0.0.1-rc1 && git push --tags`. 2. Wait for release workflow. 3. `cosign verify-blob --certificate-identity-regexp='^https://github.com/foobarto/glorbo/\.github/workflows/.+@refs/tags/v.+$' --certificate-oidc-issuer='https://token.actions.githubusercontent.com' --bundle glorbo-linux-x86_64.sig glorbo-linux-x86_64` → exit 0 |
| aarch64 binary boots on real aarch64 host | FND-04 | No aarch64 hardware on dev machine; CI proves build but not field runtime | Copy `glorbo-linux-aarch64` to a Raspberry Pi / aarch64 VM, run `./glorbo-linux-aarch64 doctor`. Document exit code. |
| Release signing identity cannot be spoofed | FND-05 | Negative test — verifies regex excludes tampered signatures | Attempt verification against a hand-crafted signature from a different repo workflow → `cosign verify-blob` must fail with "no matching signatures" |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (7 test files + 1 workflow YAML)
- [ ] No watch-mode flags (CI-compatible commands only)
- [ ] Feedback latency < 30s for task+wave sampling
- [ ] `nyquist_compliant: true` set in frontmatter once planner binds task IDs to this table

**Approval:** pending — planner will finalize task IDs, then set `nyquist_compliant: true` in frontmatter.
