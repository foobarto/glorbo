# Phase 5: CLI Completeness + Backup/Restore Portability — Context

**Gathered:** 2026-04-16
**Status:** Ready for planning
**Mode:** Auto-generated (--auto; recommended defaults)

<domain>
## Phase Boundary

Deliver the full CLI surface from DESIGN.md §10 and prove the portability story end-to-end: on machine A run `glorbo backup`, `scp` the archive to machine B, run `glorbo restore` + `glorbo doctor --fix`, then `glorbo up` — and the previously-running agent in the previously-existing company executes a task successfully on the fresh host. Every CLI verb dispatches through `Glorbo.CLI.dispatch/1` (the argv-from-Burrito path already shipped in Phase 1); the Director never touches `mix` outside of local development.

**In scope:**
- Implement every verb listed in DESIGN.md §10 and ROADMAP.md Phase 5 success criterion 1:
  - Lifecycle: `init` (Phase 2 reuse), `up`, `down`, `status`, `serve`
  - Ephemeral run: `run` (one-shot agent dispatch for cron/CI)
  - Scaffolding: `new company`, `new agent`, `new project`
  - Observability: `logs <company> [agent]`, `doctor`, `doctor --fix` (actual repairs — Phase 2 stubbed this)
  - Maintenance: `reindex` (Phase 2 reuse), `migrate`
  - Portability: `backup`, `restore`
  - Ops: `console` (Elixir remote shell into running release)
- Atomic `backup` produces `~/glorbo-backup-{timestamp}.tar.gz` containing `companies/`, `config.md`, `audit/`, and `glorbo.db` (WAL checkpointed first); excludes `bin/`, `models/`, `containers/`, `runtime/` (re-downloadable / rebuildable).
- Atomic `restore <archive>` extracts into a fresh `~/.glorbo/` (or prompts if non-empty), runs `reindex`, runs `doctor --fix` via chain, leaves the install usable.
- Cross-host portability proof: scripted end-to-end test (`test/integration/portability_test.exs`) that simulates machine A → machine B by staging `~/.glorbo` to `/tmp/glorbo-hostA`, running backup, wiping, running restore pointed at a second staging root, and asserting a company's agent dispatch succeeds post-restore.
- `logs` supports `--follow`, `--lines N`, and the pair (`company`) and (`company agent`) routing forms.
- `doctor --fix` resolves each Phase-2/Phase-3 check category the check itself can auto-repair (missing `~/.glorbo/`, missing `bin/` binaries, stale DB, missing acme example when `--example` was passed). Unrepairable checks print actionable guidance and exit with severity-appropriate code.
- `console` opens `iex --remsh glorbo@127.0.0.1 --name console@127.0.0.1 --cookie <from config>` into the running `glorbo serve`/`glorbo up` release; cookie generated into `~/.glorbo/config.md` on first boot (Phase 4 `Glorbo.Config` already owns the file — extend it with `erl_cookie:`).

**Out of scope (deferred / not in v0.0.2):**
- Backup encryption / signing (plain `.tar.gz`; user wraps with age/gpg if needed)
- Differential / incremental backup
- Backup scheduling (cron-in-glorbo) — user wraps with system cron
- Restore partial (select-a-company) — restore is all-or-nothing in v0.0.2
- Multi-node distribution / clustering — `glorbo up` is single-node
- Multi-tenant hosting (one Director per machine)
- CLI JSON output for every verb (only `doctor --json` in v0.0.2; others print human-readable)
- `glorbo logs --level` log-level filtering (tail only in v0.0.2)
- `glorbo serve --port` override — for v0.0.2 the port is config.md only; CLI flag lands in v0.0.3
- Plugin mechanism for new verbs (closed set in v0.0.2)
- REPL-like verbs (`glorbo shell`, `glorbo eval`) — `console` is the Elixir remote shell only

</domain>

<decisions>
## Implementation Decisions

### CLI argv dispatch + verb registry
- **D-01:** Every new verb lands as a branch in `Glorbo.CLI.dispatch/1` (lib/glorbo/cli.ex), following the existing `["doctor" | rest]` pattern. No separate verb registry module — a flat switch is fine for ~17 verbs, and the single-file dispatch keeps Burrito's argv path easy to follow.
- **D-02:** Multi-word verbs (`new company`, `new agent`, `new project`) are parsed as `["new", sub, ...rest]` in the dispatcher, with a nested switch. Not `["new-company"]`.
- **D-03:** Every verb returns `{verb_atom, exit_code, output_string}` from the dispatcher. Printing + halting is the Application.start/2 responsibility (already in place). Keeps verbs unit-testable without CaptureIO.
- **D-04:** Unknown subcommands under `new` return `{:unknown, 1, help_text}` — same shape as top-level unknowns.
- **D-05:** Every verb accepts `--help` / `-h` and prints a verb-specific usage block. Top-level `glorbo help <verb>` aliases to the same (like `git help <verb>`).

### Lifecycle verbs (`up`, `down`, `status`, `serve`, `run`)
- **D-06:** `glorbo serve` is the Phoenix LiveView dashboard launcher — starts the full supervision tree + Phoenix endpoint, blocks until SIGINT. Already possible in Phase 4 dev; Phase 5 just wires the argv branch.
- **D-07:** `glorbo up` = `glorbo serve` **in background** via `nohup` + pidfile at `~/.glorbo/run/glorbo.pid`. Reason: from the Director's perspective `up` is "start everything and leave it running"; they'll open the dashboard in a browser.
- **D-08:** `glorbo down` reads the pidfile, sends SIGTERM, waits up to 10s for graceful shutdown, then SIGKILL if needed. Removes the pidfile.
- **D-09:** `glorbo status` checks (1) pidfile exists, (2) pid is alive, (3) Bandit port 4000 is listening. Prints a terse status table. Exit 0 if running, 3 if not (like `systemctl is-active`).
- **D-10:** `glorbo run <company>/<agent> <task-file>` — one-shot agent dispatch outside the dashboard. Starts the supervision tree, dispatches the named agent against the named task, waits for completion, prints result, exits. Useful for cron and CI without needing the long-running server.

### Scaffolding verbs (`new company`, `new agent`, `new project`)
- **D-11:** `glorbo new company <slug>` scaffolds `~/.glorbo/companies/<slug>/` with `company.md` + empty `agents/`, `projects/`, `channels/`, `audit/` subdirectories (Phase 2's hierarchy template). Idempotent on re-run (emits `⏭ already exists`). Inputs slug is validated against `~r/\A[a-z0-9-]+\z/` (same regex Phase 4 ships).
- **D-12:** `glorbo new agent <company>/<slug> [--role R] [--provider P]` scaffolds `agents/<slug>/agent.md` with frontmatter defaults (role = "Agent", provider = `claude-code`, network = `api-only`, permissions = `[]`, budget = 1000 ¢/month). Director-only — the CLI caller IS the Director (SEC constraint). No "agent-creates-agent" vector per AGT-05.
- **D-13:** `glorbo new project <company>/<slug>` creates `projects/<slug>/README.md`. Projects are just directories; lightweight scaffold.

### Observability verbs (`logs`, `doctor --fix`)
- **D-14:** `glorbo logs <company>` tails the top-level company audit log (`companies/<co>/audit/YYYY-MM.jsonl`) as pretty-printed JSON (one line per event). `--lines N` controls the initial backfill (default 50). `--follow` tails forever via inotify (graceful degradation when inotify unavailable — prints a warning and polls every 1s).
- **D-15:** `glorbo logs <company> <agent>` tails the agent stdout log (`agents/<ag>/stdout.log`). Same flags as company-scope.
- **D-16:** `glorbo doctor --fix` runs the check set then, for each failed check with a registered repair, attempts the repair and re-checks. Repairs are registered in `Glorbo.Doctor.Fixer`:
  - Missing `~/.glorbo/` → `File.mkdir_p/1`
  - Missing `bin/` binaries → re-run Phase 2 `Glorbo.Init.BinaryBootstrap.run/1`
  - Missing migrations → `Ecto.Migrator.run/3`
  - Corrupt / missing `glorbo.db` → `glorbo reindex` (after rebuild)
  - Phase-3 `bwrap` missing → print install guidance, do NOT auto-install (sudo required)
- **D-17:** `doctor --fix --dry-run` prints what would be repaired without running repairs.

### Maintenance (`migrate`)
- **D-18:** `glorbo migrate` runs Ecto migrations in place against `~/.glorbo/glorbo.db`. Thin wrapper over `Ecto.Migrator.run(Glorbo.Repo, :up, all: true)`. Exits non-zero on failure. No `--rollback` in v0.0.2 (Director edits migration files manually in advanced cases).

### Backup / restore / portability (`backup`, `restore`)
- **D-19:** `glorbo backup [--output <path>]` produces a `tar.gz` archive containing:
  - `companies/` (the Director's work — always)
  - `config.md`
  - `audit/` (system-level audit, not per-company which is inside `companies/*/audit`)
  - `glorbo.db` (after `PRAGMA wal_checkpoint(FULL)` to merge the WAL)
  Excludes `bin/`, `models/`, `containers/`, `runtime/` (re-downloadable) and the `.sock` / `.pid` run state (`run/`).
- **D-20:** Default output path: `~/glorbo-backup-{UTC ISO8601}.tar.gz`. `--output <path>` overrides.
- **D-21:** `glorbo backup` requires `glorbo down` first (pidfile must be absent). Otherwise emits `⚠ glorbo is running. Run glorbo down first, or pass --force-live` and exits 2.
- **D-22:** `glorbo restore <archive> [--force]` extracts into `~/.glorbo/`. If `~/.glorbo/` is non-empty, prints a summary of what would be overwritten and exits 2 unless `--force` passed. After extraction, runs `migrate` then `reindex` then `doctor --fix` (chained internally). Final state: running `glorbo up` should just work.
- **D-23:** Portability integration test (`test/integration/portability_test.exs`) stages a source tree at `/tmp/glorbo-portA` with a fake `acme` company and CEO agent task, runs `Glorbo.Backup.run/1`, destructively moves the result to `/tmp/glorbo-portB`, runs `Glorbo.Restore.run/1`, asserts the CEO agent can dispatch a task post-restore. Tagged `:integration` (excluded from default suite because it touches disk heavily).

### Ops (`console`)
- **D-24:** `glorbo console` opens `iex --remsh glorbo@127.0.0.1 --name console@127.0.0.1 --cookie <cookie>` where `<cookie>` is read from `Glorbo.Config.erl_cookie/0`. If `glorbo up`/`serve` isn't running, exits with `⚠ glorbo is not running`.
- **D-25:** Cookie generation: `Glorbo.Config` ensures `erl_cookie:` is present in `~/.glorbo/config.md` on first boot, generated via `:crypto.strong_rand_bytes(24) |> Base.url_encode64()`. File mode stays 0600 (Phase 4 invariant).
- **D-26:** Elixir release distribution is enabled via `rel/env.sh.eex` (Burrito extension). `glorbo up`/`serve` invokes with `--sname glorbo@127.0.0.1 --cookie <cookie>`. `console` re-uses the cookie.

### Error handling + UX
- **D-27:** All verbs print human-readable output (no JSON by default). `--json` supported on `doctor`, `status` (v0.0.2); others land in v0.0.3.
- **D-28:** Exit code conventions:
  - 0 = success
  - 1 = unknown command / usage error
  - 2 = operational failure with actionable hint (e.g., "glorbo is running — run glorbo down first")
  - 3 = "not running" (for `status` / `console`)
  - ≥128 = signal-terminated (via nohup / service manager)
- **D-29:** Every error message names the remediation verb. "Could not find ~/.glorbo/ — run `glorbo init` first." No raw stacktraces to stdout.

### Tests
- **D-30:** Unit tests per verb under `test/glorbo/cli/{verb}_test.exs` — assert the `{verb_atom, exit_code, output_string}` tuple for happy-path + 2-3 error cases.
- **D-31:** Integration tests: `portability_test.exs` (D-23), `backup_restore_roundtrip_test.exs`, `up_down_status_test.exs` (spawns a subprocess, checks pidfile + port, sends `down`), `doctor_fix_test.exs` (each registered fixer). Tagged `:integration`.
- **D-32:** Manual / live items that can't be automated ship as UAT entries: cross-host `scp` test, `console` remote shell (requires actual distribution wiring + `glorbo up` in another terminal).

### Claude's Discretion
- Exact column layout of `glorbo status` table.
- Whether `glorbo up --foreground` should ship in v0.0.2 (currently `serve` fills that role).
- Pidfile cleanup on abnormal exit (SIGKILL) — trap via Elixir `System.at_exit/1`.
- tar options: `--no-xattrs` vs default. Default is fine unless tests say otherwise.
- Progress output during long backup / restore (spinner? % progress?).
- Whether `doctor --fix` should prompt before destructive repairs (v0.0.2: no prompt — `--fix` implies consent; `--dry-run` is the preview).
- Whether `logs --follow` rotates on month boundaries (`audit/YYYY-MM.jsonl`). v0.0.2: restart the tail on month rollover; log a warning.
- Whether `glorbo new agent` without a slug prompts interactively. v0.0.2: no prompt — require the slug.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Architecture (authoritative)
- `DESIGN.md` §10 — CLI surface (the full verb list).
- `DESIGN.md` §3 — Filesystem hierarchy (shapes `backup` / `restore` content lists).
- `DESIGN.md` §13 — Distribution / Burrito packaging (constrains how `up`/`serve`/`console` interact with the release binary).
- `DESIGN.md` §14 — Portability story (the phase goal).

### Project-level
- `.planning/REQUIREMENTS.md` CLI-01, CLI-03 (2 requirements).
- `.planning/ROADMAP.md` Phase 5 (4 success criteria).
- `CLAUDE.md` — Load-bearing invariants. Specifically: filesystem is source of truth (backup/restore must be a verbatim round-trip of markdown + JSONL + SQLite), audit log append-only (backup does NOT merge audit entries; restore writes them verbatim).

### Prior phase handoffs (live dependencies)
- `lib/glorbo/cli.ex` — existing verb dispatch (Phase 1 skeleton + Phase 2 `init`); Phase 5 extends in place.
- `lib/glorbo/init/orchestrator.ex` — Phase 2 pipeline; `doctor --fix` calls out to the individual steps.
- `lib/glorbo/doctor.ex` — check registry; `--fix` consumes this.
- `lib/glorbo/filesystem/reindex.ex` — called from `restore` chain.
- `lib/glorbo/config.ex` (Phase 4) — owns `~/.glorbo/config.md`; extend with `erl_cookie:`.
- `lib/glorbo/application.ex` — supervision tree; `glorbo up`/`serve`/`run` start this.
- `lib/glorbo_web/endpoint.ex` (Phase 4) — Phoenix endpoint; `glorbo serve` starts it.
- `rel/vm.args.eex`, `rel/env.sh.eex` (Phase 1 / Phase 5 extension) — Burrito / release config for distribution.

### External specs / research
- Erlang/OTP distribution: https://www.erlang.org/doc/reference_manual/distributed.html (`-sname`, `-cookie`).
- `Ecto.Migrator` docs — used by `migrate`.
- Burrito release hooks: https://github.com/burrito-elixir/burrito (how argv lands in Application.start/2).
- Tar packaging in Elixir: `:erl_tar.create/2` (stdlib) or shell out to `tar` binary (already on the host).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable assets
- **`Glorbo.CLI.dispatch/1`** (Phase 1+2) — extend with 10+ new verb branches.
- **`Glorbo.Init.Orchestrator`** / `Glorbo.Init.{BinaryBootstrap,Hierarchy,ImagePull,Reindex,PreDoctor,PostDoctor,ExampleCompany}` — `doctor --fix` composes these.
- **`Glorbo.Doctor`** + `Glorbo.Doctor.Formatter` — `status` / `doctor` / `doctor --fix` reuse the check shape.
- **`Glorbo.Config`** (Phase 4) — extend with `erl_cookie:` parsing; format already covers the 0600 bootstrap.
- **`Glorbo.Filesystem.Reindex`** — called by `restore`.
- **`Glorbo.Application`** supervision tree — already started by `Burrito` argv dispatch when `glorbo serve` lands.
- **`GlorboWeb.Endpoint`** (Phase 4) — started by `glorbo serve`.

### Established patterns
- **Verb dispatch**: pattern-match on argv, use `OptionParser.parse(rest, strict: @switches)` for flag parsing (Phase 1 `doctor`, Phase 2 `init` templates).
- **Return shape**: `{verb_atom, exit_code, output_string}`. Phase 1 `Glorbo.CLI` defines the `@type result` already.
- **Filesystem-first**: Every verb that mutates state writes a file or a SQLite row. No in-memory "last command" cache.
- **Idempotency**: Phase 2 established that every verb that can be re-run (`init`, `reindex`) must be idempotent. `backup` overwrites only if `--output <path>` points at an existing file and `--force` is set.
- **Audit events**: Every verb that mutates state appends `cli.<verb>.start` / `cli.<verb>.complete` to `audit/_system/YYYY-MM.jsonl` (system-scope audit, same format as `init.step.*`).

### Integration points
- **Burrito argv**: Phase 1's `Glorbo.Application.start/2` already dispatches to `Glorbo.CLI.dispatch/1` when `__BURRITO` env var is set. Phase 5 just adds verb branches.
- **Pidfile**: new — Phase 5 adds `~/.glorbo/run/glorbo.pid`. Directory is created by `init` (add to hierarchy list). Pidfile content = single line with OS pid.
- **SQLite WAL**: backup MUST checkpoint the WAL before archiving, otherwise `restore` on the other host sees stale data. Use `Ecto.Adapters.SQL.query!(Glorbo.Repo, "PRAGMA wal_checkpoint(FULL)", [])`.
- **Release distribution**: Phase 5 extends `rel/env.sh.eex` with `-sname glorbo@127.0.0.1 -cookie $GLORBO_ERL_COOKIE`. `GLORBO_ERL_COOKIE` is exported by `config/runtime.exs` from `Glorbo.Config.erl_cookie/0`.

</code_context>

<specifics>
## Specific Ideas

- **The portability story is the phase-defining demo.** Everything else is plumbing. The success criterion reads: "on machine A run `glorbo down && glorbo backup`; `scp` the archive to machine B (fresh glorbo binary only); run `glorbo restore && glorbo doctor --fix && glorbo up`; a previously-running agent in a previously-existing company executes a task successfully on machine B." The integration test (D-23) simulates this end-to-end on one host using staging directories.
- **`glorbo backup` must be lossless for the source-of-truth data** — markdown + JSONL + SQLite must round-trip byte-for-byte. Anything derived (bin, models, runtime, containers) is explicitly excluded because it's reproducible.
- **`glorbo doctor --fix` is the "install doctor" equivalent of `brew doctor` — it fixes what it can, names what it can't.** In v0.0.2 it repairs the plumbing layer (directories, binaries, migrations, reindex). It does NOT mutate agent configs, company contents, or LLM provider credentials — those are user-owned data.
- **`glorbo console` is the emergency repair seat.** The Director uses it to hot-fix a running system without restart. Read-write access, full IEx. Distribution cookie lives in `config.md` (file mode 0600), not committed, not backed up off-machine without encryption.
- **All CLI verbs are Director-run.** No agent ever invokes the CLI. This is a SEC constraint (agents run sandboxed inside bwrap — no `glorbo` binary in the bwrap tree).
- **v0.0.2 ships a "good-enough" CLI.** The closed verb set is final for this milestone. Extensions (plugin verbs, JSON output everywhere, `serve --port`) are explicitly v0.0.3 work.

</specifics>

<deferred>
## Deferred Ideas

- Backup encryption / signing (age / gpg wrap) — Director responsibility in v0.0.2.
- Differential / incremental backup.
- Scheduled backups (cron-in-glorbo). Use system cron.
- Restore partial (pick companies). All-or-nothing in v0.0.2.
- `serve --port <N>` CLI flag override (config.md only in v0.0.2).
- JSON output on every verb (only `doctor`, `status` in v0.0.2).
- Plugin verbs / third-party command extensions.
- `glorbo shell` / `glorbo eval` (Elixir expressions from argv).
- Multi-node clustering.
- CLI completion files for bash/zsh/fish.
- i18n on error messages.
- Windows / macOS support (Linux-only per PROJECT.md).
- `glorbo rollback <migration>` — v0.0.3.

</deferred>

---

*Phase: 05-cli-completeness-backup-restore-portability*
*Context gathered: 2026-04-16 (--auto)*
