# Phase 2: Filesystem Foundation + Container Runtime + Local LLM - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in `02-CONTEXT.md` — this log preserves the alternatives considered.

**Date:** 2026-04-15
**Phase:** 02-filesystem-foundation-container-runtime-local-llm
**Areas discussed:** Binary bootstrap strategy, Container image design, Init orchestration flow, Reindex strategy & SQLite schemas, File watcher architecture, Python worker API contract, Doctor scope expansion

---

## Binary bootstrap strategy

### Q1: Where should `glorbo init` download the static Podman and Ollama binaries from?

| Option | Description | Selected |
|--------|-------------|----------|
| GitHub releases | Download from official release assets, version-pinned | ✓ |
| Package manager first, fallback to GitHub | Try dnf/apt/etc first | |

**User's choice:** GitHub releases

### Q2: How should Podman/Ollama versions be managed?

| Option | Description | Selected |
|--------|-------------|----------|
| Pinned in config | Specific versions in config.md or bundled versions file | ✓ |
| Latest available from GitHub | Always fetch newest | |

**User's choice:** Pinned in config

### Q3: How should init verify downloaded binary integrity?

| Option | Description | Selected |
|--------|-------------|----------|
| SHA256 checksums only | Checksums from release file; relies on HTTPS + GitHub TLS | ✓ |
| SHA256 + cryptographic signatures | Full cosign/GPG verification | |

**User's choice:** SHA256 checksums only

### Q4: What happens when system deps like `uidmap` are missing at init time?

| Option | Description | Selected |
|--------|-------------|----------|
| Warn and continue | Clear message + final doctor check flags as warning | ✓ |
| Hard fail — init aborts | Block install until user installs uidmap | |

**User's choice:** Warn and continue

### Q5: Which default Ollama model should `glorbo init` pull?

| Option | Description | Selected |
|--------|-------------|----------|
| qwen3:8b (Recommended) | Balanced quality/size default | |
| llama3.2:3b (smaller) | Faster, smaller download | |
| No model — user pulls manually | init pulls nothing; user runs `ollama pull` | ✓ |

**User's choice:** No model — user pulls manually

### Q6: If the system already has Podman installed, use it or download static?

| Option | Description | Selected |
|--------|-------------|----------|
| Prefer system, fallback to static | Use PATH podman if present | ✓ |
| Always use static binary | Consistent isolated binary | |

**User's choice:** Prefer system, fallback to static

### Q7: Should `glorbo init` auto-start the Ollama daemon if it's not running?

| Option | Description | Selected |
|--------|-------------|----------|
| Auto-start daemon if not running (Recommended) | init runs `ollama serve` as needed | |
| Manual start — user runs `ollama serve` | init only ensures binary present | ✓ |

**User's choice:** Manual start — user runs ollama serve themselves

### Q8: Ollama: prefer system install or always use static binary?

| Option | Description | Selected |
|--------|-------------|----------|
| Prefer system, fallback to static | Consistent with podman | ✓ |
| Always use static binary | | |

**User's choice:** Prefer system, fallback to static

### Q9: Where should the Podman/Ollama static binaries be downloaded to?

| Option | Description | Selected |
|--------|-------------|----------|
| `~/.glorbo/bin/` directly | Simple, matches DESIGN.md §3 | ✓ |
| Temp dir → verify → move to `~/.glorbo/bin/` | Atomic staging | |

**User's choice:** ~/.glorbo/bin/ directly

### Q10: What should `glorbo init` do when network is unavailable?

| Option | Description | Selected |
|--------|-------------|----------|
| Skip downloads, continue rest | Check per-step, skip + message, continue | ✓ |
| Hard fail — init aborts on missing network | | |

**User's choice:** Skip downloads, continue rest

### Q11: Should `glorbo init` scaffold an example company with a CEO agent?

| Option | Description | Selected |
|--------|-------------|----------|
| Yes — include example company | `acme` with CEO, general channel, simple goal | ✓ |
| No — empty install, user creates companies | | |

**User's choice:** Yes — include example company

---

## Container image design

### Q1: Base for the `glorbo-runtime` container image?

| Option | Description | Selected |
|--------|-------------|----------|
| Fedora-based (Recommended) | Aligned with host distro | |
| Alpine (smaller, musl-based) | Smallest image; musl compat risk for AI SDKs | |
| Ubuntu-based (middle ground) | ~200MB, stable glibc, broad SDK support | ✓ |

**User's choice:** Ubuntu-based

### Q2: Which Python packages in requirements.txt for Phase 2?

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal: ollama + huggingface_hub only (Recommended) | Smallest image, add SDKs in Phase 3 | |
| Full: all AI SDKs from DESIGN.md §4.2 | ollama, huggingface_hub, anthropic, openai, google-genai, litellm | ✓ |

**User's choice:** Full: all AI SDKs from DESIGN.md §4.2

### Q3: What shape should the Python container entrypoint take?

| Option | Description | Selected |
|--------|-------------|----------|
| Thin worker entrypoint (Recommended) | Short-lived per-task process | |
| FastAPI server inside container | Persistent server, HTTP POST contract | ✓ |

**User's choice:** FastAPI server inside container

### Q4: How should the `glorbo-runtime` container image be created?

| Option | Description | Selected |
|--------|-------------|----------|
| Build at init time (Recommended) | Bundle Containerfile; build locally | |
| Pre-built image bundled/downloaded | Ship a prebuilt OCI image | ✓ |

**User's choice:** Pre-built image bundled/downloaded

### Q5: Where should the pre-built OCI image tarball be hosted?

| Option | Description | Selected |
|--------|-------------|----------|
| GitHub Releases OCI tarball (Recommended) | Bundled with binary release | |
| Container registry (e.g. ghcr.io) | Standard OCI workflow, automatic caching | ✓ |

**User's choice:** Container registry (e.g. ghcr.io)

### Q6: Should the ghcr.io repository be public or private?

| Option | Description | Selected |
|--------|-------------|----------|
| Public repo — no auth needed for pull | Image has no secrets | ✓ |
| Public repo, but note it could go private later | | |

**User's choice:** Public repo — no auth needed for pull

### Q7: How should the image be tagged?

| Option | Description | Selected |
|--------|-------------|----------|
| Version-tagged + latest | Both `v0.1.0` and `latest` | ✓ |
| Latest only | | |

**User's choice:** Version-tagged + latest

### Q8: What should `glorbo init` do if `podman pull` from ghcr.io fails?

| Option | Description | Selected |
|--------|-------------|----------|
| Skip pull, use cached image if available | Continue init; warn if uncached | ✓ |
| Hard fail — init aborts | | |

**User's choice:** Skip pull, use cached image if available

---

## Init orchestration flow

### Q1: How should `glorbo init` report progress?

| Option | Description | Selected |
|--------|-------------|----------|
| Step-by-step with ✓/✗ | Matches doctor visual style | ✓ |
| Silent by default, verbose with --verbose | | |

**User's choice:** Step-by-step with ✓/✗

### Q2: Should `glorbo init` be fully idempotent?

| Option | Description | Selected |
|--------|-------------|----------|
| Fully idempotent | Re-runnable anytime; mkdir_p, exist-check, caching | ✓ |
| First-run vs re-run with verification only | | |

**User's choice:** Fully idempotent

### Q3: How should `glorbo init` handle errors during bootstrap?

| Option | Description | Selected |
|--------|-------------|----------|
| Fail-fast, re-run to retry (Recommended) | Abort on first error | |
| Continue-on-error, summarize all issues | Collect failures, aggregated summary | ✓ |

**User's choice:** Continue-on-error, summarize all issues

### Q4: What should the step ordering be for `glorbo init`?

| Option | Description | Selected |
|--------|-------------|----------|
| Doctor first and last | 7-step sequence: pre-doctor → hierarchy → binaries → image → scaffold → reindex → post-doctor | ✓ |
| Doctor at end only | | |
| Doctor first only | | |

**User's choice:** Doctor first and last

### Q5: How should `glorbo init` wire into the existing CLI architecture?

| Option | Description | Selected |
|--------|-------------|----------|
| Extend Glorbo.CLI.dispatch | Add `:init` branch, returns `{verb, exit_code, output}` | ✓ |
| Separate Mix task + CLI branch | | |

**User's choice:** Extend Glorbo.CLI.dispatch

### Q6: What flags should `glorbo init` support beyond the default?

| Option | Description | Selected |
|--------|-------------|----------|
| Just --repair (Recommended) | Minimal flag surface | |
| Multiple: --repair, --force, --skip-pull, --example | Wider configurability | ✓ |

**User's choice:** Multiple

### Q7: Should `glorbo init` append audit events? How granular?

| Option | Description | Selected |
|--------|-------------|----------|
| One event per init run (Recommended) | Single `init_completed` event | |
| One event per init step | Separate event for each of the 7 steps | ✓ |

**User's choice:** One event per init step

### Q8: How should `glorbo init` relate to `glorbo doctor`?

| Option | Description | Selected |
|--------|-------------|----------|
| Init calls doctor programmatically | Parses JSON output of Doctor.run_checks/0 | ✓ |
| Init runs own checks, doctor is separate | | |

**User's choice:** Init calls doctor programmatically

---

## Reindex strategy & SQLite schemas

### Q1: Should `glorbo reindex` always do a full rebuild or support incremental?

| Option | Description | Selected |
|--------|-------------|----------|
| Always full rebuild (Recommended) | Simpler; DELETE + INSERT everything | |
| Incremental — only changed files | MD5 content hashing via reindex_state table | ✓ |

**User's choice:** Incremental using MD5 content hashing

### Q2: MD5 vs another hash for change detection?

| Option | Description | Selected |
|--------|-------------|----------|
| MD5 content hash tracking | No NIF dependency | ✓ |
| XXH128 for speed (requires NIF) | Faster; native integration cost | |

**User's choice:** MD5 content hash tracking

### Q3: Which Ecto schemas should Phase 2 create?

| Option | Description | Selected |
|--------|-------------|----------|
| Minimal: companies, agents, audit, reindex_state | Just what Phase 2 needs | ✓ |
| Full: all DESIGN.md §4.5 tables now | Tasks, channels, budgets, projects all at once | |

**User's choice:** Minimal

### Q4: How should `glorbo reindex` handle corrupt/unparsable markdown?

| Option | Description | Selected |
|--------|-------------|----------|
| Warn, skip, summarize | Log warning per file; summary at end | ✓ |
| Fail on first corrupt file | | |

**User's choice:** Warn, skip, summarize

---

## File watcher architecture

### Q1: How should file_system watchers be structured?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-company watcher | One `file_system` process per company | ✓ |
| Global watcher routing to companies | | |

**User's choice:** Per-company watcher

### Q2: Which filesystem events should the watcher subscribe to?

| Option | Description | Selected |
|--------|-------------|----------|
| created + modified + deleted | Covers all state transitions | ✓ |
| created only (simplest) | | |

**User's choice:** created + modified + deleted

### Q3: Should the file watcher debounce rapid successive events?

| Option | Description | Selected |
|--------|-------------|----------|
| 100ms debounce | Via `Process.send_after` | ✓ |
| No debounce (immediate processing) | | |

**User's choice:** 100ms debounce

### Q4: Watch the entire company tree, or separate subdirectory watches?

| Option | Description | Selected |
|--------|-------------|----------|
| Full company tree, route by path | Recursive watch + path-prefix router | ✓ |
| Separate watches per subdirectory | | |

**User's choice:** Full company tree, route by path

---

## Python worker API contract

### Q1: Transport between Elixir (host) and the Python FastAPI worker?

| Option | Description | Selected |
|--------|-------------|----------|
| Unix domain socket (bind-mounted) | Preserves network: none; uvicorn binds in container | ✓ |
| HTTP on loopback via slirp4netns | Weakens network: none; adds policy tier | |
| stdin/stdout via podman exec | No server; short-lived run | |

**User's choice:** Unix domain socket (bind-mounted)

**Notes:** Scope requested whether running an Elixir distribution node inside each container (talking to Python via Port) would simplify IPC. Rejected: breaks network: none (distribution needs TCP), bloats every image by ~50–70MB of BEAM/ERTS, contradicts PROJECT.md-locked "Elixir/OTP on host, Python only in containers", puts BEAM adjacent to LLM-generated Python, and doesn't remove the Elixir↔Python IPC boundary — only moves it inside the container. Captured in Deferred Ideas.

### Q2: What does Elixir send the Python worker per task?

| Option | Description | Selected |
|--------|-------------|----------|
| Task path + runtime config | Python reads task.md/agent.md/skills from mounted FS | ✓ |
| Full task blob in JSON | Body carries the fully-assembled prompt | |
| Hybrid: path + selected fields | Mixed approach with overrides | |

**User's choice:** Task path + runtime config

### Q3: How should LLM token streaming surface back to Elixir?

| Option | Description | Selected |
|--------|-------------|----------|
| NDJSON over transport (Recommended) | Line-delimited JSON events over socket | |
| SSE (Server-Sent Events) | HTTP-only; rules out Unix socket | |
| File tail of stdout.log | Python writes to stdout.log; inotify tails | ✓ |
| No streaming — final result only | | |

**User's choice:** File tail of stdout.log

### Q4: Per-task timeout and failure handling contract?

| Option | Description | Selected |
|--------|-------------|----------|
| Global default, per-agent override | 300s default; `timeout_seconds:` frontmatter override | ✓ |
| Fixed global timeout only | | |
| No enforced timeout | | |

**User's choice:** Global default, per-agent override

### Q5: How should the Python worker dispatch to different LLM providers?

| Option | Description | Selected |
|--------|-------------|----------|
| litellm as unified layer | `litellm.completion(model="anthropic/claude-...", ...)` for every provider | ✓ |
| Native SDKs only (no litellm) | | |
| Native SDKs + litellm for edge cases | | |

**User's choice:** litellm as unified layer

### Q6: Unix socket lifecycle — who creates and cleans up?

| Option | Description | Selected |
|--------|-------------|----------|
| Elixir owns the dir, uvicorn creates socket | Elixir owns parent dir with ACLs; container binds inside | ✓ |
| Container owns everything, Elixir discovers | | |
| Shared tmpfs with cleanup on restart | | |

**User's choice:** Elixir owns the dir, uvicorn creates socket

### Q7: How should Elixir wait for FastAPI readiness?

| Option | Description | Selected |
|--------|-------------|----------|
| Retry-connect with backoff | 50ms → 100ms → 200ms → 500ms, ~5s total | ✓ |
| Filesystem ready marker | Python touches `/ready`; Elixir inotify-waits | |
| Health endpoint poll | GET /health loop until 200 | |

**User's choice:** Retry-connect with backoff

### Q8: How should LLM provider API keys reach the Python worker?

| Option | Description | Selected |
|--------|-------------|----------|
| Per-request body field | `api_key` in request body; never env, never FS | ✓ |
| `podman run -e KEY=...` at container start | | |
| Bind-mount a per-agent secrets file | | |

**User's choice:** Per-request body field

### Q9: Task cancellation — how does Director stop an in-flight task?

| Option | Description | Selected |
|--------|-------------|----------|
| Graceful → kill (two-phase) | /cancel first; `podman kill` after 5s unresponsive | ✓ |
| `podman kill` only | | |
| Deferred to Phase 3/4 | | |

**User's choice:** Graceful → kill (two-phase)

---

## Doctor scope expansion

### Q1: Which new checks should doctor gain in Phase 2?

| Option | Description | Selected |
|--------|-------------|----------|
| Full runtime: binary + version + exec test | Deep checks ~1-2s; high confidence | ✓ |
| Binary presence + config sanity only | Fast; shallow | |
| Tiered: --quick vs --deep | Two modes | |

**User's choice:** Full runtime: binary + version + exec test

### Q2: Doctor JSON schema — keep Phase 1 schema stable or evolve?

| Option | Description | Selected |
|--------|-------------|----------|
| Additive only in Phase 2 | Existing keys unchanged; new keys appended | ✓ |
| Add `schema_version` and evolve freely | | |
| Frozen — Phase 2 adds a separate subcommand | | |

**User's choice:** Additive only in Phase 2

### Q3: Doctor exit-code contract?

| Option | Description | Selected |
|--------|-------------|----------|
| Severity-weighted exit codes | 0=pass, 1=blocker, 2=warnings only | ✓ |
| Binary 0/1 | Phase 1 contract unchanged | |
| Exit 0 + `status` field per check | Always-success exit | |

**User's choice:** Severity-weighted exit codes

### Q4: Should doctor attempt any self-repair or stay read-only?

| Option | Description | Selected |
|--------|-------------|----------|
| Read-only + ~/.glorbo/ creation (Recommended) | Preserve Phase 1 rule | |
| Doctor --fix flag | Add `--fix` that runs init subset | ✓ |
| Read-only including ~/.glorbo/ | Stricter than Phase 1 | |

**User's choice:** Doctor --fix flag

### Q5 (follow-up): How should `doctor --fix` relate to `glorbo init` and `init --repair`?

| Option | Description | Selected |
|--------|-------------|----------|
| doctor --fix = targeted subset | Fix only specific flagged issues; three distinct scopes | |
| doctor --fix = alias to init --repair | Same implementation; more discoverable entry point | ✓ |
| Defer --fix to Phase 5 | Phase 2 doctor stays read-only | |

**User's choice:** doctor --fix = alias to init --repair

---

## Claude's Discretion

Areas deferred to Claude during planning/implementation:
- Doctor table layout details for new Phase 2 rows (colors, spacing, version-string truncation)
- Ecto migration file ordering and names
- FastAPI JSON response envelope shape
- `reindex_state` PK choice (composite vs synthetic)
- Audit event JSON keys for init-step events
- `ubuntu:24.04` vs `ubuntu:24.04-slim` vs `chainguard/python` — whichever minimizes image size without compat loss
- Backoff curve specifics for retry-connect on the Unix socket

## Deferred Ideas (from discussion)

- Elixir-in-container distributed node — rejected on network-none conflict, image bloat, locked-decision conflict, BEAM-adjacent-to-LLM-code concern, doesn't remove IPC boundary
- `doctor --deep` as a separate tier — subsumed by D-43
- API-key rotation / vault integration — post-v1
- Wire-protocol schema_version for Python worker API — not needed until detached image+binary releases
- NDJSON/SSE streaming over the socket — file-tail chosen; revisit only if inotify latency becomes a UX issue
- Ubuntu-slim / Chainguard / Alpine re-basing — Phase 2 uses Ubuntu
- Template marketplace — already marked v2 in REQUIREMENTS.md
- Ollama daemon as Glorbo-managed systemd unit — Director manages daemon lifecycle
