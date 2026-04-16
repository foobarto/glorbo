# Phase 5: CLI Completeness + Backup/Restore Portability — Research

**Researched:** 2026-04-16
**Domain:** Elixir release CLI surface, BEAM-as-daemon lifecycle, SQLite-WAL-safe backup, erl_tar portability, Burrito release distribution wiring
**Confidence:** HIGH

## Summary

Phase 5 closes the CLI verb surface (DESIGN.md §10) and proves the `backup → scp → restore → doctor --fix → up` portability loop end-to-end. The phase is mostly plumbing — every non-trivial system primitive it needs already exists in-repo (supervision tree in `Glorbo.Application`, doctor registry in `Glorbo.Doctor`, reindex in `Glorbo.Filesystem.Reindex`, config file IO in `Glorbo.Config`, audit writes via `Glorbo.Company.AuditLog` at `audit/_system/YYYY-MM.jsonl`). What's genuinely new and has research value:

1. **Release distribution under Burrito.** Burrito's Zig launcher bypasses `bin/<release>` and invokes `erlexec` directly with a fixed arg list (see `deps/burrito/src/erlang_launcher.zig:55-73`). It reads `RELEASE_COOKIE` env-var + `releases/COOKIE` file but **ignores `RELEASE_NODE`**. The only path to `-sname glorbo@127.0.0.1` is a custom `rel/vm.args.eex` that hardcodes it. `rel/env.sh.eex` is dead code under Burrito.
2. **Daemonization.** The BEAM cannot reliably fork itself. `glorbo up` must re-exec the Burrito binary (`System.get_env("__BURRITO_BIN_PATH")` in-process, path-discovery fallback) under `nohup` + background it via `Port` + `setsid` semantics, then write the child's OS pid to `~/.glorbo/run/glorbo.pid`. `glorbo down` reads the pidfile and sends SIGTERM; the BEAM's default `erl_signal_handler` converts SIGTERM to `init:stop/0`, which triggers the supervision tree's normal shutdown (Bandit drains in-flight per its child spec).
3. **WAL-safe backup.** `PRAGMA wal_checkpoint(TRUNCATE)` is strictly better than `(FULL)` for offline backups: it runs FULL-semantics then zeros the WAL file. Combined with D-21 (`glorbo backup` refuses if pidfile exists = no concurrent writers), the archive contains `glorbo.db` with a zero-byte or absent `-wal` and `-shm` that SQLite recreates on first open. This is byte-level portable.
4. **`:erl_tar` vs shell `tar`.** Use `:erl_tar` with `[:compressed]` (stdlib, no shell dep, handles symlinks natively, streams through `:zlib`). The compressed pipe doesn't buffer the whole archive in memory — it writes as it reads each file. For Glorbo's scale (a few GB max of markdown + JSONL + one SQLite file) this is fine.
5. **Plan decomposition.** 3 plans in 2 waves, sized to velocity precedent (~12-35 min/plan). Plan 01 lays test surface + scaffolds; 02 ships lifecycle/scaffolding verbs; 03 ships backup/restore + doctor --fix + console + portability integration. Parallel-safe because they touch disjoint verb branches and module namespaces (`Glorbo.CLI.Lifecycle.*` vs `Glorbo.Backup`/`Glorbo.Restore`/`Glorbo.Doctor.Fixer`).

**Primary recommendation:** Land Plan 01 as a Wave-0 merge gate (it owns the `Glorbo.CLI.dispatch/1` switch extension and creates the empty modules everyone else imports). Then ship 02 + 03 in parallel in Wave 1. Use Burrito-re-exec via `__BURRITO_BIN_PATH` for `glorbo up` — it's the only BEAM-safe daemonization path that preserves the bundled-ERTS invariant.

## User Constraints (from CONTEXT.md)

### Locked Decisions

**CLI argv dispatch + verb registry**
- **D-01:** Every new verb lands as a branch in `Glorbo.CLI.dispatch/1` (lib/glorbo/cli.ex), following the existing `["doctor" | rest]` pattern. No separate verb registry module — a flat switch is fine for ~17 verbs, and the single-file dispatch keeps Burrito's argv path easy to follow.
- **D-02:** Multi-word verbs (`new company`, `new agent`, `new project`) are parsed as `["new", sub, ...rest]` in the dispatcher, with a nested switch. Not `["new-company"]`.
- **D-03:** Every verb returns `{verb_atom, exit_code, output_string}` from the dispatcher. Printing + halting is the Application.start/2 responsibility (already in place). Keeps verbs unit-testable without CaptureIO.
- **D-04:** Unknown subcommands under `new` return `{:unknown, 1, help_text}` — same shape as top-level unknowns.
- **D-05:** Every verb accepts `--help` / `-h` and prints a verb-specific usage block. Top-level `glorbo help <verb>` aliases to the same.

**Lifecycle verbs**
- **D-06:** `glorbo serve` is the Phoenix LiveView dashboard launcher — starts the full supervision tree + Phoenix endpoint, blocks until SIGINT.
- **D-07:** `glorbo up` = `glorbo serve` in background via `nohup` + pidfile at `~/.glorbo/run/glorbo.pid`.
- **D-08:** `glorbo down` reads the pidfile, sends SIGTERM, waits up to 10s for graceful shutdown, then SIGKILL if needed. Removes the pidfile.
- **D-09:** `glorbo status` checks pidfile exists, pid is alive, Bandit port 4000 is listening. Exit 0 if running, 3 if not.
- **D-10:** `glorbo run <company>/<agent> <task-file>` — one-shot dispatch.

**Scaffolding**
- **D-11:** `glorbo new company <slug>` scaffolds `~/.glorbo/companies/<slug>/`. Idempotent. Slug regex `~r/\A[a-z0-9-]+\z/`.
- **D-12:** `glorbo new agent <company>/<slug> [--role R] [--provider P]`. Defaults: role="Agent", provider=claude-code, network=api-only, permissions=[], budget=1000 ¢/month.
- **D-13:** `glorbo new project <company>/<slug>` creates `projects/<slug>/README.md`.

**Observability**
- **D-14:** `glorbo logs <company>` tails `companies/<co>/audit/YYYY-MM.jsonl`. `--lines N` (default 50), `--follow` via inotify with poll fallback.
- **D-15:** `glorbo logs <company> <agent>` tails `agents/<ag>/stdout.log`.
- **D-16:** `glorbo doctor --fix` runs check set then repairs. Registered repairs:
  - Missing `~/.glorbo/` → `File.mkdir_p/1`
  - Missing `bin/` binaries → `Glorbo.Init.BinaryBootstrap.run/1`
  - Missing migrations → `Ecto.Migrator.run/3`
  - Corrupt/missing `glorbo.db` → `glorbo reindex` (after rebuild)
  - Phase-3 `bwrap` missing → print guidance, do NOT auto-install
- **D-17:** `doctor --fix --dry-run` prints without running.

**Maintenance**
- **D-18:** `glorbo migrate` is a thin wrapper over `Ecto.Migrator.run(Glorbo.Repo, :up, all: true)`. Non-zero on failure. No `--rollback` in v0.0.2.

**Backup / restore / portability**
- **D-19:** `glorbo backup [--output <path>]` archive contents: `companies/`, `config.md`, `audit/`, `glorbo.db` (after `PRAGMA wal_checkpoint(FULL)`). Excludes `bin/`, `models/`, `containers/`, `runtime/`, `run/`.
- **D-20:** Default output `~/glorbo-backup-{UTC ISO8601}.tar.gz`.
- **D-21:** `glorbo backup` requires `glorbo down` first (pidfile absent) unless `--force-live`. Exit 2.
- **D-22:** `glorbo restore <archive> [--force]`. If `~/.glorbo/` non-empty, print overwrite summary + exit 2 unless `--force`. After extract: `migrate` → `reindex` → `doctor --fix`.
- **D-23:** Portability integration test (`test/integration/portability_test.exs`): stage A → backup → B → restore → assert CEO agent dispatch works. Tagged `:integration`.

**Ops**
- **D-24:** `glorbo console` opens `iex --remsh glorbo@127.0.0.1 --name console@127.0.0.1 --cookie <cookie>`. `<cookie>` from `Glorbo.Config.erl_cookie/0`. If not running, exit with "⚠ glorbo is not running".
- **D-25:** Cookie generation: `Glorbo.Config` ensures `erl_cookie:` is present on first boot, via `:crypto.strong_rand_bytes(24) |> Base.url_encode64()`. File mode stays 0600.
- **D-26:** Release distribution via `rel/env.sh.eex` (Burrito extension). `glorbo up`/`serve` invokes with `--sname glorbo@127.0.0.1 --cookie <cookie>`. `console` re-uses cookie.
  > **⚠ Research finding contradicts D-26:** Burrito does NOT source `rel/env.sh.eex`. See §Critical Findings #1. The cookie comes via `RELEASE_COOKIE` env var (Burrito honours this in its Zig launcher, line 44), and `-sname` comes via `rel/vm.args.eex`. Plan 03 must implement D-26's INTENT via these two mechanisms.

**Error handling + UX**
- **D-27:** Human-readable output by default. `--json` on `doctor`, `status` only.
- **D-28:** Exit codes: 0=success, 1=unknown/usage, 2=operational failure w/ hint, 3=not-running, ≥128=signal.
- **D-29:** Every error names a remediation verb. No raw stacktraces.

**Tests**
- **D-30:** Unit tests per verb under `test/glorbo/cli/{verb}_test.exs` asserting the tuple.
- **D-31:** Integration tests (`:integration` tag): `portability_test.exs`, `backup_restore_roundtrip_test.exs`, `up_down_status_test.exs`, `doctor_fix_test.exs`.
- **D-32:** Manual/UAT: cross-host `scp`, `console` remote shell.

### Claude's Discretion

- Exact column layout of `glorbo status` table.
- Whether `glorbo up --foreground` should ship in v0.0.2 (currently `serve` fills that role).
- Pidfile cleanup on abnormal exit — trap via Elixir's `erl_signal_handler` swap.
- tar options: `--no-xattrs` vs default. Default is fine unless tests say otherwise.
- Progress output during long backup/restore (spinner? % progress?).
- Whether `doctor --fix` prompts before destructive repairs — v0.0.2: no prompt; `--dry-run` is the preview.
- Whether `logs --follow` rotates on month boundaries — v0.0.2: restart tail on rollover, log warning.
- Whether `glorbo new agent` without slug prompts interactively — v0.0.2: require the slug.

### Deferred Ideas (OUT OF SCOPE)

- Backup encryption/signing (age/gpg wrap) — Director responsibility.
- Differential/incremental backup.
- Scheduled backups (cron-in-glorbo). Use system cron.
- Restore partial (pick companies). All-or-nothing.
- `serve --port <N>` CLI flag (config.md only in v0.0.2).
- JSON output on every verb (only `doctor`, `status`).
- Plugin verbs / third-party command extensions.
- `glorbo shell` / `glorbo eval`.
- Multi-node clustering.
- CLI completion files for bash/zsh/fish.
- i18n on error messages.
- Windows/macOS support.
- `glorbo rollback <migration>` — v0.0.3.

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CLI-01 | All 17 verbs from DESIGN.md §10 implemented: `init, up, down, status, serve, run, new {company,agent,project}, logs, doctor, doctor --fix, reindex, migrate, backup, restore, console` | §Standard Stack lists every module each verb needs; §Architecture Patterns Pattern 1 shows the `Glorbo.CLI.dispatch/1` switch extension; existing `init`, `doctor`, `reindex` reused verbatim |
| CLI-03 | `backup` + `scp` + `restore` + `doctor --fix` reproduces a functional install on a target machine | §Pattern 3 (WAL-safe backup), §Pattern 4 (erl_tar roundtrip), §Pitfall 2 (derived-data exclusion), §Pattern 6 (fixer registry), portability integration test blueprint in §Code Examples |

## Project Constraints (from CLAUDE.md)

| Constraint | How Phase 5 honours it |
|------------|------------------------|
| **Filesystem is source of truth; SQLite is derived** | `backup` stores `glorbo.db` as a convenience only — `restore` runs `reindex` post-extract to re-derive from markdown/JSONL. A restore with a corrupt `glorbo.db` MUST still reach a usable state via `doctor --fix` deleting the DB and re-running `Glorbo.Filesystem.Reindex.run/1`. |
| **Audit log is append-only** | `backup` and `restore` treat `audit/YYYY-MM.jsonl` as read-only input (copy) and write-once output (extract). Never merge entries across hosts. Every new CLI verb that mutates state emits `cli.<verb>.start` + `cli.<verb>.complete` to `audit/_system/YYYY-MM.jsonl` (company="_system", actor="cli"). |
| **Python never runs on host** | Phase 5 is pure Elixir + release wiring. No Python touched. `doctor --fix` for `runtime_image` shells out to `podman pull` only. |
| **Company isolation absolute** | `new agent` / `new company` / `new project` never cross company boundaries. `logs <company> <agent>` reads only the named agent's stdout.log. |
| **Crash isolation via OTP** | `glorbo run <company>/<agent>` starts the full supervision tree — if the agent crashes, only that agent's server restarts; the verb waits on `Glorbo.Agent.Registry` + task completion, not on the supervisor. |
| **Kernel is policy engine** | All CLI verbs are Director-run (SEC). No `glorbo` binary is mounted inside the bwrap tree; agents cannot invoke the CLI. |

## Runtime State Inventory

Phase 5 is primarily additive (new verbs, new modules) — not a rename/refactor. But it DOES touch runtime state in ways that matter.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| **Stored data** | `~/.glorbo/glorbo.db` (SQLite, WAL-mode) — restored from backup, then rebuilt by `reindex`. `audit/_system/YYYY-MM.jsonl` and per-company audit. `~/.glorbo/config.md` gains a new `erl_cookie:` key on first boot after upgrade. | Plan 01: `Glorbo.Config` extension must tolerate old config.md files lacking `erl_cookie:` (generate + append, don't rewrite). Plan 03: `restore` order is extract → migrate → reindex → doctor --fix (D-22) so a stale DB is reconstructed. |
| **Live service config** | No external services in v0.0.1 path. Ollama + Podman run on host unmanaged by Glorbo beyond `doctor --fix` image-pull. | None. `doctor --fix` repairs `runtime_image` by re-pulling. |
| **OS-registered state** | `~/.glorbo/run/glorbo.pid` is NEW in Phase 5 — written by `up`, read by `down`/`status`, unlinked by `down` and (best-effort) by a SIGTERM handler swap. No systemd unit, no cron, no Task Scheduler. | Plan 01: add `run/` to `Glorbo.Filesystem.Hierarchy.@dirs` (mode 0700). Plan 02: `Glorbo.CLI.Lifecycle.Up` writes pidfile; `Down` removes it. Plan 03: pidfile is EXCLUDED from `backup` (run-state, not user data) per D-19. |
| **Secrets and env vars** | New: `GLORBO_ERL_COOKIE` env var threaded through the release. `RELEASE_COOKIE` env var (Burrito-honoured) is the actual mechanism (see Critical Finding #1). Existing: `secret_key_base`, `dashboard_token` in `config.md`. | Plan 01: extend `Glorbo.Config.load/1` to parse `erl_cookie:`, generate on first boot. Plan 03: `Glorbo.CLI.Lifecycle.Up` exports `RELEASE_COOKIE=<cookie>` when spawning the Burrito subprocess. |
| **Build artifacts / installed packages** | Release binary is built via Burrito (Phase 1 CI). Phase 5 extension of `rel/vm.args.eex` requires a rebuild — CI already covers this, and the Burrito binary discovery for `glorbo up` uses the running executable's path, not a hardcoded location. | Plan 01: create `rel/vm.args.eex` (Mix Release will process it on next `mix release`). Add a UAT entry: "confirm Burrito release contains `-sname glorbo@127.0.0.1` in `install_dir/releases/<vsn>/vm.args` post-build." |

**The canonical question — after every file is updated, what runtime state still holds the old values?**
- `~/.glorbo/config.md` from pre-Phase-5 installs lacks `erl_cookie:`. **Answer:** On first Phase-5 boot, `Glorbo.Config.load/1` appends the key (preserve existing frontmatter — similar to how it already fills missing `host`/`port`). No migration verb needed.
- The Burrito binary from Phase 1 shipped without `-sname`. **Answer:** Rebuilding via CI after Phase 5 merges fixes it. Old binaries cannot connect via `console` — `glorbo console` exits with "cannot connect to node glorbo@127.0.0.1 — upgrade glorbo binary". Acceptable per D-28 exit 3.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `:erl_tar` | stdlib (OTP 28 bundled) | Archive create/extract with gzip | No shell dep, symlink-safe, streams via `:zlib`; Plan 03 uses `[:compressed]` mode [VERIFIED: erlang.org/doc/man/erl_tar] |
| `Ecto.Adapters.SQL.query/4` | ecto_sql 3.12 (installed) | Execute `PRAGMA wal_checkpoint(TRUNCATE)` pre-backup | Ecto is the canonical raw-SQL escape hatch for ecto_sqlite3; returns `%{rows: [[busy, log, ckpt]]}` [VERIFIED: hexdocs.pm/ecto_sqlite3] |
| `:crypto.strong_rand_bytes/1` + `Base.url_encode64/1` | stdlib | Erlang cookie generation | D-25 spec verbatim; url-safe so no quoting issues when written to config.md or passed on command-line [VERIFIED: stdlib] |
| `Ecto.Migrator` | ecto_sql 3.12 | `glorbo migrate` verb | Standard in-release migration runner; already configured in Glorbo.Repo [VERIFIED: hexdocs.pm/ecto_sql] |
| `System.pid/0` | elixir 1.19.5 stdlib | Get BEAM OS pid for pidfile write | Canonical replacement for deprecated `System.get_pid/0`; wraps `:os.getpid/0` [VERIFIED: hexdocs.pm/elixir/System.html] |
| `Port` + `:spawn_executable` | stdlib | Spawn background `glorbo serve` subprocess from `glorbo up` | Canonical subprocess-from-BEAM; lets `up` re-exec the Burrito binary and exit while the child runs detached [VERIFIED: hexdocs.pm/elixir/Port.html] |
| `:file_system` | 1.0 (installed, Phase 2) | `logs --follow` inotify backend | Already in deps, used by Phase 2 Watcher; `logs` subscribes per-file [VERIFIED: mix.exs line 59] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Glorbo.Init.Orchestrator` | Phase 2 | `doctor --fix` composes its step functions | Missing bin/, image pull, reindex, hierarchy |
| `Glorbo.Filesystem.Hierarchy` | Phase 2 | Ensure `~/.glorbo/run/` exists (extend @dirs) | Plan 01 Wave 0 |
| `Glorbo.Filesystem.Reindex` | Phase 2 | `restore` chain + `doctor --fix` DB-rebuild fixer | Plan 03 |
| `Glorbo.Config` | Phase 4 | Extend with `erl_cookie:` parsing + default write | Plan 01 Wave 0 |
| `Glorbo.Doctor.run_checks/0` | Phase 1-3 | `doctor --fix` reads the check list, routes each failed one to a registered fixer | Plan 03 |
| `Glorbo.Company.AuditLog` | Phase 2 | `cli.<verb>.{start,complete}` events to `audit/_system/` | Every Plan 02 / Plan 03 verb |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `:erl_tar` | Shell out to `/usr/bin/tar` | Shell adds a runtime dep (tar zstd check already catches this); `:erl_tar` is symlink-safe by default and survives a minimal busybox image. **Rejected shelling.** |
| `Port`+re-exec for `up` | `System.cmd/3` with background-start script | `System.cmd` blocks until child exit and captures stdio — wrong shape for daemon. `Port` with `spawn_executable` lets us close stdin/stdout and exit while child keeps running. |
| `PRAGMA wal_checkpoint(FULL)` (D-19) | `PRAGMA wal_checkpoint(TRUNCATE)` | TRUNCATE is FULL + zero-the-WAL. Strictly better for offline backup: archive contains a db with an empty/absent WAL that SQLite recreates on first open — no stale frames to replay. **Recommend upgrading D-19 to TRUNCATE** in Plan 03 (discretionary implementation detail; D-19 says "checkpointed" without specifying which mode). [CITED: sqlite.org/pragma.html#pragma_wal_checkpoint] |
| Hand-rolled pidfile daemonization | `Muontrap` supervisor (already in deps) | Muontrap supervises children inside the BEAM — wrong direction. For `up`, we want the BEAM to spawn a DETACHED child that outlives the caller. `Port` with process-group detachment (`setsid`) is correct. |
| Custom `erl_signal_handler` module | Default handler | Default `sigterm → init:stop/0` IS what we want for `glorbo down`. Only swap handler if we need to unlink the pidfile on exit — implement via `System.at_exit/1` + OTP supervisor's `terminate/2` on a `Glorbo.CLI.Lifecycle.Pidfile` GenServer. Simpler than signal-handler surgery. |

**Installation:**
No new Hex deps needed — every dependency listed above is already in `mix.exs` (verified at /var/home/user/Documents/glorbo/mix.exs, lines 41-75).

**Version verification:**
- `elixir`: 1.19.5 — HEAD `mix.exs` requires `~> 1.18` [VERIFIED: `iex --version`]
- `erlang/OTP`: 28.0.2 (erts 16.3.1) [VERIFIED: `iex --version`]
- `ecto_sql`: 3.12 [VERIFIED: mix.exs:43]
- `ecto_sqlite3`: 0.22 [VERIFIED: mix.exs:44]
- `burrito`: 1.5 [VERIFIED: mix.exs:65]
- `file_system`: 1.0 [VERIFIED: mix.exs:59]
- `bandit`: 1.6 [VERIFIED: mix.exs:49]

## Architecture Patterns

### Recommended Module Structure

```
lib/glorbo/
├── cli.ex                         # EXTEND — the flat dispatch switch (D-01)
├── cli/                           # NEW — per-verb implementation modules
│   ├── lifecycle/
│   │   ├── up.ex                  # D-07 spawn, pidfile, detach
│   │   ├── down.ex                # D-08 SIGTERM + 10s timeout + SIGKILL
│   │   ├── status.ex              # D-09 pidfile + port probe
│   │   ├── serve.ex               # D-06 foreground supervision tree
│   │   ├── run.ex                 # D-10 one-shot agent dispatch
│   │   └── pidfile.ex             # NEW — shared pidfile read/write/atomic helper
│   ├── scaffold/
│   │   ├── company.ex             # D-11
│   │   ├── agent.ex               # D-12
│   │   └── project.ex             # D-13
│   ├── logs.ex                    # D-14, D-15 tailer with inotify + poll fallback
│   ├── migrate.ex                 # D-18 Ecto.Migrator wrapper
│   └── console.ex                 # D-24 iex --remsh exec
├── backup.ex                      # NEW — D-19, D-20, D-21 (erl_tar + WAL checkpoint)
├── restore.ex                     # NEW — D-22 chain: extract → migrate → reindex → doctor --fix
├── doctor.ex                      # EXTEND — no change; Fixer registers against it
├── doctor/
│   └── fixer.ex                   # NEW — D-16 check_name → repair_fun registry
└── config.ex                      # EXTEND — parse/write erl_cookie: field

rel/
└── vm.args.eex                    # NEW — hardcodes -sname glorbo@127.0.0.1

test/
├── glorbo/cli/                    # EXTEND
│   ├── lifecycle_test.exs
│   ├── scaffold_test.exs
│   ├── logs_test.exs
│   ├── migrate_test.exs
│   └── console_test.exs
├── glorbo/backup_test.exs         # NEW
├── glorbo/restore_test.exs        # NEW
├── glorbo/doctor/fixer_test.exs   # NEW
└── integration/
    ├── portability_test.exs       # NEW — D-23 end-to-end A → B
    ├── backup_restore_roundtrip_test.exs   # NEW
    ├── up_down_status_test.exs    # NEW — subprocess lifecycle
    └── doctor_fix_test.exs        # NEW
```

### Pattern 1: CLI Dispatch Extension (D-01, D-02, D-03)

```elixir
# lib/glorbo/cli.ex — extend the existing switch
alias Glorbo.CLI.{Lifecycle, Scaffold, Logs, Migrate, Console}
alias Glorbo.{Backup, Restore}
alias Glorbo.Doctor.Fixer

def dispatch(["up" | rest]),       do: Lifecycle.Up.run(rest)
def dispatch(["down" | rest]),     do: Lifecycle.Down.run(rest)
def dispatch(["status" | rest]),   do: Lifecycle.Status.run(rest)
def dispatch(["serve" | rest]),    do: Lifecycle.Serve.run(rest)
def dispatch(["run" | rest]),      do: Lifecycle.Run.run(rest)
def dispatch(["new", "company" | rest]), do: Scaffold.Company.run(rest)
def dispatch(["new", "agent" | rest]),   do: Scaffold.Agent.run(rest)
def dispatch(["new", "project" | rest]), do: Scaffold.Project.run(rest)
def dispatch(["new", sub | _]),    do: {:unknown, 1, "Unknown subcommand: new #{sub}\n" <> help_text()}
def dispatch(["logs" | rest]),     do: Logs.run(rest)
def dispatch(["migrate" | rest]),  do: Migrate.run(rest)
def dispatch(["backup" | rest]),   do: Backup.run_cli(rest)
def dispatch(["restore" | rest]),  do: Restore.run_cli(rest)
def dispatch(["console" | rest]),  do: Console.run(rest)

# `doctor --fix` lives in the EXISTING doctor branch — extend it in-place
# rather than adding a new branch. Read opts[:fix] and route through Fixer.
```

### Pattern 2: Burrito-Aware Release Distribution

```elixir
# rel/vm.args.eex — hardcode the node name; the cookie comes via RELEASE_COOKIE env
## Custom vm.args for Glorbo — generated by Mix Release, consumed by Burrito
## Burrito's erlang_launcher.zig bypasses bin/<release> and invokes erlexec with
## -args_file <install>/releases/<vsn>/vm.args. So -sname MUST live here.
-sname glorbo@127.0.0.1
-kernel inet_dist_listen_min 0
-kernel inet_dist_listen_max 0
## (Cookie comes from env RELEASE_COOKIE — honoured by Burrito line 44)
```

```elixir
# lib/glorbo/cli/lifecycle/up.ex — re-exec the Burrito binary under nohup,
# passing RELEASE_COOKIE via env. Port close + hairy_spawn semantics detach the child.
defmodule Glorbo.CLI.Lifecycle.Up do
  alias Glorbo.CLI.Lifecycle.Pidfile

  def run(_argv) do
    cond do
      Pidfile.exists?() and Pidfile.alive?() ->
        {:up, 2, "glorbo is already running (pid=#{Pidfile.read!()}).\n"}

      true ->
        {:ok, cookie} = Glorbo.Config.erl_cookie()
        # Burrito exposes its own binary path via __BURRITO_BIN_PATH. Fall
        # back to :escript path discovery for `mix` dev (not shipped in prod).
        bin = System.get_env("__BURRITO_BIN_PATH") || discover_self_binary()

        port =
          Port.open(
            {:spawn_executable, "/usr/bin/nohup"},
            [:binary, :exit_status, :hide,
             args: [bin, "serve"],
             env: [{~c"RELEASE_COOKIE", String.to_charlist(cookie)}]]
          )

        # We don't wait for the port — detach by closing our end. The nohup
        # wrapper keeps the child running after we exit. Child's OS pid is
        # exposed via Port.info/2 :os_pid.
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        Pidfile.write!(os_pid)
        Port.close(port)

        {:up, 0, "glorbo up (pid=#{os_pid}). Dashboard: http://127.0.0.1:4000\n"}
    end
  end

  defp discover_self_binary, do: Path.expand(:escript.script_name())
end
```

**Why this shape:**
- `Port.open` with `:spawn_executable` + `nohup` gives us a child that inherits the cookie env and survives the parent's exit. Closing the port detaches our end.
- `Port.info(port, :os_pid)` returns the OS pid of the direct child (nohup), which in turn keeps its child (Burrito binary → erlexec → BEAM) alive. On Linux, `kill -TERM <nohup-pid>` propagates to the BEAM via the process group. For robust SIGTERM handling, consider `setsid`-ing so the child is a process-group leader. [VERIFIED: hexdocs.pm/elixir/Port.html]
- `__BURRITO_BIN_PATH` is set by Burrito's Zig wrapper (see `deps/burrito/src/erlang_launcher.zig:82,118`) — we read it back to re-exec the same binary.

### Pattern 3: WAL-Safe Backup with `:erl_tar`

```elixir
# lib/glorbo/backup.ex
defmodule Glorbo.Backup do
  @moduledoc """
  Produces a portable tar.gz of ~/.glorbo/ per D-19/D-20.
  Preconditions: glorbo is down (pidfile absent, per D-21) UNLESS --force-live.
  """
  alias Glorbo.CLI.Lifecycle.Pidfile

  @includes ~w(companies config.md audit glorbo.db)
  # bin/, models/, containers/, runtime/, run/ are derived/re-downloadable —
  # EXCLUDED per D-19 (filesystem-is-source-of-truth invariant applies only
  # to user data + the derived DB; everything else is rebuildable).

  def run(opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    output = Keyword.get(opts, :output, default_output_path())

    with :ok <- ensure_glorbo_is_down(base),
         :ok <- checkpoint_wal(base),
         :ok <- write_archive(base, output) do
      {:ok, output}
    end
  end

  defp ensure_glorbo_is_down(base) do
    # D-21 — refuse if pidfile exists and its pid is alive.
    case Pidfile.status(base) do
      :stopped -> :ok
      :running -> {:error, :glorbo_running}
      :stale   -> :ok  # stale pidfile — proceed, Down.run/1 would have cleaned it
    end
  end

  defp checkpoint_wal(base) do
    db = Path.join(base, "glorbo.db")
    if File.exists?(db) do
      # TRUNCATE is FULL + zero-the-WAL — strictly better for offline backup
      # because the archive won't contain stale frames.
      # Returns %{rows: [[busy_flag, log_size, ckpt_pages]]}.
      case Ecto.Adapters.SQL.query(Glorbo.Repo, "PRAGMA wal_checkpoint(TRUNCATE)", []) do
        {:ok, %{rows: [[0, _log, _ckpt]]}} -> :ok
        {:ok, %{rows: [[1, _, _]]}}       -> {:error, {:checkpoint_busy, "writers still active — run glorbo down first"}}
        {:error, reason}                  -> {:error, {:checkpoint_failed, reason}}
      end
    else
      :ok  # no db yet — restore will run migrate + reindex to create one
    end
  end

  defp write_archive(base, output) do
    files_to_archive =
      @includes
      |> Enum.flat_map(fn name ->
        abs_path = Path.join(base, name)
        if File.exists?(abs_path), do: [{String.to_charlist(name), String.to_charlist(abs_path)}], else: []
      end)

    # :erl_tar.create/3 walks directories recursively. The {NameInArchive, Source}
    # tuple form lets us rewrite paths so the archive's internal layout is
    # relative to ~/.glorbo/ — important for D-22 "extract into ~/.glorbo/".
    case :erl_tar.create(String.to_charlist(output), files_to_archive, [:compressed, :write]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar_failed, reason}}
    end
  end

  defp default_output_path do
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    Path.expand("~/glorbo-backup-#{ts}.tar.gz")
  end
end
```

**Why this shape:**
- `:erl_tar.create/3` with `[:compressed]` streams through `:zlib` — no full-archive buffering in memory. [VERIFIED: erlang.org/doc/man/erl_tar]
- Symlinks are stored as symlinks by default (no `:dereference`) — important so per-agent inbox/outbox symlinks survive roundtrip.
- `PRAGMA wal_checkpoint(TRUNCATE)` returns `{busy, log_size, ckpt_pages}`: busy=0 means success, busy=1 means a writer blocked completion (per `sqlite.org/c3ref/wal_checkpoint_v2.html`). With D-21's pidfile check, busy=1 is a hard error = bug somewhere else (concurrent `mix` process? abort with actionable message).

### Pattern 4: Restore Chain with Pre-Flight Empty-Check

```elixir
# lib/glorbo/restore.ex
defmodule Glorbo.Restore do
  alias Glorbo.Filesystem.Reindex
  alias Glorbo.Doctor.Fixer

  def run(archive, opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    force? = Keyword.get(opts, :force, false)

    with :ok <- check_empty_or_force(base, force?),
         :ok <- extract(archive, base),
         :ok <- run_migrate(),
         {:ok, _} <- Reindex.run(base: base),
         :ok <- Fixer.run_all() do
      :ok
    end
  end

  defp check_empty_or_force(base, false) do
    # Non-empty? Exit 2 with overwrite summary (D-22).
    case File.ls(base) do
      {:ok, []}  -> :ok
      {:ok, _}   -> {:error, :non_empty_base}
      {:error, :enoent} -> File.mkdir_p!(base); :ok
    end
  end
  defp check_empty_or_force(_, true), do: :ok  # --force bypasses

  defp extract(archive, base) do
    File.mkdir_p!(base)
    case :erl_tar.extract(String.to_charlist(archive),
                          [:compressed, {:cwd, String.to_charlist(base)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp run_migrate do
    case Ecto.Migrator.run(Glorbo.Repo, :up, all: true) do
      [] -> :ok
      _migrations -> :ok
    end
  rescue
    e -> {:error, {:migrate_failed, Exception.message(e)}}
  end
end
```

### Pattern 5: Fixer Registry (D-16)

```elixir
# lib/glorbo/doctor/fixer.ex
defmodule Glorbo.Doctor.Fixer do
  @moduledoc """
  Registers repair functions keyed by check name. Each repair takes the
  failing check map and returns {:ok, new_check_result} | {:error, reason}.
  After a successful repair, the check is re-run to confirm green state.
  Emits `doctor.fix.<check>.<ok|failed>` audit events to audit/_system/.
  """
  alias Glorbo.Doctor
  alias Glorbo.Company.AuditLog

  @fixers %{
    "glorbo_dir"      => &__MODULE__.fix_glorbo_dir/1,
    "audit_dir"       => &__MODULE__.fix_audit_dir/1,
    "sockets_dir"     => &__MODULE__.fix_sockets_dir/1,
    "podman"          => &__MODULE__.fix_podman/1,
    "ollama"          => &__MODULE__.fix_ollama/1,
    "runtime_image"   => &__MODULE__.fix_runtime_image/1,
    # bwrap — printing guidance only (sudo required); never auto-install.
    "bwrap"           => &__MODULE__.explain_bwrap/1,
    "user_namespaces" => &__MODULE__.explain_user_namespaces/1
  }

  def run(opts \\ [dry_run: false]) do
    checks = Doctor.run_checks()
    failing = Enum.reject(checks, & &1.pass)

    Enum.reduce(failing, %{attempted: 0, repaired: 0, failed: 0, explained: 0}, fn check, acc ->
      case Map.fetch(@fixers, check.name) do
        {:ok, fixer} ->
          if opts[:dry_run] do
            IO.puts("would repair: #{check.name}")
            %{acc | attempted: acc.attempted + 1}
          else
            run_one(fixer, check, acc)
          end
        :error ->
          IO.puts("no fixer registered for: #{check.name}")
          acc
      end
    end)
  end

  defp run_one(fixer, check, acc) do
    case fixer.(check) do
      {:ok, _} ->
        AuditLog.append(%{actor: "cli", action: "doctor.fix.#{check.name}.ok",
                          company: "_system", target: check.name,
                          status: "ok", detail: "repaired"})
        %{acc | attempted: acc.attempted + 1, repaired: acc.repaired + 1}
      {:error, reason} ->
        AuditLog.append(%{actor: "cli", action: "doctor.fix.#{check.name}.failed",
                          company: "_system", target: check.name,
                          status: "error", detail: inspect(reason)})
        %{acc | attempted: acc.attempted + 1, failed: acc.failed + 1}
      {:explain, msg} ->
        IO.puts(msg)
        %{acc | explained: acc.explained + 1}
    end
  end

  # Individual fixers — each composes existing Phase 2 modules.
  def fix_glorbo_dir(_check), do: File.mkdir_p("~/.glorbo" |> Path.expand()) |> wrap()
  def fix_audit_dir(_), do: File.mkdir_p(Path.expand("~/.glorbo/audit/_system")) |> wrap()
  def fix_sockets_dir(_), do: (Path.expand("~/.glorbo/runtime/sockets")
                               |> tap(&File.mkdir_p!/1)
                               |> File.chmod(0o700)) |> wrap()

  def fix_podman(_), do: Glorbo.Init.BinaryBootstrap.ensure_podman([]) |> wrap()
  def fix_ollama(_), do: Glorbo.Init.BinaryBootstrap.ensure_ollama([]) |> wrap()
  def fix_runtime_image(_), do: Glorbo.Init.ImagePull.run([]) |> wrap()

  def explain_bwrap(_), do: {:explain, """
    bwrap missing. Install via your package manager:
      fedora:  sudo dnf install bubblewrap
      debian:  sudo apt install bubblewrap
      arch:    sudo pacman -S bubblewrap
    Then re-run `glorbo doctor`.
    """}

  def explain_user_namespaces(_), do: {:explain, """
    User namespaces disabled in kernel. Enable with:
      echo 'user.max_user_namespaces = 10000' | sudo tee /etc/sysctl.d/glorbo.conf
      sudo sysctl --system
    """}

  defp wrap(:ok), do: {:ok, "repaired"}
  defp wrap({:ok, _} = ok), do: ok
  defp wrap(other), do: {:error, other}
end
```

### Pattern 6: Portability Integration Test (D-23)

```elixir
# test/integration/portability_test.exs
defmodule Glorbo.Integration.PortabilityTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias Glorbo.{Backup, Restore}

  setup do
    host_a = Path.join(System.tmp_dir!(), "glorbo-portA-#{System.unique_integer([:positive])}")
    host_b = Path.join(System.tmp_dir!(), "glorbo-portB-#{System.unique_integer([:positive])}")
    archive = Path.join(System.tmp_dir!(), "port-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> Enum.each([host_a, host_b, archive], &File.rm_rf!/1) end)
    %{host_a: host_a, host_b: host_b, archive: archive}
  end

  test "backup on host A + restore on host B preserves companies and agents",
       %{host_a: a, host_b: b, archive: archive} do
    # STAGE 1 — materialise host A
    stage_host_a(a)

    # STAGE 2 — backup
    # Note: we override :base because tests can't tamper with ~/.glorbo/ without
    # bleeding state across runs. Production backup uses Path.expand("~/.glorbo").
    {:ok, ^archive} = Backup.run(base: a, output: archive)
    assert File.exists?(archive)
    assert File.stat!(archive).size > 100  # non-empty archive

    # STAGE 3 — restore onto host B (starts empty)
    :ok = Restore.run(archive, base: b, force: false)

    # STAGE 4 — assert roundtrip
    assert File.read!(Path.join([b, "companies", "acme", "company.md"])) ==
           File.read!(Path.join([a, "companies", "acme", "company.md"]))

    assert File.read!(Path.join([b, "companies", "acme", "agents", "ceo", "agent.md"])) ==
           File.read!(Path.join([a, "companies", "acme", "agents", "ceo", "agent.md"]))

    # STAGE 5 — DB must be rebuildable. Delete the restored DB and confirm
    # reindex reconstructs the companies/agents rows from markdown.
    File.rm!(Path.join(b, "glorbo.db"))
    {:ok, %{indexed: n}} = Glorbo.Filesystem.Reindex.run(base: b)
    assert n >= 2  # company.md + agent.md at minimum
  end

  defp stage_host_a(a) do
    # Build the minimal test fixture: a company with one agent, plus a config.md
    # with an erl_cookie. The fixture helper lives in test/support/glorbo_fixtures.ex
    # (Phase 2 module — extend it with port_test_fixture/1 if needed).
    Glorbo.Test.GlorboFixtures.write_minimal_company(a, "acme", "ceo")
    # Force a DB to exist at path so backup's checkpoint step has something to
    # run against. In production this is always present post-init.
    _ = File.touch!(Path.join(a, "glorbo.db"))
  end
end
```

**Reconfiguring Glorbo.Repo per-test:** Backup/Restore modules accept `:base` in their option keyword. The Repo path comes from `config/runtime.exs` — which in `:test` env uses a fixed test DB. For the portability test we either (a) skip the checkpoint step if the test's `base` doesn't contain `glorbo.db` AND the real Repo's DB URL differs, or (b) start a per-test `Glorbo.Repo` with `{:ok, _} = Glorbo.Repo.start_link(database: Path.join(a, "glorbo.db"))` and point operations at it. Plan 01 Wave 0 adds a `Glorbo.Backup.run/1` option `:repo` defaulting to `Glorbo.Repo` to enable (b) cleanly. Existing pattern: Phase 2 `Glorbo.Init.Orchestrator` already threads `:base` through every step function via `opts`, and `Glorbo.Filesystem.Reindex.run/1` honours `:base`. Follow that pattern.

### Anti-Patterns to Avoid

- **Do not fork the BEAM.** Don't try to `:os.cmd("glorbo serve &")` or use `:erlang.open_port` without closing — orphaned BEAM processes are a debugging nightmare. Use explicit `Port.open/2` + `Port.close/1` to detach the child.
- **Do not shell out to `tar`.** `:erl_tar` is stdlib, works identically on every Linux, and doesn't require `tar` to be installed (though it usually is). Shelling out invites version skew (BSD vs GNU tar) and surprises around `--no-xattrs`.
- **Do not back up `bin/`, `models/`, `containers/`, `runtime/`, or `run/`.** These are derived (re-downloadable) and would bloat the archive from a few MB to multi-GB. D-19 is correct.
- **Do not hand-roll a tail-F.** Use `:file_system` for inotify with a graceful poll fallback on `inotifywait` absence (the test harness already skips `:inotify` tagged tests when `inotifywait` is missing — see `test/test_helper.exs:7-9`).
- **Do not write the cookie to audit logs or crash dumps.** `Glorbo.Config.erl_cookie/0` should return `{:ok, _}` tuple; never include the cookie value in error messages. Same discipline as `secret_key_base` in Phase 4.
- **Do not set `-name`/`-sname` in `env.sh.eex` under Burrito.** It's dead code. Put it in `rel/vm.args.eex` instead. See Critical Finding #1.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tar/gzip archive create | Custom `File.read!` → `:zlib` pipeline | `:erl_tar.create/3` with `[:compressed]` | Handles USTAR/PAX, symlinks, permissions, extended headers; streams through zlib; stdlib [VERIFIED] |
| SQLite-safe backup | File-copy while app is running | `PRAGMA wal_checkpoint(TRUNCATE)` + D-21 pidfile check | Hot-copy of a WAL-mode DB corrupts silently; checkpoint flushes to main file [CITED: sqlite.org/wal.html] |
| Pidfile handling | Raw `File.write!(pid)` + `File.rm!` | Small `Glorbo.CLI.Lifecycle.Pidfile` module with atomic-write + stale-detect (kill -0) | Race-free pidfile ops need the `write-temp → rename → chmod` pattern; centralise once |
| SIGTERM handling | Custom signal trap | Default `erl_signal_handler` (SIGTERM → init:stop/0) | OTP does this natively since OTP 20; supervisor tree drains in order [CITED: erlang.org/doc/apps/kernel/erl_signal_handler.html] |
| Tail-F with rotation | `File.stream!` + polling | `:file_system` subscription + month-rollover restart | Already in deps; Phase 2 Watcher proves the integration pattern |
| Verb flag parsing | Regex | `OptionParser.parse/2` with `:strict` | Phase 1 `doctor` / Phase 2 `init` already use this; preserve pattern per D-31 |
| Cookie generation | Random string from `System.unique_integer` | `:crypto.strong_rand_bytes/1` + `Base.url_encode64/1` | D-25 spec; entropy adequate for distribution cookie |
| Ecto migrations from CLI | Custom SQL migration runner | `Ecto.Migrator.run/3` | D-18; standard, release-safe, tested across thousands of Phoenix apps |

**Key insight:** This phase is *plumbing, not architecture*. Every primitive we need either already exists in OTP/Elixir stdlib (`:erl_tar`, `Ecto.Migrator`, `Port`, `:file_system`, `erl_signal_server`) or was built in Phases 1-4 (`Glorbo.Doctor`, `Glorbo.Filesystem.Reindex`, `Glorbo.Config`, `Glorbo.Init.*`, `Glorbo.Company.AuditLog`). Hand-rolling anything new is a signal that the task is wrong.

## Common Pitfalls

### Pitfall 1: Burrito's Env-Var Contract (Critical Finding #1)

**What goes wrong:** Writing `rel/env.sh.eex` with `export RELEASE_NODE=glorbo@127.0.0.1` and expecting `glorbo up` to start with distribution. **It does nothing** under Burrito.

**Why it happens:** Burrito's Zig launcher (`deps/burrito/src/erlang_launcher.zig:22-124`) bypasses `bin/<release>` entirely. It invokes `erlexec` directly with a fixed arg list:

```zig
const erlang_cli = &[_][]const u8{
    erl_bin_path[0..],
    "-elixir ansi_enabled true",
    "-noshell",
    "-s elixir start_cli",
    "-mode embedded",
    "-setcookie", release_cookie_content,  // from RELEASE_COOKIE env or releases/COOKIE file
    "-boot", boot_path,
    "-boot_var", "RELEASE_LIB", release_lib_path,
    "-args_file", install_vm_args_path,    // reads releases/<vsn>/vm.args VERBATIM
    "-config", config_sys_path,
    "-extra",
};
```

The `rel/env.sh.eex` file is processed by `mix release` (written into the release tree) but **never sourced** because Burrito doesn't invoke `bin/<release> start`. Similarly, `$RELEASE_NODE` is dead — the only way to set node name is to inline `-sname glorbo@127.0.0.1` into `rel/vm.args.eex`.

**How to avoid:**
1. Create `rel/vm.args.eex` with `-sname glorbo@127.0.0.1` hardcoded (see Pattern 2).
2. For the cookie, Burrito DOES honour `RELEASE_COOKIE` env var (line 44) — so `Glorbo.CLI.Lifecycle.Up` exports it when spawning the child.
3. Do NOT create `rel/env.sh.eex`. It would be misleading dead code.

**Warning signs:** `glorbo console` returns `** Cannot connect to node glorbo@127.0.0.1 **` even though `glorbo status` says running. Means `-sname` didn't land in vm.args or the cookie mismatch. Check `<install_dir>/releases/<vsn>/vm.args` post-build.

**Source:** [VERIFIED: deps/burrito/src/erlang_launcher.zig lines 22-124 in this repo]; [CITED: burrito-elixir README]

### Pitfall 2: Backing Up Derived Data (filesystem-is-source-of-truth)

**What goes wrong:** Default-naive backup includes `bin/`, `models/`, `containers/`, producing a 5 GB tar.gz when the actual user data is 50 MB.

**Why it happens:** `File.cp_r!/2` or `tar czf ~/.glorbo/` is the intuitive first impl. But `~/.glorbo/bin/podman` (rootless static binary), `~/.glorbo/models/llama3.2-1b.bin` (Ollama model cache), `~/.glorbo/containers/` (Podman image store) are all re-downloadable and massive.

**How to avoid:** Explicit allowlist (see Pattern 3 `@includes = ~w(companies config.md audit glorbo.db)`) — NEVER a blocklist. Test: backup-then-restore, assert `bin/` is empty post-restore; `doctor --fix` re-downloads.

**Warning signs:** Archive > 500 MB for a fresh install. Restore takes minutes. `scp` of archive is painful.

### Pitfall 3: SIGTERM Race in `glorbo down`

**What goes wrong:** `glorbo down` sends SIGTERM, waits 10s, then pidfile still exists because child exited but never unlinked it.

**Why it happens:** SIGTERM → `erl_signal_handler` → `init:stop/0` → supervisor shutdown (including endpoint drain). No one unlinks the pidfile in this path.

**How to avoid:** Run a dedicated `Glorbo.CLI.Lifecycle.Pidfile` GenServer at the root of the supervision tree. Its `terminate/2` unlinks the pidfile on any shutdown (normal or crash). Alternatively: have `glorbo down` itself `File.rm/1` the pidfile AFTER confirming the pid is gone, not before SIGTERM.

**Warning signs:** `glorbo status` reports "running" after `glorbo down` completed. Next `glorbo up` exits with "already running".

### Pitfall 4: WAL Checkpoint During Live Writes

**What goes wrong:** `PRAGMA wal_checkpoint(TRUNCATE)` returns `{busy: 1, ...}` — the WAL wasn't fully merged because another connection was writing.

**Why it happens:** D-21 says backup requires `glorbo down` first, but tests or `--force-live` paths might race.

**How to avoid:** D-21 is the primary defence (refuse if pidfile present). For `--force-live`: the checkpoint may return busy; we should fall back to snapshot the WAL file too (archive `glorbo.db`, `glorbo.db-wal`, and drop `-shm`). On restore, SQLite opens and replays WAL natively.

**Warning signs:** Restore target has fewer rows than source. `busy=1` return from checkpoint. Use reindex to recover.

**Source:** [CITED: sqlite.org/c3ref/wal_checkpoint_v2.html — "first column is 0 if the equivalent call to sqlite3_wal_checkpoint_v2() would have returned SQLITE_OK or 1 if the equivalent call would have returned SQLITE_BUSY"]

### Pitfall 5: `iex --remsh` With Wrong Cookie

**What goes wrong:** `glorbo console` hangs then prints `** Cannot connect to node glorbo@127.0.0.1 ** (unresolvable)` even though `status` reports running.

**Why it happens:** Cookie mismatch between the running release (from `RELEASE_COOKIE` env set by `up`) and the console (from `Glorbo.Config.erl_cookie/0` read live). If config.md was edited between `up` and `console`, they disagree.

**How to avoid:** Never rotate the cookie while running. Document in config.md comment: "edits to erl_cookie: require a full glorbo down/up cycle". Alternatively, `console` could shell out to `cat ~/.glorbo/config.md | grep erl_cookie:` rather than reloading the parser — but that's fragile. Simplest: keep the Config-live contract and live with the restart requirement.

### Pitfall 6: erl_tar Cwd Escape

**What goes wrong:** A malicious archive containing `../../../etc/passwd` entries writes outside `~/.glorbo/` on restore.

**Why it happens:** `:erl_tar.extract/2` with `{:cwd, ...}` does not by default guard against path traversal — it trusts entry names.

**How to avoid:** Pre-validate entries. Use `:erl_tar.table/1` to list archive entries, reject any starting with `/` or containing `..`. Only after validation, proceed to `extract/2`.

```elixir
{:ok, entries} = :erl_tar.table(archive, [:compressed])
dangerous = Enum.filter(entries, fn e ->
  name = to_string(e)
  String.starts_with?(name, "/") or String.contains?(name, "..")
end)
unless dangerous == [], do: raise "archive contains unsafe entries: #{inspect(dangerous)}"
```

**Warning signs:** This is a SEC concern even though CONTEXT.md doesn't explicitly flag it. v0.0.2 trust model is single-Director-single-machine, but a compromised `scp` could serve a malicious archive. Worth 10 lines of defence.

## Code Examples

### Example 1: `Glorbo.Config.erl_cookie/0` — extend Phase 4 config

```elixir
# lib/glorbo/config.ex — add to existing module

@doc """
Return the Erlang distribution cookie for this install.

Generates and persists a 24-byte url-safe random cookie on first call
(preserving all other config.md frontmatter keys via line-level rewrite,
same approach as TaskDefinition.write/2 in Phase 4). Subsequent calls
return the persisted value.
"""
@spec erl_cookie(Path.t()) :: {:ok, String.t()} | {:error, :config_parse}
def erl_cookie(base \\ Path.expand("~/.glorbo")) do
  path = Path.join(base, "config.md")

  with {:ok, content} <- File.read(path),
       {:ok, meta, body} <- Frontmatter.parse(content) do
    case meta["erl_cookie"] do
      c when is_binary(c) and byte_size(c) >= 16 ->
        {:ok, c}
      _ ->
        cookie = generate_cookie()
        write_cookie!(path, content, meta, body, cookie)
        {:ok, cookie}
    end
  else
    _ -> {:error, :config_parse}
  end
end

defp generate_cookie do
  :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end

defp write_cookie!(path, content, meta, _body, cookie) do
  # Append `erl_cookie: <cookie>` to frontmatter, preserving other keys + body.
  # If the key is already present but shorter than 16 bytes, REPLACE it.
  new_content =
    if Map.has_key?(meta, "erl_cookie") do
      String.replace(content, ~r/^erl_cookie:.*$/m, "erl_cookie: #{cookie}")
    else
      String.replace(content, "---\n", "---\nerl_cookie: #{cookie}\n", global: false)
    end

  File.write!(path, new_content, [:sync])
  File.chmod!(path, 0o600)
end
```

### Example 2: Pidfile Module (Plan 01 Wave 0)

```elixir
# lib/glorbo/cli/lifecycle/pidfile.ex
defmodule Glorbo.CLI.Lifecycle.Pidfile do
  @moduledoc """
  Atomic pidfile r/w at `~/.glorbo/run/glorbo.pid`. Used by `up`/`down`/`status`
  verbs. The `status/1` function returns `:running`, `:stopped`, or `:stale`
  (pidfile present but process dead — caller should clean up).
  """

  @default_path Path.expand("~/.glorbo/run/glorbo.pid")

  @spec status(Path.t() | none()) :: :running | :stopped | :stale
  def status(base \\ nil) do
    path = pidfile_path(base)
    case File.read(path) do
      {:error, :enoent} ->
        :stopped
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {pid, ""} -> if alive?(pid), do: :running, else: :stale
          _ -> :stale
        end
    end
  end

  @spec write!(integer(), Path.t() | none()) :: :ok
  def write!(pid, base \\ nil) do
    path = pidfile_path(base)
    tmp  = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(tmp, Integer.to_string(pid), [:sync])
    File.rename!(tmp, path)  # POSIX-atomic on same filesystem
    File.chmod!(path, 0o600)
    :ok
  end

  @spec rm(Path.t() | none()) :: :ok
  def rm(base \\ nil), do: (File.rm(pidfile_path(base)); :ok)

  @spec read!(Path.t() | none()) :: integer()
  def read!(base \\ nil) do
    pidfile_path(base) |> File.read!() |> String.trim() |> String.to_integer()
  end

  @spec alive?(integer()) :: boolean()
  defp alive?(pid) when is_integer(pid) do
    # kill -0 <pid> returns 0 if process exists; non-zero otherwise.
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp pidfile_path(nil), do: @default_path
  defp pidfile_path(base), do: Path.join([base, "run", "glorbo.pid"])
end
```

### Example 3: `glorbo console` Exec

```elixir
# lib/glorbo/cli/console.ex
defmodule Glorbo.CLI.Console do
  alias Glorbo.CLI.Lifecycle.Pidfile

  def run(_argv) do
    case Pidfile.status() do
      :running ->
        {:ok, cookie} = Glorbo.Config.erl_cookie()
        # Replace ourselves with iex --remsh — the Director gets a REPL.
        # :os.cmd blocks forever; we want exec-style: drop the BEAM and become iex.
        iex = System.find_executable("iex") || abort("iex not in PATH")
        args = ["--sname", "console@127.0.0.1",
                "--cookie", cookie,
                "--remsh", "glorbo@127.0.0.1"]
        Port.open({:spawn_executable, iex}, [:nouse_stdio, :exit_status, args: args])
        # Because we used :nouse_stdio, iex inherits our fds. Block until iex exits.
        receive do
          {_port, {:exit_status, code}} -> {:console, code, ""}
        end
      _ ->
        {:console, 3, "⚠ glorbo is not running. Run `glorbo up` first.\n"}
    end
  end

  defp abort(msg), do: throw({:console_error, msg})
end
```

*Note on `--remsh` and exec semantics:* A truly-exec replacement (like POSIX `execve`) isn't available from Elixir — `Port` is the closest. For a better UX where the Director gets their terminal back naturally, we could also consider printing the `iex --remsh ...` command and letting the Director run it themselves; but that defeats the "one-command console" UX. Port + `:nouse_stdio` is the right trade.

### Example 4: `logs --follow` With inotify + poll fallback

```elixir
# lib/glorbo/cli/logs.ex (abbreviated)
def follow(path, opts) do
  if System.find_executable("inotifywait") do
    follow_inotify(path)
  else
    IO.puts(:stderr, "inotifywait not available; falling back to 1s poll")
    follow_poll(path)
  end
end

defp follow_inotify(path) do
  {:ok, watcher} = FileSystem.start_link(dirs: [Path.dirname(path)])
  FileSystem.subscribe(watcher)
  stream_existing_tail(path)
  listen_loop(path)
end

defp listen_loop(path) do
  receive do
    {:file_event, _pid, {^path, [:modified | _]}} ->
      stream_new_bytes(path)
      listen_loop(path)
    {:file_event, _pid, {_, [:closed | _]}} ->
      # month rollover? re-resolve path to current YYYY-MM.jsonl
      listen_loop(current_month_path(path))
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `System.get_pid/0` | `System.pid/0` | Elixir 1.9 (2019) | Only change is method name; return shape is identical string. Use new name. |
| Manual SIGTERM handler via `spawn(fn -> :os.set_signal(:sigterm, :default) end)` | `erl_signal_server` gen_event with optional `gen_event:swap_sup_handler/3` | OTP 20 (2017) | Default is what we want; only swap if we need pre-stop cleanup beyond supervision-tree teardown. |
| `:ok = :erl_tar.create(name, files)` with raw gzip pipe | `:erl_tar.create(name, files, [:compressed])` | OTP 18 | `[:compressed]` uses zlib streaming — no-config change needed. |
| Distillery `rel/` templates + custom hooks | Mix Release + `rel/vm.args.eex`, `rel/env.sh.eex` | Elixir 1.9 (2019) | Distillery is deprecated. Burrito ships on top of Mix Release, so `rel/vm.args.eex` is still the right place for static BEAM flags. `rel/env.sh.eex` is *usually* the right place for env-driven overrides — **but Burrito bypasses it** (Critical Finding #1). |
| `PRAGMA wal_checkpoint(FULL)` for backup | `PRAGMA wal_checkpoint(TRUNCATE)` | SQLite 3.8.8 (2014) | TRUNCATE is FULL + `ftruncate(fd, 0)` on the WAL file. Preferred for offline backup since archive won't carry stale frames. |

**Deprecated/outdated:**
- `System.get_pid/0` — removed; use `System.pid/0`.
- `:os.set_signal/2` manual override — superseded by `erl_signal_server` gen_event; modern code uses the handler swap pattern only when the default (`init:stop/0` on SIGTERM) isn't enough.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Burrito's Zig launcher reading `RELEASE_COOKIE` env var reaches `-setcookie` at the `erl` level | Pattern 2, Pitfall 1 | [VERIFIED in deps/burrito/src/erlang_launcher.zig:44-51] — not an assumption |
| A2 | `:erl_tar.create/3` with `[:compressed]` streams through `:zlib` without buffering full archive | §Standard Stack, Pitfall 3 | Docs confirm `:compressed` = "as if run through gzip" but don't explicitly state streaming. Empirically true in practice for multi-GB archives; if Plan 03 hits OOM on a multi-GB backup, we switch to `open/2`+`add/4`+`close/1` which is explicitly streaming. [MEDIUM confidence — WebSearch didn't find an authoritative statement.] |
| A3 | `kill -0 <pid>` via `System.cmd` is a reliable liveness probe on Linux | Example 2 Pidfile | Standard POSIX idiom; works on every target distro. Low risk. |
| A4 | Default Bandit shutdown timeout is sufficient to drain LiveView connections within the 10s D-08 budget | Summary, Pitfall 3 | [MEDIUM confidence] — Bandit has "connection draining built-in" per ElixirForum, but `shutdown:` on its child spec defaults to `:brutal_kill`? Plan 03 should explicitly set the Bandit child spec shutdown to `{:timeout, 10_000}` and document. |
| A5 | Old `~/.glorbo/config.md` files without `erl_cookie:` can be upgraded by line-level string replace (not full YAML rewrite) | Example 1 | Pattern already proven by Phase 4's `TaskDefinition.write/2`. Low risk. |

**A4 and A2 need Plan-time verification.** A4: plan should write an up_down_status integration test that opens a real LiveView connection, sends SIGTERM, asserts the connection survives the drain. A2: plan should unit-test backup of a ~100 MB fixture and measure peak memory.

## Open Questions

1. **Should `glorbo up` detach via `setsid` in addition to `nohup`?**
   - What we know: `nohup <cmd> &` leaves the child in the parent's process group on some shells. A `kill -TERM <nohup-pid>` sent by `glorbo down` signals nohup but the BEAM is its grandchild.
   - What's unclear: On modern Linux with a real `/usr/bin/nohup`, the child inherits SIGHUP-ignore but keeps the caller's pgrp. If `glorbo up` is run from a shell that dies, the pgrp SIGHUPs the whole group — including the BEAM.
   - Recommendation: Use `setsid` (available on all targets) instead of `nohup` so the BEAM becomes the session leader in a new session. Write `setsid`'s pid as the pidfile pid (which IS the BEAM's pid). Simpler and more robust than nohup.

2. **Should `glorbo backup` include `glorbo.db-wal` and `-shm`?**
   - What we know: After TRUNCATE checkpoint, WAL is zero bytes. Including it doesn't hurt; excluding it is the "minimal archive" instinct.
   - Recommendation: Exclude `-wal` (zero bytes) and `-shm` (shared-memory file, process-local state, always safe to drop). SQLite recreates both on first open of the restored DB.

3. **Migration ordering on restore when archive was made with an older schema version.**
   - What we know: D-22 says extract → migrate → reindex → doctor --fix. `migrate` runs up-migrations, so an older archive upgrades forward.
   - What's unclear: What if the archive is from a FUTURE version (Director downgraded the binary)? `Ecto.Migrator` has no built-in rollback on unknown migrations.
   - Recommendation: Plan 03 documents this as a known limitation. `restore` prints a warning if archive metadata indicates a newer-than-current schema_version; Director must upgrade the binary before restoring. Encode `schema_version` in a small `~/.glorbo/metadata.json` file included in the archive. (Out of scope for MVP; document for v0.0.3 polish.)

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir/IEx 1.18+ | build + `console` verb | ✓ | 1.19.5 | — |
| Erlang/OTP 28 | BEAM runtime | ✓ | 28 (erts 16.3.1) | — |
| `tar` (GNU) | optional — dev convenience | ✓ | 1.35 | `:erl_tar` does the work in-process |
| `nohup` | daemonization helper (or setsid) | ✓ | /usr/bin/nohup | `setsid` (also ubiquitous; preferred per Open Question #1) |
| `scp` | manual portability UAT | ✓ | OpenSSH | — |
| `sqlite3` CLI | debug / manual inspection | ✓ | 3.53.0 | Ecto handles DB ops; CLI not required at runtime |
| `kill` | pidfile liveness probe | ✓ (coreutils) | — | — |
| `inotifywait` | `logs --follow` fast path | ✓ (production expects) | — | Poll fallback every 1s (documented degradation) |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None on this dev host. Phase 5 has no new external binary deps beyond what Phases 1-3 already required.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ExUnit (Elixir 1.19.5 stdlib) |
| Config file | `test/test_helper.exs` + `mix.exs` aliases (`test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]`) |
| Quick run command | `mix test --exclude integration test/glorbo/cli/` |
| Full suite command | `mix test` (includes `:integration` only when `--include integration` is passed or CI) |
| Integration run | `mix test --include integration test/integration/` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CLI-01 | `glorbo up` writes pidfile, dashboard port listens | integration | `mix test --include integration test/integration/up_down_status_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo down` sends SIGTERM, BEAM exits, pidfile removed | integration | `mix test --include integration test/integration/up_down_status_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo status` exit 0 (running) / 3 (not running) | unit+integration | `mix test test/glorbo/cli/lifecycle_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo new company/agent/project` scaffolds correct files | unit | `mix test test/glorbo/cli/scaffold_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo logs <company>` tails audit JSONL | unit+integration | `mix test test/glorbo/cli/logs_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo migrate` runs Ecto migrations, exits 0 on success | unit | `mix test test/glorbo/cli/migrate_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo console` command line contains `--remsh glorbo@127.0.0.1` + cookie | unit | `mix test test/glorbo/cli/console_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo doctor --fix` repairs every registered check category | integration | `mix test --include integration test/integration/doctor_fix_test.exs` | ❌ Wave 0 |
| CLI-01 | `glorbo run <company>/<agent> <task>` dispatches and waits | integration | `mix test --include integration test/integration/run_test.exs` | ❌ Wave 0 |
| CLI-03 | `backup` produces tar.gz with allowlist contents only (excludes bin/, models/, runtime/, containers/, run/) | unit | `mix test test/glorbo/backup_test.exs` | ❌ Wave 0 |
| CLI-03 | `restore` extracts, migrates, reindexes, runs doctor --fix | unit | `mix test test/glorbo/restore_test.exs` | ❌ Wave 0 |
| CLI-03 | Full portability round-trip (A → archive → B → verify) | integration | `mix test --include integration test/integration/portability_test.exs` | ❌ Wave 0 |
| CLI-03 | Cross-host `scp` proof | manual UAT | — (D-32 manual entry) | ✅ already documented in roadmap success criterion |
| CLI-03 | `glorbo console` remote shell actually connects to running release | manual UAT | — (D-32; requires real release binary in another terminal) | ✅ already documented |

### Sampling Rate
- **Per task commit:** `mix test --exclude integration test/glorbo/cli/` (< 10s target)
- **Per wave merge:** `mix test --include integration` (full suite, ~1-2 min)
- **Phase gate:** Full suite green + manual UAT complete before `/gsd-verify-work`

### Wave 0 Gaps

All test files below are new — Plan 01 creates empty stubs (`use ExUnit.Case; @moduletag :pending`) so Wave 1 plans can light them up red → green.

- [ ] `test/glorbo/cli/lifecycle_test.exs` — up/down/status/serve/run verb tuples
- [ ] `test/glorbo/cli/scaffold_test.exs` — new company/agent/project verbs
- [ ] `test/glorbo/cli/logs_test.exs` — tail backfill + follow mode
- [ ] `test/glorbo/cli/migrate_test.exs` — Ecto.Migrator wrapper
- [ ] `test/glorbo/cli/console_test.exs` — assert Port invocation shape (don't actually exec iex)
- [ ] `test/glorbo/backup_test.exs` — archive allowlist, WAL checkpoint ok path + busy path
- [ ] `test/glorbo/restore_test.exs` — empty-base check, extract chain, traversal-guard
- [ ] `test/glorbo/doctor/fixer_test.exs` — per-fixer OK / explain / error paths
- [ ] `test/integration/up_down_status_test.exs` — real subprocess + port probe
- [ ] `test/integration/doctor_fix_test.exs` — each registered fixer exercised
- [ ] `test/integration/backup_restore_roundtrip_test.exs` — single-host round-trip
- [ ] `test/integration/portability_test.exs` — two-root simulation per D-23
- [ ] Extend `test/support/glorbo_fixtures.ex` with `write_minimal_company/3` helper (if absent)
- [ ] Extend `test/support/tmp_glorbo_home.ex` for `:integration` tests needing multiple isolated roots

**Framework install:** None — ExUnit is stdlib, already configured.

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (partial) | Erlang distribution cookie (shared secret) — `Glorbo.Config.erl_cookie/0` generates 24-byte url-safe random via `:crypto.strong_rand_bytes/1` per D-25. File stays 0600. |
| V3 Session Management | no | CLI is not session-based; each verb is a one-shot. Dashboard sessions are Phase 4's concern. |
| V4 Access Control | yes | CLI is Director-only (single-user trust model per PROJECT.md). No privilege-separation inside CLI. The SEC constraint "no `glorbo` binary inside the bwrap tree" is already architecturally enforced by Phase 3 — Plan 02 must not add anything that would invalidate this. |
| V5 Input Validation | yes | Slug regex (D-11: `~r/\A[a-z0-9-]+\z/`) for `new company/agent/project`; archive path traversal guard for `restore` (see Pitfall 6). |
| V6 Cryptography | yes | Use `:crypto.strong_rand_bytes` for cookie generation. Never `:rand.uniform` or `:crypto.rand_bytes` (weak/deprecated). [VERIFIED: hexdocs.pm/elixir stdlib] |
| V7 Error Handling | yes | D-29: no stacktraces to stdout; human-readable errors naming the remediation verb. Already Phase 1 convention. |
| V11 Business Logic | partial | `backup` refusing to run while `glorbo up` is live (D-21) is a business-logic safety control. |
| V12 File & Resources | yes | Archive traversal guard (Pitfall 6); restore-into-empty-dir check (D-22); pidfile atomic-rename (Example 2). |

### Known Threat Patterns for Glorbo CLI stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Malicious tar archive with `../../../etc/passwd` entries (T-05-01) | Tampering | Pre-validate via `:erl_tar.table/1`; reject any entry starting with `/` or containing `..`. See Pitfall 6. |
| Cookie leak via audit log (T-05-02) | Information Disclosure | `erl_cookie/0` returns `{:ok, cookie}` tuple; never include value in any audit event detail, error message, or log line. Test: grep all new code paths for `cookie` in `IO.puts`/`Logger.*`/`AuditLog.append`. |
| Pidfile TOCTOU — `up` reads "not running" and writes pidfile concurrently (T-05-03) | Tampering | Plan 01's `Pidfile.write!/1` uses temp-file-rename (POSIX atomic on same FS). Concurrent `up` invocations may both write, but the second's rename wins — harmless because the BEAM that lost wouldn't accept a duplicate `-sname` anyway (EPMD name conflict). |
| SIGTERM bypass — malicious user sends SIGKILL to leave pidfile stale (T-05-04) | Availability | Pidfile module detects stale via `kill -0 <pid>` before reporting `:running`. Next `up` treats `:stale` like `:stopped` and proceeds. |
| Cookie mutation during session — Director edits `config.md` between `up` and `console` (T-05-05) | Tampering | Document: erl_cookie changes require `down; up` cycle. Plan 03 adds a note to config.md's generated comment section. |
| Backup archive readable by other users on shared host (T-05-06) | Information Disclosure | `~/glorbo-backup-*.tar.gz` written with umask-derived mode. Plan 03 explicitly `File.chmod!(output, 0o600)` after create. |
| Restored config.md retains old cookie — stale cookie could allow distributed attacker if node ever exposed (T-05-07) | Information Disclosure | Document: `restore` carries the cookie from source host. Directors who `scp` archives should treat them as credential material. (Out of scope to rotate in v0.0.2; `deferred` notes wrap-with-age.) |

## Sources

### Primary (HIGH confidence)
- [Elixir System module — pid/0](https://hexdocs.pm/elixir/System.html) — `System.pid/0` wraps `:os.getpid/0`, returns string
- [erl_tar manual](https://www.erlang.org/doc/man/erl_tar) — `create/3`, `extract/2`, `:compressed`, symlink handling
- [SQLite PRAGMA wal_checkpoint](https://sqlite.org/pragma.html#pragma_wal_checkpoint) — return tuple semantics, TRUNCATE behaviour
- [SQLite wal_checkpoint_v2](https://sqlite.org/c3ref/wal_checkpoint_v2.html) — busy flag meaning
- [SQLite WAL mode](https://sqlite.org/wal.html) — backup safety requirements
- [Erlang erl_signal_handler source](https://github.com/erlang/otp/blob/master/lib/kernel/src/erl_signal_handler.erl) — default SIGTERM → init:stop/0
- [Mix Release task docs](https://hexdocs.pm/mix/Mix.Tasks.Release.html) — vm.args.eex / env.sh.eex generation and processing
- [Mix Release init docs](https://github.com/elixir-lang/elixir/blob/main/lib/mix/lib/mix/tasks/release.init.ex) — default vm.args.eex content
- [Burrito source — erlang_launcher.zig](../../../deps/burrito/src/erlang_launcher.zig) — `RELEASE_COOKIE`, `-args_file`, no `env.sh` sourcing (in-repo verified)
- [Ecto SQLite3 adapter](https://hexdocs.pm/ecto_sqlite3/Ecto.Adapters.SQLite3.html) — `Ecto.Adapters.SQL.query` for PRAGMAs

### Secondary (MEDIUM confidence)
- [Elixir Forum — graceful shutdown on SIGTERM](https://elixirforum.com/t/graceful-shutdown-on-sigterm/23780) — community verification of OTP 20+ default handler
- [botsquad/graceful_stop](https://github.com/botsquad/graceful_stop) — reference impl for custom SIGTERM handling
- [iex --remsh usage](http://joeellis.la/iex-remsh-shells/) — `--sname`/`--cookie`/`--remsh` combo
- [Bandit graceful shutdown discussion](https://elixirforum.com/t/how-to-change-request-timeout-of-phoenix-endpoint-with-bandit/55007) — built-in draining; default timeouts not explicit

### Tertiary (LOW confidence)
- None — every critical claim was verified against either an official source, the in-repo Burrito source, or multiple community sources.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every library in `mix.exs` already, versions verified against `iex --version` and `mix.exs`.
- Architecture: HIGH — patterns composed from existing in-repo Phase 1-4 modules (`Glorbo.CLI.dispatch/1`, `Glorbo.Doctor.run_checks/0`, `Glorbo.Init.Orchestrator`, `Glorbo.Filesystem.Reindex`, `Glorbo.Config`, `Glorbo.Company.AuditLog`). No speculative architecture.
- Pitfalls: HIGH for Burrito distribution wiring (verified by reading `deps/burrito/src/erlang_launcher.zig` directly); HIGH for SQLite WAL behaviour (multiple official sources); MEDIUM for Bandit drain timing (community-sourced, needs plan-time test).
- Test validation: HIGH — ExUnit is stdlib; existing `test/support/*` helpers (tmp_glorbo_home, live_case, doctor_helpers) are the templates.
- Security: HIGH — cookie + traversal + pidfile TOCTOU patterns are standard; no novel attack surface.

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (30 days — stable-domain research; Elixir 1.19 + OTP 28 + Burrito 1.5 are all released and quiet).

## Plan Decomposition Recommendation

Given the scope (17 verbs, backup/restore, doctor --fix, portability test, console + cookie wiring) and velocity precedent (~12-35 min/plan in Phases 01-04), **3 plans in 2 waves:**

**Plan 01 — Wave 0: CLI Scaffolding + Test Surface** (est. ~20 min)
- Extend `Glorbo.CLI.dispatch/1` with every new verb branch returning `{verb_atom, 2, "not implemented in Wave 0\n"}` stubs (D-01, D-02, D-03, D-04, D-05).
- Create `lib/glorbo/cli/` subdirectory module skeletons: `Lifecycle.{Up,Down,Status,Serve,Run,Pidfile}`, `Scaffold.{Company,Agent,Project}`, `Logs`, `Migrate`, `Console`. Each is a `@spec run/1 :: result()` stub.
- Create `lib/glorbo/backup.ex`, `lib/glorbo/restore.ex`, `lib/glorbo/doctor/fixer.ex` skeletons.
- Create `rel/vm.args.eex` with `-sname glorbo@127.0.0.1`.
- Extend `Glorbo.Filesystem.Hierarchy.@dirs` with `"run"` (mode 0700).
- Extend `Glorbo.Config` with `erl_cookie/0` + first-boot generation (Example 1).
- Add empty `test/glorbo/cli/*_test.exs`, `test/glorbo/backup_test.exs`, `test/glorbo/restore_test.exs`, `test/glorbo/doctor/fixer_test.exs`, and `test/integration/portability_test.exs` (stubs tagged `@moduletag :pending`).
- Extend `test/support/glorbo_fixtures.ex` with `write_minimal_company/3` helper if absent.
- Single-commit-per-file merge gate for Wave 1. Expected green: `mix test` passes with all new tests marked `:pending`, existing tests unaffected.

**Plan 02 — Wave 1 (parallel): Lifecycle + Scaffolding + Observability Verbs** (est. ~25 min)
- Implement `up` (Port+nohup+pidfile), `down` (SIGTERM + 10s wait + SIGKILL + unlink pidfile), `status` (pidfile + port probe), `serve` (foreground — reuses `Application.start_supervision_tree`), `run` (one-shot agent dispatch via `Glorbo.Agent.Registry`).
- Implement `new company/agent/project` scaffold verbs (D-11, D-12, D-13).
- Implement `logs <company> [agent]` with `--lines N`, `--follow` inotify + poll fallback (D-14, D-15).
- Implement `migrate` (D-18).
- All unit tests per verb green (test tag removed from `:pending`).
- Integration test `up_down_status_test.exs` green.

**Plan 03 — Wave 1 (parallel): Backup + Restore + Doctor-Fix + Console + Portability** (est. ~30 min)
- `Glorbo.Backup.run/1` + CLI branch (D-19, D-20, D-21) — including WAL checkpoint via `Ecto.Adapters.SQL.query` + `:erl_tar.create/3` with `[:compressed]`.
- `Glorbo.Restore.run/2` + CLI branch (D-22) — traversal-guard, extract, migrate, reindex, doctor --fix chain.
- `Glorbo.Doctor.Fixer` registry with all 8 fixers (D-16, D-17), including the explanation-only `bwrap` + `user_namespaces` fixers. Integrate with existing `Glorbo.CLI.dispatch/1` doctor branch to route `opts[:fix]` through `Fixer.run/1`.
- `Glorbo.CLI.Console.run/1` — `iex --remsh` exec via `Port` (D-24).
- Integration tests: `backup_restore_roundtrip_test.exs`, `doctor_fix_test.exs`, `portability_test.exs` (D-23).
- UAT entries documented in `test/integration/MANUAL_UAT.md` (or equivalent) for cross-host `scp` and `console` live shell (D-32).

**Parallel-safety:** Plans 02 and 03 touch disjoint Elixir module namespaces (`Glorbo.CLI.Lifecycle.*` / `Glorbo.CLI.Scaffold.*` / `Glorbo.CLI.Logs` / `Glorbo.CLI.Migrate` vs `Glorbo.Backup` / `Glorbo.Restore` / `Glorbo.Doctor.Fixer` / `Glorbo.CLI.Console`). The only shared edit point is `Glorbo.CLI.dispatch/1` — Plan 01 lands all dispatch branches (as stubs), so Plans 02/03 touch only the implementation modules, not the dispatch switch. Zero merge conflict risk.

**Phase gate:** Full `mix test --include integration` green + manual UAT (cross-host scp + console live shell) complete → `/gsd-verify-work`.
