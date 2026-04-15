---
phase: 2
slug: filesystem-foundation-container-runtime-local-llm
status: planned
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-15
last_updated: 2026-04-16
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir) — established in Phase 1 |
| **Config file** | `test/test_helper.exs`, `config/test.exs` |
| **Quick run command** | `mix test --stale` |
| **Full suite command** | `mix test` |
| **Estimated runtime** | ~15s quick, ~60s full (container-gated tests add ~30s when enabled) |

Container/Ollama integration tests are gated behind `@tag :podman`, `@tag :ollama`, `@tag :integration`, and `@tag :airplane` — excluded by default, included by `mix test --include podman` etc. on dev hosts with rootless Podman + kernel support.

---

## Sampling Rate

- **After every task commit:** `mix test --stale`
- **After every plan wave:** `mix test` (host-only tests)
- **Before `/gsd-verify-work`:** `mix test --include podman --include ollama --include integration` must be green on a Fedora-like dev host
- **Max feedback latency:** 60 seconds (host-only); 120 seconds (with container tags)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-01-01 | 01 | 1 | FS-01, FS-05 | T-2-02, T-2-07 | Hierarchy idempotent; sockets dir 0700; audit_events table DDL safe | unit | `mix test test/glorbo/filesystem/hierarchy_test.exs` | ❌ W0 | ⬜ pending |
| 2-01-02 | 01 | 1 | FS-02, FS-03, FS-04 | T-2-01, T-2-03, T-2-08 | YAML safe-load only; symlink escape rejected; parameterized Ecto queries | unit + integration | `mix test test/glorbo/filesystem/frontmatter_test.exs test/glorbo/filesystem/reindex_test.exs test/integration/reindex_roundtrip_test.exs --include integration` | ❌ W0 | ⬜ pending |
| 2-01-03 | 01 | 1 | FS-05 | T-2-02 | Append-only verb surface; JSONL written with `[:append, :sync]` before SQLite mirror | unit | `mix test test/glorbo/company/audit_log_test.exs test/glorbo/stubs_test.exs` | ❌ W0 (stubs_test exists; extend) | ⬜ pending |
| 2-02-01 | 02 | 1 | RT-01, LLM-01 | T-2-10, T-2-11, T-2-12 | SHA256 verified before extract; TLS via curl default; allow-list copy from staging | unit | `mix test test/glorbo/init/versions_test.exs test/glorbo/init/binary_bootstrap_test.exs` | ❌ W0 | ⬜ pending |
| 2-02-02 | 02 | 1 | RT-01, LLM-01 (doctor surface) | T-2-14, T-2-15, T-2-16 | Doctor additive-only schema; severity-weighted exit code surfaces "needs bootstrap" vs "host broken" | unit | `mix test test/glorbo/doctor_test.exs test/glorbo/cli_test.exs` | ⚠️ extends Phase 1 | ⬜ pending |
| 2-03-01 | 03 | 1 | RT-06, LLM-02 | T-2-23, T-2-26, T-2-29 | No API-key env injection; PyYAML safe_load; rootless image build in CI | manual (image build) + unit | `test -f containers/glorbo-runtime/Containerfile && grep 'litellm' containers/glorbo-runtime/requirements.txt` | ❌ W0 | ⬜ pending |
| 2-03-02 | 03 | 1 | RT-02, RT-03, RT-04, RT-05 | T-2-21, T-2-22, T-2-24 | Invocation enforces --userns/--read-only/--network none; socket dir 0700; negative tests for --privileged/--network host/API_KEY env | unit + integration | `mix test test/glorbo/container/invocation_test.exs test/glorbo/container/socket_test.exs test/glorbo/container/worker_client_test.exs && mix test test/integration/container_isolation_test.exs test/integration/container_lifecycle_test.exs --include podman --include integration` | ❌ W0 | ⬜ pending |
| 2-03-03 | 03 | 1 | RT-02 (multi-arch CI) | T-2-20, T-2-31 | Cosign keyless signs image; skopeo verifies multi-arch manifest | manual CI | `actionlint .github/workflows/runtime-image.yml \|\| true` (best-effort) | ❌ W0 | ⬜ pending |
| 2-04-01 | 04 | 2 | FS-06 | T-2-43, T-2-44 | Debounce bounded per path; :stop logged; supervisor restarts preserve invariants | unit + integration | `mix test test/glorbo/filesystem/watcher_test.exs --include integration` | ❌ W0 | ⬜ pending |
| 2-04-02 | 04 | 2 | CLI-02 (orchestrator) | T-2-40, T-2-42, T-2-48 | OptionParser strict; path expansion prevents traversal; audit-per-step provenance | unit | `mix test test/glorbo/init/example_company_test.exs test/glorbo/init/orchestrator_test.exs` | ❌ W0 | ⬜ pending |
| 2-04-03 | 04 | 2 | CLI-02 (CLI dispatch) | T-2-40 | CLI :init branch; no --repair flag; --fix accepted on doctor | unit | `mix test test/glorbo/cli_test.exs` | ⚠️ extends Phase 1 | ⬜ pending |
| 2-04-04 | 04 | 2 | CLI-02 (timing) | — | Manual ritual: `rm -rf ~/.glorbo && time ./glorbo init`; assert ≤ 90s | manual | N/A — see Manual-Only Verifications | ❌ W0 | ⬜ pending |
| 2-04-05 | 04 | 2 | LLM-05 | T-2-46 | Airplane-mode ritual: host network off → WorkerClient over UDS → Ollama host bind-mount → completion | manual + integration | `mix test test/integration/airplane_mode_test.exs --include airplane` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky · ⚠️ extends = file exists from Phase 1 and is extended here*

---

## Wave 0 Requirements

Every test file referenced in the Per-Task Verification Map is new and must be scaffolded by its owning plan's Task 1 (or the first task that writes production code). Wave 0 deliverables:

- [ ] `test/support/tmp_glorbo_home.ex` — ExUnit helper that creates an isolated `~/.glorbo/`-shaped tree under `System.tmp_dir!()` (Plan 01 Task 1)
- [ ] `test/support/podman_case.ex` — `@moduletag :podman` + skip-when-absent fixture (Plan 02 Task 1)
- [ ] `test/support/ollama_case.ex` — `@moduletag :ollama` + skip-when-absent fixture (Plan 02 Task 1)
- [ ] `test/glorbo/filesystem/hierarchy_test.exs` — FS-01 + migrations (Plan 01 Task 1)
- [ ] `test/glorbo/filesystem/frontmatter_test.exs` — FS-02 + YAML safe-load (Plan 01 Task 2)
- [ ] `test/glorbo/filesystem/reindex_test.exs` — FS-03 MD5 incremental (Plan 01 Task 2)
- [ ] `test/glorbo/company/audit_log_test.exs` — FS-05 JSONL + SQLite mirror + append-only (Plan 01 Task 3)
- [ ] `test/integration/reindex_roundtrip_test.exs` — FS-04 round-trip proof (Plan 01 Task 2)
- [ ] `test/glorbo/init/versions_test.exs` — RT-01/LLM-01 version pins (Plan 02 Task 1)
- [ ] `test/glorbo/init/binary_bootstrap_test.exs` — RT-01/LLM-01 download+verify (Plan 02 Task 1)
- [ ] `test/glorbo/container/invocation_test.exs` — RT-04 argv flags + negatives (Plan 03 Task 2)
- [ ] `test/glorbo/container/socket_test.exs` — socket dir lifecycle (Plan 03 Task 2)
- [ ] `test/glorbo/container/worker_client_test.exs` — UDS Finch + backoff (Plan 03 Task 2)
- [ ] `test/integration/container_isolation_test.exs` — RT-03 cross-company isolation (Plan 03 Task 2)
- [ ] `test/integration/container_lifecycle_test.exs` — RT-05 ephemeral + persistent (Plan 03 Task 2)
- [ ] `test/integration/image_pull_test.exs` — RT-02 podman pull (Plan 03 Task 2)
- [ ] `test/glorbo/filesystem/watcher_test.exs` — FS-06 sub-second (Plan 04 Task 1)
- [ ] `test/glorbo/init/example_company_test.exs` — D-10 scaffold (Plan 04 Task 2)
- [ ] `test/glorbo/init/orchestrator_test.exs` — D-21 pipeline (Plan 04 Task 2)
- [ ] `test/integration/airplane_mode_test.exs` — LLM-05 proof (Plan 04 Task 5)
- [ ] `containers/glorbo-runtime/tests/conftest.py` + `test_worker.py` — in-image pytest (Plan 03 Task 1)

*All test-support helpers follow the `.ex`-under-`test/support/` convention established by Phase 1 Plan 01 (decision row in STATE.md). `:integration`, `:podman`, `:ollama`, `:airplane` tags are excluded from `mix test` default set.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Airplane-mode Ollama inference | Success Criterion #6, LLM-05 | Requires operator to physically disable networking (`sudo nmcli networking off`) — cannot be reliably simulated inside CI; also requires Director pre-start of `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve` | Plan 04 Task 5 checkpoint. Ritual: (1) complete `glorbo init`, (2) `mkdir -p /tmp && OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &`, (3) `ollama pull llama3.2:1b`, (4) `mix test test/integration/airplane_mode_test.exs --include airplane`; assert non-empty completion ≤ 10s |
| `glorbo init` on a fresh Fedora-like host completes in ~1 minute (Success Criterion #1) | CLI-02, RT-01..06, FS-01..05 | First-run behavior depends on host state (no `~/.glorbo/`, no podman, no ollama) — automated test can simulate but cannot prove "fresh host" | Plan 04 Task 4 checkpoint. Ritual: `podman system reset --force; rm -rf ~/.glorbo && time ./glorbo init`. Record timing in 02-04-SUMMARY.md. Idempotent re-run: `time ./glorbo init` expect < 5s |
| SELinux/AppArmor label interaction with bind mounts (`:Z`) | RT-03 | Behavior differs across Fedora Silverblue, Ubuntu, RHEL; ExUnit cannot assert enforcement context | Doctor check reports the active LSM; operator verifies labels on a Silverblue host as part of phase sign-off. Test via `ls -Z ~/.glorbo/companies/acme/` after `glorbo up` in Phase 3 — but Phase 2 documents the `:Z` mount flag is present in Invocation.build_argv/4 |
| First ghcr.io multi-arch image push (Plan 03 Task 3) | RT-02 (CI-delivered) | Requires pushing a git tag `runtime-v0.1.0` which triggers a production workflow — cannot be exercised by ExUnit | After Plan 03 merge: `git tag runtime-v0.1.0 && git push origin runtime-v0.1.0`. Observe GitHub Actions green. Verify: `skopeo inspect --raw docker://ghcr.io/foobarto/glorbo-runtime:v0.1.0 \| jq '.manifests[].platform.architecture'` returns `["amd64","arm64"]` and `cosign verify --certificate-identity-regexp 'foobarto/glorbo' --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/foobarto/glorbo-runtime:v0.1.0` succeeds |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags (no `--watch`, no `mix test.watch`)
- [x] Feedback latency < 120s with container tags (excluding `:airplane` ritual)
- [ ] `nyquist_compliant: true` set in frontmatter — flipped by plan-checker after review
- [x] All 6 Success Criteria from ROADMAP.md mapped (Per-Task Map rows + Manual-Only entries)

**Approval:** pending plan-checker review
