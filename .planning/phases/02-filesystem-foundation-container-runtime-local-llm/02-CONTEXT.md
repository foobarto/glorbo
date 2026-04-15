# Phase 2: Filesystem Foundation + Container Runtime + Local LLM - Context

**Gathered:** 2026-04-15
**Status:** Ready for planning

<domain>
## Phase Boundary

`glorbo init` turns a fresh Fedora-like host into a working Glorbo installation in ~1 minute: creates the `~/.glorbo/` hierarchy from `DESIGN.md` §3, downloads Podman and Ollama static binaries when absent, pulls and caches the `glorbo-runtime` OCI image, scaffolds an example company, and leaves the host with an appending audit log, a reindex-from-disk contract, per-company inotify watchers, and a rootless-Podman/FastAPI-over-Unix-socket runtime path proven by an airplane-mode Ollama inference call.

Agents, routing, permissions, budgets, channel semantics, and the LiveView dashboard are **out of scope** for this phase — module stubs from Phase 1 remain stubs. This phase proves the *runtime contract*: that markdown + binaries + containers + a rebuildable SQLite index compose into a directory that behaves like a Glorbo install.

</domain>

<decisions>
## Implementation Decisions

### Binary bootstrap (Podman + Ollama)
- **D-01:** Source — download `podman-static` and `ollama` from their official GitHub release assets. No CDN, no package-manager path.
- **D-02:** Versions are **pinned** in a bundled versions file (not "latest"). Upgrades are explicit Glorbo release bumps.
- **D-03:** Integrity — verify SHA256 checksums from each release's checksum file. No GPG/cosign verification of the upstream artifacts (relies on HTTPS + GitHub's TLS).
- **D-04:** System-install preference — if `podman`/`ollama` is already in `$PATH`, **use the system binary**; only fall back to downloading the static binary when absent. Applies to both binaries.
- **D-05:** Download destination — `~/.glorbo/bin/` directly (no temp-dir staging).
- **D-06:** Ollama daemon — `glorbo init` does **not** auto-start `ollama serve`. It only guarantees the binary is installed; the Director runs `ollama serve` themselves (or systemd-units it).
- **D-07:** Default model — `init` pulls **no** default model. Fastest init; Director picks via `ollama pull` afterward.
- **D-08:** Missing system deps (e.g. `uidmap`) — `init` warns and continues. Final doctor check flags as warning, not blocker.
- **D-09:** Offline-tolerance — if the network is unreachable, skip every download step with a clear "skipped: no network" message; continue the rest of init to completion.
- **D-10:** Example company — `init` scaffolds an example company (`acme`) with a CEO agent, a `general` channel, and a simple goal. Gives the Director something to `glorbo up` immediately.

### `glorbo-runtime` container image
- **D-11:** Base — **Ubuntu** (`ubuntu:24.04` or similar stable tag). ~200MB, broad Python-AI-SDK compatibility, stable glibc. Not Fedora-aligned with host, but the tradeoff is deliberate.
- **D-12:** Python package set — **full** AI-SDK list from `DESIGN.md` §4.2: `ollama`, `huggingface_hub`, `anthropic`, `openai`, `google-genai`, `litellm`. Build everything upfront; no Phase-3 rebuild.
- **D-13:** Entrypoint shape — **FastAPI server** (uvicorn) inside the container. Elixir sends tasks via POST over a Unix socket. Not a thin one-shot worker.
- **D-14:** Image creation — **pre-built OCI image** shipped via container registry (not built at init time). Version-coupled to the Glorbo release.
- **D-15:** Image host — **`ghcr.io/foobarto/glorbo-runtime`**, **public** repo (contains no secrets; reproducible from the public `Containerfile`).
- **D-16:** Tagging — **version-tagged + `latest`** (`v0.1.0`, `v0.2.0`, …, `latest`). Release binary and image versions move together.
- **D-17:** Pull failure at init — if `podman pull` fails (no network), use cached image if present; otherwise warn that "LLM execution requires network for first pull" and continue the rest of init.

### Init orchestration flow
- **D-18:** Progress UX — **step-by-step with ✓/⏭/✗** lines, matching `doctor`'s visual style (`✓ Created ~/.glorbo/`, `⏭ Ollama already installed (system)`, `✗ Could not pull image`).
- **D-19:** Idempotency — **fully idempotent** and safe to re-run. `mkdir -p` for dirs, existence-check before every download, Podman/layer caching for images. Directly supports `init --repair`.
- **D-20:** Error handling — **continue-on-error + end-of-run summary**. Collect failures, print an aggregated block at the end. Accepts partial-init state in exchange for showing the Director every problem at once.
- **D-21:** Step ordering — **doctor first and last**:
  1. Doctor (pre-flight)
  2. Create `~/.glorbo/` hierarchy
  3. Install/verify Podman + Ollama binaries
  4. Pull `glorbo-runtime` image
  5. Scaffold example company
  6. `glorbo reindex`
  7. Doctor (post-flight verification)
- **D-22:** CLI wiring — extend `Glorbo.CLI.dispatch/1` with an `:init` branch (same shape as `:doctor`). Returns the `{verb, exit_code, output}` tuple. No separate Mix task.
- **D-23:** Flags — **`--repair`, `--force`, `--skip-pull`, `--example`**. `--repair` rebuilds the container image (Phase 5 fuller semantics); `--force` ignores warnings; `--skip-pull` skips binary + image downloads; `--example` toggles example-company scaffolding.
- **D-24:** Audit granularity — **one audit event per init step** (doctor, download-podman, download-ollama, pull-image, scaffold-company, reindex, post-doctor). Every `init` run leaves a structured trail in `audit/YYYY-MM.jsonl`.
- **D-25:** Doctor coupling — `init` calls `Glorbo.Doctor.run_checks/0` programmatically, parses the result (shared module from Phase 1), and reports per-check status in its own output.

### Reindex strategy + SQLite schemas
- **D-26:** Reindex algorithm — **incremental** via MD5 content hashing. A `reindex_state` table stores `file_path → md5 → size → mtime`. Reindex hashes all files, upserts only changed rows, deletes rows for missing files. Full-rebuild equivalent is `DELETE FROM reindex_state; reindex`.
- **D-27:** Hash — **MD5** (fast enough for <10KB markdown; no NIF dependency). XXH128 considered and rejected for the NIF surface-area cost.
- **D-28:** Ecto schemas (Phase 2 scope) — **minimal**: `companies`, `agents`, `audit_events`, `reindex_state`. `tasks`, `channels`, `budgets`, `projects`, `skills` schemas are deferred to Phase 3.
- **D-29:** Corrupt markdown handling — `reindex` logs a warning (file path + parse error), **skips** the file, continues. End-of-run summary lists every skipped file.

### File watcher architecture
- **D-30:** Watcher topology — **one `file_system` watcher process per company**, started under that company's supervisor. Matches the `DESIGN.md` §4.1 crash-isolation invariant.
- **D-31:** Event set — subscribe to **`:created`, `:modified`, `:deleted`**. All three route to reindex and (where applicable) agent wake / audit handler.
- **D-32:** Debounce — **100ms** via `Process.send_after`. Coalesces rapid bursts before dispatching.
- **D-33:** Watch shape — **recursive watch on the full company tree**, path-prefix router: `agents/<name>/inbox/` → agent-wake signal; `audit/` → audit-log handler; `channels/` → channel update; everything else → reindex.

### Python worker API contract
- **D-34:** Transport — **Unix domain socket, bind-mounted** from host into container. Host side: `~/.glorbo/runtime/sockets/<company>/<agent>.sock`. Container side: `unix:/run/agent.sock`. Uvicorn binds there directly; Elixir connects via `Finch`/`Mint`/`:gen_tcp` Unix-socket support. Preserves `network: none` default cleanly.
- **D-35:** Socket ownership — **Elixir owns the containing dir** with restrictive POSIX ACLs (agent's Linux user only). Uvicorn creates/unlinks the socket inside. Elixir unlinks stale sockets before next container start.
- **D-36:** Request shape — POST `/run` body carries `{task_path, provider, model, api_key, skills[], timeout_seconds?}`. Python reads `task.md`, `agent.md`, and `skills/<n>.md` from the mounted filesystem itself. Keeps "filesystem is source of truth" honest on both sides of the container boundary.
- **D-37:** API key injection — **per-request body field** (`api_key`). Never a container env var, never written to the company directory, never visible in `podman inspect`. Lives only in request-scope memory.
- **D-38:** Streaming — **file tail of `agents/<name>/stdout.log`**. Python writes tokens and stdout there; Elixir's inotify watcher tails and publishes to PubSub (Phase 4 dashboard hook). Transport carries request + final result only; no NDJSON/SSE streaming protocol.
- **D-39:** Readiness — **retry-connect with backoff** (50ms → 100ms → 200ms → 500ms, ~5s total). No `/health` polling loop, no filesystem ready-marker.
- **D-40:** LLM provider dispatch — **`litellm` as the unified layer** inside the worker. One `litellm.completion(model="anthropic/claude-...", ...)` code path for every provider (Ollama / Anthropic / OpenAI / Google / HF local). Matches the one-provider-per-agent model and single-error-surface philosophy.
- **D-41:** Timeout contract — **global default (300s) with per-agent override** via `agent.md` frontmatter `timeout_seconds: N`. On timeout, Elixir `podman kill`s the container, logs a `timeout` audit event, sets the task status to `failed`. No auto-retry — retry is a Director decision.
- **D-42:** Cancellation — **two-phase: graceful → kill**. Elixir POSTs `/cancel` to FastAPI first (asyncio task cancellation, partial stdout flush, `cancelled` audit event). If the worker doesn't respond within 5s, `podman kill` the container. Preserves partial state when possible, guarantees termination.

### Doctor scope expansion (Phase 2)
- **D-43:** Check set — **full runtime checks** (binary + version + exec-test tier):
  - podman: present, version ≥ pinned
  - ollama: present, version ≥ pinned; daemon reachable (HTTP 200 on `/api/version`)
  - `glorbo-runtime` image: present, digest matches pinned tag
  - container exec smoke test: `podman run --rm glorbo-runtime python -c "import litellm"` exits 0
  - `~/.glorbo/audit/` writable
  - `~/.glorbo/runtime/sockets/` writable
  
  Deeper than Phase 1 (~1–2s runtime), but high-confidence: catches "image present but broken" class of bugs.
- **D-44:** JSON schema — **additive only**. Phase 1 keys (`kernel`, `uidmap`, `disk`, `home_perms`, `erts`) stay identical. Phase 2 appends new keys (`podman`, `ollama`, `ollama_daemon`, `runtime_image`, `runtime_exec`, `audit_dir`, `sockets_dir`). No renames, no removals, no `schema_version` bump.
- **D-45:** Exit codes — **severity-weighted**:
  - `0` = all pass
  - `1` = any **blocker** fails (kernel, home_perms, uidmap-hard, ERTS, audit_dir write)
  - `2` = **warnings only** (missing podman binary, stopped ollama daemon, unbuilt image, missing uidmap-soft)
  
  Lets `glorbo init` script-distinguish "host broken" from "needs bootstrap".
- **D-46:** Doctor mutation posture — **read-only + `~/.glorbo/` creation** (unchanged from Phase 1) for the plain `doctor` invocation. Introduce `doctor --fix` as an **alias to `init --repair`** — a more-discoverable entry point from the doctor output without forking the implementation. Mental model: doctor reports; `--fix`/`init --repair` repair; plain `init` bootstraps from scratch.

### Claude's Discretion
- Exact doctor table layout for new Phase 2 rows (colors, spacing, truncation of version strings).
- Ecto migration file ordering and names — just keep schemas in the order above.
- FastAPI JSON response envelope shape (e.g. `{ok: bool, result: ..., error: ...}` vs status code + body) — pick the simpler idiomatic one at planning time.
- `reindex_state` PK choice (composite `(company_id, file_path)` vs synthetic id).
- Audit event JSON keys for init-step events (stable within phase, refine in Phase 3).
- `ubuntu:24.04` vs a minimal derivative (e.g. `ubuntu:24.04-slim`, `chainguard/python`) — whichever minimizes image size without losing glibc compat.
- Backoff curve for retry-connect on the Unix socket (the numbers in D-39 are guidance, not contractual).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §3 — `~/.glorbo/` directory hierarchy (companies/, agents/, audit/, bin/, config.md, runtime/)
- `DESIGN.md` §4.1 — Elixir/Phoenix supervision-tree shape (CompanySupervisor, FileWatcher, Router, AuditLog)
- `DESIGN.md` §4.2 — Python runtime, container entrypoint, AI-SDK set
- `DESIGN.md` §4.4 — Podman container runtime configuration (`--userns keep-id`, `--read-only`, `--network none`)
- `DESIGN.md` §4.5 — SQLite index + `reindex` rebuild contract
- `DESIGN.md` §7 — Permissions & isolation (company isolation absolute; ACLs; foreshadowed for Phase 3)
- `DESIGN.md` §8.3 — Append-only JSONL audit log format
- `DESIGN.md` §10 — CLI surface, including `glorbo init`, `init --repair`, `doctor`, `reindex`
- `DESIGN.md` §11 — Deployment & portability (init bootstraps; system dependency list)

### Project-level constraints
- `CLAUDE.md` — Load-bearing invariants (kernel-is-policy-engine, filesystem-as-source-of-truth, one-way inbox/outbox, append-only audit, Python-never-on-host, company isolation, OTP crash isolation)
- `.planning/PROJECT.md` — Core value "it's just a directory"; Key Decisions table (Elixir/OTP on host, Python only in containers; Podman over Docker; SQLite as rebuildable index; Ollama default)
- `.planning/REQUIREMENTS.md` — FS-01..06, RT-01..06, LLM-01, LLM-02, LLM-05, CLI-02 (15 requirements this phase must satisfy)
- `.planning/ROADMAP.md` Phase 2 — six concrete success criteria

### Phase 1 handoff
- `.planning/phases/01-compilable-skeleton-ci-release-pipeline/01-CONTEXT.md` — Phase 1 decisions, especially D-06 (module stubs for `Glorbo.FileSystem.*`, `Glorbo.ContainerManager`, `Glorbo.AuditLog`), D-18..D-21 (Doctor module architecture — shared between Mix task and release binary, `--json` mode required because Phase 2 `init` parses it)
- Phase 1 commit history — argv dispatch via `__BURRITO` env var (not argv emptiness); Doctor shared module + formatter pattern to extend

### External specs to investigate during research
- Podman rootless networking: https://docs.podman.io/en/latest/markdown/podman-run.1.html — `--network none` semantics, bind-mount for Unix socket transport
- uvicorn Unix socket binding: `uvicorn --uds /run/agent.sock` — confirm behaviour under bind-mount inside rootless container
- `file_system` Elixir library: https://github.com/falood/file_system — inotify backend, recursive watching, debounce patterns
- litellm unified LLM API: https://docs.litellm.ai/ — provider string format (`"anthropic/claude-..."`), streaming semantics, error taxonomy
- Ollama HTTP API: https://github.com/ollama/ollama/blob/main/docs/api.md — `/api/version`, `/api/generate`, daemon lifecycle
- podman-static releases: https://github.com/containers/podman/releases — static binary availability per arch, checksum layout
- Ollama binary releases: https://github.com/ollama/ollama/releases — static asset naming conventions

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`Glorbo.Doctor`** (`lib/glorbo/doctor.ex`, Phase 1) — shared module with `run_checks/0` returning a list of check maps. Phase 2 extends by appending new check functions (podman, ollama, runtime_image, runtime_exec, audit_dir, sockets_dir) to the same pipeline.
- **`Glorbo.Doctor.Formatter`** — table + `--json` rendering. Phase 2 adds new row types; no rendering logic changes.
- **`Glorbo.CLI.dispatch/1`** — argv router from Phase 1 that already dispatches `doctor`. Phase 2 adds `init` (and extends `doctor` with `--fix`/`--deep` flags).
- **Supervision-tree stubs** from Phase 1 `D-06`: `Glorbo.FileSystem.*`, `Glorbo.ContainerManager`, `Glorbo.AuditLog`, `Glorbo.CompanySupervisor`. These are where per-company file watchers, Podman invocations, audit JSONL appenders, and the per-company runtime path land — public function shapes already stable (Phase 1 D-07).
- **Burrito release pipeline** (Phase 1 D-08..D-10) — the `init` binary wraps this; no release-mechanism changes needed.
- **`ecto_sqlite3` + WAL** (Phase 1 D-04) — configured and tested. Phase 2 adds migrations against this; does not re-plumb the database layer.

### Established Patterns
- **Mix-task + CLI-dispatch shared module** (Phase 1 Doctor). Phase 2 `init` follows the same shape: orchestration logic in `Glorbo.Init`, callable by both `Glorbo.CLI.dispatch([:init, ...])` and (if useful) a Mix task.
- **Argv dispatch gated on `__BURRITO`** (Phase 1 D-11 equivalent) — means `iex -S mix` still starts the OTP supervision tree; only the Burrito binary routes to CLI. Phase 2 init must respect that gating.
- **Shared-dep-injection for host-independent unit tests** (Phase 1 Doctor pattern) — every check takes a keyword-list of injectable functions so tests don't hit the real kernel / disk / Podman. Phase 2 extends this pattern to Podman/Ollama/image checks.

### Integration Points
- **Phase 3 handoff:** `reindex_state`, `audit_events`, `companies`, `agents` Ecto schemas are the contract Phase 3 builds on. Column names must be stable across Phase 2 → 3. Agent Linux-user provisioning and POSIX ACL application happen in Phase 3 on top of Phase 2's directory hierarchy.
- **Phase 3 handoff:** The Unix socket path convention (`~/.glorbo/runtime/sockets/<company>/<agent>.sock`) and the `/run` / `/cancel` FastAPI contract become the Router's transport in Phase 3. Don't break either.
- **Phase 4 handoff:** `stdout.log` tailing via inotify, published to PubSub, is what powers the dashboard's live-stdout pane in Phase 4. Phase 2 must wire the file-watcher → PubSub pipeline even though no dashboard consumer exists yet — the publish side is reusable.
- **Phase 5 handoff:** `init --repair` is invoked after `glorbo restore` on a new host. Phase 2 defines the semantic ("rebuild/refetch container image, re-verify binaries, reindex from disk") that Phase 5 must preserve.

</code_context>

<specifics>
## Specific Ideas

- **Transport vs network-policy tension is real.** The Python-worker transport decision (D-34: Unix socket) was the last unforced choice that made `network: none` viable by default. HTTP-on-loopback would have forced a new "loopback-only" network policy tier; stdin/stdout would have forfeited mid-task streaming. Unix socket is the only option that composes cleanly with the three locked invariants: network-none, Elixir-on-host-only, and filesystem-first.
- **Elixir-in-container was raised and rejected.** The scope requested whether running an Elixir distribution node inside each container (alongside Python) would simplify IPC. Response: net-negative. Breaks `network: none` (distribution needs TCP), bloats every container by ~50–70MB of BEAM/ERTS, contradicts the PROJECT.md-locked "Elixir/OTP on host, Python only in containers" decision, puts BEAM adjacent to LLM-generated Python (erodes the container's supply-chain-isolation purpose), and doesn't even remove the Elixir↔Python IPC boundary — only moves it inside the container. Captured in Deferred Ideas.
- **"Filesystem is the source of truth" drove three decisions in tandem:** reindex is incremental-from-disk (D-26), Python reads task/agent/skills files itself (D-36), and streaming is file-tail (D-38). Together they keep the invariant honest on both sides of the container boundary — there is no in-Elixir "ground truth" of task state that the filesystem doesn't have.
- **`litellm` over native SDKs (D-40)** was deliberate for error-surface symmetry. Every provider error ends up as a `litellm` exception with a stable taxonomy, which is what the Router's retry/budget logic will consume in Phase 3. Native SDKs would force five parallel error-handling code paths.
- **Doctor exit codes are a real contract.** `glorbo init` uses exit-code 1 vs 2 (D-45) to decide "abort — host broken" vs "proceed — bootstrap needed". This is why severity-weighted beats binary 0/1.
- **Target feel:** `curl` binary → `glorbo init` → example company scaffold → `glorbo up` (Phase 5 verb stub) → dashboard (Phase 4 stub) all within ~1 minute on a fresh Fedora-like host with reasonable network. Phase 2 delivers the first three of those four with runtime-verified airplane-mode Ollama inference.

</specifics>

<deferred>
## Deferred Ideas

- **Elixir-in-container distributed node** for host↔Python IPC. Rejected for network-none conflict, image bloat, violation of locked "Elixir on host only" decision, BEAM-adjacent-to-untrusted-code concern, and because it doesn't eliminate the IPC boundary. Revisit only if a compelling host↔container workload appears that Unix sockets genuinely can't serve.
- **`doctor --deep` as a separate tier** — considered for Phase 2 (shallow default + deep on demand) but subsumed by D-43 (default is already the deep set). Reintroduce only if doctor runtime becomes a UX problem.
- **API-key rotation mid-run / key vault integration** — D-37 (per-request body field) is sufficient for v1. Vault-backed rotation is post-v1.
- **Request/response schema versioning for the Python worker API** (`schema_version` on the wire) — not needed in Phase 2 (single binary + single image version move together). Revisit if/when a detached image+binary release model emerges.
- **NDJSON / SSE streaming over the socket** — D-38 chose file-tail instead. Revisit only if inotify round-trip latency (tens of ms) becomes a dashboard UX complaint in Phase 4.
- **Ubuntu-slim / Chainguard-python / Alpine re-basing** — image base is Ubuntu (D-11). Reconsider for image-size-sensitive distributions in a later milestone.
- **Template marketplace for companies / agents / skills** — already marked v2 in REQUIREMENTS.md (EXT-01). Noted here because `init --example` is the zero-th instance of that idea.
- **Ollama daemon as a Glorbo-managed systemd unit** — D-06 keeps daemon lifecycle with the Director. Revisit only if users consistently run into "ollama serve not started" confusion.

</deferred>

---

*Phase: 02-filesystem-foundation-container-runtime-local-llm*
*Context gathered: 2026-04-15*
