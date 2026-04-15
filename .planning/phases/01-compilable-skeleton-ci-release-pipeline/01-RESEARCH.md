# Phase 1: Compilable Skeleton + CI Release Pipeline - Research

**Researched:** 2026-04-15
**Domain:** Elixir/Phoenix project bootstrap, Burrito single-file releases, GitHub Actions multi-arch CI, Cosign keyless signing
**Confidence:** HIGH (primary tooling verified via hexdocs + official GitHub sources; a small number of details — exact Burrito output filename, Credo friction points on fresh Phoenix — remain MEDIUM until observed at implementation time)

## Summary

Phase 1 is mechanical assembly, not novel design: every technical choice is locked by `01-CONTEXT.md`. The research task is to translate those locked choices (Burrito wraps `mix release`, native aarch64 runners, Cosign keyless, `mix glorbo.doctor`, ExUnit+Credo strict, domain-nested layout from `DESIGN.md` §4.1) into concrete `mix.exs`, workflow YAML, config snippets, and a complete module-stub inventory.

Three integration seams are the main risk surface — (1) Burrito + Phoenix (`PHX_SERVER` handling so the release binary doesn't silently exit), (2) exqlite NIF compilation per-arch (which is why `ubuntu-24.04-arm` native runners replace QEMU), and (3) Burrito output filename vs the `glorbo-linux-x86_64` URL promised in `DESIGN.md` §10 (Burrito emits `{release}_{target}`; CI needs a rename step). All three have known-good resolutions documented below.

**Primary recommendation:** Lock Elixir 1.18.4 + OTP 28.0.2 via `.tool-versions` (matches Burrito v1.5.0's precompiled ERTS exactly, avoiding an ERTS rebuild); use one GitHub Actions workflow with a `[ubuntu-24.04, ubuntu-24.04-arm]` matrix for build+test, a tag-gated `release` job that signs with Cosign keyless and publishes renamed binaries + SHA256SUMS. Structure the work as **three PLAN.md files**: (Plan A) Project skeleton + domain-nested layout + SQLite WAL + Credo/ExUnit; (Plan B) `mix glorbo.doctor` Mix task + its test suite; (Plan C) Burrito integration + GitHub Actions workflow + Cosign signing.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Project generation**
- **D-01:** Initialize with `mix phx.new . --app glorbo --database sqlite3 --no-mailer --no-gettext`
- **D-02:** Keep Phoenix LiveView dependencies (needed in Phase 4); strip only the generated example routes, `/dev` dashboards, and page controller boilerplate
- **D-03:** Reshape the generated layout into the domain-nested structure in `DESIGN.md` §4.1 (`lib/glorbo/{company,agent,router,...}`, `lib/glorbo_web/`) before any other work

**Database**
- **D-04:** SQLite via `ecto_sqlite3`, WAL journal mode enabled in `config/dev.exs`, `config/test.exs`, and `config/runtime.exs` (verified by grep-level checks)
- **D-05:** No migrations or schemas in this phase beyond what Phoenix generates — real schemas land with their owning phase

**Module stubs**
- **D-06:** Create stubs for every top-level domain module listed in `DESIGN.md` §4.1 (supervisors, servers, router, file watcher, audit log, budget tracker). Functions return `{:error, :not_implemented}` or equivalent placeholders
- **D-07:** Wire all stubs into `Glorbo.Application`'s supervision tree — the tree must *start* cleanly, even though every branch is a stub. This locks the OTP shape early (crash-isolation invariant from `CLAUDE.md`)

**Single-binary release**
- **D-08:** Use Burrito to wrap `mix release` (ERTS bundled via `include_erts: true`) into a true single-file executable
- **D-09:** Output binary names match `DESIGN.md` §10 curl URL: `glorbo-linux-x86_64` and `glorbo-linux-aarch64`
- **D-10:** Burrito targets configured for both x86_64-linux-gnu and aarch64-linux-gnu; NIF dependencies (exqlite/ecto_sqlite3) built natively on each target runner, not cross-compiled

**CI pipeline**
- **D-11:** GitHub Actions as CI provider
- **D-12:** Two runners per build job: `ubuntu-24.04` (x86_64) and `ubuntu-24.04-arm` (native aarch64 — GA since 2025-01, free for public repos, no QEMU)
- **D-13:** Trigger matrix — pull requests: compile + test on both archs; push to `main`: compile + test + upload development artifacts (not published to Releases); tags `v*.*.*`: compile + test + signed, versioned release published via GitHub Releases
- **D-14:** Cache `deps/` and `_build/` per-arch keyed on `mix.lock`

**Release signing & integrity**
- **D-15:** Cosign **keyless** signing via Sigstore using the GitHub OIDC token
- **D-16:** Publish `SHA256SUMS` and `SHA256SUMS.sig` alongside every release; end users verify with `cosign verify-blob`
- **D-17:** Dev builds from `main` are not signed — signing only on tagged releases

**`mix glorbo.doctor` CLI**
- **D-18:** Implemented as a `Mix.Task` at `lib/mix/tasks/glorbo.doctor.ex`
- **D-19:** Checks: Linux kernel version, `uidmap` package present, disk space ≥ 1 GB free in `$HOME`, write permission on `~/.glorbo/` (creates if missing), ERTS version sanity check
- **D-20:** Output modes — default human-friendly table with ✓/✗ + terminal colors (auto-disable on non-TTY); `--json` machine-readable; exit `0` on all pass, `1` on any failure
- **D-21:** Doctor is non-destructive — detects + creates `~/.glorbo/`, never installs system packages

**Test stack**
- **D-22:** ExUnit + Credo (strict mode) only in Phase 1
- **D-23:** Dialyzer, StreamData, and Mox deferred until Phase 3
- **D-24:** CI fails on: compile warnings (`--warnings-as-errors`), test failures, Credo strict violations

### Claude's Discretion
- Exact layout/styling of the doctor table output
- Module docstring conventions (aim for useful, not comprehensive)
- `mix.exs` application metadata (version `0.1.0`, SPDX license from `README.md`)
- Credo config tuning (start with strict defaults; loosen only on justified friction)
- GitHub Actions YAML file structure (one vs split workflows)
- Elixir and OTP version (pick current stable; lock via `.tool-versions`)

### Deferred Ideas (OUT OF SCOPE)
- Dialyzer integration (Phase 3)
- Property-based testing / StreamData (Phase 3+)
- Mox mocking (Phase 3)
- SBOM generation (post-v1)
- Signed source-archive provenance (post-v1)
- Homebrew / Nix flake packaging (out of scope for v1)
- Release notes automation (post-v1)
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| FND-01 | Phoenix project generated with `mix phx.new`, SQLite via `ecto_sqlite3`, modules reshaped to domain-nested layout from `DESIGN.md` §4.1 | §Phoenix Generator Trimming + §Domain-Nested Module Stubs |
| FND-02 | SQLite configured in WAL mode for dev, test, and runtime | §SQLite WAL Configuration |
| FND-03 | Single-binary release via `mix release` with `include_erts: true` — no Erlang on target | §Burrito Integration + §`mix release` Configuration |
| FND-04 | Linux x86_64 **and** aarch64 release artifacts produced | §Burrito Targets + §GitHub Actions aarch64 Runners |
| FND-05 | CI compiles, tests, and uploads signed binary artifacts per push to `main` (signed only on tags per D-17) | §CI Workflow Structure + §Cosign Keyless Signing |
| FND-06 | `mix glorbo.doctor` verifies host prerequisites | §`mix glorbo.doctor` Design |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

These constraints from `./CLAUDE.md` shape the supervision-tree shape in Phase 1 — the stubs must honour them even though they're non-functional:

- **Crash isolation follows the OTP supervision tree.** Agent crash → only that agent restarts. Company crash → only that company's agents restart. Dashboard and other companies are unaffected. → **Phase 1 implication:** Use `DynamicSupervisor` for `Glorbo.CompanySupervisor`. Each company is a `Supervisor` with `:one_for_one` strategy. Each agent is a child of its company supervisor, not a top-level child. Do not wire every stub as a sibling of `Glorbo.Repo`.
- **Kernel is the policy engine** — no-op in Phase 1, but the stub `Glorbo.Router` function signatures must shape around "permission check" as a call-site, not a pure function, so Phase 3 can wire it without renaming.
- **Filesystem is source of truth; SQLite is derived.** → **Phase 1 implication:** Don't add any Ecto schemas that wouldn't be rebuildable. Since we're not adding schemas at all in Phase 1, this is trivially satisfied, but set the precedent in module docstrings.
- **Python never runs on host.** → **Phase 1 implication:** Do not add any Python dep, pip, or container exec code to the host-side skeleton. `Glorbo.ContainerManager` is a pure GenServer stub in Phase 1; Phase 2 adds `podman` CLI calls.
- **Audit log is append-only.** → **Phase 1 implication:** `Glorbo.AuditLog` stub exposes `append/2`, never `update/2` or `delete/2`.
- **Inbox/outbox one-way flow.** → **Phase 1 implication:** `Glorbo.Router` stub exposes `route/1` from outbox perspective; no `write_inbox` public function — keep that internal so no caller can bypass the router.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir | 1.18.4 | Language | [VERIFIED: elixir-lang.org] Matches Burrito v1.5.0's bundled ERTS exactly (1.18.4-otp-28). 1.19.5 is current stable (2026-01-09) but using it would force Burrito to rebuild ERTS — not worth the 20-30 min per CI run. |
| OTP / Erlang | 28.0.2 | Runtime | [VERIFIED: Burrito release notes] Matches Burrito v1.5.0 bundled ERTS. |
| Phoenix | 1.8.x (current) | Web framework | [CITED: hexdocs.pm/phoenix] Keeps LiveView path open for Phase 4 (D-02) |
| phoenix_live_view | 1.1.x | Dashboard substrate | [CITED: hexdocs.pm/phoenix_live_view] Brought in by `mix phx.new` default; keep per D-02 |
| ecto | ~> 3.12 | DB abstraction | [CITED: hexdocs.pm/ecto] Brought in transitively by `ecto_sqlite3` |
| ecto_sqlite3 | 0.22.0 | SQLite adapter | [VERIFIED: hexdocs.pm/ecto_sqlite3] Default `:journal_mode` is already `:wal`; explicit config is still required per D-04 for grep-verifiability |
| exqlite | ~> 0.36 | SQLite NIF driver | [VERIFIED: github.com/elixir-sqlite/exqlite, v0.36.0 2026-03-27] Dirty NIF; compiles SQLite3.c during `mix deps.compile`. **Rebuilt per target arch** — this is why we use native aarch64 runners (D-12). |
| burrito | ~> 1.5.0 | Single-file wrapper | [VERIFIED: hexdocs.pm/burrito, v1.5.0 2025-11-03] Wraps `mix release` output in a Zig-compiled self-extracting binary; precompiled ERTS for linux x86_64 + aarch64 |
| file_system | ~> 1.0 | inotify watcher | [CITED: hexdocs.pm/file_system, DESIGN.md §4.1] Not USED in Phase 1 but must be declared as a dep so `mix release` build doesn't drop it. Stub `Glorbo.FileWatcher` references it. |

### Supporting (Dev/Test Only)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| credo | ~> 1.7.18 | Static analysis (strict) | [VERIFIED: hexdocs.pm/credo, v1.7.18] `mix credo --strict` in CI; `.credo.exs` with `strict: true` |
| phoenix_live_reload | ~> 1.6 | Dev-only code reload | Bundled by `mix phx.new`; scoped to `:dev` env in `mix.exs` |

### Deferred to Later Phases (DO NOT ADD in Phase 1)
- `dialyxir` / Dialyzer → Phase 3 (D-23)
- `stream_data` → Phase 3
- `mox` → Phase 3
- `table_rex` or `owl` — initial recommendation is **hand-rolled ANSI** for the doctor table (7 rows × 3 columns; adding a dep for this is overkill and adds `mix release` surface area)

**Installation:**
```bash
# Step 1: generate Phoenix skeleton (adds most deps automatically)
mix phx.new . --app glorbo --database sqlite3 --no-mailer --no-gettext

# Step 2: manually add to mix.exs deps/0 (Burrito + Credo)
# {:burrito, "~> 1.5.0"},
# {:credo, "~> 1.7", only: [:dev, :test], runtime: false}

mix deps.get
```

**Version verification commands** (planner should include in first task):
```bash
mix hex.info burrito    # expect 1.5.0 or newer
mix hex.info ecto_sqlite3   # expect 0.22.0 or newer
mix hex.info credo    # expect 1.7.18 or newer
```

### Alternatives Considered (per CONTEXT.md these are locked; documenting for completeness)
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Burrito | `mix release` tarball + install script | Locked out by D-08; Burrito is the only mainstream Elixir tool that produces a true single-file executable. `mix release` alone emits a tarball of ~60 files. |
| GitHub Actions | Forgejo Actions / Woodpecker / Drone | Locked out by D-11; GitHub Actions is required by D-11 and natural fit for GitHub Releases + Cosign OIDC. |
| Cosign keyless | GPG + long-lived keyring | Locked out by D-15; keyless ties signatures to workflow identity, no key to rotate. |
| ExUnit + Credo | Dialyzer too | Locked out by D-22; deferred to Phase 3. |

## Architecture Patterns

### Recommended Project Structure (Post-Reshape)

Starting from `mix phx.new` output, reshape into the domain-nested layout from `DESIGN.md` §4.1:

```
glorbo/
├── .github/workflows/
│   └── ci.yml                        # Single workflow: PR/main/tag logic
├── .tool-versions                    # elixir 1.18.4-otp-28 / erlang 28.0.2
├── .credo.exs                        # strict: true
├── .formatter.exs                    # Phoenix default
├── mix.exs                           # deps + releases block with Burrito
├── mix.lock
├── config/
│   ├── config.exs                    # shared
│   ├── dev.exs                       # SQLite WAL for dev
│   ├── test.exs                      # SQLite WAL for test
│   ├── runtime.exs                   # SQLite WAL for prod; PHX_SERVER guard
│   └── prod.exs                      # compile-time prod
├── lib/
│   ├── glorbo.ex                     # top-level module docstring
│   ├── glorbo/
│   │   ├── application.ex            # supervision tree entry
│   │   ├── repo.ex                   # Ecto SQLite repo
│   │   ├── company_supervisor.ex     # DynamicSupervisor stub
│   │   ├── container_manager.ex      # GenServer stub (Phase 2)
│   │   ├── company/
│   │   │   ├── supervisor.ex         # per-company Supervisor stub
│   │   │   ├── file_watcher.ex       # GenServer stub (Phase 2/3)
│   │   │   ├── router.ex             # GenServer stub (Phase 3)
│   │   │   ├── scheduler.ex          # GenServer stub (Phase 3)
│   │   │   ├── budget_tracker.ex     # GenServer stub (Phase 3)
│   │   │   └── audit_log.ex          # GenServer stub; append/2 only
│   │   └── agent/
│   │       └── server.ex             # GenServer stub (Phase 3)
│   ├── glorbo_web.ex
│   ├── glorbo_web/
│   │   ├── endpoint.ex               # Phoenix endpoint (stripped routes)
│   │   ├── router.ex                 # minimal: root route only
│   │   ├── telemetry.ex
│   │   ├── components/
│   │   │   ├── core_components.ex    # kept (LiveView baseline)
│   │   │   └── layouts.ex
│   │   └── controllers/
│   │       ├── error_html.ex         # kept (release boot needs it)
│   │       ├── error_json.ex
│   │       └── page_controller.ex    # minimal: health check only
│   └── mix/
│       └── tasks/
│           └── glorbo.doctor.ex      # Mix.Task
├── priv/
│   ├── repo/migrations/              # empty in Phase 1
│   └── static/
├── rel/
│   ├── overlays/                     # optional: doctor wrapper script
│   └── env.sh.eex                    # from `mix phx.gen.release`
├── test/
│   ├── test_helper.exs
│   ├── glorbo/
│   │   └── (stub-module tests, mostly "process starts" smoke tests)
│   └── mix/
│       └── tasks/
│           └── glorbo.doctor_test.exs
└── README.md
```

**Deletions from `mix phx.new` output:**
- `lib/glorbo_web/controllers/page_html/home.html.heex` → replace with minimal `index.html.heex` (or inline string)
- `lib/glorbo_web/controllers/page_html.ex` home rendering → keep module, trim to empty
- Any LiveDashboard route — already excluded by NOT passing `--no-dashboard` would include it; since we DO want LiveView deps but NOT the `/dev/dashboard` route, the scope `scope "/" do` block referencing `LiveDashboard` in `router.ex` must be removed. Alternatively, use `--no-dashboard` and manually re-add `{:phoenix_live_view, "~> 1.1"}` to deps since that's a separate dep from dashboard. **Recommendation: pass `--no-dashboard` to `mix phx.new`; LiveView is a separate dep already included unless `--no-live` is passed.** Keep `--no-gettext`, `--no-mailer`, and add `--no-dashboard`; do NOT add `--no-live` or `--no-html`.

**Kept from `mix phx.new` (critical for boot):**
- `endpoint.ex` — Phoenix needs this; release boot attaches to it
- `error_html.ex` + `error_json.ex` — Phoenix will 500 without them
- `router.ex` with at least one matched route — release boot warns without any routes
- `telemetry.ex` — supervision tree child
- `core_components.ex` + `layouts.ex` — LiveView scaffolding for Phase 4

### Pattern 1: Stub GenServer (for every module in §4.1 not implemented in Phase 1)

```elixir
# Source: https://hexdocs.pm/elixir/GenServer.html (standard OTP pattern)
defmodule Glorbo.Company.Router do
  @moduledoc """
  Routes outbox messages to recipient inboxes and channels.

  *Phase 1 stub.* The Router is the application-layer permission enforcement
  point (CLAUDE.md load-bearing invariant). Phase 3 wires real routing;
  Phase 1 only ensures the process starts under its Company.Supervisor.
  """
  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Route a message from an agent's outbox. Returns `{:error, :not_implemented}`
  in Phase 1; returns `:ok` or `{:error, reason}` from Phase 3 onward.
  """
  def route(_server, _message), do: {:error, :not_implemented}

  @impl true
  def init(opts), do: {:ok, %{company: Keyword.fetch!(opts, :company)}}

  @impl true
  def handle_call(_msg, _from, state), do: {:reply, {:error, :not_implemented}, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}
end
```

**Rationale for GenServer stubs over plain module stubs:**
- Honours D-07 ("supervision tree must start cleanly")
- Surfaces the `CompanySupervisor → Company.Supervisor → {FileWatcher, Router, …}` shape on day 1 — any mistake is caught immediately, not in Phase 3
- Phase 2/3 can replace `handle_call` bodies without changing the spawn/wire-up code
- The supervision tree itself is the FND-01 deliverable: tests can assert `Process.whereis(Glorbo.Company.Router)` returns a pid

### Pattern 2: `Glorbo.Application` supervision tree (Phase 1 shape)

```elixir
# Source: DESIGN.md §7 (supervision tree sketch), adapted for stubs
defmodule Glorbo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Glorbo.Repo,
      {Phoenix.PubSub, name: Glorbo.PubSub},
      Glorbo.Telemetry,                           # already exists from phx.new
      Glorbo.ContainerManager,                    # Phase 1 stub
      {DynamicSupervisor, name: Glorbo.CompanySupervisor, strategy: :one_for_one},
      GlorboWeb.Endpoint
    ]
    opts = [strategy: :one_for_one, name: Glorbo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GlorboWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

**Why `Glorbo.Company` (per-company supervisor) is NOT in the top-level tree:** companies are started dynamically via `DynamicSupervisor.start_child(Glorbo.CompanySupervisor, {Glorbo.Company.Supervisor, company_spec})` in Phase 2. In Phase 1, `Glorbo.CompanySupervisor` is started empty. A Phase 1 test can assert `DynamicSupervisor.count_children(Glorbo.CompanySupervisor) == %{active: 0, …}`.

**Why `Glorbo.Agent.Server` is NOT here at all in Phase 1:** agents are children of their `Glorbo.Company.Supervisor` (DESIGN.md §4.1), not of the application. The module exists as a stub so Phase 3 can implement without renaming, but its start_link is never called in Phase 1.

### Pattern 3: Mix.Task with OptionParser + exit-code discipline

```elixir
# Source: hexdocs.pm/elixir/OptionParser.html; elixir-lang/elixir Mix.Tasks.Test
defmodule Mix.Tasks.Glorbo.Doctor do
  @moduledoc """
  Verifies host prerequisites for running Glorbo.

  ## Usage

      mix glorbo.doctor         # human-readable table
      mix glorbo.doctor --json  # machine-readable

  Exit code: 0 if all checks pass; 1 if any fail.
  """
  @shortdoc "Verify host prerequisites for Glorbo"
  use Mix.Task

  @switches [json: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    results = Glorbo.Doctor.run_checks()

    if opts[:json] do
      results |> Glorbo.Doctor.Formatter.to_json() |> IO.puts()
    else
      results |> Glorbo.Doctor.Formatter.to_table() |> IO.puts()
    end

    if Enum.all?(results, & &1.pass), do: :ok, else: exit({:shutdown, 1})
  end
end
```

The actual check logic lives in `Glorbo.Doctor` (non-Mix module) so Phase 2's `glorbo init` can call it directly without invoking Mix:

```elixir
defmodule Glorbo.Doctor do
  @moduledoc "Host prerequisite checks. Callable from the Mix task or from Phase 2's init flow."

  @type check_result :: %{
          name: String.t(),
          pass: boolean(),
          detail: String.t()
        }

  @spec run_checks() :: [check_result()]
  def run_checks do
    [
      check_kernel_version(),
      check_uidmap(),
      check_disk_space(),
      check_glorbo_dir(),
      check_erts_version()
    ]
  end

  # each check: {:ok, detail} | {:fail, detail} → normalised to check_result map
  defp check_kernel_version, do: …
  defp check_uidmap, do: …
  # etc.
end
```

**Split rationale:** `Mix.Task.run/2` is brittle to call programmatically (it side-effects Mix state, prints to stdout, terminates the Mix process on failure). Putting logic in a plain module lets Phase 2 do `case Glorbo.Doctor.run_checks() |> Enum.split_with(…) do …` without forking or shelling.

### Pattern 4: Burrito in `mix.exs`

```elixir
# Source: hexdocs.pm/burrito/readme.html (v1.5.0)
defmodule Glorbo.MixProject do
  use Mix.Project

  def project do
    [
      app: :glorbo,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      compilers: Mix.compilers(),
      # CI will run mix compile --warnings-as-errors; don't set globally
    ]
  end

  def application do
    [
      mod: {Glorbo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp releases do
    [
      glorbo: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.6"},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.22"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:floki, ">= 0.37.0", only: :test},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.6"},
      {:dns_cluster, "~> 0.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:burrito, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:file_system, "~> 1.0"}  # Phase 2 uses it; declared so stub reference compiles
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
```

**Build command:** `MIX_ENV=prod mix release` (Burrito's `steps: [:assemble, &Burrito.wrap/1]` plugs into the `mix release` pipeline automatically).

**Output location:** `burrito_out/` directory, filenames `glorbo_linux_x86_64` and `glorbo_linux_aarch64` (pattern `{release_name}_{target_atom_name}`). These underscores do NOT match `DESIGN.md` §10's `glorbo-linux-x86_64` URL pattern — CI must rename via `mv` before upload (see §CI Workflow Structure).

### Anti-Patterns to Avoid

- **Putting every domain module directly under `Glorbo.Application`'s children list.** Violates CLAUDE.md crash isolation. Per-agent GenServers must be children of per-company supervisors, not of the application. Even as Phase 1 stubs, the shape must be right.
- **Using `Mix.Task.run/2` to call doctor from Phase 2 code.** Always call `Glorbo.Doctor.run_checks/0` directly; the Mix task is a thin CLI wrapper.
- **Hard-coding BEAM paths in runtime.exs.** Burrito unpacks to `~/.local/share/.burrito/` (or XDG equivalent); any `File.cwd!/0` or `:code.priv_dir/1` assumption that the release is run from its unpacked dir will break. Use `Application.app_dir/2` exclusively.
- **Running `mix release` without `MIX_ENV=prod`.** Burrito will assemble a dev-mode release with reloaders and test deps baked in — ~3x binary size and unsafe config.
- **Forgetting `PHX_SERVER` handling.** Without it, the release binary boots, starts supervisors, then exits because the Phoenix endpoint doesn't start its HTTP listener. In Phase 1 we don't need the HTTP server for `./glorbo doctor` to work, but we DO need it for `./glorbo` (no args) not to be surprising. See §`mix release` Configuration below.
- **Passing `--no-live` to `mix phx.new`.** This comments out the LiveView socket in endpoint.ex; Phase 4 would have to re-add it, which is exactly what D-02 forbids.
- **Adding Dialyzer / Dialyxir "just while we're in here."** Locked out by D-23. Adds 2-3 min to CI, adds a `.dialyzer_ignore.exs` maintenance file, and catches almost nothing on stub GenServers.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Wrapping `mix release` output in a single file | A bash script that tars, adds a shebang preamble, and self-extracts | Burrito v1.5.0 | [VERIFIED: hexdocs.pm/burrito] Burrito handles ERTS bundling, Zig-wrapper extraction, per-arch ERTS selection, maintenance commands (`./glorbo maintenance uninstall`). Reinventing it is ~2000 lines of fragile shell + Zig. |
| Signing release artifacts | GPG + long-lived maintainer keys | Cosign keyless via GitHub OIDC | [VERIFIED: docs.sigstore.dev] Keyless removes the key-rotation and key-compromise threat model entirely; signatures are tied to the workflow run identity and logged in Rekor's transparency log. |
| Multi-arch CI builds | QEMU emulation of aarch64 on x86_64 runners | Native `ubuntu-24.04-arm` runners | [VERIFIED: github.blog 2025-01-16, github.blog 2024-06-24] Native runners are free for public repos, free of QEMU bugs and NIF silent corruption, and ~5-10x faster than emulated builds. CONTEXT.md D-12 already locks this in. |
| SQLite driver | Compiling sqlite3.c in Phase 1 ourselves | `exqlite` (brought in by `ecto_sqlite3`) | [VERIFIED: github.com/elixir-sqlite/exqlite v0.36.0] Already bundles + compiles SQLite C source via Dirty NIF; maintained, well-tested, current. |
| CLI option parsing | Hand-parsing `argv` strings | Elixir stdlib `OptionParser` | [CITED: hexdocs.pm/elixir/OptionParser.html] Stdlib; handles `--json`, `--no-json`, bundled flags correctly; no reason to add a dep. |
| JSON output | Hand-rolling JSON escaping | Stdlib `JSON` module (Elixir 1.18+) OR `Jason` (already a dep) | [CITED: elixir-lang.org/blog/2024/12/19] Elixir 1.18 added a stdlib `JSON` module; for Phase 1, use `Jason.encode!/1` since `jason` is already in Phoenix's default deps — avoids the "is 1.18's JSON stable?" question. |
| Table rendering for doctor | Bringing in `owl` or `table_rex` | Hand-rolled with `IO.ANSI` + `String.pad_trailing/3` | Five check rows × three columns. A ~40-line formatter is simpler, has no release-size impact, and dodges a dependency. The `IO.ANSI.enabled?/0` guard handles non-TTY auto-disable (D-20). |

**Key insight:** For this phase specifically, the temptation is to add "just one more dep" to save a few lines. Resist — every dep is now part of the shipped binary, Burrito's wrap time, and the dep-tree audit surface. Only Burrito and Credo are genuinely load-bearing additions over `mix phx.new` output.

## Burrito Integration (detailed)

### Current state

Burrito v1.5.0 (2025-11-03) provides precompiled ERTS for OTP 25.3+ on Linux (x86_64, aarch64), macOS (x86_64, aarch64), and Windows (x86_64). Zig 0.15.2 is required on the build machine; `xz` is required for compression. Burrito's `wrap` step runs after `:assemble` in the `mix release` pipeline, taking the assembled release directory and producing a single executable per configured target.

### Target syntax

Targets are keyword-list entries where the key becomes part of the output filename and the value is a keyword list with `os:` and `cpu:` (no `libc:` field in v1.5.0 — Burrito's precompiled ERTS is built against musl libc internally, making binaries portable across glibc/musl distros):

```elixir
targets: [
  linux_x86_64: [os: :linux, cpu: :x86_64],     # → burrito_out/glorbo_linux_x86_64
  linux_aarch64: [os: :linux, cpu: :aarch64]    # → burrito_out/glorbo_linux_aarch64
]
```

### NIF handling

[VERIFIED: hexdocs.pm/burrito/readme.html, github.com/elixir-sqlite/exqlite v0.36.0]

- `exqlite` is a Dirty NIF that compiles `sqlite3.c` during `mix deps.compile`.
- Burrito bundles the **already-compiled** NIF `.so` files from `_build/prod/lib/*/priv/`.
- Because NIFs are architecture-specific ELF shared objects, **Burrito does NOT cross-compile them** — you must run `MIX_ENV=prod mix release` on a build machine matching the target architecture.
- This is the entire reason CONTEXT.md D-10 and D-12 lock in native `ubuntu-24.04-arm` runners: building the aarch64 binary on an x86_64 runner would produce an x86_64 `exqlite.so` inside an aarch64 Burrito wrapper → `exec format error` at runtime.
- `skip_nifs: true` is a Burrito option to suppress NIF recompilation; do NOT set this — the default behaviour (compile + bundle) is what we want.

### Phoenix + Burrito gotchas

[VERIFIED: hexdocs.pm/burrito/readme.html "Phoenix Application Configuration"]

1. **`PHX_SERVER` environment variable.** The default Phoenix `runtime.exs` only starts the HTTP endpoint if `System.get_env("PHX_SERVER")` is truthy. Since our `mix glorbo.doctor` and future `./glorbo doctor` invocations do NOT need HTTP, leave this mechanism in place. Phase 4 (or Phase 1's decision) can add a `./glorbo serve` Burrito maintenance hook that sets `PHX_SERVER=1` before boot.
   - **Recommendation:** Write a tiny `rel/overlays/bin/glorbo-serve` shell overlay OR wire `argv[0] == "serve"` into `Glorbo.Application.start/2` to set `PHX_SERVER`. Defer the actual implementation to Phase 4 — in Phase 1, `./glorbo` with no args boots, runs doctor via `argv`, then halts.
2. **Asset precompilation.** `MIX_ENV=prod mix assets.deploy` must run BEFORE `mix release` so Phoenix's static assets are compiled + digested into `priv/static/`. Burrito bundles `priv/`, so post-wrap asset changes won't appear. In Phase 1 there are no meaningful assets (no LiveView pages yet), but the `mix assets.deploy` step still runs on the default Phoenix generator output — include it in CI to avoid a surprise in Phase 4.

### Burrito output filename

[VERIFIED via multiple sources: hexdocs.pm/burrito + community writeups]

Pattern: `burrito_out/{release_name}_{target_keyword}`

- Release named `glorbo` with target keyword `:linux_x86_64` → `burrito_out/glorbo_linux_x86_64`
- Release named `glorbo` with target keyword `:linux_aarch64` → `burrito_out/glorbo_linux_aarch64`

**Filename mismatch with DESIGN.md §10:** Glorbo's README/DESIGN promises `curl github.com/.../releases/latest/download/glorbo-linux-x86_64` (hyphen-separated). Burrito produces `glorbo_linux_x86_64` (underscore-separated). Resolution: CI renames after build:

```yaml
- name: Rename to release naming
  run: |
    mv burrito_out/glorbo_linux_x86_64 burrito_out/glorbo-linux-x86_64
    # or for aarch64 job
    mv burrito_out/glorbo_linux_aarch64 burrito_out/glorbo-linux-aarch64
```

**Alternative:** Change Burrito target names to use valid-identifier equivalents that happen to match (`:"linux-x86_64"` is not a valid Elixir atom as written without quoting, but `:linux_x86_64` → Burrito produces `glorbo_linux_x86_64`). The rename step is clearer and more robust — no hidden coupling between target atom string and output file convention.

### Verification: building locally

```bash
# Pre-reqs on build machine
which zig       # 0.15.2+
which xz

# Build
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile --warnings-as-errors
MIX_ENV=prod mix assets.deploy    # noop without real assets but harmless
MIX_ENV=prod mix release

# Verify
ls -la burrito_out/
file burrito_out/glorbo_linux_x86_64    # ELF 64-bit LSB executable, x86-64
./burrito_out/glorbo_linux_x86_64 maintenance meta    # prints bundled metadata

# Run doctor
./burrito_out/glorbo_linux_x86_64 doctor    # if argv dispatch wires mix glorbo.doctor
```

The "argv dispatch" is a Phase 1 decision: since `mix glorbo.doctor` runs `Mix.Task.run/2`, and Mix is NOT available in a `mix release` binary (release strips Mix), the release binary needs a separate dispatch mechanism. **Recommendation:** Have `Glorbo.Application.start/2` inspect `Burrito.Util.Args.argv()` — if `argv == ["doctor"]`, run `Glorbo.Doctor.run_checks/0`, print, and `System.halt/1`. The Mix task is the dev-time entry point; `Burrito.Util.Args.argv()` is the release-binary entry point; both call the shared `Glorbo.Doctor` module.

## GitHub Actions aarch64 Runners

### Current state

[VERIFIED: github.blog 2025-01-16, 2024-06-24]

- `ubuntu-24.04-arm` label is GA since 2024-06-24 on paid plans, and **free for public repositories** since 2025-01-16. Private repos require a paid Team/Enterprise plan OR self-hosted runners.
- `ubuntu-22.04-arm` also exists but we should prefer 24.04 to match x86_64.
- Native aarch64 runners provision in the same pool as x86_64 — no special syntax besides the label.
- `erlef/setup-beam@v1` supports ARM64 runners; it downloads the correct prebuilt OTP/Elixir for the runner architecture automatically [VERIFIED: github.com/erlef/setup-beam README — "self-hosted ARM runners need ImageOS set"; hosted runners handle this automatically].

### Matrix pattern

```yaml
jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-24.04
            arch: x86_64
          - runner: ubuntu-24.04-arm
            arch: aarch64
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18.4'
          otp-version: '28.0.2'
      - name: Cache deps
        uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ matrix.arch }}-${{ hashFiles('mix.lock') }}
          restore-keys: |
            mix-${{ matrix.arch }}-
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
      - run: mix credo --strict
      - run: mix format --check-formatted
```

**Visibility gate:** If this repo is private at first and moves public later, either (a) set up on a public mirror, (b) pay for the Team plan, OR (c) use self-hosted aarch64 runners. Decision for Phase 1: **assume public repo** (as `DESIGN.md` §10's `github.com/glorbo/glorbo/releases/` implies a public release distribution). Flag in the plan if this assumption is wrong.

### Zig installation for Burrito

Zig is not preinstalled on GitHub runners. Use `goto-bus-stop/setup-zig` OR install via apt. Recommendation:

```yaml
- name: Install Zig 0.15.2
  uses: goto-bus-stop/setup-zig@v2
  with:
    version: 0.15.2
```

This action provides per-runner architecture handling and is the Burrito-project-recommended approach (referenced in several community Burrito CI examples).

## Cosign Keyless Signing

### Current state

[VERIFIED: github.com/sigstore/cosign, docs.sigstore.dev]

- Cosign v3.0.6 (2026-04-06) is current. Cosign 2.x removed the `COSIGN_EXPERIMENTAL=1` requirement — keyless signing is now GA, no env var needed.
- `sigstore/cosign-installer@v3` is the GitHub Action for installing cosign on runners.
- Keyless signing requires `id-token: write` workflow permission.
- The modern recommended flow uses `--bundle` (single JSON file combining signature + certificate + Rekor proof) instead of separate `--output-signature` and `--output-certificate` files — verification is simpler and offline-friendly.

### Blob signing flow

```yaml
release:
  needs: [build-x86_64, build-aarch64]
  if: startsWith(github.ref, 'refs/tags/v')
  runs-on: ubuntu-24.04
  permissions:
    contents: write    # to create release
    id-token: write    # to get OIDC token for Sigstore
  steps:
    - uses: actions/download-artifact@v4
      with:
        path: artifacts/
    - name: Generate SHA256SUMS
      working-directory: artifacts/
      run: |
        sha256sum glorbo-linux-x86_64 glorbo-linux-aarch64 > SHA256SUMS
        cat SHA256SUMS
    - uses: sigstore/cosign-installer@v3
      with:
        cosign-release: 'v3.0.6'
    - name: Sign SHA256SUMS
      working-directory: artifacts/
      run: |
        cosign sign-blob --yes --bundle SHA256SUMS.sig SHA256SUMS
    - uses: softprops/action-gh-release@v2
      with:
        files: |
          artifacts/glorbo-linux-x86_64
          artifacts/glorbo-linux-aarch64
          artifacts/SHA256SUMS
          artifacts/SHA256SUMS.sig
```

**Note on naming:** Traditionally `SHA256SUMS.sig` was a raw signature and `SHA256SUMS.pem` held the cert. With `--bundle`, the single `SHA256SUMS.sig` file is a JSON bundle containing both. This matches CONTEXT.md D-16 (`SHA256SUMS` + `SHA256SUMS.sig`) — no separate `.pem`.

### End-user verification

```bash
# Download all three
curl -LO https://github.com/glorbo/glorbo/releases/download/v0.1.0/glorbo-linux-x86_64
curl -LO https://github.com/glorbo/glorbo/releases/download/v0.1.0/SHA256SUMS
curl -LO https://github.com/glorbo/glorbo/releases/download/v0.1.0/SHA256SUMS.sig

# Verify signature on SHA256SUMS
cosign verify-blob \
  --bundle SHA256SUMS.sig \
  --certificate-identity-regexp '^https://github.com/glorbo/glorbo/\.github/workflows/.+@refs/tags/v.+$' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  SHA256SUMS

# Then verify the binary's checksum
sha256sum -c SHA256SUMS --ignore-missing
```

Document this exact incantation in a top-level `VERIFY.md` or the release description template.

**Pitfall:** The `--certificate-identity-regexp` value must match the exact workflow file path + ref pattern. If you rename `.github/workflows/ci.yml` later, the verification regex must update accordingly (or it falsely rejects old releases if the regex is too narrow). Keep the regex broad enough: `^https://github.com/glorbo/glorbo/\.github/workflows/.+$`.

### Why keyless is preferred over GPG (reinforcing CONTEXT.md D-15)

- No maintainer key to rotate, lose, or compromise.
- Signature identity is the GitHub workflow run itself — verifiable via Rekor transparency log without trusting a maintainer keyring.
- Zero setup on contributor side — no `gpg --import` dance for users or devs.
- Any fork inherits the same signing infrastructure automatically.

## `mix release` Configuration

### `mix.exs` releases block

Shown above in §Pattern 4. Key points:
- Single release named `glorbo` (matches `app: :glorbo`).
- `:assemble` runs the standard `mix release` steps; `&Burrito.wrap/1` runs after, wrapping the release into the final binary.
- No `include_erts: true` is strictly needed — Burrito handles ERTS via its own precompiled set — but it does no harm and makes intent explicit. `mix release`'s own ERTS embedding would be redundant but not broken.

### `config/runtime.exs` additions

After `mix phx.gen.release` runs, `runtime.exs` has a scaffold. Phase 1 needs:

```elixir
# config/runtime.exs
import Config

# Start Phoenix HTTP only if PHX_SERVER set — per Burrito guidance
if System.get_env("PHX_SERVER") do
  config :glorbo, GlorboWeb.Endpoint, server: true
end

if config_env() == :prod do
  # SQLite WAL mode — D-04
  database_path =
    System.get_env("GLORBO_DB_PATH") ||
      Path.expand("~/.glorbo/glorbo.db")

  config :glorbo, Glorbo.Repo,
    database: database_path,
    journal_mode: :wal,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      # Generate a stable key derived from the binary path — acceptable for
      # Phase 1 since HTTP endpoint is not exposed. Phase 4 may replace with
      # ~/.glorbo/config.md-derived secret.
      :crypto.hash(:sha256, System.get_env("HOME", "/tmp")) |> Base.encode64()

  config :glorbo, GlorboWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
    secret_key_base: secret_key_base
end
```

**Phase 1 scope:** The `runtime.exs` scaffold is in place but Phase 1 does not exercise `PHX_SERVER=1` — the release only needs to start its supervision tree, optionally run `doctor`, and exit cleanly. Phase 4 adds the real `./glorbo serve` path.

### Running from a release binary

`mix release` strips Mix entirely, so `mix glorbo.doctor` doesn't exist in the installed binary. Two paths to expose doctor via the release:

**Option A (recommended): argv dispatch in `Glorbo.Application.start/2`**

```elixir
@impl true
def start(_type, _args) do
  case Burrito.Util.Args.argv() do
    ["doctor" | rest] -> run_doctor_and_halt(rest)
    _ -> start_supervision_tree()
  end
end

defp run_doctor_and_halt(argv) do
  {opts, _, _} = OptionParser.parse(argv, strict: [json: :boolean])
  results = Glorbo.Doctor.run_checks()
  output =
    if opts[:json],
      do: Glorbo.Doctor.Formatter.to_json(results),
      else: Glorbo.Doctor.Formatter.to_table(results)
  IO.puts(output)
  exit_code = if Enum.all?(results, & &1.pass), do: 0, else: 1
  # start a minimal supervisor so Application returns {:ok, pid} then halt
  {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
  Task.start(fn -> System.halt(exit_code) end)
  {:ok, pid}
end
```

**Option B: release overlay script** — `rel/overlays/bin/glorbo-doctor` invokes `RELEASE_NAME eval 'Glorbo.Doctor.run_checks() |> …'`. More fragile (two code paths for the same command) and doesn't match the `./glorbo doctor` UX promised in `DESIGN.md` §10.

Use Option A. Keep the `Mix.Tasks.Glorbo.Doctor` module for dev-time `mix glorbo.doctor`; argv dispatch handles the release path. Both share `Glorbo.Doctor.run_checks/0`.

## Phoenix Generator Trimming

### `mix phx.new . --app glorbo --database sqlite3 --no-mailer --no-gettext --no-dashboard`

Note the addition of `--no-dashboard` to CONTEXT.md's command — this removes the `/dev/dashboard` LiveDashboard wiring without removing LiveView itself. LiveView is a separate dep (`{:phoenix_live_view, "~> 1.1"}`) that remains unless you pass `--no-live` (which we do NOT pass, per D-02).

### Files to strip after `mix phx.new`

[VERIFIED: hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html + hexdocs.pm/phoenix/directory_structure.html]

After generation:

1. **Delete the home page template:**
   - Remove `lib/glorbo_web/controllers/page_html/home.html.heex`
   - In `lib/glorbo_web/controllers/page_html.ex`, remove the `home` function/template reference (leave the module empty or delete if no other templates reference it)

2. **Trim the PageController:**
   - `lib/glorbo_web/controllers/page_controller.ex` — replace the default `home/2` action with either `nothing` (delete the file + its route) OR `def health(conn, _), do: send_resp(conn, 200, "ok")` for a `/health` probe.

3. **Trim the router:**
   - `lib/glorbo_web/router.ex` — remove the `get "/", PageController, :home` line; replace with `get "/health", PageController, :health` if keeping the controller, OR leave only the default browser pipeline and no routes.
   - Remove any `scope "/dev"` block that referenced LiveDashboard (should already be absent given `--no-dashboard`).

4. **Keep code-reload scaffolding in `config/dev.exs`:**
   - The `live_reload:` block inside `config :glorbo, GlorboWeb.Endpoint, …` is fine to keep; it only activates in dev and is harmless when there are no LiveView pages to reload. Phase 4 uses it.

### What `mix phx.new` dependencies look like (expected mix.exs after generation)

Phoenix 1.8 adds roughly these deps:
- `:phoenix ~> 1.8`
- `:phoenix_ecto ~> 4.6`
- `:ecto_sql ~> 3.12`
- `:ecto_sqlite3` (version from generator, typically `>= 0.17.0` — we pin `~> 0.22` explicitly)
- `:phoenix_html ~> 4.2`
- `:phoenix_live_reload ~> 1.6` (dev only)
- `:phoenix_live_view ~> 1.1` (NOT added if `--no-live`)
- `:floki >= 0.37.0` (test only)
- `:phoenix_live_dashboard` — EXCLUDED by `--no-dashboard`
- `:swoosh`, `:finch` — EXCLUDED by `--no-mailer`
- `:gettext` — EXCLUDED by `--no-gettext`
- `:jason ~> 1.4`
- `:bandit ~> 1.6`
- `:dns_cluster ~> 0.2`
- `:telemetry_metrics ~> 1.0`
- `:telemetry_poller ~> 1.1`

Add to this: `:burrito`, `:credo`, `:file_system` (so Phase 2's stubs compile without surprise).

### Test config gotcha

`mix phx.new` default `config/test.exs` configures a filesystem-backed SQLite DB at `_build/test/glorbo_test.db`. Explicitly set `journal_mode: :wal` per D-04:

```elixir
# config/test.exs
config :glorbo, Glorbo.Repo,
  database: Path.expand("../glorbo_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal,
  pool_size: System.schedulers_online() * 2
```

**[VERIFIED: hexdocs.pm/ecto_sqlite3 v0.22]** WAL applies to disk-backed DBs. If we used `:memory:`, WAL is effectively ignored (SQLite in-memory DBs don't create WAL files). Since we use `_build/test/glorbo_test.db`, WAL is meaningful. **Do NOT switch test DB to `:memory:`** — per hexdocs warning, "a crash in a process performing a query… will cause the database to be destroyed."

## Domain-Nested Module Stubs (DESIGN.md §4.1 catalog)

Quoting DESIGN.md §4.1 (Supervision tree sketch), the full set of modules this phase must stub out:

```
Glorbo.Application              # fully implemented (wires children)
Glorbo.Repo                     # fully implemented (Ecto repo, trivial)
Glorbo.ContainerManager         # GenServer stub
GlorboWeb.Endpoint              # from phx.new, fully working
Glorbo.CompanySupervisor        # DynamicSupervisor, starts empty
Glorbo.Company.Supervisor       # per-company Supervisor, NOT started in Phase 1
Glorbo.Company.FileWatcher      # GenServer stub
Glorbo.Company.Router           # GenServer stub  [LOAD-BEARING per CLAUDE.md]
Glorbo.Company.Scheduler        # GenServer stub
Glorbo.Company.BudgetTracker    # GenServer stub
Glorbo.Company.AuditLog         # GenServer stub; exposes only append/2
Glorbo.Agent.Server             # GenServer stub, not started anywhere in Phase 1
```

Additional modules needed but not explicitly named in §4.1 (inferred from §3, §5, §6, §7):

```
Glorbo.Doctor                   # fully implemented (check logic)
Glorbo.Doctor.Formatter         # fully implemented (table + JSON output)
Mix.Tasks.Glorbo.Doctor         # fully implemented (dev-time CLI)
```

### Stub contract

Every GenServer stub follows the pattern shown in §Pattern 1:

- `start_link/1` that accepts a `:name` (optionally scoped like `{:via, Registry, ...}` — but we don't need a Registry in Phase 1; plain atoms are fine for the CompanySupervisor stubs since they aren't dynamically spawned)
- `init/1` returning `{:ok, state}` where state is a map with minimum needed keys
- `handle_call/3`, `handle_cast/2`, `handle_info/2` all returning safe-default tuples
- Public API functions (e.g., `route/2`, `append/2`, `check_budget/1`) return `{:error, :not_implemented}`
- `@moduledoc` that names the responsibility AND flags Phase-1-stub status

### Test expectations for stubs

Two classes of tests:

1. **Smoke tests (per stub):** `test "Glorbo.Company.Router is startable" do {:ok, pid} = Glorbo.Company.Router.start_link(name: :test_router, company: :test); assert Process.alive?(pid) end`
2. **Application boot test:** `test "Glorbo.Application supervision tree starts cleanly" do assert Process.whereis(Glorbo.Repo); assert Process.whereis(Glorbo.ContainerManager); assert Process.whereis(GlorboWeb.Endpoint); assert is_pid(Process.whereis(Glorbo.CompanySupervisor)) end`

This directly satisfies FND-01's "domain-nested module layout… and OTP supervision tree skeleton… in place" success criterion, and Phase 3 gets a runnable tree to fill in.

## `mix glorbo.doctor` Design

### Checks (from D-19)

| Check | Implementation | Pass Criterion |
|-------|----------------|----------------|
| Linux kernel version | `{output, 0} = System.cmd("uname", ["-r"])` and parse | ≥ 5.13 (supports rootless userns with idmapped mounts) |
| `uidmap` present | `System.find_executable("newuidmap") != nil` AND same for `newgidmap` | Both present |
| Disk space ≥ 1 GB | `System.cmd("df", ["-B1", "--output=avail", System.user_home!()])` parse line 2 | ≥ 1_073_741_824 bytes |
| `~/.glorbo/` writable | `File.mkdir_p!(Path.expand("~/.glorbo"))` + `File.write("~/.glorbo/.doctor_probe", "ok")` + remove | No raise |
| ERTS version | `:erlang.system_info(:otp_release) \|> List.to_string()` parse to int | ≥ 27 (we ship 28, but 27 is an OK floor for any release binary running under older ERTS if user does something weird) |

### Non-destructive creation

D-21: doctor CREATES `~/.glorbo/` if missing but does not install packages. Implementation: `File.mkdir_p!(path)` is idempotent and considered "detection + safe creation" per D-21.

Do NOT have doctor attempt to create sub-directories like `~/.glorbo/companies/` — that's Phase 2's job (FS-01). Phase 1 just creates the top-level dir.

### Output formats

**Table (default):**

```
Glorbo Doctor — host prerequisite check

  ✓ Linux kernel           6.17.7 (required: ≥ 5.13)
  ✓ uidmap                 /usr/bin/newuidmap, /usr/bin/newgidmap
  ✓ Disk space             128.4 GB available in /home/user (required: ≥ 1 GB)
  ✓ ~/.glorbo/ writable    /home/user/.glorbo (created)
  ✓ ERTS version           28 (required: ≥ 27)

All checks passed (5/5).
```

On any failure:

```
  ✗ uidmap                 newuidmap not found in PATH; install the 'uidmap' or 'shadow-utils' package

1 check failed (4/5 passed).
```

Exit `1`.

**JSON (--json):**

```json
{
  "version": "0.1.0",
  "checks": [
    {"name": "linux_kernel", "pass": true, "detail": "6.17.7", "required": "≥ 5.13"},
    {"name": "uidmap", "pass": false, "detail": "newuidmap not found", "required": "installed"},
    ...
  ],
  "all_passed": false,
  "passed_count": 4,
  "total_count": 5,
  "exit_code": 1
}
```

Stable keys: `name`, `pass`, `detail`, `required`, `version`, `all_passed`, `passed_count`, `total_count`, `exit_code`. Phase 2's `glorbo init` shells this via `System.cmd(…, ["doctor", "--json"])` (or, better, calls `Glorbo.Doctor.run_checks/0` directly — but the JSON path is the stable cross-process contract).

### Color handling

```elixir
defp maybe_color(text, color) do
  if IO.ANSI.enabled?(), do: IO.ANSI.format([color, text], true), else: text
end
```

`IO.ANSI.enabled?/0` returns `false` on non-TTY stdout (piped output), honouring D-20's auto-disable requirement.

### Mix task + argv dispatch coordination

Two entry points must call the same `Glorbo.Doctor.run_checks/0`:

1. **Dev-time:** `mix glorbo.doctor [--json]` → `Mix.Tasks.Glorbo.Doctor.run/1`
2. **Release-time:** `./glorbo doctor [--json]` → `Glorbo.Application.start/2` inspects `Burrito.Util.Args.argv()`

Both parse `--json` with the same OptionParser config, call `Glorbo.Doctor.run_checks/0`, call `Glorbo.Doctor.Formatter.to_table/1` or `to_json/1`, and exit with 0 or 1.

## Credo Strict Mode Configuration

### `.credo.exs`

```elixir
# .credo.exs
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          # Credo's default enabled checks apply; additions/suppressions below.
        ],
        disabled: [
          # Most common fresh-Phoenix friction points:
          {Credo.Check.Readability.ModuleDoc, []},          # stub modules have tiny @moduledoc
          {Credo.Check.Design.TagTODO, []},                 # Phase 1 stubs intentionally use TODO markers
          {Credo.Check.Readability.AliasOrder, []}          # subjective; not worth the noise
        ]
      }
    }
  ]
}
```

[VERIFIED: hexdocs.pm/credo v1.7.18]

### CI command

```yaml
- run: mix credo --strict    # redundant with .credo.exs's strict: true, but explicit
```

**Common friction points** (ranked by likelihood of hitting in a fresh Phoenix skeleton):

1. **`Credo.Check.Readability.ModuleDoc`** — phx.new generates modules without `@moduledoc`. Either add empty `@moduledoc false` to every stripped-down phx.new module, OR disable (shown above).
2. **`Credo.Check.Warning.IExPry`** — never relevant in fresh code.
3. **`Credo.Check.Design.TagTODO`** — Phase 1 stubs will likely have `# TODO: Phase N`. Disable for this phase.
4. **`Credo.Check.Refactor.LongQuoteBlocks`** — `core_components.ex` generated by Phoenix has large `~H` quote blocks. Either raise the threshold OR keep default (Phoenix tends to stay under).
5. **`Credo.Check.Readability.Specs`** — strict mode enables this. Stub GenServers don't need specs. **Recommendation:** disable for Phase 1, re-enable in Phase 3 when modules have real behaviour.

**Strategy:** Start with default strict, run `mix credo --strict`, fix what's easy (missing `@moduledoc false`), disable what's noise on stubs (the list above). Document each disable with a `# reason:` comment in `.credo.exs`.

### `mix format --check-formatted`

In CI, add this as a separate step after `mix credo --strict`. Fresh Phoenix skeleton passes `mix format --check-formatted` out of the box; hand-written stub code might not. Run `mix format` before committing.

### `mix compile --warnings-as-errors`

Per D-24, CI must fail on warnings. `mix compile --warnings-as-errors` does this. Common first-run warnings:

- Unused `@moduledoc` content in stubs — trim.
- `unused variable` in stub `handle_call` pattern-match — prefix with underscore.
- Pattern-match warnings if a stub's `init/1` doesn't handle all opts — use catch-all `_opts`.

## SQLite WAL Configuration

### Per-env config

[VERIFIED: hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html v0.22 — `:journal_mode` default is already `:wal`]

**config/dev.exs:**
```elixir
config :glorbo, Glorbo.Repo,
  database: Path.expand("../glorbo_dev.db", __DIR__),
  pool_size: 5,
  journal_mode: :wal,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
```

**config/test.exs:**
```elixir
config :glorbo, Glorbo.Repo,
  database: Path.expand("../glorbo_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  journal_mode: :wal
```

**config/runtime.exs (prod only):**
```elixir
if config_env() == :prod do
  database_path =
    System.get_env("GLORBO_DB_PATH") ||
      Path.expand("~/.glorbo/glorbo.db")

  config :glorbo, Glorbo.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    journal_mode: :wal
end
```

### Verification (grep-level per D-04)

```bash
grep -n 'journal_mode: :wal' config/*.exs
# config/dev.exs:5:  journal_mode: :wal
# config/test.exs:6:  journal_mode: :wal
# config/runtime.exs:20:    journal_mode: :wal
```

Include this check in the Phase 1 verification step.

### Why it persists across boots

WAL mode is stored in the SQLite database file header. Once set, `journal_mode=WAL` persists for the file — re-setting it on each boot is a no-op but cheap. This is good: even if someone drops the config, an existing `glorbo.db` remains in WAL mode until explicitly changed via `PRAGMA journal_mode=DELETE`.

## CI Workflow Structure

### Recommended: single `ci.yml` workflow

Per CONTEXT.md's discretion-allowed discretion, one workflow is simpler and easier to reason about than split files. Shape:

```yaml
# .github/workflows/ci.yml
name: CI

on:
  pull_request:
  push:
    branches: [main]
    tags: ['v*.*.*']

permissions:
  contents: read

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  build-and-test:
    name: ${{ matrix.arch }} build + test
    strategy:
      fail-fast: false
      matrix:
        include:
          - runner: ubuntu-24.04
            arch: x86_64
            binary_name: glorbo-linux-x86_64
            burrito_out: glorbo_linux_x86_64
          - runner: ubuntu-24.04-arm
            arch: aarch64
            binary_name: glorbo-linux-aarch64
            burrito_out: glorbo_linux_aarch64
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.18.4'
          otp-version: '28.0.2'
      - uses: actions/cache@v4
        with:
          path: |
            deps
            _build
          key: mix-${{ matrix.arch }}-${{ hashFiles('mix.lock') }}
          restore-keys: mix-${{ matrix.arch }}-
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
      - run: mix credo --strict
      - run: mix format --check-formatted
      - name: Install Zig 0.15.2
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.2
      - name: Install xz
        run: sudo apt-get update && sudo apt-get install -y xz-utils
      - name: Build release
        env:
          MIX_ENV: prod
        run: |
          mix deps.get --only prod
          mix compile --warnings-as-errors
          mix assets.deploy
          mix release
      - name: Rename binary to release convention
        run: mv burrito_out/${{ matrix.burrito_out }} burrito_out/${{ matrix.binary_name }}
      - uses: actions/upload-artifact@v4
        with:
          name: ${{ matrix.binary_name }}
          path: burrito_out/${{ matrix.binary_name }}
          retention-days: 30
          if-no-files-found: error

  release:
    name: Publish signed release
    if: startsWith(github.ref, 'refs/tags/v')
    needs: build-and-test
    runs-on: ubuntu-24.04
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: artifacts/
          merge-multiple: true
      - name: Generate SHA256SUMS
        working-directory: artifacts/
        run: |
          sha256sum glorbo-linux-x86_64 glorbo-linux-aarch64 > SHA256SUMS
          cat SHA256SUMS
      - uses: sigstore/cosign-installer@v3
        with:
          cosign-release: 'v3.0.6'
      - name: Sign SHA256SUMS
        working-directory: artifacts/
        run: cosign sign-blob --yes --bundle SHA256SUMS.sig SHA256SUMS
      - uses: softprops/action-gh-release@v2
        with:
          files: |
            artifacts/glorbo-linux-x86_64
            artifacts/glorbo-linux-aarch64
            artifacts/SHA256SUMS
            artifacts/SHA256SUMS.sig
          generate_release_notes: true
          draft: false
          prerelease: false
```

### Cache key rationale

- Include `${{ matrix.arch }}` in the key: aarch64 `_build` artifacts are NOT compatible with x86_64 (recall: exqlite NIF is per-arch).
- `hashFiles('mix.lock')` as the exact-match key ensures cache invalidation on any dep change.
- `restore-keys: mix-${{ matrix.arch }}-` as a prefix fallback saves partial compile time if mix.lock changed trivially.

### Matrix vs jobs

A single matrix strategy is cleanest. `fail-fast: false` so an x86_64 test failure doesn't cancel the aarch64 build — we want to see both.

### Dev builds vs signed releases

Per D-13 + D-17:
- PR/main: `actions/upload-artifact@v4` — visible to maintainers only, expires per retention-days. **Unsigned.**
- Tags `v*.*.*`: `softprops/action-gh-release@v2` with Cosign-signed `SHA256SUMS`. Publicly downloadable.

The `release` job's `if: startsWith(github.ref, 'refs/tags/v')` gates this correctly.

### Permissions hygiene

Top-level `permissions: contents: read` (least privilege). Only the `release` job escalates to `contents: write` + `id-token: write`. This prevents a compromised test dependency from opening a PR or pushing a tag.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ExUnit (stdlib, Elixir 1.18.4) |
| Config file | `test/test_helper.exs` |
| Quick run command | `mix test --stale` |
| Full suite command | `mix test` |
| Additional lint/format | `mix credo --strict`, `mix format --check-formatted`, `mix compile --warnings-as-errors` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| FND-01 | `mix compile` succeeds on fresh checkout with domain-nested layout | smoke | `mix compile --warnings-as-errors` | ✅ (mix compile is always available) |
| FND-01 | `Glorbo.Application` supervision tree starts cleanly | unit | `mix test test/glorbo/application_test.exs` | ❌ Wave 0 |
| FND-01 | Every §4.1 stub module is addressable (module exists + has expected public API) | unit | `mix test test/glorbo/stubs_test.exs` | ❌ Wave 0 |
| FND-02 | SQLite WAL configured in dev, test, runtime | integration | `mix test test/glorbo/repo_wal_test.exs` (asserts `PRAGMA journal_mode` on running connection) | ❌ Wave 0 |
| FND-02 | WAL verified grep-level in config files | static | `grep -rn 'journal_mode: :wal' config/ \| wc -l` ≥ 3 | ❌ Wave 0 (add as shell script test) |
| FND-03 | `mix release` produces a Burrito binary | integration | `MIX_ENV=prod mix release && test -x burrito_out/glorbo_linux_x86_64` | ❌ Wave 0 (runs in CI, slow) |
| FND-03 | Binary runs on host with no Erlang installed | smoke (manual-in-CI via clean ubuntu container) | Phase-1 manual verification: `docker run --rm -v $PWD/burrito_out:/b ubuntu:24.04 /b/glorbo_linux_x86_64 doctor` | ❌ Wave 0 (CI-only test) |
| FND-04 | Both x86_64 and aarch64 artifacts produced by CI | CI matrix | CI workflow runs both matrix entries; both upload artifacts | ❌ Wave 0 (requires workflow) |
| FND-05 | CI compiles, tests, and uploads binary on push to main | CI workflow | GitHub Actions run visible in repo | ❌ Wave 0 |
| FND-05 | Signed binary + SHA256SUMS on tag | CI workflow | On `v*.*.*` tag, release job produces `SHA256SUMS.sig`; `cosign verify-blob` passes | ❌ Wave 0 (manual gate) |
| FND-06 | `mix glorbo.doctor` runs each of 5 checks | unit | `mix test test/mix/tasks/glorbo.doctor_test.exs` | ❌ Wave 0 |
| FND-06 | `mix glorbo.doctor --json` emits valid JSON with stable keys | unit | same file, `--json` case | ❌ Wave 0 |
| FND-06 | `./glorbo doctor` (Burrito binary) runs checks via argv dispatch | integration | CI step: build release + `./burrito_out/glorbo-linux-x86_64 doctor --json \| jq .all_passed` | ❌ Wave 0 (CI-only) |

### Sampling Rate
- **Per task commit:** `mix test --stale && mix credo --strict` (~5-15 seconds, under the Nyquist per-commit budget)
- **Per wave merge:** `mix test && mix credo --strict && mix format --check-formatted && mix compile --warnings-as-errors` (~30 seconds)
- **Phase gate:** Full suite green + CI workflow dry-run on a feature branch PR confirms multi-arch build succeeds + manual `cosign verify-blob` on a test tag-like pre-release

### Wave 0 Gaps

All of these test files must be created before Phase 1 implementation begins. They are currently absent (greenfield):

- [ ] `test/glorbo/application_test.exs` — asserts supervision tree starts, expected children present
- [ ] `test/glorbo/stubs_test.exs` — asserts each §4.1 module exists, has `start_link/1`, and Mox-less smoke-level "returns {:error, :not_implemented}"
- [ ] `test/glorbo/repo_wal_test.exs` — connects to test repo, runs `Ecto.Adapters.SQL.query!(Glorbo.Repo, "PRAGMA journal_mode;", [])`, asserts result is `"wal"`
- [ ] `test/mix/tasks/glorbo.doctor_test.exs` — calls `Mix.Tasks.Glorbo.Doctor.run/1` with each combination of argv flags; asserts stdout (via `ExUnit.CaptureIO`)
- [ ] `test/glorbo/doctor_test.exs` — unit-tests each `check_*` private function in `Glorbo.Doctor`
- [ ] `test/support/` directory + `test/support/doctor_helpers.exs` — shared fixtures for mocking `System.cmd` via fn injection (so we can test without actually requiring newuidmap on the test host)

- [ ] `.github/workflows/ci.yml` — the workflow itself is a test artifact; it must parse validly (`action-validator` is a nice CI-of-CI check if desired)

**Framework install note:** ExUnit ships with Elixir 1.18.4; no `mix archive.install` needed. Credo needs `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}` in deps.

## Environment Availability

| Dependency | Required By | Available (on dev machine) | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | All Phase 1 work | ✓ | 1.19.5 (dev machine has newer than recommended 1.18.4 — will still work, but CI must lock 1.18.4) | — |
| Erlang/OTP | All Phase 1 work | ✓ | 28.3.1 (dev); 28.0.2 (CI pin) | — |
| Zig | Burrito build (local verification) | ✗ | — | CI always has it via `goto-bus-stop/setup-zig`; local dev can `curl -L https://ziglang.org/download/0.15.2/...` OR defer local Burrito builds and rely on CI |
| xz | Burrito compression | ✓ (Linux stdlib) | present | — |
| cosign | Release signing | ✓ | installed on dev machine; CI installs via action | — |
| GitHub Actions runners (aarch64) | CI matrix | N/A on dev | — | None — aarch64 testing must happen in CI. Local dev can only test x86_64 path. |

**Missing on dev machine, with fallback:** Zig. Impact: planner cannot run `MIX_ENV=prod mix release` locally without first installing Zig 0.15.2. Recommendation: **include a one-time "install Zig locally" step in Plan C's first task** OR defer all release-binary verification to CI (slower feedback loop). Strong recommendation: install Zig locally so Plan C's tasks have a fast feedback loop — reduces "oops, the workflow was wrong" round-trips.

**Missing dependencies with no fallback:** None. Native aarch64 testing must happen in CI, but CONTEXT.md D-12 already encodes this decision.

## Common Pitfalls

### Pitfall 1: NIF Architecture Mismatch
**What goes wrong:** Burrito bundles NIF shared objects from `_build/prod/lib/exqlite/priv/`. If you run `mix release` on x86_64 and package the aarch64 binary somehow, the bundled NIF is x86_64 → `exec format error` at runtime.
**Why it happens:** Someone tries to "save a CI run" by cross-compiling, or uses QEMU emulation and the NIF silently links against the wrong arch.
**How to avoid:** Locked by D-10 + D-12: native aarch64 runners only. Never use QEMU for Burrito builds.
**Warning signs:** Release binary runs on build host but fails with "exec format error" or "invalid ELF" on a different host.

### Pitfall 2: `PHX_SERVER` Gate Silently Skipped
**What goes wrong:** The release binary starts, the supervision tree boots, then the BEAM exits because the Phoenix endpoint never ran its HTTP listener and there's no permanent application.
**Why it happens:** `runtime.exs` wraps endpoint `server: true` in `if System.get_env("PHX_SERVER")` (Burrito docs recommend this). Without the env var or argv dispatch, the release has no permanent process → BEAM halts.
**How to avoid:** For `./glorbo doctor`, argv dispatch handles halt explicitly. For `./glorbo serve` (Phase 4), overlay script sets `PHX_SERVER=1`. For `./glorbo` with no args in Phase 1: either print help and halt, OR keep tree running on a permanent GenServer. Recommendation: print help and halt — the tree shouldn't run without a command.
**Warning signs:** `./glorbo` exits immediately with no error, code 0.

### Pitfall 3: `mix.exs` Release Block Missing `steps: [:assemble, &Burrito.wrap/1]`
**What goes wrong:** Running `MIX_ENV=prod mix release` produces the default tarball in `_build/prod/rel/glorbo/` instead of a Burrito single-file binary in `burrito_out/`.
**Why it happens:** Adding `:burrito` to deps doesn't auto-wire it; the `steps:` list must explicitly include `&Burrito.wrap/1`.
**How to avoid:** Include `steps: [:assemble, &Burrito.wrap/1]` in the release config. Phase 1 test: `MIX_ENV=prod mix release && test -f burrito_out/glorbo_linux_x86_64`.
**Warning signs:** `burrito_out/` directory never appears; `_build/prod/rel/glorbo/` appears instead.

### Pitfall 4: SQLite WAL Files on `/tmp` or NFS
**What goes wrong:** `~/.glorbo/glorbo.db` on an NFS mount — SQLite WAL requires mmap + shared memory → corruption.
**Why it happens:** User's `$HOME` is on NFS.
**How to avoid:** Phase 1 scope: doctor does NOT currently check for NFS. Add to Phase 2's `glorbo init`. Document the limitation in `README.md` constraints section.
**Warning signs:** Intermittent `database is locked` errors; corrupted DB after crash.

### Pitfall 5: Credo Strict Mode Blocks on First CI Run
**What goes wrong:** Fresh `mix phx.new` output passes `mix credo` but NOT `mix credo --strict` — strict mode enables `Credo.Check.Readability.Specs` which demands `@spec` on every public function, which phx.new doesn't generate.
**Why it happens:** Default vs strict mode difference.
**How to avoid:** Disable `Credo.Check.Readability.Specs` in `.credo.exs` for Phase 1 (see §Credo Strict Mode Configuration). Re-enable in Phase 3 when real functions with meaningful types exist.
**Warning signs:** CI red on first push, output like "Specs missing for function foo/1" across a dozen stub files.

### Pitfall 6: Cosign Certificate Identity Regex Too Narrow
**What goes wrong:** User tries `cosign verify-blob --certificate-identity-regexp '…/release\.yml@refs/tags/v0\.1\.0$' …`, then Phase 2 publishes `v0.2.0`, and the identity regex rejects the new version.
**Why it happens:** Users copy-paste the exact tag from the release notes into the regex.
**How to avoid:** Document the canonical verification regex as `^https://github.com/glorbo/glorbo/\.github/workflows/.+@refs/tags/v.+$` in `VERIFY.md`. Never hard-code a specific tag.
**Warning signs:** Old releases verify, new ones reject with "no matching signatures".

### Pitfall 7: Burrito Doesn't Rebuild on Source Change Without `--force`
**What goes wrong:** Developer edits `lib/glorbo/doctor.ex`, runs `mix release`, tests stale binary.
**Why it happens:** `mix release` uses incremental builds; Burrito's wrap step compares timestamps and may skip.
**How to avoid:** Use `mix release --overwrite` during development iteration. CI always runs on clean checkouts so doesn't hit this.
**Warning signs:** Changes not appearing in binary output; `./glorbo maintenance meta` shows old version.

### Pitfall 8: `priv/` Directory Assets Missing from Release
**What goes wrong:** Phoenix `mix assets.deploy` produces digested assets in `priv/static/assets/`. If skipped before `mix release`, the release has no assets.
**Why it happens:** CI workflow skips the `mix assets.deploy` step.
**How to avoid:** Always run `MIX_ENV=prod mix assets.deploy` before `MIX_ENV=prod mix release` in CI. Phase 1 has no real assets but the step is idempotent and cheap.
**Warning signs:** Phase 4 LiveView pages 404 on assets.

## Code Examples

Full file templates the planner can use verbatim in tasks:

### `.tool-versions`
```
elixir 1.18.4-otp-28
erlang 28.0.2
```

### `.credo.exs` (see §Credo Strict Mode Configuration)

### `.github/workflows/ci.yml` (see §CI Workflow Structure)

### `mix.exs` releases block (see §Pattern 4)

### `Glorbo.Application` (see §Pattern 2)

### Stub GenServer template (see §Pattern 1)

### `Mix.Tasks.Glorbo.Doctor` (see §Pattern 3)

### `Glorbo.Doctor` skeleton
```elixir
defmodule Glorbo.Doctor do
  @moduledoc """
  Host prerequisite checks shared between `mix glorbo.doctor` (dev entry) and
  `./glorbo doctor` (release binary argv dispatch).
  """

  @type check :: %{
          name: String.t(),
          pass: boolean(),
          detail: String.t(),
          required: String.t()
        }

  @spec run_checks() :: [check()]
  def run_checks do
    [
      check(:linux_kernel, &check_linux_kernel/0),
      check(:uidmap, &check_uidmap/0),
      check(:disk_space, &check_disk_space/0),
      check(:glorbo_dir, &check_glorbo_dir/0),
      check(:erts_version, &check_erts_version/0)
    ]
  end

  defp check(name, fun) do
    case fun.() do
      {:ok, detail, required} ->
        %{name: Atom.to_string(name), pass: true, detail: detail, required: required}

      {:fail, detail, required} ->
        %{name: Atom.to_string(name), pass: false, detail: detail, required: required}
    end
  end

  # --- individual checks (each returns {:ok | :fail, detail, required}) ---

  defp check_linux_kernel do
    {output, 0} = System.cmd("uname", ["-r"])
    version = String.trim(output)
    # naive major.minor parse:
    [major, minor | _] = version |> String.split(".") |> Enum.map(&Integer.parse/1) |> Enum.map(&elem(&1, 0))
    pass = major > 5 or (major == 5 and minor >= 13)
    tag = if pass, do: :ok, else: :fail
    {tag, version, "≥ 5.13"}
  end

  defp check_uidmap do
    uid = System.find_executable("newuidmap")
    gid = System.find_executable("newgidmap")

    case {uid, gid} do
      {nil, _} -> {:fail, "newuidmap not found", "uidmap package installed"}
      {_, nil} -> {:fail, "newgidmap not found", "uidmap package installed"}
      {u, g} -> {:ok, "#{u}, #{g}", "uidmap package installed"}
    end
  end

  defp check_disk_space do
    home = System.user_home!()
    {output, 0} = System.cmd("df", ["-B1", "--output=avail", home])
    bytes = output |> String.split("\n") |> Enum.at(1, "0") |> String.trim() |> String.to_integer()
    required = 1_073_741_824
    tag = if bytes >= required, do: :ok, else: :fail

    {tag, "#{format_gb(bytes)} GB available in #{home}", "≥ 1 GB"}
  end

  defp check_glorbo_dir do
    path = Path.expand("~/.glorbo")
    File.mkdir_p!(path)
    probe = Path.join(path, ".doctor_probe")
    File.write!(probe, "ok")
    File.rm!(probe)
    {:ok, "#{path} (writable)", "writable"}
  rescue
    e in [File.Error] ->
      {:fail, Exception.message(e), "writable"}
  end

  defp check_erts_version do
    v = :erlang.system_info(:otp_release) |> List.to_string() |> String.to_integer()
    tag = if v >= 27, do: :ok, else: :fail
    {tag, "OTP #{v}", "≥ 27"}
  end

  defp format_gb(bytes), do: Float.round(bytes / 1_073_741_824, 1)
end
```

### `Glorbo.Doctor.Formatter`
```elixir
defmodule Glorbo.Doctor.Formatter do
  @moduledoc "Human + JSON output for Glorbo.Doctor."

  alias IO.ANSI

  def to_table(results) do
    header = "Glorbo Doctor — host prerequisite check\n"
    rows = Enum.map_join(results, "\n", &format_row/1)
    summary = format_summary(results)
    Enum.join([header, rows, "", summary], "\n")
  end

  def to_json(results) do
    passed = Enum.count(results, & &1.pass)
    total = length(results)

    %{
      version: "0.1.0",
      checks: results,
      all_passed: passed == total,
      passed_count: passed,
      total_count: total,
      exit_code: if(passed == total, do: 0, else: 1)
    }
    |> Jason.encode!(pretty: true)
  end

  defp format_row(%{pass: pass, name: name, detail: detail, required: required}) do
    icon = if pass, do: color("✓", :green), else: color("✗", :red)
    "  #{icon} #{String.pad_trailing(name, 24)} #{detail} (required: #{required})"
  end

  defp format_summary(results) do
    passed = Enum.count(results, & &1.pass)
    total = length(results)

    if passed == total do
      color("All checks passed (#{passed}/#{total}).", :green)
    else
      color("#{total - passed} check(s) failed (#{passed}/#{total} passed).", :red)
    end
  end

  defp color(text, color) do
    if ANSI.enabled?(), do: ANSI.format([color, text], true) |> IO.iodata_to_binary(), else: text
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `Distillery` for Elixir releases | `mix release` (stdlib) + Burrito for single-file | Elixir 1.9 (2019) added `mix release`; Burrito v1.0 (2023-12) | Phase 1 uses the current stack; Distillery is end-of-life |
| `COSIGN_EXPERIMENTAL=1` for keyless signing | keyless is GA in Cosign 2.x, now 3.x | Cosign 2.0 (2023-06) | No env var needed; just use `cosign sign-blob --yes` |
| QEMU emulation for aarch64 CI | Native `ubuntu-24.04-arm` runners | 2025-01-16 public repos GA | No emulation bugs, no NIF corruption, ~5-10x faster |
| GPG-signed releases | Cosign keyless via OIDC | Sigstore GA (2022) + GitHub OIDC (2021) | No long-lived keys; signatures tied to workflow identity |
| Separate `.sig` and `.pem` files | `--bundle` combined JSON | Cosign 2.x | One artifact, simpler verification |
| `Mix.Task` as only CLI mechanism for Elixir apps | argv-dispatch from a Burrito release binary | Burrito v1.0+ | Dev-time (`mix foo`) and release-time (`./app foo`) share logic |

**Deprecated / avoid:**
- **`Distillery`** — superseded by `mix release`; no new projects should use it.
- **`COSIGN_EXPERIMENTAL=1`** — no longer required; older docs still show it.
- **GPG for binary signing in CI workflows** — operational burden without benefit vs Cosign keyless.
- **QEMU-based multi-arch Elixir builds** — silent NIF bugs; avoid unless forced (e.g., arch not offered by GitHub).
- **`:memory:` SQLite for Ecto test adapter** — ecto_sqlite3 docs explicitly warn against it (crash of query process destroys DB).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The target `github.com/glorbo/glorbo` repo is or will be public, so free `ubuntu-24.04-arm` runners apply | §GitHub Actions aarch64 Runners | If private, needs paid Team plan or self-hosted aarch64 runners; CI cost/setup changes materially |
| A2 | Elixir 1.18.4 + OTP 28.0.2 is the ideal pin to avoid Burrito ERTS rebuilds | §Standard Stack (Core) | If wrong Elixir version is picked, Burrito rebuilds ERTS which adds ~20-30 min per CI run |
| A3 | `mix phx.new` current generator (Phoenix 1.8.x) produces the directory structure described in §Phoenix Generator Trimming | §Phoenix Generator Trimming | Minor — if generator output differs slightly, trimming list needs small adjustment |
| A4 | Disabling `Credo.Check.Readability.Specs` in Phase 1 is acceptable discretion | §Credo Strict Mode Configuration | Low — if strict specs are desired on Phase 1 stubs, disable list shrinks; planner decides |
| A5 | Dev machine is expected to install Zig locally for Burrito testing | §Environment Availability | Low — CI works without local Zig; only affects dev feedback loop speed |
| A6 | `./glorbo` (no args) should print help and halt, not run a headless service | §Pitfall 2 + §`mix release` Configuration | Low — behavior choice; DESIGN.md §10 has `glorbo run` as explicit headless-orchestration verb, suggesting the no-arg default should not be headless |
| A7 | `cosign-release: v3.0.6` in the cosign-installer action is the current recommended version | §Cosign Keyless Signing | Low — planner verifies at implementation time; v3.0.6 was released 2026-04-06 |
| A8 | Burrito output naming is `{release}_{target_atom}`, verified via community examples but not directly in official docs | §Burrito Integration (filename) | Low — if pattern differs, CI rename step adjusts one line; planner confirms empirically in first Plan C task |
| A9 | `DESIGN.md` §10's curl URL `glorbo-linux-x86_64` is the binding naming convention | §Burrito Integration (filename) | Low but binding — if this URL is "aspirational" and not contractual, the rename step could be dropped |

**Three items warrant user confirmation before implementation:** A1 (repo visibility — affects CI cost), A6 (no-arg CLI behavior — affects UX), A9 (binary filename — affects published download URL). All others are low-risk discretion items the planner can default.

## Open Questions for Planner

1. **Plan boundary decision: one plan or three?**
   - Recommended: **three plans** (coarse granularity per `config.json` + ROADMAP.md):
     - **Plan A:** Project skeleton + domain-nested layout + SQLite WAL + Credo/ExUnit baseline (FND-01, FND-02)
     - **Plan B:** `mix glorbo.doctor` Mix task + `Glorbo.Doctor` + argv dispatch wiring (FND-06)
     - **Plan C:** Burrito + GitHub Actions workflow + Cosign signing (FND-03, FND-04, FND-05)
   - Plan A has no external dependencies; Plan B depends on A (needs the module tree to live in); Plan C depends on A (needs compilable code) and benefits from B being done (can test `./glorbo doctor` end-to-end).
   - **Alternative:** two plans — merge A+B into "Code + Tests" and keep C as "CI + Release". This matches the dev-time vs release-time split. Planner's choice — I recommend three.

2. **Whether `Glorbo.Agent.Server` and `Glorbo.Company.Supervisor` should be *started* by any test in Phase 1.**
   - These modules exist (stubs) but aren't wired into the boot-time tree. Should a Phase 1 test manually `DynamicSupervisor.start_child(Glorbo.CompanySupervisor, {Glorbo.Company.Supervisor, …})` to exercise the per-company branch?
   - Recommendation: **yes, one smoke test** — confirms the full tree shape works, catches wiring bugs early. Not "real behavior"; just "supervisor accepts child_spec, children start, CompanySupervisor count goes to 1".

3. **Secret key base strategy for release binary.**
   - `runtime.exs` needs `secret_key_base` for `GlorboWeb.Endpoint`. Phase 1 has no real HTTP exposure; any value works. Phase 4 needs a real secret.
   - Recommendation for Phase 1: derive from host hash (shown in §`mix release` Configuration runtime.exs example) OR accept `SECRET_KEY_BASE` env var with a lame-but-consistent fallback. Planner decides; not load-bearing for FND-01..06.

---

## Sources

### Primary (HIGH confidence)
- [Burrito README @ hexdocs v1.5.0](https://hexdocs.pm/burrito/readme.html) — target syntax, mix.exs integration, Phoenix pitfalls, Zig requirement, NIF handling
- [ecto_sqlite3 v0.22.0 docs](https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html) — WAL default, all pragmas, in-memory warning
- [exqlite v0.36.0 GitHub](https://github.com/elixir-sqlite/exqlite) — NIF architecture, EXQLITE_USE_SYSTEM, build requirements
- [erlef/setup-beam GitHub](https://github.com/erlef/setup-beam) — ARM64 runner support, ImageOS requirement for self-hosted
- [GitHub Actions ARM64 GA changelog](https://github.blog/changelog/2025-01-16-linux-arm64-hosted-runners-now-available-for-free-in-public-repositories-public-preview/) — public-repo availability, 2024-24.04-arm label
- [Phoenix 1.8 `mix phx.new` docs](https://hexdocs.pm/phx_new/Mix.Tasks.Phx.New.html) — all flags including --no-dashboard, --no-mailer, --no-gettext
- [Phoenix 1.8 directory structure](https://hexdocs.pm/phoenix/directory_structure.html) — generated file layout
- [Phoenix releases guide](https://hexdocs.pm/phoenix/releases.html) — mix phx.gen.release, runtime.exs pattern, rel/overlays
- [Credo v1.7.18 config docs](https://hexdocs.pm/credo/config_file.html) — strict mode via config file, default checks
- [sigstore/cosign GitHub](https://github.com/sigstore/cosign) — v3.0.6 current, --bundle flag, keyless GA
- [DESIGN.md §4.1, §7, §10, §11 (in-repo)](../../../DESIGN.md) — supervision tree shape, CLI surface, release URL pattern
- [CLAUDE.md (in-repo)](../../../CLAUDE.md) — load-bearing invariants driving stub shape

### Secondary (MEDIUM confidence)
- [Burrito target filename convention](https://www.jonathanychan.com/blog/statically-linking-an-elixir-command-line-application-using-burrito/) — `burrito_out/{release}_{target}` pattern (community article; planner should verify empirically)
- [Cosign GitHub Actions blob signing example](https://shibumi.dev/posts/keyless-signatures-with-github-actions/) — workflow YAML pattern; dated but core pattern unchanged in 3.x
- [Elixir 1.18 + OTP 28 combo](https://elixir-lang.org/blog/2024/12/19/elixir-v1-18-0-released/) — version pin rationale

### Tertiary (LOW confidence — verify at implementation time)
- Exact Burrito filename for `linux_aarch64` target (inferred from `linux` → `app_linux` pattern) — verify in first Plan C task
- Credo strict-mode "first-run friction" list — predicted based on typical phx.new output; planner should run `mix credo --strict` on the generated skeleton and adjust

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all library versions verified via hexdocs or GitHub releases within the last 6 months
- Architecture: HIGH — DESIGN.md §4.1 is authoritative and read directly; supervision shape follows CLAUDE.md invariants
- Burrito integration: MEDIUM-HIGH — target syntax + Phoenix gotchas verified; exact output filename pattern is MEDIUM (inferred from community examples)
- CI workflow: HIGH — each action version verified; cosign + setup-beam + runner labels all current
- Doctor CLI: HIGH — standard Mix.Task + OptionParser pattern; check commands are trivial Linux primitives
- Pitfalls: MEDIUM — some are "known traps" (pitfalls 1-3 verified in docs/community), some are predictive (pitfall 5 Credo friction list)

**Research date:** 2026-04-15
**Valid until:** 2026-05-15 for fast-moving surfaces (Elixir/OTP/Cosign versions); 2026-10-15 for architectural patterns (Burrito wrap, supervision shape, SQLite WAL) — stable

---

## Research Complete
