# Phase 2: Filesystem Foundation + Container Runtime + Local LLM — Research

**Researched:** 2026-04-15
**Domain:** Elixir release binary orchestration × rootless Podman × local LLM × append-only filesystem
**Confidence:** HIGH (versions + interfaces verified against live registries; a few LOW items flagged for user confirmation)

## Summary

Phase 2 turns the Phase-1 Burrito binary into a tool that can bootstrap an entire container runtime from nothing. The plan must cover: downloading two third-party static binaries with pinned versions and checksum verification, pulling a pre-built OCI image from ghcr.io, materialising the `~/.glorbo/` tree, wiring an inotify-per-company watcher, configuring SQLite as a *derived* index rebuilt from disk via MD5 content hashing, and proving end-to-end that a rootless Podman container can run a Python FastAPI server over a bind-mounted Unix socket calling Ollama on the host — with `network: none` still intact.

The entire phase turns on three decisions that are already locked in CONTEXT.md and constrain implementation: (1) the Python worker talks to Elixir via Unix domain socket bind-mounted from the host, not over HTTP (this alone lets `network: none` remain the default for RT-04); (2) Ollama runs on the host and is reached from inside the container via bind-mounted Unix socket, not inside the container (Ollama inside-container would double the image size and complicate model caching); (3) SQLite is derived — anything we store must also be reconstructible from disk or it breaks FS-03.

**Primary recommendation:** Split Phase 2 into four plans. (1) `~/.glorbo/` hierarchy + append-only AuditLog + SQLite schemas + reindex engine. (2) Binary bootstrap (Podman + Ollama download/verify/install) + Doctor expansion. (3) `glorbo-runtime` OCI image (Containerfile + requirements.txt + CI push to ghcr.io) + ContainerManager Port wrapper. (4) FileWatcher + example company scaffold + end-to-end `glorbo init` orchestrator + airplane-mode proof. Plans 1–3 can partially parallelise inside Phase 2 once schemas are stable.

## User Constraints (from CONTEXT.md)

### Locked Decisions

**Binary bootstrap (Podman + Ollama):**
- **D-01** Source: download `podman-static` and `ollama` from official GitHub release assets. No CDN, no package-manager path.
- **D-02** Versions are **pinned** in a bundled versions file.
- **D-03** Integrity: verify SHA256 checksums from each release's checksum file (no GPG/cosign of upstream). **⚠ Research finding conflicts with this for podman-static — see Assumptions Log A1.**
- **D-04** If `podman`/`ollama` is in `$PATH`, use the system binary; only fall back to downloading.
- **D-05** Download destination: `~/.glorbo/bin/` directly.
- **D-06** `glorbo init` does **not** auto-start `ollama serve`. Director is responsible.
- **D-07** `init` pulls **no** default model.
- **D-08** Missing system deps (e.g. `uidmap`): warn and continue.
- **D-09** Offline-tolerant: skip downloads with clear message, continue.
- **D-10** Example company `acme` scaffolded with CEO, `general` channel, simple goal.

**`glorbo-runtime` container image:**
- **D-11** Base: **Ubuntu** (`ubuntu:24.04` or similar stable tag).
- **D-12** Python package set: full AI-SDK list (`ollama`, `huggingface_hub`, `anthropic`, `openai`, `google-genai`, `litellm`).
- **D-13** Entrypoint: **FastAPI server** (uvicorn) over Unix domain socket.
- **D-14** Pre-built OCI image, not built at init time.
- **D-15** Image host: `ghcr.io/foobarto/glorbo-runtime`, public.
- **D-16** Tagging: version-tagged + `latest`.
- **D-17** Pull failure: use cached image if present; otherwise warn, continue.

**Init orchestration flow:**
- **D-18** Step-by-step `✓/⏭/✗` progress (matches doctor).
- **D-19** Fully idempotent; safe to re-run. Directly supports `doctor --fix`.
- **D-20** Continue-on-error with end-of-run aggregated summary.
- **D-21** Step ordering: (1) doctor pre-flight, (2) `~/.glorbo/` hierarchy, (3) install/verify Podman + Ollama, (4) pull image, (5) scaffold example company, (6) `glorbo reindex`, (7) doctor post-flight.
- **D-22** Extend `Glorbo.CLI.dispatch/1` with `:init` branch. No separate Mix task.
- **D-23** Flags: `--force`, `--skip-pull`, `--example`. **No `--repair`** — repair lives under `doctor --fix`.
- **D-24** One audit event per init step.
- **D-25** `init` calls `Glorbo.Doctor.run_checks/0` programmatically.

**Reindex + SQLite schemas:**
- **D-26** Incremental reindex via MD5 content hashing; `reindex_state` table.
- **D-27** Hash: **MD5** (no NIF dependency).
- **D-28** Phase 2 Ecto schemas: `companies`, `agents`, `audit_events`, `reindex_state`. `tasks`, `channels`, `budgets`, `projects`, `skills` deferred to Phase 3.
- **D-29** Corrupt markdown: log warning, skip, end-of-run summary.

**File watcher:**
- **D-30** One `file_system` watcher process per company, under company supervisor.
- **D-31** Subscribe to `:created`, `:modified`, `:deleted`.
- **D-32** 100ms debounce via `Process.send_after`.
- **D-33** Recursive watch on full company tree; path-prefix router.

**Python worker API:**
- **D-34** Transport: Unix domain socket bind-mounted from host. Host: `~/.glorbo/runtime/sockets/<company>/<agent>.sock`. Container: `unix:/run/agent.sock`.
- **D-35** Elixir owns socket dir with restrictive ACLs; uvicorn creates/unlinks the socket.
- **D-36** Request shape: POST `/run` with `{task_path, provider, model, api_key, skills[], timeout_seconds?}`. Python reads markdown from the mounted FS itself.
- **D-37** API keys: per-request body field; never env var, never on disk, never `podman inspect`-visible.
- **D-38** Streaming: file tail of `agents/<name>/stdout.log` via inotify.
- **D-39** Readiness: retry-connect backoff (50/100/200/500ms, ~5s total).
- **D-40** `litellm` as unified LLM provider layer.
- **D-41** Timeout: 300s default, per-agent override. On timeout `podman kill`.
- **D-42** Cancellation: two-phase (POST `/cancel` → 5s grace → `podman kill`).

**Doctor expansion:**
- **D-43** Full runtime checks: podman, ollama (with daemon reachability), runtime_image digest, `podman run --rm glorbo-runtime python -c "import litellm"` smoke, `audit/` and `sockets/` writable.
- **D-44** JSON schema: additive only; existing Phase 1 keys unchanged.
- **D-45** Severity-weighted exit codes: 0 pass, 1 blocker, 2 warnings only.
- **D-46** `doctor --fix` is the **only** repair entry point. No `init --repair`.

### Claude's Discretion

- Exact doctor table layout for Phase 2 rows (colors, spacing, version truncation).
- Ecto migration file ordering and names.
- FastAPI JSON response envelope shape.
- `reindex_state` PK choice (composite vs synthetic).
- Audit event JSON keys for init-step events (stable within phase, refine Phase 3).
- `ubuntu:24.04` vs `ubuntu:24.04-slim` vs `chainguard/python` — whichever minimizes image size without glibc compat loss.
- Backoff curve specifics for retry-connect on Unix socket.

### Deferred Ideas (OUT OF SCOPE)

- Elixir-in-container distributed node (rejected: breaks network-none, bloats image, violates locked Elixir-on-host decision).
- `doctor --deep` as separate tier (subsumed by D-43).
- API-key rotation / vault integration.
- Wire-protocol schema versioning for Python worker API.
- NDJSON/SSE over the socket (file-tail chosen).
- Ubuntu-slim / Chainguard / Alpine re-basing.
- Template marketplace.
- Ollama daemon as Glorbo-managed systemd unit.

## Project Constraints (from CLAUDE.md)

Directives with the same authority as locked decisions:

| Directive | Phase 2 implication |
|-----------|---------------------|
| Kernel is the policy engine (2-layer enforcement) | Phase 2 *prepares* the container for Phase-3 ACLs. Do not implement ACLs here; do not short-circuit Phase-3's ability to add them. |
| Filesystem is the source of truth | `glorbo.db` must be reconstructible from disk. No schema in Phase 2 may store data not also serialised as markdown/JSONL. |
| One-way inbox/outbox | Phase 2 creates the directories and the watcher; actual routing is Phase 3. Watcher must *observe* `outbox/` writes, not mediate them yet. |
| Audit log is append-only | `Glorbo.Company.AuditLog` module must expose ONLY `append/2` — no `update`, `delete`, `edit`. Enforced structurally AND by negative test (`refute function_exported?/3`). |
| Python never runs on the host | All `pip`/Python work happens inside the `Containerfile` build context. The host `requirements.txt` is a resource file for the container, not a host dependency. |
| Company isolation is absolute | Every `podman run` mounts only that company's directory. No shared volumes between companies. |
| Crash isolation via OTP tree | `file_system` watcher + Podman Port wrapper crash must restart only that company's subtree, not the whole VM. |

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| FS-01 | `~/.glorbo/` hierarchy created by `glorbo init` matches DESIGN.md §3 | §Standard Stack (File.mkdir_p), §Code Examples (hierarchy creator) |
| FS-02 | Markdown + YAML frontmatter canonical for companies/agents/tasks/channels/goals/skills/permissions | §Standard Stack (YamlFrontmatter hex pkg or inline parser) |
| FS-03 | `~/.glorbo/glorbo.db` is rebuildable — `glorbo reindex` fully reconstructs from disk | §Architecture Patterns (Reindex Engine), §Code Examples |
| FS-04 | Deleting `glorbo.db` never loses user data | Proven by reindex contract; AGT/channel/task data are markdown-only in Phase 2 |
| FS-05 | Append-only JSONL `audit/YYYY-MM.jsonl` + SQLite mirror; never modified/deleted | §Code Examples (AuditLog append), CLAUDE.md-enforced negative test |
| FS-06 | `file_system` (inotify) watchers report changes sub-second | §Standard Stack (file_system 1.1.1), §Architecture Patterns (per-company watcher) |
| RT-01 | Rootless Podman auto-detected; static binary downloaded when missing | §Standard Stack (mgoltzsche/podman-static v5.8.1), §Common Pitfalls (GPG not SHA256) |
| RT-02 | `glorbo-runtime` OCI image cached; `doctor --fix` rebuilds after restore | §Architecture Patterns (image-pull flow), §Code Examples (podman pull retry) |
| RT-03 | Each company in own Podman container, only its directory mounted | §Code Examples (podman run invocation) |
| RT-04 | `--userns keep-id`, `--read-only`, `--network none` defaults | §Code Examples (exact `podman run` command line) |
| RT-05 | Ephemeral default; persistent opt-in | §Architecture Patterns (ContainerManager modes) |
| RT-06 | Python never on host | §Architecture Patterns (Containerfile-only build); §Don't Hand-Roll |
| LLM-01 | Ollama auto-downloaded by `glorbo init`; local inference offline | §Standard Stack (Ollama v0.20.7 tar.zst), §Common Pitfalls (tar.zst extraction) |
| LLM-02 | Hugging Face local models via `huggingface_hub` | Included in `requirements.txt` (D-12) |
| LLM-05 | End-to-end flow offline after `init` | §Validation Architecture (airplane-mode test), §Code Examples (unix-socket Ollama call) |
| CLI-02 | `glorbo init` bootstraps in ~1 minute on fresh Fedora host | §Architecture Patterns (parallel init steps), §Common Pitfalls (image pull timing) |

## Standard Stack

### Core (Elixir host)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `file_system` | 1.1.1 | inotify wrapper on Linux | Only serious Elixir inotify lib; already in mix.exs (Phase 1); Phoenix LiveReload depends on it [VERIFIED: hex.pm API 2026-04-15] |
| `ecto_sqlite3` | 0.22.0 | SQLite adapter via Exqlite | Already wired Phase 1 with WAL [VERIFIED: hex.pm] |
| `finch` | 0.21.0 | HTTP client with Unix socket support | Supports `unix_socket:` option; already transitive dep via Phoenix; use for ghcr pull + Ollama socket client [VERIFIED: hex.pm, hexdocs Finch] |
| `jason` | 1.4.4 | JSON encode/decode | Already in mix.exs [VERIFIED: hex.pm] |

### Supporting (Elixir host)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `yaml_elixir` or `yaml_front_matter` | latest | YAML frontmatter parsing for `agent.md`, `company.md`, task files | Needed for reindex to extract frontmatter into SQLite. `yaml_front_matter` handles the `---\nyaml\n---\nmd` split natively. [ASSUMED: both exist and are viable — verify at planning time] |
| `muontrap` | ~> 1.6 | Supervised external-process runner | Recommended over raw `Port` for long-running `podman run` + persistent-mode containers (handles OOM-via-mailbox flood + orphan cleanup). Ephemeral `podman run` calls can use `System.cmd` or one-shot Port. [CITED: muontrap README, tonyc.github.io posts] |
| `:crypto` (built-in) | — | MD5 hashing for reindex_state | `:crypto.hash(:md5, content)` — no deps, no NIF beyond what BEAM already ships |

### Container image (Python)

| Library | Version pin | Purpose |
|---------|-------------|---------|
| python | 3.12 | Runtime [CITED: DESIGN.md §4.2] |
| `fastapi` | latest compatible with Python 3.12 | HTTP server framework for the worker [CITED: D-13] |
| `uvicorn[standard]` | latest | ASGI server; supports `--uds /path/to/sock` for Unix socket binding [CITED: uvicorn docs] |
| `litellm` | ~> 1.x | Unified LLM provider layer [CITED: litellm docs — model string format `{provider}/{model_name}`] |
| `ollama` | latest | Ollama Python client; will connect over Unix socket to host daemon |
| `huggingface_hub` | latest | HF model downloads (LLM-02) |
| `anthropic`, `openai`, `google-genai` | latest | Native SDK fallbacks + litellm support [CITED: DESIGN.md §4.2] |

**Version verification (recommended before planning):**

```bash
# Elixir deps — verified 2026-04-15
curl -s https://hex.pm/api/packages/file_system | jq .latest_stable_version    # 1.1.1
curl -s https://hex.pm/api/packages/ecto_sqlite3 | jq .latest_stable_version   # 0.22.0
curl -s https://hex.pm/api/packages/finch | jq .latest_stable_version          # 0.21.0

# External binaries — verified 2026-04-15
curl -s https://api.github.com/repos/mgoltzsche/podman-static/releases/latest | jq .tag_name  # v5.8.1
curl -s https://api.github.com/repos/ollama/ollama/releases/latest | jq .tag_name              # v0.20.7
```

### External binaries (bundled via download)

| Binary | Version | Source | Verified 2026-04-15 |
|--------|---------|--------|---------------------|
| podman-static | v5.8.1 | `github.com/mgoltzsche/podman-static` | [VERIFIED: GitHub API — published 2026-03-15] |
| ollama | v0.20.7 | `github.com/ollama/ollama` | [VERIFIED: GitHub API — published 2026-04-13] |

**Exact asset URLs and sizes (VERIFIED via `api.github.com`):**

```
# Podman (mgoltzsche static rootless build)
https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-amd64.tar.gz       (33.7 MB)
https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-amd64.tar.gz.asc   (GPG — not SHA256)
https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-arm64.tar.gz       (30.9 MB)
https://github.com/mgoltzsche/podman-static/releases/download/v5.8.1/podman-linux-arm64.tar.gz.asc

# Ollama (official)
https://github.com/ollama/ollama/releases/download/v0.20.7/ollama-linux-amd64.tar.zst                (2.05 GB — includes CUDA libs)
https://github.com/ollama/ollama/releases/download/v0.20.7/ollama-linux-arm64.tar.zst                (1.32 GB)
https://github.com/ollama/ollama/releases/download/v0.20.7/sha256sum.txt                             (1.4 KB)
```

### Alternatives Considered

| Instead of | Could Use | Why Rejected for Phase 2 |
|------------|-----------|--------------------------|
| `mgoltzsche/podman-static` | Official `containers/podman` GitHub releases | Official podman org publishes Windows/macOS installers + remote client + source tarballs — **no Linux static binary**. Confirmed via GitHub API + WebFetch. mgoltzsche is the de-facto static build for rootless Linux. |
| `Finch` Unix socket client | Raw `Mint.HTTP.connect/4` with `:unix` transport | Finch wraps Mint with pooling + a supported `unix_socket:` option. Lower surface area, fewer edge cases. [CITED: Finch hexdocs] |
| `MuonTrap` | Raw Erlang `Port.open/2` | `muontrap` adds cgroup wrapping, mailbox backpressure, orphan cleanup — materially matters for persistent-mode containers running for hours. For one-shot ephemeral calls the distinction is less critical; use System.cmd or Port there. |
| `yaml_front_matter` | hand-rolled regex split + `yaml_elixir` | Either works. The named package is tiny (<100 LoC) and the markdown+frontmatter split is a solved problem — don't re-solve it. |

**Installation (delta vs Phase 1 mix.exs):**

```elixir
# Add to deps in mix.exs
{:yaml_front_matter, "~> 1.0"},    # or equivalent; planner to decide
{:yaml_elixir, "~> 2.9"},          # yaml_front_matter transitively depends on this
{:muontrap, "~> 1.6"}              # only if persistent-mode containers ship in Phase 2
```

## Architecture Patterns

### Recommended Project Structure (Phase 2 additions to Phase 1 layout)

```
lib/glorbo/
├── init/                              # NEW — glorbo init orchestrator
│   ├── orchestrator.ex                # Top-level 7-step runner (D-21)
│   ├── hierarchy.ex                   # Step 2: mkdir_p the ~/.glorbo/ tree
│   ├── binary_bootstrap.ex            # Step 3: podman + ollama download/verify/install
│   ├── image_pull.ex                  # Step 4: podman pull ghcr.io/foobarto/glorbo-runtime
│   ├── example_company.ex             # Step 5: scaffold acme/
│   └── versions.ex                    # Pinned versions + SHA256s (D-02)
│
├── filesystem/                        # NEW — FS-01..FS-06
│   ├── hierarchy.ex                   # Directory layout constants
│   ├── reindex.ex                     # Incremental MD5-based reindex (D-26)
│   ├── frontmatter.ex                 # YAML frontmatter parser wrapper
│   └── watcher.ex                    # Per-company inotify wrapper
│
├── container/                         # EXTENDS container_manager.ex stub
│   ├── manager.ex                     # GenServer managing podman lifecycle
│   ├── invocation.ex                  # Build `podman run` argv list
│   └── socket.ex                      # Socket-dir create/chmod, stale-socket cleanup
│
├── company/
│   ├── audit_log.ex                   # EXTEND stub — implement append/2 writing JSONL + SQLite mirror
│   ├── file_watcher.ex                # EXTEND stub — wire to file_system, dispatch to reindex + router stubs
│   └── ...                            # other company/* stubs remain Phase-3 responsibility
│
├── doctor/
│   └── formatter.ex                   # EXTEND (no rendering changes, new rows only)
│
└── doctor.ex                          # EXTEND: append podman/ollama/runtime_image/runtime_exec/audit_dir/sockets_dir checks

priv/repo/migrations/
├── 202604_<ts>_create_companies.exs
├── 202604_<ts>_create_agents.exs
├── 202604_<ts>_create_audit_events.exs
└── 202604_<ts>_create_reindex_state.exs

containers/glorbo-runtime/              # NEW — source for ghcr image
├── Containerfile                       # ubuntu:24.04 → python 3.12 + requirements.txt
├── requirements.txt                    # Pinned Python deps (D-12)
├── worker/
│   ├── main.py                         # FastAPI app
│   ├── routes.py                       # /run, /cancel handlers
│   ├── dispatch.py                     # litellm wrapper
│   └── context.py                      # reads task.md/agent.md/skills from mounted FS
└── .github/workflows/runtime-image.yml # Builds + pushes to ghcr.io on runtime-v* tags
```

### Pattern 1: Init Orchestrator (7-step pipeline with continue-on-error)

**What:** A reducer that threads `{successes, warnings, failures}` through each step.
**When to use:** `glorbo init` main loop; also the Phase-5 `doctor --fix` substrate.
**Example:**

```elixir
# Source: derived from CONTEXT D-18..D-25 + Phase 1 Doctor pattern
defmodule Glorbo.Init.Orchestrator do
  @type result :: %{step: atom(), status: :ok | :skipped | :error, detail: String.t()}

  def run(opts \\ []) do
    steps = [
      {:pre_doctor,        &Glorbo.Init.step_pre_doctor/1},
      {:hierarchy,         &Glorbo.Init.Hierarchy.ensure/1},
      {:binary_bootstrap,  &Glorbo.Init.BinaryBootstrap.run/1},
      {:image_pull,        &Glorbo.Init.ImagePull.run/1},
      {:example_company,   &Glorbo.Init.ExampleCompany.scaffold/1},
      {:reindex,           &Glorbo.Filesystem.Reindex.run/1},
      {:post_doctor,       &Glorbo.Init.step_post_doctor/1}
    ]

    state = %{opts: opts, results: [], audit: []}

    Enum.reduce(steps, state, fn {name, fun}, acc ->
      IO.puts("⧖ #{name} ...")
      result = fun.(acc.opts)
      :ok = Glorbo.Company.AuditLog.append(:system,
               %{step: name, status: result.status, detail: result.detail, ts: now()})
      print_line(result)
      %{acc | results: [result | acc.results]}
    end)
    |> summarize()
  end
end
```

### Pattern 2: Per-Company File Watcher (D-30, D-32, D-33)

**What:** A GenServer started under each Company.Supervisor that wraps `file_system` and debounces events into a router call.
**When to use:** Every running company.
**Example:**

```elixir
# Source: file_system README + CONTEXT D-30..D-33
defmodule Glorbo.Filesystem.Watcher do
  use GenServer
  require Logger

  def start_link(opts) do
    company = Keyword.fetch!(opts, :company)
    GenServer.start_link(__MODULE__, opts,
      name: :"#{company}_file_watcher")
  end

  def init(opts) do
    company_dir = Path.expand("~/.glorbo/companies/#{opts[:company]}")
    {:ok, pid} = FileSystem.start_link(dirs: [company_dir])
    FileSystem.subscribe(pid)
    {:ok, %{company: opts[:company], dir: company_dir, pending: %{}, debounce_ms: 100}}
  end

  # file_system message shape: {:file_event, worker, {path, events}}
  def handle_info({:file_event, _pid, {path, events}}, state) do
    # D-31: only route created/modified/deleted
    interesting = Enum.any?(events, &(&1 in [:created, :modified, :deleted, :removed]))
    if interesting do
      ref = Process.send_after(self(), {:flush, path}, state.debounce_ms)
      # Cancel prior timer for same path if any (coalesce bursts)
      if prior = state.pending[path], do: Process.cancel_timer(prior)
      {:noreply, put_in(state.pending[path], ref)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:flush, path}, state) do
    dispatch_by_prefix(state.company, path)
    {:noreply, update_in(state.pending, &Map.delete(&1, path))}
  end

  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("FileWatcher for #{state.company} stopped")
    {:stop, :normal, state}
  end

  # D-33: path-prefix routing
  defp dispatch_by_prefix(company, path) do
    rel = Path.relative_to(path, Path.expand("~/.glorbo/companies/#{company}"))
    cond do
      String.starts_with?(rel, "agents/") and String.contains?(rel, "/inbox/") ->
        # Phase 3 will wire; Phase 2 just logs
        :ok
      String.starts_with?(rel, "audit/") ->
        :ok  # audit log writes are observed but not re-routed
      String.starts_with?(rel, "channels/") ->
        :ok
      true ->
        Glorbo.Filesystem.Reindex.mark_dirty(company, path)
    end
  end
end
```

### Pattern 3: Incremental MD5 Reindex Engine (D-26, D-27)

**What:** Walk company tree; for each file compute MD5; compare against `reindex_state` row; upsert if changed; delete rows for vanished files.
**When to use:** Once on startup, once on `glorbo reindex`, incrementally per file when the watcher marks dirty.
**Example:**

```elixir
# Source: derived from CONTEXT D-26..D-29
defmodule Glorbo.Filesystem.Reindex do
  alias Glorbo.Repo
  alias Glorbo.Filesystem.{Frontmatter, ReindexState}

  @spec run(keyword()) :: %{status: atom(), detail: String.t()}
  def run(opts) do
    companies_dir = Path.expand("~/.glorbo/companies")
    skipped = []

    seen_paths =
      Path.wildcard(Path.join(companies_dir, "**/*.md"))
      |> Enum.reduce(MapSet.new(), fn path, acc ->
        case process_file(path) do
          {:ok, _} -> MapSet.put(acc, path)
          {:skip, reason} ->
            Logger.warning("reindex skipped #{path}: #{reason}")
            skipped = [path | skipped]
            acc
          _ -> acc
        end
      end)

    # D-26: delete rows for files no longer on disk
    Repo.delete_all(
      from r in ReindexState,
           where: r.file_path not in ^MapSet.to_list(seen_paths)
    )

    %{status: :ok,
      detail: "reindexed #{MapSet.size(seen_paths)} files, skipped #{length(skipped)}"}
  end

  defp process_file(path) do
    content = File.read!(path)
    digest = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
    stat = File.stat!(path)

    case Repo.get(ReindexState, path) do
      %{md5: ^digest} -> {:ok, :unchanged}
      _ ->
        case Frontmatter.parse(content) do
          {:ok, meta, body} ->
            upsert_domain_row(path, meta, body)
            Repo.insert!(%ReindexState{
              file_path: path, md5: digest,
              size: stat.size, mtime: stat.mtime
            }, on_conflict: :replace_all, conflict_target: :file_path)
            {:ok, :indexed}
          {:error, reason} -> {:skip, reason}
        end
    end
  end

  # Phase 2: companies, agents only. Tasks/channels/etc are Phase 3.
  defp upsert_domain_row(path, meta, _body) do
    cond do
      String.ends_with?(path, "/company.md") -> upsert_company(path, meta)
      String.ends_with?(path, "/agent.md") -> upsert_agent(path, meta)
      true -> :ok
    end
  end
end
```

### Pattern 4: Podman Invocation (RT-03, RT-04, RT-05)

**What:** Build the exact argv list for `podman run` per company/agent.
**When to use:** Every container launch.
**Example:**

```elixir
# Source: DESIGN.md §4.4 + podman-run(1) docs + CONTEXT D-34 (socket mount)
defmodule Glorbo.Container.Invocation do
  @runtime_image "ghcr.io/foobarto/glorbo-runtime:v0.1.0"

  def build_argv(company, agent, mode \\ :ephemeral) do
    host_company_dir = Path.expand("~/.glorbo/companies/#{company}")
    host_socket_dir  = Path.expand("~/.glorbo/runtime/sockets/#{company}")
    File.mkdir_p!(host_socket_dir)
    # Pre-create socket dir with tight perms (0700); Phase 3 adds per-agent ACLs
    File.chmod!(host_socket_dir, 0o700)

    base = [
      "run",
      (if mode == :ephemeral, do: "--rm", else: "-d"),
      "--name", "glorbo-#{company}-#{agent}",
      "--userns", "keep-id",              # RT-04
      "--read-only",                       # RT-04
      "--network", "none",                 # RT-04
      "--tmpfs", "/tmp",                   # required because root FS is read-only
      "--volume", "#{host_company_dir}:/company:Z,ro",
      "--volume", "#{host_socket_dir}:/run:Z,rw",
      "--env", "GLORBO_COMPANY=#{company}",
      "--env", "GLORBO_AGENT=#{agent}"
    ]

    base ++ [@runtime_image,
             "uvicorn", "worker.main:app",
             "--uds", "/run/agent.sock",
             "--uds-permissions", "0600"]  # Note: uvicorn does not support this flag natively; see Pitfall 5
  end
end
```

**Note on `:Z`:** The uppercase `:Z` SELinux label is mandatory on Fedora (SELinux-enforcing) hosts. Lowercase `:z` is for shared volumes. Use `:Z` — CLAUDE.md invariant is company isolation is absolute, not shared.

### Pattern 5: Container as a MuonTrap-supervised GenServer (for persistent mode)

**What:** Wrap long-running `podman run -d` + log-tail in a GenServer so crashes restart only that agent.
**When to use:** Persistent-mode containers (D-13 FastAPI, persistent lifecycle opt-in per RT-05).
**Example:**

```elixir
# Source: muontrap README + OTP supervision pattern
defmodule Glorbo.Container.Manager do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via(opts))

  def init(opts) do
    argv = Glorbo.Container.Invocation.build_argv(
      opts[:company], opts[:agent], :persistent)
    {:ok, port} = MuonTrap.Daemon.start_link("podman", argv, [
      log_output: :info,
      stderr_to_stdout: true,
      exit_status_to_reason: true
    ])
    {:ok, %{port: port, company: opts[:company], agent: opts[:agent]}}
  end
end
```

### Anti-Patterns to Avoid

- **Running `podman build` at init time.** D-14 locks the image as pre-built on ghcr.io. Building locally adds Podman build dependencies to init's critical path, contradicts D-17 (cached-image fallback), and loses image-digest immutability.
- **Storing the Ollama binary inside the OCI image.** Doubles image size by ~2 GB (ollama-linux-amd64.tar.zst is 2.05 GB). Ollama runs on the host; the container reaches it via bind-mounted Unix socket OR skips Ollama entirely when `network: none` is strict. **If the container truly needs to reach Ollama, Phase 2 must decide: bind-mount `/tmp/ollama.sock` into the container, OR relax `network: none` for the one agent that uses Ollama. CONTEXT does not resolve this.** See Assumptions Log A2.
- **Trusting `podman inspect` for secrets.** D-37 is explicit: API keys are per-request body, not env vars. A `podman inspect` of a running container exposes its env — hence env-var injection is banned.
- **Using `Mix.Task` to wire init.** D-22: init lives on the CLI dispatch path, not as a Mix task. Mix is not available in the Burrito release.
- **Calling `ollama pull` from Elixir with `System.cmd` synchronously.** Model pulls are GBs and stream progress; block the CLI and you lose the `✓/⏭/✗` UX. Since D-07 says init pulls no default model, this is moot for Phase 2 — but if any future step pulls a model, use `Port.open` with `:exit_status` and forward chunks.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| inotify wrapper | custom `:erlang.open_port({:spawn, "inotifywait -r..."})` | `file_system` 1.1.1 | Cross-platform abstraction, handles backend differences, already a Phoenix transitive dep |
| YAML frontmatter parser | regex-based ad-hoc splitter | `yaml_front_matter` + `yaml_elixir` | `---\n`/`---` markers have edge cases (trailing whitespace, Windows line endings, YAML anchors). Use a library. |
| HTTP-over-Unix-socket client | raw Mint transport handling | `Finch` with `unix_socket:` option | Finch supports this natively; see §Code Examples. Going raw loses pooling + retries. |
| Supervised external process | `Port.open/2` + hand-rolled flow control | `muontrap` for persistent mode | `muontrap` handles mailbox OOM + orphan cleanup. Phase 1 uses raw Port in doctor for short commands — acceptable there, wrong for hours-running containers. |
| MD5 / SHA256 | Pure-Elixir hash impl | `:crypto.hash/2` | Built into BEAM. Both MD5 (reindex) and SHA256 (binary verification) hit this one function. |
| Tar/zstd extraction | shell-out to external `tar` | shell-out to external `tar` (with `--zstd`) | Sorry — BEAM has no native zstd. Ollama ships `.tar.zst`. Use `System.cmd("tar", ["--zstd", "-xf", ..., "-C", ...])`. Verify `tar --version` supports `--zstd` (GNU tar ≥ 1.31, 2019). **Add to Doctor.** |
| GPG signature verify | hand-rolled `gpg` wrapper | Skip (see A1) or shell out to `gpg --verify` | mgoltzsche podman-static signs with GPG `.asc`, not SHA256. CONTEXT D-03 picks SHA256 — conflict requires user resolution. |
| Progress bars | custom ANSI | `ProgressBar` hex pkg OR just `IO.write/1` with `\r` | Both fine; pick at planning time. Not a moral issue. |

**Key insight:** Every single "deceptively complex" problem in this phase (FS watching, YAML parsing, HTTP-over-unix, supervised subprocess) has a battle-tested Hex package. The only hand-rolled code should be Glorbo-specific orchestration and the directory-hierarchy/reindex logic.

## Runtime State Inventory

**Not applicable.** Phase 2 is greenfield within the filesystem domain. There are no prior companies, no prior SQLite rows, no prior container images to migrate. The `~/.glorbo/` hierarchy is created from scratch.

- Stored data: none exists prior to Phase 2. Phase-1 Doctor creates `~/.glorbo/` *empty* for its writability probe. Phase 2 populates it.
- Live service config: none — Phase 2 *starts* the runtime.
- OS-registered state: none.
- Secrets/env vars: none reach Phase 2 code (D-37 bans API keys in env).
- Build artifacts: Phase 1's `burrito_out/glorbo_*` is the binary Phase 2 extends; no stale artifacts.

## Common Pitfalls

### Pitfall 1: GPG vs SHA256 for podman-static
**What goes wrong:** CONTEXT D-03 says "verify SHA256 checksums from each release's checksum file". Verified 2026-04-15: mgoltzsche/podman-static v5.8.1 ships `.tar.gz.asc` (GPG detached signatures) — **not** a SHA256 file. Ollama ships `sha256sum.txt`. The two binaries have different verification channels.
**Why it happens:** Different upstream conventions. CONTEXT was written without checking asset listings.
**How to avoid:** Either (a) compute our own SHA256 for podman-static against the pinned version at Glorbo-release time, publish it in the binary's `Glorbo.Init.Versions` module, and verify downloads against that embedded hash (simple, no GPG key distribution); or (b) bundle the signing key and shell out to `gpg --verify`. Recommendation: option (a). Keeps the single verification path (SHA256) while respecting that the upstream convention differs.
**Warning signs:** A plan that tries to curl a `SHA256SUMS` file from mgoltzsche's release and expects it to exist.

### Pitfall 2: Ollama `.tar.zst` extraction
**What goes wrong:** `tar -xf ollama-linux-amd64.tar.zst` without `--zstd` fails on GNU tar that isn't zstd-aware. The archive extracts to *current directory* (no top-level folder) — if you `cd ~/.glorbo/bin && tar xf ollama-linux-amd64.tar.zst`, you splat `bin/`, `lib/`, etc. into `~/.glorbo/bin/` unexpectedly [CITED: ollama issue #13970].
**Why it happens:** Ollama packages with full /usr layout, assumes extraction to `/usr`.
**How to avoid:** Extract to a staging dir, then `cp usr/bin/ollama ~/.glorbo/bin/ollama`. Also `cp -r usr/lib/ollama ~/.glorbo/lib/ollama` — Ollama ships accelerator runtimes (ROCm/CUDA libs) in `usr/lib/ollama/`. Decide at planning time: ship with libs (~2 GB) or CPU-only (~100 MB)? **CONTEXT does not resolve this.** Add Doctor check: `tar --version | grep -q zstd` or `command -v zstd`.
**Warning signs:** `init` claims success but `./ollama --version` fails with "cannot open libcudart.so" or similar.

### Pitfall 3: `mgoltzsche/podman-static` is not an official binary
**What goes wrong:** A plan could say "download official podman-static" and 404 at runtime.
**Why it happens:** Searching "podman static" commonly finds this repo, and it IS the de-facto standard, but it's third-party. The official `containers/podman` GitHub releases ship no Linux static binary.
**How to avoid:** Plans and docs must name `mgoltzsche/podman-static` explicitly. A `.glorbo/config.md` template could surface this to Directors. Monitor: if mgoltzsche stops publishing, Glorbo is stranded — add a "last verified" date to `Glorbo.Init.Versions`.
**Warning signs:** A code review that says "bump to latest podman" without verifying the source repo exists.

### Pitfall 4: `--userns keep-id` on Fedora Silverblue + Quadlet
**What goes wrong:** Documented Silverblue issue: `--userns=keep-id` + systemd Quadlet produces UID-mapping conflicts.
**Why it happens:** Silverblue's systemd-managed rootless setup differs from ad-hoc rootless [CITED: Fedora forum].
**How to avoid:** Phase 2 doesn't launch containers via systemd (no Quadlet). Ad-hoc `podman run` from the Elixir release is the documented happy path. Document this in the user-facing README: "Glorbo does not install systemd units; Podman calls are direct from the Elixir release."
**Warning signs:** Users on Silverblue reporting `newuidmap: write to uid_map failed: Invalid argument`.

### Pitfall 5: uvicorn `--uds` default permissions are 0766
**What goes wrong:** [CITED: uvicorn issues #337, #2731] uvicorn creates the Unix socket with permissions 0766 (world-readable/writable) and this is not configurable via CLI flag. In a rootless container with `--userns keep-id`, this exposes the socket to any process that can reach `/run/agent.sock` on the host side of the bind mount.
**Why it happens:** uvicorn design decision.
**How to avoid:** Elixir owns the **containing directory** (`~/.glorbo/runtime/sockets/<company>/`) and chmods it to 0700 before container start. The socket itself inside the dir can be 0766 — attackers still need traverse permission on the parent. Or: after container start, Elixir `File.chmod!` the socket file to 0600 (Phase 3 concern after POSIX ACLs land). Phase 2 relies on directory-level isolation.
**Warning signs:** A plan that claims "socket is 0600" without verifying — it's not, by default.

### Pitfall 6: SQLite + Unix socket + BEAM = one writer
**What goes wrong:** `Glorbo.Company.AuditLog.append/2` writes BOTH JSONL AND SQLite. Under concurrent companies, SQLite's single-writer-at-a-time constraint serializes all audit writes through one Repo connection.
**Why it happens:** SQLite WAL allows concurrent readers but only one writer [CITED: sqlite.org docs].
**How to avoid:** This is fine for Phase 2 — audit events are infrequent (≤ 10s of writes/minute globally). Set `busy_timeout: 5000`. Batch writes only matter at 100s/sec scale. Audit the assumption when Phase 3 lands and agents start producing events at higher rates. Add a `busy_timeout` observability metric.
**Warning signs:** Intermittent `Ecto.QueryError :database_busy` under load test.

### Pitfall 7: `file_system` recursive watch on large trees
**What goes wrong:** inotify on Linux has per-user watch limits (`/proc/sys/fs/inotify/max_user_watches`, often 8192 or 65536). A recursive watch on a company with hundreds of files + thousands of task history entries can exhaust the limit.
**Why it happens:** Each watched directory consumes one watch descriptor.
**How to avoid:** Add Doctor check: `cat /proc/sys/fs/inotify/max_user_watches`, warn if < 65536. Fedora default is 524288 — plenty. Ubuntu default 8192 — tight. Document how Directors raise it: `sudo sysctl fs.inotify.max_user_watches=524288`.
**Warning signs:** `file_system` logs "inotify: no space left on device" or subscribes stop firing for newly created subdirs.

### Pitfall 8: OCI image built on one arch, pulled on another
**What goes wrong:** `ghcr.io/foobarto/glorbo-runtime:v0.1.0` built on amd64 only; `podman pull` on aarch64 Raspberry Pi fails with "no matching manifest".
**Why it happens:** Container registries need multi-arch manifests; build must push both.
**How to avoid:** CI workflow must build with `podman manifest` or use `buildah build --manifest --platform linux/amd64,linux/arm64`. Match Phase 1's aarch64 coverage (FND-04 spans both). Add post-build smoke: `podman manifest inspect ghcr.io/foobarto/glorbo-runtime:v0.1.0` shows both platforms.
**Warning signs:** aarch64 users report image pull failures in GitHub issues.

### Pitfall 9: `network: none` container can't reach host Ollama
**What goes wrong:** An agent configured `provider: ollama` in a `network: none` container cannot reach `http://host.containers.internal:11434`. Obvious in retrospect.
**Why it happens:** `--network none` disables all networking including loopback to host.
**How to avoid:** The Ollama binding must use a Unix socket: `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve` (supported since PR #8072 [CITED]) → bind-mount `/tmp/ollama.sock` into the container → litellm in the container connects via Unix socket. **But:** CONTEXT D-06 says init does NOT start `ollama serve`. So Phase 2 cannot prove LLM-05 end-to-end without the Director starting Ollama manually with a Unix socket binding. Planner to decide: document the exact `OLLAMA_HOST=unix://...` recipe in the example-company README? Or emit it during `init` as a "next step" hint? See Assumptions Log A3.
**Warning signs:** Airplane-mode test fails with "connection refused" — confirm socket path + OLLAMA_HOST + volume mount.

## Code Examples

### Download + verify a static binary

```elixir
# Source: derived from D-02, D-03, verified-URL research finding
defmodule Glorbo.Init.BinaryBootstrap do
  alias Glorbo.Init.Versions

  def ensure_podman do
    case System.find_executable("podman") do
      nil -> download_and_install(:podman)  # D-04 fallback
      path -> {:ok, :system, path}
    end
  end

  defp download_and_install(:podman) do
    arch = detect_arch()  # :amd64 | :arm64
    url = Versions.podman_url(arch)
    expected_sha = Versions.podman_sha256(arch)  # bundled in release, computed at Glorbo release time
    dest_dir = Path.expand("~/.glorbo/bin")
    File.mkdir_p!(dest_dir)

    tmp = Path.join(System.tmp_dir!(), "podman-#{arch}.tar.gz")
    :ok = download(url, tmp)
    :ok = verify_sha256(tmp, expected_sha)  # Pitfall 1: we supply our own SHA
    :ok = extract_podman(tmp, dest_dir)
    File.rm!(tmp)
    {:ok, :downloaded, Path.join(dest_dir, "podman")}
  end

  defp verify_sha256(path, expected) do
    actual =
      File.stream!(path, 65536, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, {:checksum_mismatch, expected, actual}}
  end

  defp extract_podman(tar_gz, dest) do
    # mgoltzsche archive structure: usr/bin/podman, usr/bin/crun, etc.
    # Extract to staging then copy binaries we care about
    staging = Path.join(System.tmp_dir!(), "podman-extract-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(staging)

    {_, 0} = System.cmd("tar", ["-xzf", tar_gz, "-C", staging])
    for bin <- ~w(podman crun conmon runc) do
      src = Path.join([staging, "usr/bin", bin])
      if File.exists?(src) do
        dst = Path.join(dest, bin)
        File.cp!(src, dst)
        File.chmod!(dst, 0o755)
      end
    end
    File.rm_rf!(staging)
    :ok
  end
end
```

### Append-only audit log

```elixir
# Source: CLAUDE.md invariant + Phase 1 stubs_test.exs negative test pattern
defmodule Glorbo.Company.AuditLog do
  use GenServer
  alias Glorbo.Repo

  # Public API — ONLY append. No update. No delete. No edit.
  # Negative test in test/glorbo/stubs_test.exs enforces this.
  def append(actor, event_map) when is_atom(actor) and is_map(event_map) do
    GenServer.call(__MODULE__, {:append, actor, event_map})
  end

  # Intentionally absent:
  #   def update/2
  #   def delete/1
  #   def edit/2

  def init(_), do: {:ok, %{}}

  def handle_call({:append, actor, event}, _from, state) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    record = Map.merge(event, %{ts: ts, actor: Atom.to_string(actor)})
    json = Jason.encode!(record) <> "\n"

    month = Date.utc_today() |> Date.to_string() |> String.slice(0, 7)
    audit_dir = Path.expand("~/.glorbo/companies/#{event[:company] || "_system"}/audit")
    File.mkdir_p!(audit_dir)
    path = Path.join(audit_dir, "#{month}.jsonl")

    # Append to JSONL first — this is the source of truth (FS-05).
    :ok = File.write(path, json, [:append, :sync])

    # Mirror to SQLite — derived data; if this fails the JSONL is still intact.
    {:ok, _} = Repo.insert(%Glorbo.AuditEvent{
      company: event[:company], actor: record.actor,
      action: record.action, detail: Jason.encode!(event), ts: ts
    })

    {:reply, :ok, state}
  end
end
```

### Finch call over Unix socket (Elixir → uvicorn in container)

```elixir
# Source: Finch hexdocs + D-34
defmodule Glorbo.Container.WorkerClient do
  def post_run(company, agent, body_map) do
    socket_path = Path.expand("~/.glorbo/runtime/sockets/#{company}/#{agent}.sock")

    request = Finch.build(
      :post,
      "http://localhost/run",                  # host header required even over socket
      [{"content-type", "application/json"}],
      Jason.encode!(body_map)
    )

    Finch.request(request, Glorbo.Finch,
      unix_socket: socket_path,
      receive_timeout: body_map[:timeout_seconds] * 1000 || 300_000
    )
  end
end
```

### Runtime Containerfile (reference)

```dockerfile
# Source: containers/glorbo-runtime/Containerfile (Phase 2 deliverable)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/
RUN pip3 install --break-system-packages -r requirements.txt

COPY worker/ /app/worker/

# Default CMD is overridden by Elixir's `podman run ... uvicorn ...` invocation.
CMD ["uvicorn", "worker.main:app", "--uds", "/run/agent.sock"]
```

### Minimal `requirements.txt`

```
# Source: DESIGN.md §4.2 + CONTEXT D-12
fastapi==0.115.*
uvicorn[standard]==0.30.*
litellm==1.*
ollama==0.3.*
huggingface-hub==0.25.*
anthropic==0.40.*
openai==1.55.*
google-genai==0.3.*
pyyaml==6.*
```

All versions are the planner's responsibility to pin; [ASSUMED] numbers above are 2026-04-15-plausible ranges based on training data. Exact pins should be `pip-compile`-generated from top-level requirements at image-build time.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker-in-container FastAPI workers | Rootless Podman + bind-mounted Unix socket | ~2022+ | No daemon, no root, no TCP for IPC |
| Native SDK per provider (Anthropic + OpenAI + Google) | `litellm` unified interface | 2024 | One error taxonomy, model-agnostic dispatch, trivial provider swap |
| HTTP TCP between Elixir and Python | Unix domain socket with Finch | 2023+ (Finch socket support) | Preserves `network: none` without compromising ergonomics |
| SHA256 from upstream SHA256SUMS | Glorbo-hosted pinned SHA256 | Phase-2 decision | Handles upstreams that ship GPG-only (podman-static) |

**Deprecated/outdated:**
- Ollama inside the container image: used to be common; now prohibitive at ~2 GB and requires GPU passthrough. Host-side Ollama + Unix-socket mount is the modern pattern.
- `podman build` at install time: replaced by registry pulls. Local builds are reserved for dev iteration.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | CONTEXT D-03's "verify SHA256 checksums from each release's checksum file" can be satisfied by Glorbo publishing its own SHA256s for pinned binaries, rather than consuming an upstream SHA256SUMS file (which mgoltzsche podman-static does not ship; only ollama does). | §Common Pitfalls (Pitfall 1) | If the planner interprets D-03 strictly as "consume upstream SHA256SUMS", podman-static verification fails silently or requires a last-minute switch to GPG — either adds scope. Recommend: raise this with user during plan-check. |
| A2 | `network: none` containers reach host Ollama via bind-mounted Unix socket at `/tmp/ollama.sock`, with `OLLAMA_HOST=unix:///tmp/ollama.sock` set by the Director. | §Common Pitfalls (Pitfall 9), §Architecture Patterns | If wrong, LLM-05 (end-to-end offline after init) is unprovable in Phase 2. Airplane-mode test becomes manual-only. Requires user confirmation: does "Director runs ollama serve" (D-06) include "Director uses the Unix-socket binding we document"? |
| A3 | Ollama Python client supports connecting to a Unix socket (via `OLLAMA_HOST=unix://...`). Verified only for the CLI + HTTP server side of PR #8072; client-side support in `ollama-python` SDK has not been confirmed against current package docs. | §Standard Stack, §Code Examples | If wrong, litellm + ollama Python client cannot reach host Ollama over the socket; fallback is TCP loopback, which requires relaxing `network: none` for ollama agents. Verify at planning time by reading `ollama-python` README. |
| A4 | `yaml_front_matter` Hex package exists and is maintained at a reasonable version (or an equivalent package does). Training data says yes; not verified at this session. | §Supporting libraries | If no maintained YAML-frontmatter package exists, planner writes a ~40-line regex + YAML combo. Small risk. |
| A5 | `/proc/sys/fs/inotify/max_user_watches` on Fedora 43 default is ≥ 65536 and does not need to be raised for a handful of companies with a few hundred files each. | §Common Pitfalls (Pitfall 7) | If wrong on a target host, FileWatcher subscribes silently stop firing. Doctor check mitigates. |
| A6 | Python packages in D-12 (`litellm`, `anthropic`, `openai`, `google-genai`, `huggingface_hub`, `ollama`) are all pip-installable into an Ubuntu 24.04 Python 3.12 image at some currently-valid version range. | §requirements.txt example | Version pinning is a planner responsibility; `pip install` against current top-level names is extremely likely to succeed. |
| A7 | Phase 2 does NOT need to implement POSIX ACLs (SEC-01, SEC-02 are locked to Phase 3 per the PROJECT.md Key Decisions: "SEC-01 and SEC-02 must land together in Phase 3"). Phase 2 prepares container launch infrastructure that Phase 3 extends. | §Project Constraints | Explicit in STATE.md Recent Decisions. Low risk. |

## Open Questions

1. **Ollama host-socket policy (blocks LLM-05 proof):**
   - What we know: PR #8072 added `OLLAMA_HOST=unix://` to the daemon; CONTEXT D-06 hands daemon management to the Director.
   - What's unclear: Does `glorbo init` document the Unix-socket binding Director-facing? Does airplane-mode E2E test require the Director to have started Ollama with that binding pre-test?
   - Recommendation: During plan-check, ask the user: "Should `init` emit a 'Next steps' block showing `OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve`?" If yes, Phase 2 scope includes this documentation path.

2. **Ollama accelerator libraries (image size vs capability):**
   - What we know: `ollama-linux-amd64.tar.zst` is 2.05 GB including ROCm + CUDA userspace libs.
   - What's unclear: Does Glorbo ship the full archive (~2 GB disk cost per install) or only `usr/bin/ollama` (~50 MB, CPU-only)?
   - Recommendation: Phase 2 decision. Default should be **full archive** — CPU-only on a laptop is 10× too slow for any useful Qwen/Llama inference. Flag as Claude's discretion pick.

3. **`--userns keep-id` behaviour when host UID > 60000:**
   - What we know: keep-id requires matching entries in `/etc/subuid` and `/etc/subgid`.
   - What's unclear: What happens when the Director's UID is 0 (root install) or > 60000 (some LDAP setups)?
   - Recommendation: Doctor check: "current UID is in subuid range" with clear remediation message.

4. **Multi-arch ghcr.io image build timing:**
   - What we know: Image must be pulled for both amd64 and aarch64 per FND-04 carryover.
   - What's unclear: Is the runtime-image CI workflow in scope for Phase 2, or a Phase-2 prerequisite that Phase 1 punted to Phase 2?
   - Recommendation: Phase 2 scope. Add `.github/workflows/runtime-image.yml` to the plan. Tag `v0.1.0` on first green push.

## Environment Availability

Probe run 2026-04-15 on dev host (Fedora 43, kernel 6.17.7):

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| podman (system) | RT-01 system-first path | ✓ (assumed) | 5.x | download static v5.8.1 |
| ollama (system) | LLM-01 system-first path | — | — | download static v0.20.7 |
| tar with `--zstd` | Ollama archive extraction | ✓ (GNU tar ≥ 1.31) | — | — (blocker if missing) |
| gpg | If reverting A1 to upstream GPG verify | ✓ (typically) | — | Skip verification (insecure) |
| curl or wget | All downloads | ✓ | — | Fall back to `:httpc` / Finch |
| newuidmap/newgidmap | rootless Podman userns | ✓ (checked by Phase 1 Doctor) | — | Warn + continue (D-08) |
| cgroups v2 | Rootless containers | ✓ (Fedora default since 31) | — | Document Silverblue gotcha |
| `fs.inotify.max_user_watches` ≥ 65536 | FileWatcher | ✓ (Fedora 524288; Ubuntu varies) | — | Doctor warn |

**Missing dependencies with no fallback:**
- `tar` with zstd support. Ships with GNU tar 1.31+ (2019). Any modern distro has it. If absent: hard warning, require Director to `dnf install tar` / `apt install tar`.

**Missing dependencies with fallback:**
- System `podman` / `ollama`: auto-download per RT-01, LLM-01.
- `uidmap`: warn and continue; container launches may later fail with a clear message.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ExUnit (Elixir built-in) |
| Config file | `test/test_helper.exs` (existing) |
| Quick run command | `mix test --only phase2 --stale` |
| Full suite command | `mix test && mix credo --strict && mix format --check-formatted` |
| Container-level | pytest inside the `glorbo-runtime` image (new); driven by Elixir test suite via `podman run` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| FS-01 | `~/.glorbo/` hierarchy created matches DESIGN.md §3 | unit | `mix test test/glorbo/init/hierarchy_test.exs` | ❌ Wave 0 |
| FS-02 | Markdown+YAML frontmatter parses into domain rows | unit | `mix test test/glorbo/filesystem/frontmatter_test.exs` | ❌ Wave 0 |
| FS-03 | `glorbo reindex` reconstructs DB from disk | integration | `mix test test/glorbo/filesystem/reindex_test.exs --only integration` | ❌ Wave 0 |
| FS-04 | Deleting `glorbo.db` + reindex = no data loss | integration | `mix test test/integration/reindex_roundtrip_test.exs` | ❌ Wave 0 |
| FS-05 | AuditLog is append-only (negative assertion) | unit | `mix test test/glorbo/company/audit_log_test.exs` | ❌ Wave 0 (extends Phase-1 stubs_test) |
| FS-05 | AuditLog JSONL + SQLite mirror on every append | unit | (same file) | ❌ Wave 0 |
| FS-06 | FileWatcher reports changes sub-second | integration | `mix test test/glorbo/filesystem/watcher_test.exs --only integration` (uses `File.touch!` + `assert_receive` within 1s) | ❌ Wave 0 |
| RT-01 | Static podman downloads, installs, verifies | unit (with mock curl) | `mix test test/glorbo/init/binary_bootstrap_test.exs` | ❌ Wave 0 |
| RT-02 | Image present after pull; `doctor --fix` re-pulls | integration | `mix test test/integration/image_pull_test.exs --only podman` | ❌ Wave 0 |
| RT-03 | Container A cannot see Company B's dir | integration | `mix test test/integration/container_isolation_test.exs --only podman` | ❌ Wave 0 |
| RT-04 | `--userns keep-id --read-only --network none` assertable via `podman inspect` | integration | assertion on `podman inspect <name>` JSON | ❌ Wave 0 |
| RT-05 | Ephemeral vs persistent mode both launch | integration | `mix test test/integration/container_lifecycle_test.exs --only podman` | ❌ Wave 0 |
| RT-06 | Host has no `python3` installed after `init` | verification | `command -v python3` asserted missing in `Glorbo.Doctor` | (stretch — skip if it fails because dev hosts all have python) |
| LLM-01 | Ollama binary present and executable after init | unit | `mix test test/glorbo/init/binary_bootstrap_test.exs` | ❌ Wave 0 (same file as RT-01) |
| LLM-02 | `huggingface_hub` importable in container | integration | `podman run --rm glorbo-runtime python -c "import huggingface_hub"` exits 0 | covered by Doctor `runtime_exec` |
| LLM-05 | Airplane-mode Ollama inference works | manual + integration | see §Airplane-Mode Test below | ❌ Wave 0 (`test/integration/airplane_mode_test.exs`) |
| CLI-02 | `glorbo init` completes in ~1 minute on fresh host | manual timing | `time ./glorbo init` on a Fedora container; assert < 90s excluding model pull | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `mix test --only phase2 --stale`
- **Per wave merge:** `mix test` (full suite) + `mix credo --strict`
- **Phase gate:** full suite green + manual airplane-mode test + manual `glorbo init` timing on a fresh Fedora 43 container.

### Wave 0 Gaps

Every test file in the Requirements → Test Map is new. Wave 0 of each plan must scaffold:

- [ ] `test/glorbo/init/hierarchy_test.exs` — FS-01
- [ ] `test/glorbo/filesystem/frontmatter_test.exs` — FS-02
- [ ] `test/glorbo/filesystem/reindex_test.exs` — FS-03, FS-04
- [ ] `test/glorbo/filesystem/watcher_test.exs` — FS-06
- [ ] `test/glorbo/company/audit_log_test.exs` — FS-05 (extends Phase 1 `stubs_test.exs` negative assertion)
- [ ] `test/glorbo/init/binary_bootstrap_test.exs` — RT-01, LLM-01
- [ ] `test/integration/reindex_roundtrip_test.exs` — FS-04
- [ ] `test/integration/image_pull_test.exs` — RT-02 (gated by `@moduletag :podman`)
- [ ] `test/integration/container_isolation_test.exs` — RT-03 (gated)
- [ ] `test/integration/container_lifecycle_test.exs` — RT-05 (gated)
- [ ] `test/integration/airplane_mode_test.exs` — LLM-05 (gated `@moduletag :airplane`)
- [ ] `test/support/podman_helpers.ex` — shared fixture: assert `podman` available, skip otherwise
- [ ] `containers/glorbo-runtime/tests/test_worker.py` (+ `conftest.py`) — pytest inside container image (built into image or mounted at test time)

No framework-install step — ExUnit ships with Elixir, pytest ships in the `requirements.txt` (add it).

### Airplane-Mode Test (LLM-05 proof)

Structure:

```elixir
# test/integration/airplane_mode_test.exs
defmodule Glorbo.Integration.AirplaneModeTest do
  use ExUnit.Case
  @moduletag :airplane

  test "Ollama inference executes with no host network" do
    # Precondition: init has completed, runtime image cached,
    # Director has run: OLLAMA_HOST=unix:///tmp/ollama.sock ollama serve &
    # AND pulled a small model: ollama pull llama3.2:1b

    # Drop host networking
    {_, 0} = System.cmd("sudo", ["nmcli", "networking", "off"])
    on_exit(fn -> System.cmd("sudo", ["nmcli", "networking", "on"]) end)

    response = Glorbo.Container.WorkerClient.post_run("acme", "ceo", %{
      task_path: "/company/agents/ceo/inbox/ping.md",
      provider: "ollama",
      model: "llama3.2:1b",
      api_key: nil,
      skills: []
    })

    assert {:ok, %{status: 200}} = response
    assert response |> elem(1) |> Map.get(:body) |> Jason.decode!() |> Map.get("completion")
  end
end
```

The test is `@moduletag :airplane` so it doesn't run in CI (which has network). It's a manual gate on the Director's dev box. Document the full setup in `VERIFY.md` alongside the Phase-1 cosign recipe.

## Security Domain

### Applicable ASVS Categories (per config.json `security_asvs_level: 2`)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no (Phase 3) | — |
| V3 Session Management | no | — |
| V4 Access Control | partial (Phase 3 owns POSIX ACLs; Phase 2 ensures container isolation primitives) | `--userns keep-id`, bind-mount isolation, `--network none` |
| V5 Input Validation | yes | YAML frontmatter parser (reject malformed), `podman inspect` output parsed as JSON (not regex), file-path validation on watcher events |
| V6 Cryptography | yes | `:crypto.hash(:sha256, ...)` for binary verification; `:crypto.hash(:md5, ...)` for reindex (non-security use; MD5 is fine for change detection — collision resistance not required) |
| V12 File + Resource | yes | SELinux `:Z` labels mandatory; tmp file extraction paths sanitized; socket dir chmod 0700 |
| V14 Configuration | yes | No secrets in env; no secrets in `podman inspect`; `config.md` API keys in Phase 3 only |

### Known Threat Patterns for Phase 2 stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tainted tarball from compromised GitHub release | Tampering | SHA256 pinned at Glorbo release time (A1); TLS to github.com; last-known-good date in Versions module |
| Command injection via company/agent names (which become `podman run --name glorbo-${company}-${agent}`) | Tampering | Validate `company` + `agent` against `^[a-z0-9][a-z0-9-]{0,62}$` at creation time; reject anything with shell metacharacters |
| YAML deserialization RCE (PyYAML's `load` vs `safe_load`; yaml_elixir defaults) | Tampering / RCE | Use safe loaders only; `YamlElixir.read_from_file/2` is safe by default; PyYAML inside worker must use `yaml.safe_load` |
| Symlink escape from `~/.glorbo/companies/<co>` to elsewhere on host | Tampering | `realpath` the company dir after mounting; reject if it escapes `~/.glorbo/companies/`. Also: `--read-only` + `:Z` SELinux label block cross-company tampering |
| API keys leaking to logs via `podman inspect` | Info Disclosure | D-37: keys never go in env. Per-request body only. Validate at review time that no `--env GLORBO_API_KEY=...` appears in Invocation code |
| Runaway resource usage (fork bomb, memory blowup) in Python worker | DoS | Phase 2 doesn't set cgroup limits (Phase 3 concern). Document as known gap. `--read-only` + `:Z` limits filesystem damage. |
| Inotify watch resource exhaustion | DoS | Doctor check on `/proc/sys/fs/inotify/max_user_watches`; documented remediation. Debouncing (D-32) keeps event rate bounded. |
| SHA256 verification bypass via race (TOCTOU on downloaded tarball) | Tampering | Verify hash on the in-hand bytes (single-pass stream hash during download) BEFORE extraction. Never verify after-write and re-read. See Pattern in §Code Examples. |

No HIGH-severity threats identified that Phase 2 cannot mitigate with the locked decisions. Phase 3 threat modelling will extend this.

## Sources

### Primary (HIGH confidence)

- [GitHub API — mgoltzsche/podman-static v5.8.1 assets](https://api.github.com/repos/mgoltzsche/podman-static/releases/latest) — verified asset filenames, sizes, published date 2026-04-15
- [GitHub API — ollama/ollama v0.20.7 assets](https://api.github.com/repos/ollama/ollama/releases/latest) — verified asset filenames, sizes, published date 2026-04-15
- [hex.pm/api/packages/file_system](https://hex.pm/api/packages/file_system) — 1.1.1 (2026-04-15)
- [hex.pm/api/packages/ecto_sqlite3](https://hex.pm/api/packages/ecto_sqlite3) — 0.22.0 (2026-04-15)
- [hex.pm/api/packages/finch](https://hex.pm/api/packages/finch) — 0.21.0 (2026-04-15)
- [Ecto.Adapters.SQLite3 hexdocs](https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html) — pragma configuration options
- [podman-run(1)](https://docs.podman.io/en/latest/markdown/podman-run.1.html) — `--userns keep-id`, `--read-only`, `--network none`, `:Z` mount label
- [Ollama PR #8072 — Unix socket support](https://github.com/ollama/ollama/pull/8072) — `OLLAMA_HOST=unix:///path/to/sock` syntax
- [DESIGN.md §3, §4.2, §4.4, §4.5, §8.3, §10, §11](local: /var/home/user/Documents/glorbo/DESIGN.md) — authoritative spec
- [CLAUDE.md](local: /var/home/user/Documents/glorbo/CLAUDE.md) — load-bearing invariants
- [CONTEXT.md for Phase 2](local: .planning/phases/02-filesystem-foundation-container-runtime-local-llm/02-CONTEXT.md) — 46 locked decisions

### Secondary (MEDIUM confidence)

- [mgoltzsche/podman-static README](https://github.com/mgoltzsche/podman-static/blob/master/README.md) — rootless install, included components
- [falood/file_system README](https://github.com/falood/file_system) — subscribe API, message shape
- [Finch hexdocs](https://hexdocs.pm/finch/Finch.html) — `unix_socket:` option, stream callback API
- [litellm provider docs](https://docs.litellm.ai/docs/providers) — `{provider}/{model}` string format
- [uvicorn issue #337](https://github.com/encode/uvicorn/issues/337) — Unix socket permission 0766 default
- [Red Hat — Podman rootless userns modes](https://www.redhat.com/en/blog/rootless-podman-user-namespace-modes) — keep-id semantics
- [Red Hat — User namespaces and SELinux](https://www.redhat.com/en/blog/user-namespaces-selinux-rootless-containers) — `:Z` label behaviour
- [oldmoe blog — SQLite WAL concurrent writes](https://oldmoe.blog/2024/07/08/the-write-stuff-concurrent-write-transactions-in-sqlite/) — writer-serialization confirmation
- [Fedora Silverblue + rootless Podman](https://podman.io/blogs/2019/10/29/podman-crun-f31.html) — cgroups v2 + /etc/subuid setup
- [tonyc.github.io — Elixir ports for external commands](https://tonyc.github.io/posts/managing-external-commands-in-elixir-with-ports/) — MuonTrap rationale

### Tertiary (LOW confidence — flagged for plan-time validation)

- Exact `yaml_front_matter` package name + version — multiple similarly-named Hex packages exist. A5 depends.
- Ollama Python client Unix-socket support (A3) — PR #8072 covers daemon-side only; client-side inferred.
- `ollama-linux-amd64-rocm.tar.zst` necessity vs the plain `ollama-linux-amd64.tar.zst` — plain variant includes both CPU + CUDA paths based on observed size (2 GB vs ~990 MB for ROCm-only). Confirm at planning time.

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — versions verified against live registries on 2026-04-15; asset URLs and sizes pulled from GitHub API.
- Architecture patterns: HIGH — derived directly from CONTEXT's 46 locked decisions + DESIGN.md.
- Runtime state: HIGH — Phase 2 is greenfield; no prior state to migrate.
- Pitfalls: HIGH for documented ones (verified against cited issues); MEDIUM for Silverblue + inotify-watch-limit where dev-box experience informs but wasn't reproduced this session.
- Validation architecture: HIGH for Elixir-side tests (ExUnit + Finch + file_system have known test patterns); MEDIUM for container-level pytest (needs image to exist first; chicken-and-egg).
- Security domain: MEDIUM — Phase 2 is infrastructure; Phase 3 owns the heavy lifting. Threat model focuses on supply chain + input validation for the surface this phase introduces.

**Research date:** 2026-04-15
**Valid until:** 2026-05-15 (30 days for stable; Podman 5.x and Ollama 0.20.x are both on monthly release cadence — bump versions + re-verify in `Glorbo.Init.Versions` when the phase plans land)
