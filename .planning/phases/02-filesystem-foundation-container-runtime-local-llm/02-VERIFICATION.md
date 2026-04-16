---
phase: 02-filesystem-foundation-container-runtime-local-llm
verified: 2026-04-16T00:08:26Z
status: human_needed
score: 4/6 must-haves verified (2 pending human-on-host)
overrides_applied: 0
gaps: []
deferred: []
human_verification:
  - test: "Run `./glorbo init` on a fresh Fedora-like host (or `rm -rf ~/.glorbo && podman image rm ghcr.io/foobarto/glorbo-runtime:latest`, then `time ./_build/dev/rel/glorbo/bin/glorbo init`)."
    expected: "Wall-clock ≤ 90s; 7 step lines with ✓/⏭/✗ icons; `cat ~/.glorbo/audit/_system/*.jsonl | wc -l` returns 7; idempotent rerun ≤ 5s with most steps ⏭; exit code 0 or 2 (never 1). `tree -L 3 ~/.glorbo/` matches DESIGN.md §3 and `companies/acme/agents/ceo/agent.md` is populated with CEO frontmatter."
    why_human: "Success Criterion #1 is inherently host-dependent (timing, network, Podman/Ollama downloads, QEMU) and was explicitly declared a checkpoint:human-verify task (Plan 04 Task 4). Auto-approved under workflow.auto_advance=true but the Director must execute on target host to fill in SUMMARY's TODO timing table."
  - test: "Airplane-mode LLM-05 proof: `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &`, `ollama pull llama3.2:1b`, then `mix test test/integration/airplane_mode_test.exs --include airplane --include integration --include podman --include ollama`."
    expected: "Test passes. `resp[\"ok\"] == true`, `resp[\"result\"][\"completion\"]` is a non-empty string. Wall-clock after container start ≤ 10s. Q-A3 disposition recorded (ollama-python / litellm unix:// worked OR httpx-UDS shim fallback was required)."
    why_human: "Success Criterion #6 requires: (1) sudo NOPASSWD for nmcli, (2) a running Ollama daemon with a pulled model, (3) the glorbo-runtime image pulled, (4) the Director to physically cut and restore host networking. The test is tagged :airplane + :integration + :podman + :ollama and is excluded from every automated path by design (Plan 04 Task 5)."
---

# Phase 2: Filesystem Foundation + Container Runtime + Local LLM — Verification Report

**Phase Goal:** `glorbo init` converts a fresh host into a working Glorbo installation — Podman and Ollama bootstrapped, `glorbo-runtime` image built, `~/.glorbo/` hierarchy created, audit log appending, reindex contract operational, offline-capable.
**Verified:** 2026-04-16T00:08:26Z
**Status:** human_needed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths (ROADMAP.md §Phase 2 Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `glorbo init` on a fresh Fedora-like host completes in ~1 minute: creates hierarchy, auto-downloads podman+ollama, builds runtime image, pulls default model | ⚠️ HUMAN NEEDED | Orchestrator + Hierarchy + BinaryBootstrap + ImagePull + ExampleCompany + Reindex all wired; `mix compile --warnings-as-errors` clean; 158/158 unit + non-integration tests pass. Wall-clock timing and fresh-host happy-path must be measured on target host (Plan 04 Task 4 auto-approved; timing table in 02-04-SUMMARY.md is TODO). |
| 2 | Deleting `~/.glorbo/glorbo.db` and running `glorbo reindex` fully reconstructs the index from `companies/` + audit JSONL with no user data loss | ✓ VERIFIED | `lib/glorbo/filesystem/reindex.ex` implements MD5-incremental walk, on_conflict upsert, vanished-row cleanup. Integration test `test/integration/reindex_roundtrip_test.exs` asserts round-trip: populate disk → reindex → snapshot → `delete_all` → reindex → snapshot matches. W2 scope note present (audit_events deferred to Phase 3). |
| 3 | Every orchestration event appends to `audit/YYYY-MM.jsonl` append-only AND mirrors to SQLite; entries never modified or deleted | ✓ VERIFIED | `lib/glorbo/company/audit_log.ex` exports ONLY `append/2` + `start_link/1` (grep confirms zero `def update/delete/edit`); JSONL write uses `[:append, :sync]`; SQLite mirror via `Repo.insert(%AuditEvent{...})`. `test/glorbo/stubs_test.exs` negative-asserts absence of update/delete/edit. Orchestrator calls `AuditLog.append/2` once per pipeline step (D-24). |
| 4 | `file_system` (inotify) watchers report filesystem changes with sub-second latency under a test company | ✓ VERIFIED | `lib/glorbo/filesystem/watcher.ex` subscribes to file_system, 100ms debounce, path-prefix routing (agents/inbox, agents/outbox, audit/, channels/, else→reindex). Test 9 in `test/glorbo/filesystem/watcher_test.exs` asserts `< 1000ms` elapsed from `File.touch!/1` to `mark_dirty` invocation. Tagged `:inotify` so hosts without inotify-tools skip gracefully. |
| 5 | A container launches with own dir mounted (no other company visible), `--userns keep-id`, `--read-only`, `network: none`, Python only inside, ephemeral/persistent modes | ✓ VERIFIED | `lib/glorbo/container/invocation.ex` build_argv/4 emits all four flags; `test/glorbo/container/invocation_test.exs` positive-asserts `--userns keep-id`, `--read-only`, `--network none`, `--tmpfs /tmp`, `:Z,ro` company mount; negative-asserts no `--privileged`, no `--cap-add`, no `--network host`, no `API_KEY` env. Ephemeral uses `--rm`; persistent uses `-d` via MuonTrap.Daemon. Isolation proof test `test/integration/container_isolation_test.exs` gated on :podman. Python ONLY inside OCI image (Containerfile), CI verifies via `pytest /app/tests` in-image. |
| 6 | Trivial Ollama inference inside container on airplane-mode host after init | ⚠️ HUMAN NEEDED | Airplane-mode test exists at `test/integration/airplane_mode_test.exs` with all moduletags (:airplane + :integration + :podman + :ollama). Wires `ContainerManager.start_container("acme", agent: "ceo", mode: :persistent, extra_volumes: ["/tmp/ollama.sock:/tmp/ollama.sock:Z,rw"])` + `WorkerClient.post_run/3`. Cannot run in this session: no /tmp/ollama.sock on host, no sudo for nmcli, no Ollama daemon started. Plan 04 Task 5 checkpoint auto-approved but Director must execute on target host. |

**Score:** 4/6 truths verified, 2/6 human-verify-required (Success Criteria #1 and #6 are inherently host-dependent and were explicitly declared as `checkpoint:human-verify` blocking gates in Plan 04).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/glorbo/filesystem/hierarchy.ex` | ensure!/1 + §3 tree | ✓ VERIFIED | `def ensure!` present; `0o700` chmod on runtime/sockets; idempotent |
| `lib/glorbo/filesystem/frontmatter.ex` | parse/1 safe YAML | ✓ VERIFIED | uses yaml_elixir safe loader via yaml_front_matter; 10MB cap; CRLF gap flagged in REVIEW WR-01/02 (non-blocking) |
| `lib/glorbo/filesystem/reindex.ex` | MD5 incremental + B4 wrappers | ✓ VERIFIED | `defp process_file` (private, B4 contract preserved); `def mark_dirty/2` + `def process_path/2` public wrappers added by Plan 04 |
| `lib/glorbo/filesystem/reindex_state.ex` | schema | ✓ VERIFIED | `schema "reindex_state"` present |
| `lib/glorbo/filesystem/watcher.ex` | per-company inotify | ✓ VERIFIED | FileSystem.start_link + subscribe; Process.send_after + Process.cancel_timer debounce; dispatch_by_prefix |
| `lib/glorbo/company.ex` / `agent.ex` / `audit_event.ex` | Ecto schemas | ✓ VERIFIED | All three present; 4 migrations under `priv/repo/migrations/` apply cleanly |
| `lib/glorbo/company/audit_log.ex` | append-only JSONL + SQLite | ✓ VERIFIED | only `append/2` exported; `[:append, :sync]` JSONL write; Repo.insert mirror |
| `lib/glorbo/company/supervisor.ex` | Phase-2 2-child shape (B5) | ✓ VERIFIED | Children list = AuditLog + Watcher only; Router/Scheduler/BudgetTracker explicitly deferred to Phase 3 with comment |
| `lib/glorbo/init/versions.ex` | pinned REAL SHA256s | ✓ VERIFIED | podman v5.8.1 amd64/arm64, ollama v0.20.7 amd64/arm64, all 64-hex real hashes (no placeholders) |
| `lib/glorbo/init/binary_bootstrap.ex` | ensure_podman/ensure_ollama | ✓ VERIFIED | system-first, SHA256-verify, staging-dir extract, :enetunreach skip for offline tolerance |
| `lib/glorbo/init/image_pull.ex` | D-17 cached-fallback | ✓ VERIFIED | on ensure_image :ok → ok; on error + cached → skipped; on error + no cache → error |
| `lib/glorbo/init/example_company.ex` | acme scaffold | ✓ VERIFIED | `company.md` + `agents/ceo/agent.md` (provider: ollama, model: llama3.2:1b, network: none) + channels/general.md + goals/q3-2026.md; idempotent via sentinel |
| `lib/glorbo/init/orchestrator.ex` | 7-step pipeline | ✓ VERIFIED | pre_doctor, hierarchy, binary_bootstrap, image_pull, example_company, reindex, post_doctor all present; AuditLog.append per step (D-24); continue-on-error (D-20); severity-weighted exit (D-45); W3 unconditional AuditLog.start_link; W4 match?/2 in combine/1 |
| `lib/glorbo/init.ex` | public Glorbo.Init.run/1 | ✓ VERIFIED | delegates to Orchestrator.run/1 |
| `lib/glorbo/cli.ex` | :init dispatch + D-23 flags | ✓ VERIFIED | `dispatch(["init" | rest])` branch with `--force`, `--skip-pull`, `--example` via OptionParser strict; `--fix` on doctor accepted with Phase-5 deferral notice; no `--repair` (D-46) |
| `lib/glorbo/container/invocation.ex` | RT-04 flags + extra_volumes | ✓ VERIFIED | all RT-04 flags asserted; `extra_volumes:` keyword back-edit from Plan 04 supports airplane-mode bind-mount |
| `lib/glorbo/container/socket.ex` | 0700 socket dir | ✓ VERIFIED | ensure_dir!/2 with File.chmod 0o700 |
| `lib/glorbo/container/worker_client.ex` | Finch-over-UDS retry-backoff | ✓ VERIFIED | Finch.request with unix_socket:; @backoff_ms = [50,100,200,500,1000,2000] |
| `lib/glorbo/container_manager.ex` | ensure_image + start/stop | ✓ VERIFIED | podman pull idempotent; ephemeral via System.cmd; persistent via MuonTrap.Daemon; extra_volumes threaded |
| `lib/glorbo/doctor.ex` | 13-check runner + severity exit | ✓ VERIFIED | 5 Phase-1 checks + 8 Phase-2 checks (podman/ollama/ollama_daemon/runtime_image/runtime_exec/audit_dir/sockets_dir/tar_zstd); exit_code/1 returns 0/1/2 per severity |
| `containers/glorbo-runtime/Containerfile` | ubuntu:24.04 + python3.12 + AI-SDK | ✓ VERIFIED | FROM ubuntu:24.04; pip3 install -r requirements.txt |
| `containers/glorbo-runtime/requirements.txt` | litellm + fastapi + ollama + hf_hub + anthropic + openai + google-genai | ✓ VERIFIED | all 12 packages pinned |
| `containers/glorbo-runtime/worker/{main,routes,dispatch,context}.py` | FastAPI /run + /cancel over UDS, litellm only | ✓ VERIFIED | FastAPI app; routes.py has /run + /cancel; dispatch.py uses litellm.completion exclusively (no native-SDK imports); context.py uses yaml.safe_load |
| `containers/glorbo-runtime/tests/test_worker.py` | in-image pytest | ✓ VERIFIED | test_app_imports + test_litellm_importable + test_huggingface_hub_importable + test_ollama_importable + /run 404-on-missing-task + /cancel no-live-task |
| `.github/workflows/runtime-image.yml` | multi-arch ghcr push + cosign | ✓ VERIFIED | triggers on `runtime-v*` tags; buildah --platform linux/amd64,linux/arm64; cosign sign; skopeo inspect arches; `pytest /app/tests` in-image smoke |
| `.planning/phases/.../EXAMPLE_COMPANY_README.md` | Director Q-A2 recipe | ✓ VERIFIED | 5-step OLLAMA_HOST=unix:// ritual present |
| `priv/repo/migrations/202604151200{01..04}_*.exs` | companies/agents/audit_events/reindex_state tables | ✓ VERIFIED | 4 migrations present; `mix ecto.migrate` applies cleanly (SQLite WAL DB exists) |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `Glorbo.Filesystem.Reindex` | `Glorbo.Repo` | Repo.insert/delete_all on schemas | ✓ WIRED | upsert_company + upsert_agent + cleanup_vanished |
| `Glorbo.Company.AuditLog` | `audit/YYYY-MM.jsonl` | `File.write!(..., [:append, :sync])` | ✓ WIRED | jsonl_path routing "_system" vs "<company>" |
| `Glorbo.Company.AuditLog` | `Glorbo.AuditEvent` (Repo) | Repo.insert in mirror_to_sqlite | ✓ WIRED | wrapped in try/rescue; JSONL is authoritative |
| `Glorbo.Init.BinaryBootstrap` | `Glorbo.Init.Versions` | Versions.{podman,ollama}_{url,sha256}/1 | ✓ WIRED | sha_for + url_for helpers |
| `Glorbo.Doctor` | `Versions.{podman,ollama}_version/0` | runtime check strings | ✓ WIRED | Required field references Versions |
| `Glorbo.Init.Orchestrator` | `Glorbo.Company.AuditLog` | `AuditLog.append/2` per step | ✓ WIRED | audit_step/1 called after every step |
| `Glorbo.Init.Orchestrator` | `Glorbo.Doctor.run_checks/0` + `exit_code/1` | step_pre_doctor + step_post_doctor | ✓ WIRED | via run_doctor/1 helper (dep-injectable) |
| `Glorbo.Init.Orchestrator` | `Glorbo.Init.BinaryBootstrap` | ensure_podman_fun + ensure_ollama_fun | ✓ WIRED | defaulted to real BinaryBootstrap.ensure_*/1 with override hooks |
| `Glorbo.Filesystem.Watcher` | `Glorbo.Filesystem.Reindex.mark_dirty/2` | dispatch_by_prefix fallback | ✓ WIRED | reindex_fun defaults to `&Reindex.mark_dirty/2` |
| `Glorbo.CLI.dispatch(["init" | _])` | `Glorbo.Init.run/1` | OptionParser → Init.run | ✓ WIRED | :init branch present |
| `Glorbo.Container.Invocation` | podman run argv | pure string list | ✓ WIRED | all RT-04 flags hardcoded; `extra_volumes` extension preserves shape |
| `Glorbo.ContainerManager` | `Invocation.build_argv/4` | inside handle_call :start_container | ✓ WIRED | threads extra_volumes through |
| `.github/workflows/runtime-image.yml` | `ghcr.io/foobarto/glorbo-runtime` | buildah manifest push | ✓ WIRED | multi-arch + cosign + skopeo inspect |

### Data-Flow Trace (Level 4)

Phase 2 is infrastructure-heavy (filesystem + container runtime + CLI). Data-flow tracing focuses on the audit log and reindex paths that span host→DB.

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|--------------------|--------|
| `Glorbo.Company.AuditLog` | JSONL lines + AuditEvent rows | `handle_call({:append, entry}, ...)` | ✓ Yes — `File.write!` with real JSON; `Repo.insert` returns real row | ✓ FLOWING |
| `Glorbo.Filesystem.Reindex` | Company/Agent/ReindexState rows | `do_run/1` walks disk → MD5 → upsert | ✓ Yes — real `Repo.insert!` with `on_conflict: {:replace, ...}` | ✓ FLOWING |
| `Glorbo.Init.Orchestrator` | step_result records | Real step functions (not mocks) | ✓ Yes — real Doctor/Hierarchy/BinaryBootstrap/ImagePull/ExampleCompany/Reindex calls | ✓ FLOWING |
| `Glorbo.Filesystem.Watcher` | `state.pending` timer map | FileSystem.subscribe events | ✓ Yes — real inotify events (when inotify-tools installed); falls through to `reindex_fun` | ✓ FLOWING |
| `Glorbo.Doctor` | check records | Real System.cmd/find_executable/httpc/File.write probes | ✓ Yes — no hardcoded passes | ✓ FLOWING |
| `Glorbo.Container.WorkerClient` | JSON response map | Real Finch.request over UDS | ✓ Yes — not reachable without running container but shape is real | ✓ FLOWING |
| `Glorbo.Init.ExampleCompany` | scaffolded files | `File.write!` with @company_md, @ceo_agent_md, @general_channel_md, @goal_md | ✓ Yes — real markdown content with frontmatter | ✓ FLOWING |

No hollow/stub artifacts detected. `_live_tasks` dict in `worker/routes.py` is a per-process asyncio task registry populated from real task handles (flagged as multi-process-unsafe in REVIEW WR-16 but not hollow).

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Elixir compiles with --warnings-as-errors | `mix compile --warnings-as-errors` | exit 0 | ✓ PASS |
| Full non-integration test suite passes | `mix test --exclude integration --exclude inotify --exclude podman --exclude ollama --exclude airplane` | 158 tests, 0 failures (17 excluded) | ✓ PASS |
| Reindex module keeps `process_file/1` private | `grep -c "defp process_file" lib/glorbo/filesystem/reindex.ex` → 1; `grep -c "^  def process_file"` → 0 | private preserved (B4 contract) | ✓ PASS |
| AuditLog exports only append (no update/delete/edit) | `grep -cE 'def (update\|delete\|edit)' lib/glorbo/company/audit_log.ex` → 0 | negative test passes | ✓ PASS |
| AuditLog uses `[:append, :sync]` | `grep -c ":append, :sync" lib/glorbo/company/audit_log.ex` → 2 | FS-05 fsync-after-every-write preserved | ✓ PASS |
| Invocation argv omits RT-04-forbidden flags | `grep -cE "--privileged\|--cap-add" lib/glorbo/container/invocation.ex` → 0 | RT-04 negative assertions pass | ✓ PASS |
| Invocation argv has no API_KEY env | `grep -ci "api_key" lib/glorbo/container/invocation.ex` → 0 | D-37 negative assertion passes | ✓ PASS |
| Versions.ex has real SHA256s (no placeholders) | 4 real 64-hex strings present; no `"0{64}"` / `"1{64}"` / TODO-A1 | B6 Q-A1 resolved | ✓ PASS |
| Supervisor children = 2 (Phase-2 B5 shape) | `grep -c "Glorbo.Filesystem.Watcher\|Glorbo.Company.AuditLog" lib/glorbo/company/supervisor.ex` → 4 (2 specs × 2 occurrences); 0 Router/Scheduler/BudgetTracker in children block | B5 invariant preserved | ✓ PASS |
| Orchestrator: 7 step atoms present | `:pre_doctor :hierarchy :binary_bootstrap :image_pull :example_company :reindex :post_doctor` all grep-present | D-21 pipeline intact | ✓ PASS |
| CLI has :init branch + no --repair flag | `dispatch(["init" | rest])` present; 0 matches for `repair:` | D-22 + D-46 honored | ✓ PASS |
| Fresh-host `./glorbo init` timing | Requires uncached Fedora host + sudo + network | SKIPPED | ? SKIP (human) |
| Airplane-mode completion | Requires Ollama daemon + cut network + image pulled | SKIPPED | ? SKIP (human) |

All automated spot-checks pass. 2 skipped → route to human verification (matches Plan 04 Tasks 4 + 5 `checkpoint:human-verify` gates).

### Requirements Coverage

All 16 requirement IDs declared in PLAN frontmatter for this phase are cross-referenced below. REQUIREMENTS.md confirms the phase-to-requirement mapping matches (16 IDs, no orphans).

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|-------------|-------------|--------|----------|
| FS-01 | 02-01 | `~/.glorbo/` hierarchy matches DESIGN.md §4/§3 | ✓ SATISFIED | `Glorbo.Filesystem.Hierarchy.ensure!/1` materialises full §3 tree; hierarchy_test covers all dirs + modes + idempotency |
| FS-02 | 02-01 | Markdown + YAML frontmatter is canonical storage | ✓ SATISFIED | `Frontmatter.parse/1` + schemas use `file_path` as PK/unique; ExampleCompany writes real markdown with YAML frontmatter |
| FS-03 | 02-01 | `glorbo reindex` fully reconstructs SQLite from disk | ✓ SATISFIED | `Reindex.run/1` + `do_run/1` + `cleanup_vanished/1` |
| FS-04 | 02-01 | Delete glorbo.db → reindex → identical rows | ✓ SATISFIED | `test/integration/reindex_roundtrip_test.exs` proves; W2-scoped to companies+agents+reindex_state (audit_events import deferred to Phase 3 per W2 note) |
| FS-05 | 02-01 | Append-only JSONL + SQLite mirror | ✓ SATISFIED | `[:append, :sync]` + mirror; no update/delete/edit in module |
| FS-06 | 02-04 | file_system sub-second latency | ✓ SATISFIED | `watcher_test.exs` Test 9 asserts `< 1000ms` |
| RT-01 | 02-02 | Rootless podman auto-downloaded when missing | ✓ SATISFIED | `ensure_podman/1` system-first fallback to download |
| RT-02 | 02-03 | `glorbo-runtime` OCI image built + cached | ✓ SATISFIED | Containerfile + CI multi-arch workflow + `ContainerManager.ensure_image/1` idempotent |
| RT-03 | 02-03 | Per-company container, no cross-company FS access | ✓ SATISFIED | `:Z` SELinux label + single company `/company` bind-mount; `container_isolation_test.exs` integration proof (gated :podman) |
| RT-04 | 02-03 | `--userns keep-id` + `--read-only` + `network: none` | ✓ SATISFIED | Invocation positive + negative tests |
| RT-05 | 02-03 | Ephemeral default, persistent opt-in | ✓ SATISFIED | mode `:ephemeral` → `--rm`; mode `:persistent` → `-d` via MuonTrap.Daemon |
| RT-06 | 02-03 | Python never on host | ✓ SATISFIED | All Python inside Containerfile; `pytest /app/tests` runs inside image; no host-side Python invocation (`grep -r "python3" lib/` returns nothing beyond the Containerfile string) |
| LLM-01 | 02-02 | Ollama auto-downloaded by `glorbo init` | ✓ SATISFIED | `ensure_ollama/1` tar.zst extraction + `usr/bin/ollama` install |
| LLM-02 | 02-03 | Hugging Face local models supported | ✓ SATISFIED | `huggingface-hub==0.25.*` in requirements.txt + `test_huggingface_hub_importable` in-image |
| LLM-05 | 02-04 | Full e2e works offline after init | ⚠️ NEEDS HUMAN | `airplane_mode_test.exs` wired, but requires on-host ritual (Ollama daemon + cut network + pulled model). Plan 04 Task 5 explicitly blocking:human-verify, auto-approved via workflow.auto_advance. |
| CLI-02 | 02-04 | `glorbo init` bootstraps missing Podman/Ollama in ~1 min | ⚠️ NEEDS HUMAN | Orchestrator delivers full pipeline; timing budget must be measured on fresh Fedora-like host. Plan 04 Task 4 explicitly blocking:human-verify, auto-approved via workflow.auto_advance. |

**Orphan check:** REQUIREMENTS.md maps 16 IDs to Phase 2; PLAN frontmatter declares 16 IDs (FS-01..06 + RT-01..06 + LLM-01, LLM-02, LLM-05 + CLI-02). No orphans.

### Anti-Patterns Found

The phase's code review (02-REVIEW.md) enumerates 40 findings (7 Critical, 16 Warning, 17 Info). Per instructions these are tracked for a separate fix cycle and do NOT block Phase 2. Headline items, included for visibility:

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/glorbo/filesystem/reindex.ex` | 87, 207-227 | Orphan Agent row on missing company.md | 🛑 CR-01 | Agents without parent company_id silently persist |
| `lib/glorbo/company/audit_log.ex` | 140-145 | `month_bucket/1` uses local-date — non-UTC crosses boundary | 🛑 CR-02 | Cross-TZ rollover mis-bucketing |
| `lib/glorbo/container_manager.ex` | 87-104 | No stale-container pre-clean | 🛑 CR-03 | Restart collisions after SIGKILL |
| `lib/glorbo/container_manager.ex` | 131-142 | Persistent Daemon unsupervised | 🛑 CR-04 | Crash kills ContainerManager — violates CLAUDE.md crash isolation invariant |
| `containers/glorbo-runtime/worker/routes.py` | 57-71 | Duplicate request_id + create_task+wait_for race | 🛑 CR-05 | /cancel misroutes; hidden duplicate-id state corruption |
| `lib/glorbo/container_manager.ex` | 40, 57, 62 | Public API ignores `:name` opt | 🛑 CR-06 | Custom-name wiring crashes |
| `containers/glorbo-runtime/worker/dispatch.py` | 29-47 | api_key not scrubbed on error path | 🛑 CR-07 | Possible D-37 leak through litellm exceptions |

Per instructions: **logged, not blocking.** Tracked in `02-REVIEW.md` for a separate fix cycle. None of these regressed verified truths — they are correctness/robustness issues discovered post-delivery.

### Human Verification Required

See `human_verification` array in frontmatter. Both items are existing `checkpoint:human-verify` gates declared in Plan 04 (Task 4 timing + Task 5 airplane-mode), auto-approved by the GSD orchestrator under `workflow.auto_advance=true` but requiring Director execution on a target Fedora-like host. The SUMMARY's TODO timing tables remain blank pending that execution.

### Gaps Summary

No blocking code/link gaps found. Two success-criteria require physical on-host execution (fresh-install timing and airplane-mode LLM inference). The code that backs both is present, wired, and test-gated — the remaining verification is a manual ritual on a target host that this agent cannot perform (no sudo, no /tmp/ollama.sock, no uncached Fedora host).

The 7 CR-class items in `02-REVIEW.md` are correctness issues tracked for a separate fix cycle per user instruction and do not block phase completion.

---

_Verified: 2026-04-16T00:08:26Z_
_Verifier: Claude (gsd-verifier)_
