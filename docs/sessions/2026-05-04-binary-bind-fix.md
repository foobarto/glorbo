# 2026-05-04 — `glorbo serve` port-binding bug + CI aarch64 flake

User opened with a sitrep request, then reported the local
binary "failed to use today" and clarified: *the app starts
but browser fails to connect/display working app*. After
the auto-fix landed, also asked to fix the failing aarch64
CI run before the next push.

Autonomy level: **L2** — implement, test, propose commit.
Did not push or commit yet.

---

## Task — `serve` / `up` never set `server: true` in release

**Task picked.** User reported `./glorbo` (symlinked to
`burrito_out/glorbo_linux_x86_64`) failed when invoked
today. Reproduced with `./glorbo serve`: banner printed but
port 4000 never bound. `curl 127.0.0.1:4000` got connection
refused; `ss` confirmed nothing listening. With
`PHX_SERVER=1 ./glorbo serve` the port bound and `/`
returned 302 → `/companies`. Root cause:
`config/runtime.exs:19-21` only flips
`GlorboWeb.Endpoint`'s `:server` config to `true` when
`PHX_SERVER` is set in the env, and neither `glorbo serve`
nor `glorbo up` set it.

**What shipped.**

  * `config/config.exs` — new `:serve_starts_endpoint` app
    env flag, default `true`. Documents the contract that
    `glorbo serve` / `up` flip the Endpoint's `:server` at
    CLI dispatch time so the release binary doesn't need
    `PHX_SERVER` set externally.
  * `config/test.exs` — sets `:serve_starts_endpoint` to
    `false` so ConnCase + the `:integration` `--exit-after`
    test don't compete with parallel suites for port 4000.
  * `lib/glorbo/cli/lifecycle/serve.ex` —
    `enable_endpoint_serving/0` (`@doc false`, public for
    direct test exercise) reads the flag and writes
    `Application.put_env(:glorbo, GlorboWeb.Endpoint,
    Keyword.put(cfg, :server, true))` before
    `start_supervision_tree_for_serve/0` is called.
    Idempotent.
  * `lib/glorbo/cli/lifecycle/up.ex` — adds
    `{~c"PHX_SERVER", ~c"1"}` to the env list passed to
    `Daemon.spawn_detached/2`. The re-exec'd Burrito child
    reads `runtime.exs` at boot, sees `PHX_SERVER`, and
    flips `:server` itself — same path as the documented
    `PHX_SERVER=true bin/glorbo start` runbook.
  * Moduledocs in both files document the new behaviour
    + the test opt-out.

**Tests.**

  * `test/glorbo/cli/serve_test.exs` (+2 unit tests):
    `enable_endpoint_serving` flips `:server` to `true`
    when the flag is on; no-op when off.
  * `test/glorbo/cli/up_test.exs` (+1 test): the fake
    daemon writes `PHX_SERVER` to a known file on startup
    so the test can assert the export.
  * `test/support/cli_case.ex` —
    `fake_daemon_binary!/1` now writes
    `<home>/fake_glorbo.env` with the value of
    `$PHX_SERVER` it was launched with.

**End-to-end verification.** Rebuilt the binary
(`mix glorbo.build_local`), restarted `./glorbo serve`,
confirmed port 4000 binds (curl returns HTTP 302 →
`/companies`). The follow-on 503 is a *separate* issue
(see "Skipped").

**Design calls I made without you.**

  * Used a Glorbo-level flag (`:serve_starts_endpoint`)
    rather than reading `Mix.env/0` because `Mix` isn't
    available in a Burrito release. The flag is also
    cleaner — config files own the on/off knob.
  * Made the helper `@doc false` + public rather than
    private so the unit tests can call it directly. The
    alternative (extract a hidden flag, exercise via
    `run/1` --exit-after) ran the full supervision tree and
    couldn't run under `mix test` without binding ports.
  * Did NOT add a doctor check. With the auto-fix in
    place the bug class disappears at the source; doctor
    is a host-prereq tool, not an internal-config sanity
    check. If users see the symptom now they're running
    a binary built before the fix.

**Gates.** `mix format --check-formatted` clean; `mix
credo --strict` 0 issues; `mix test test/glorbo/cli/`
297/297 pass; `mix test test/glorbo_web/` 563/563 pass.

**Skipped / not done.**

  * `~/.glorbo/glorbo.db` has pending migrations from the
    v0.11.0→v0.18.0 jump (the user's daemon attempt left
    behind a `-shm`/`-wal` pair stamped today; the live
    binary was the v0.11.0 build from 2026-04-25). The
    fresh-binary `serve` returned 503 with
    `Phoenix.Ecto.PendingMigrationError`. Fix: run
    `glorbo migrate`. **Not in scope for this round.**
  * Did not add a doctor recommendation for "schema
    migrations pending" — would be useful but is a
    separate doctor-feature ticket; flagging here for
    review.

---

## Task — aarch64 CI flake on `Agents.retire` roundtrip

**Task picked.** User pointed at the failing CI run on the
last main commit. `gh run view 25309688781 --log-failed`
showed `test/glorbo/actions/agents_test.exs:341` flunking
with `refute head.sha == initial_sha` — the test waited
1000ms for the Tx debounce to auto-commit, then asserted
the new head differed from the initial SHA. On aarch64 the
auto-flush hadn't fired in time, so `head` was still the
initial commit. Two prior fixes (b48c5aa, 6390127) bumped
the sleep without closing the flake.

**What shipped.**

  * `test/glorbo/actions/agents_test.exs` — replaced
    `Process.sleep(1000)` + immediate log read with
    `wait_for_new_commit!/3`, a 25ms-poll-with-5s-deadline
    helper that halts the moment the new commit lands.
    Returns the head record so callers don't need a
    separate `HomeHistory.log/1` call.
  * `test/glorbo/home_history/tx_test.exs` — same poll
    fix on the local-flaky `with_tx happy path` test
    (same root cause: `Process.sleep(@debounce_ms * 4)`
    timing out under heavy parallel test load).

**Design calls I made without you.**

  * Did NOT touch the four other `Process.sleep(@debounce_ms * 4)`
    spots in tx_test.exs. They're not currently flaky and
    "Surgical Changes" applies — fix only what's broken.
    If they flake later the same poll helper applies
    drop-in.
  * Kept the 1000ms sleep in
    `test/glorbo/actions/agents_test.exs:391` ("retire
    with non-existent agent does not produce a commit").
    That assertion is "no commit happens" — polling for
    *absence* doesn't reduce flakiness, only adds latency.

**Gates.** `mix test test/glorbo/actions/agents_test.exs`
15/15 pass, 5 consecutive runs with random seeds all
green. `mix test test/glorbo/home_history/tx_test.exs`
16/16 pass, 5/5 stable. Full `mix precommit` 2532/2532
pass, twice in a row (was flaking 1/2532 on the same
TxTest before the poll fix).

**Skipped / not done.** None.

---

---

## Task — codex review pre-commit

**Task picked.** Standing rule per memory
`feedback_codex_review_before_commit.md`. Ran
`codex exec --skip-git-repo-check` against the staged diff.

**Codex result.** No must-fix correctness or security
issues. Three nice-to-haves:

  1. `test/glorbo/cli/up_test.exs:127` had a residual
     `Process.sleep(100)` after the daemon spawned —
     small but a real timing race. Applied the same
     poll-with-deadline pattern (`wait_for_env_file/2`).
  2. `Serve.enable_endpoint_serving/0` only takes effect
     before `GlorboWeb.Endpoint` starts — accurate; the
     CLI invokes it on the right side of that boundary.
     Logged as nice-to-have, no fix needed today (would
     require a check inside the helper that detects an
     already-started Endpoint, which the current call
     site doesn't hit).
  3. The fake daemon doesn't assert `RELEASE_COOKIE`
     export. Logged but not applied — out of scope for
     this fix; would belong in a separate hardening pass
     for `Daemon.spawn_detached/2`.

---

## Task — `glorbo doctor` migrations-pending check

**Task picked.** User had originally framed the doctor
recommendation as a fallback (*"or at very least make
glorbo doctor detect/recommend a fix"*) and the
end-to-end binary verification surfaced the exact symptom
the check would catch (`PendingMigrationError` 503 on the
fresh-binary serve). Decided to ship after autonomy
redirect.

**What shipped.**

  * `lib/glorbo/doctor.ex` — `:migrations_pending`
    warning-severity check. Reads `priv/repo/migrations/`
    file timestamps + opens `~/.glorbo/glorbo.db` in
    `:readonly` mode (Exqlite NIF directly — no Repo
    needed, doctor stays lightweight). Compares; flags
    pending count + oldest pending timestamp + the verb
    to fix it (`glorbo migrate`).
  * Three branches:
      * DB absent → `:ok` with "run `glorbo init`" hint.
      * `priv` dir missing → `:ok` skipped (binary
        structurally broken, not a doctor-fixable state).
      * pending → `:fail` with the operator-actionable
        message.
  * Dependency-injectable via `db_path_fun` /
    `migrations_dir_fun` so tests don't mutate
    `~/.glorbo/`.

**Tests** — 3 new in `doctor_phase3_test.exs` (tmp-dir
fakes; `seed_schema_migrations!/2` helper writes a fresh
SQLite file via `Exqlite.Sqlite3.prepare/step`):

  * DB absent → pass + `glorbo init` hint
  * All applied → pass + applied count
  * 2 pending → fail + oldest timestamp + `glorbo
    migrate` hint + warning severity (refute exit_code 1)

**Plus 4 count-assertion bumps** (12→13) across
`doctor_test.exs`, `doctor_phase3_test.exs`, `cli_test.exs`.
The `Enum.drop(names, 5)` ordered-list assertion picks up
the new check at the end.

**Live verification.** `mix glorbo.doctor` against the
real `~/.glorbo/glorbo.db`:

    ✗ migrations_pending [warn] 1 pending migration(s)
                                 (oldest: 20260426170000).
                                 Run `glorbo migrate`.
    1 check(s) failed (12/13 passed).

Confirms the symptom-class the user's failed-serve probe
would have caught at the earlier `glorbo doctor` step.

**Design calls I made without you.**

  * `:warning` severity not `:blocker`. A pending
    migration doesn't make the binary unusable — it makes
    the dashboard 503. Operator should be able to run
    `glorbo migrate` without doctor's exit code blocking
    automation pipelines.
  * `Exqlite.Sqlite3` directly, not Ecto. Doctor must
    work without the Repo running (e.g. `./glorbo doctor`
    pre-`up`).
  * Read-only mode. Doctor never mutates the DB.

**Gates.** Compile clean (warnings-as-errors), `mix
format --check-formatted` clean, `mix credo --strict`
0 issues, `mix precommit` 2535/2535 pass (3 new tests).

---

## Commit(s) — wave 1 (already shipped)

  1. `5a384b4 fix(cli): glorbo serve/up now bind port 4000`
  2. `42c6c01 fix(test): replace flaky debounce sleeps with deterministic poll`
  3. `f807d5e feat(doctor): migrations_pending check + 'run glorbo migrate' hint`

CI verdict: all four jobs green on `f807d5e` (x86_64 + aarch64
build/test, x86_64 + arm64 macOS cross-build). aarch64 flake fix
held.

---

## Task — verify glorbo dogfood items 5/6 + ship #5

Scope: classify the dogfood items as documentation gaps vs code gaps.
Glorbo side: **0/7 are doc gaps** — most are forward-looking feature
work, plus item #6 was a false positive against current code.

### Item #6 — inotify-tools warning fires on `--help`

**Verified false positive against current code.**
`Glorbo.Application.start/2` branches on `running_standalone?`:

  * Burrito release path → `run_cli_and_halt(argv)` with an empty
    supervisor (`Supervisor.start_link([], one_for_one)`); no
    children, no Watcher, no warning.
  * `mix phx.server` / `iex -S mix` / test → full
    `start_supervision_tree/0` with CompanyBoot → company supervisor
    → `Glorbo.Filesystem.Watcher.init/1` (where the inotify warning
    actually emits at line 112-115).

Empirical check: `./glorbo --help` / `--version` / `doctor` /
`status` all emit zero inotify lines. Either fixed before I started
working here, or never reproduced against the release binary. Not
addressing.

### Item #5 — `doctor --fix` should auto-install missing packages

**What shipped.**

  * `Glorbo.Doctor.Fixer.fixers_for/1` — opts-aware registry resolver.
    Default returns `@explain_fixers`; `install_deps: true` returns
    `@install_fixers` which routes `bwrap` / `pasta` / `uidmap` to
    real installers.
  * `install_bwrap/1` / `install_pasta/1` / `install_uidmap/1` —
    each detects distro family via `detect_distro/0` (parses
    `/etc/os-release`, honours `GLORBO_DOCTOR_DISTRO_OVERRIDE` test
    seam), looks up the (family, pkg) → `(pkgmgr, pkg, args)` table,
    runs `sudo -n <pkgmgr> <args> <pkg>`. `sudo -n` fails fast when
    there's no cached credential AND no TTY; under an interactive
    shell it prompts normally.
  * Unsupported distro → returns the existing `:explain` tuple, so
    operators on weird distros still get the printed runbook.
  * `explain_uidmap/1` added (uidmap check was previously missing
    from the fixer registry — now explicit on both paths).
  * CLI flag plumbed through `Glorbo.CLI.dispatch(["doctor"|...])`
    via the new `install_deps: :boolean` switch; `DoctorFix.run/1`
    forwards opts unchanged.
  * Help text updated in `cli.ex`.

**Tests.** 7 new in `test/glorbo/doctor/fixer_test.exs`:

  * `uidmap` is now in the registered-fixer-names table.
  * `explain_uidmap` returns guidance with `shadow-utils` + `uidmap`.
  * `fixers_for([])` == `Fixer.fixers()` (default identity).
  * `fixers_for(install_deps: true)` swaps host-package fixers but
    leaves filesystem ones untouched.
  * `detect_distro` honours `GLORBO_DOCTOR_DISTRO_OVERRIDE` for
    fedora / debian / arch and returns `:error` on unknown values.
  * `install_bwrap` / `install_pasta` / `install_uidmap` on an
    unsupported distro fall back to `:explain` (no sudo invocation
    under test).

  Positive-path testing (sudo dnf install ACTUALLY succeeds) skipped
  by design — would mutate the test machine.

**Design calls I made without you.**

  * Opt-in `--install-deps` flag, not implicit-on-`--fix`. Running
    sudo without explicit consent is bad UX; the flag IS the
    consent. Default `--fix` keeps current `:explain` behavior so no
    existing user is surprised.
  * `sudo -n` so the install fails fast in non-interactive contexts
    (CI, headless) rather than blocking forever on a password prompt.
  * `dnf install -y` / `apt install -y` / `pacman -S --noconfirm` —
    bypass the package-manager prompts. The user already opted in
    via the flag; double-confirming is friction.
  * Did NOT touch the `uidmap` fixer to also handle the rootless-
    Podman setup script some distros bundle — out of scope for this
    pass.

### Task — Makefile at project root

Scope: add a root-level Makefile for building the local Glorbo binary
into the project root. Existing `mix glorbo.build_local` already
materialises `./glorbo` as a symlink — Makefile wraps it.

**What shipped.**

  * `make` (default) → builds Burrito linux_x86_64 + symlinks
    `./glorbo`. Same end-state as `mix glorbo.build_local`.
  * `make build-real` → copies the real binary to `./glorbo`
    (no symlink) for tarball / container packaging.
  * Wrappers around common verbs: `test`, `precommit`, `format`,
    `credo`, `setup`, `serve`, `up`, `down`, `doctor`, `migrate`.
  * `make clean` + `make clean-burrito` for cleanup.
  * `make help` lists everything.

The symlink-vs-copy distinction is real: dogfood often wants the
real-file form when the project root is being shipped somewhere
that doesn't preserve symlinks (tar without --copy-links, OCI image
layers, etc.). Default stays symlink so the fast-rebuild loop
isn't slowed by an extra copy.

**Gates.** `mix compile --warnings-as-errors` clean,
`mix format --check-formatted` clean, `mix credo --strict` 0 issues,
`mix precommit` 2542/2542 pass.

---

## Commit(s) — wave 2 (shipped)

  1. `e994aab feat(doctor): --install-deps actually runs sudo <pkgmgr> install`
  2. `6d3888f feat(build): Makefile wraps mix glorbo.build_local + common verbs`

CI run 25318924289 monitoring in background.

---

## Task — GEP-45 draft (Phase 0 of stado integration)

**Scope.** Start the stado integration. The saved integration
preference at the time was "expose stado as MCP and have glorbo
agents talk to it via MCP", not a stado-as-CLI-provider adapter
parallel to codex/gemini. Surveyed existing scaffolding:

  * GEP-9 (Accepted, Informational) — protocol-integration direction.
  * GEP-29 (Implemented) — Glorbo *as* MCP server; inbound side.
  * GEP-8 (Implemented) — CLI provider registry pattern.
  * No existing `mcp_servers:` field on AGENT.md or related schema.
  * Agent dispatch (`Glorbo.Agent.Dispatch.build_invocation/3`)
    composes binds in a fixed order; current architecture binds
    `~/.claude` ro into the sandbox so claude-code reads its config
    there. User adding `stado mcp-server` to host claude config IS
    visible inside the sandbox — but the spawn fails because no
    `stado` binary in sandbox PATH and stado's own config dir
    isn't bound.

**What shipped.**

  * `docs/geps/0045-agent-mcp-client-config.md` — full GEP draft.
    Covers: schema (`mcp_servers:` AGENT.md field), registry shape
    (`priv/mcp_servers/<name>.toml` mirroring `priv/providers/*.toml`),
    sandbox bind composition extension, per-CLI config injection
    strategies (overlay vs `--mcp-config` flag — leaning flag),
    lifecycle (stdio transport for Phase 1; HTTP-SSE deferred to
    Phase 4), 6-entry decision log, 4 open questions, 4-phase plan.
  * Bidirectional links: GEP-9 `extended-by:` gains 45; GEP-29
    `see-also:` gains 45.
  * `docs/geps/README.md` table updated.
  * `docs/todo.md` P1 gains the Phase-1 ticket pointing at this GEP.
  * CHANGELOG `[Unreleased]` block.

**Design calls I made without you.**

  * GEP-45 draft (not implemented). Phase 1 (registry loader +
    FileSpec field + stado.toml) is the next session's seam. Per
    `feedback_compact_after_task.md`, this is a natural compaction
    point — wave 2 closed, GEP drafted, fresh context for Phase 1.
  * Validation target: stado specifically. User's tool, dogfood
    integration already specified, both sides have skin in the
    game. First-party case is more honest than picking some
    third-party MCP server.
  * Scope: agent-level OUTBOUND consumer of external MCP servers.
    Did NOT touch GEP-29 (inbound) or GEP-9 (direction). Three
    distinct GEPs cover three concerns.

**Skipped / not done.**

  * No FileSpec, registry loader, or `priv/mcp_servers/stado.toml`
    yet — those are Phase 1, fresh-session work.
  * No `glorbo` binary changes; no rebuild needed for this commit.

**Gates.** No code changes — docs-only. Format / credo / test gates
not run (no impact). `mix glorbo.docs.file_formats --check` would
also be a no-op since AGENT.md FileSpec is unchanged this round.

---

## Commit(s) — wave 3 (shipped, then corrected)

  1. `f43f8ec docs(gep-45): draft agent-level MCP-server consumer
     config injection (stado validation target)` — first GEP-45
     draft. Wrong-shape, see correction below.

---

## Task — GEP-45 corrected after maintainer feedback

**Maintainer correction.** The wave-3 draft framed stado as a tool
source injected into a Claude Code settings file. Feedback clarified
the intended model: stado is a standalone agent runtime and should be
treated as a provider.

The first draft had glorbo agents using claude-code as outer LLM with
stado-mcp-server as a tool source. The corrected shape is that stado
is the agent — it calls its own model with its own tools. Glorbo
should treat stado as a provider parallel to claude-code/codex/gemini,
with the MCP/ACP preference referring to the transport used
to drive stado, not the integration model.

Confirmed `stado acp` exists (cmd/stado/acp.go) — JSON-RPC 2.0 over
stdio per Zed's Agent Client Protocol; supports
`initialize` / `session/new` / `session/prompt` / `session/cancel` /
`shutdown`, with `--tools` opening the audited tool loop.

**What shipped (wave 4).**

  * `docs/geps/0045-stado-as-glorbo-provider-via-acp.md` —
    rewritten body. New title; `git mv` from
    `0045-agent-mcp-client-config.md`. The replacement design
    extends GEP-8 with `prompt_mode = "acp"` (joins
    `prompt_mode = "stdin"`), ships `priv/providers/stado.toml`
    with `args = ["acp", "--tools"]` + auth_binds for stado's
    config / state dirs, and adds a new `Glorbo.CLI.Dispatcher.Acp`
    JSON-RPC client that drives the existing bwrap-sandboxed
    binary the same way the stdin-prompt path does — only the
    run-loop branches.
  * Decision log entries D1-D6 (extend-GEP-8 / keep-reply-file /
    --tools-on / rw-state-dir / single-session / stado-as-target).
    Open questions cover stderr drain, cancellation, network
    policy, usage parser.
  * Bidirectional links rebuilt: GEP-8 `extended-by` gains 45
    (this is the right link — GEP-45 extends GEP-8's provider
    pattern); GEP-9 `extended-by` keeps 45 (concrete protocol-
    level integration on GEP-9's direction); GEP-29 `see-also`
    drops 45 (first draft's symmetric-outbound framing was wrong;
    this isn't symmetric to GEP-29 — they cover different roles).
  * `docs/geps/README.md` row updated with new title.
  * `CHANGELOG.md` `[Unreleased]` entry rewritten.
  * `docs/todo.md` Phase-1 ticket rewritten.
  * Memory note `user_stado_integration_preference.md` rewritten
    to call out the case-A / case-B split explicitly so future
    sessions don't repeat the misread.
  * `MEMORY.md` index entry updated to match.

**Design calls I made without you.**

  * Rewrote the GEP body in place rather than superseding with a
    new GEP. GEP-45 is still Draft; nothing was implemented; no
    git-graveyard problem. The history block records the pivot
    so future readers see why the title doesn't match the original
    file slug (also renamed via `git mv` for cleanliness).
  * Did NOT spin up GEP-46 for "the other case" (stado-mcp-server
    as a tool source for claude-code). That's parked indefinitely.
    If it ever becomes a real need it gets its own GEP.

**Skipped / not done.**

  * Phase 1 implementation (the dispatcher branch + provider TOML)
    is still pending. Natural compaction seam — Phase 1 happens in
    a fresh session.

**Gates.** Docs-only commit; format / credo / test gates not
applicable.

---

## Commit(s) — wave 4 (shipped)

  1. `ef40743 docs(gep-45): rewrite as stado-as-provider via ACP
     transport after maintainer correction` (was first staged as
     `342f433` rename-only, amended to include the body changes).

CI 25319803526 green on `ef40743`.

---

## Task — GEP-45 Phase 1a

**Scope.** Continue with the next GEP-45 item. Per
`feedback_finish_partials_first.md` the GEP-45 thread is a
half-shipped feature; Phase 1a is its first concrete code slice.
Scoped narrowly: registry support + provider TOML + dispatcher stub.
Phase 1b (the actual ACP client) is its own body of work.

**What shipped.**

  * `lib/glorbo/cli/registry/provider.ex` — `:acp` joins
    `@prompt_modes`; `@type prompt_mode` widened.
  * `lib/glorbo/cli/registry/loader.ex` — `"acp" => :acp` in
    `@prompt_mode_map`. Closed-mapping discipline preserved.
  * `priv/providers/stado.toml` — built-in entry. `binary = "stado"`,
    `args = ["acp", "--tools"]`, `prompt_mode = "acp"`. Auth_binds:
    `~/.config/stado` (ro), `~/.local/share/stado` (rw).
  * `lib/glorbo/cli/dispatcher.ex` — function head + first clause
    pattern-matches `prompt_mode: :acp` and returns
    `{:error, {:unimplemented_prompt_mode, %{provider, gep, message,
    ...}}}`. No half-working stdin fallback. The existing implementation
    becomes the second clause.
  * `test/glorbo/cli/registry/builtin_providers_test.exs` — provider
    count expectation 8 → 9. New test asserts the stado entry's
    shape (kind=:cli, prompt_mode=:acp, binary, args, auth_binds).
  * `test/glorbo/cli/dispatcher_test.exs` — new "GEP-45 ACP transport
    stub" describe block: fast-fail with GEP pointer in error
    payload; run_fun NOT invoked under ACP mode.

**Design calls I made without you.**

  * Stub-and-ship rather than implement-then-ship. The registry
    half is independently useful (provider surfaces in `glorbo
    doctor`, AGENT.md `provider: stado` validates) and unblocks
    later work without committing to a half-baked dispatcher
    branch. Fast-fail with structured error is better than a hung
    port handshake.
  * Function-head pattern (`def invoke(p, c, opts \\ [])` followed
    by two clauses without defaults) — Elixir's idiomatic shape
    for multi-clause + default arg, replaces the original single-
    clause `\\ []` form. Compiles clean; matches existing style
    elsewhere in the codebase.
  * Did NOT add a `prompt_mode` consumer in
    `Glorbo.Sandbox.Bwrap.run_via_port` yet. `prompt_mode` was
    vestigial-validation-only across all existing providers (every
    shipped provider uses `:stdin`; the field was only consumed at
    load-time by the loader's enum check). My Phase 1a guard at
    `Dispatcher.invoke/3` is the first real branch on it.

**Tests.** `mix test` for touched files + `mix precommit` 2545/2546
(unrelated WatcherBridge inotify-watch flake; passes 5/5 in
isolation, parallel-load race not introduced). Format clean,
Credo strict 0 issues.

---

## Task — GEP-45 Phase 1b foundation

**Task picked.** Same `feedback_finish_partials_first.md` push —
keep building on the Phase 1a momentum rather than start a new
ticket. Phase 1b is the actual ACP JSON-RPC client; foundation
sub-slice is the wire-format layer (framing + message types),
which is pure code and doesn't require touching the bwrap port
machinery.

**Pre-implementation discovery.** Read
`stado/internal/acp/jsonrpc.go` to confirm the wire format. Key
finding: ACP uses **line-delimited JSON** (one message per `\n`),
NOT LSP's Content-Length header framing. The comment at the top
of stado's jsonrpc.go is explicit:

> Wire format: JSON-RPC 2.0, one message per line (LSP-style
> Content-Length framing is NOT used by ACP — it's line-delimited
> JSON).

`bufio.Reader.ReadSlice('\n')` confirms the receiver side. Saved
me from implementing the wrong framing.

Also read `stado/internal/acp/server.go` for the inbound message
shapes glorbo will receive from a session/prompt: `session/update`
notifications with kind=`text`, `tool_call`, or `subagent`. Phase
1b's text-chunk assembly only needs the `text` kind for the reply
buffer; tool_call and subagent are surface for future audit
integration.

**What shipped.**

  * `lib/glorbo/cli/dispatcher/acp/rpc_error.ex` — JSON-RPC 2.0
    error struct (`code`, `message`, `data`). Standard codes
    documented; mirrors stado's `acp.RPCError`.
  * `lib/glorbo/cli/dispatcher/acp/message.ex` — tagged-tuple
    representation (`{:request,...}`, `{:notification,...}`,
    `{:response,...}`, `{:error_response,...}`) with id-must-be-
    non-negative-integer constructors. Standard error-code
    constants exposed as functions so callers don't sprinkle
    magic numbers. Pure data.
  * `lib/glorbo/cli/dispatcher/acp/framing.ex` — wire-format
    encode/decode:
      * `encode/1` — tagged tuple → iodata terminated by `\n`.
        Drops nil params/data so wire bytes stay compact.
      * `decode_message/1` — single line → `{:ok, tagged}` or
        a structured `{:error, reason}`. Accepts trailing-`\n`
        or no-`\n`. Rejects empty / malformed JSON / wrong
        version / ambiguous shape.
      * `parse_stream/2` — drain a stdout buffer of arbitrary
        chunked input. Pass previous remainder + fresh chunk,
        get back `{messages, new_remainder}`. Empty lines silently
        dropped; malformed lines yield error tuples without
        dropping surrounding well-formed messages.
  * `test/glorbo/cli/dispatcher/acp/framing_test.exs` — 20 round-
    trip + edge-case tests covering all four message kinds,
    partial-line buffer accumulation across multiple reads,
    malformed-line tolerance, JSON-RPC 2.0 contract violations.

**Design calls I made without you.**

  * Tagged tuples over structs for message representation. More
    idiomatic in Elixir for protocol-level matching; client state
    machine pattern-matches on `{:notification, "session/update",
    %{"kind" => "text"} = p}` without struct boilerplate.
  * Extracted `RpcError` to its own top-level module rather than
    nested inside `Message`. The nested form hit a forward-
    reference compile error (defstruct of nested module not yet
    compiled when outer `new_error_response/3` was being expanded).
    Top-level extraction is also cleaner — error shape is the
    same across the client and any future server we'd implement.
  * Closed numeric ID space — `id` must be a non-negative integer.
    No string IDs anywhere in glorbo's outbound messages, so the
    state-machine can pattern-match on integers without normalisation.
  * Did NOT implement a stateful framing GenServer. `parse_stream/2`
    is a pure function over (remainder, chunk) → (messages,
    remainder) — caller carries the remainder. Simpler than a
    Process and matches the way glorbo ports already buffer.
  * Drop-nil for missing params keeps wire bytes compact: a request
    without params emits `{"jsonrpc":"2.0","id":1,"method":"shutdown"}`
    rather than `{"jsonrpc":"2.0","id":1,"method":"shutdown","params":null}`.
    Stado's encoder follows the same convention.

**Tests.** 20/20 framing tests green. Format clean. Credo 0 issues.

**Skipped / not done.**

  * Client state machine (sub-slice 1b.3 + 1b.4): the actual
    ACP conversation driver — initialize → session/new → session/prompt
    → drain session/update text chunks → assemble reply text → shutdown.
  * Mock ACP peer fixture for testing the client without bwrap.
  * Sandbox `Bwrap.start_acp/2` (sub-slice 1b.5): open a port
    without the prompt-tempfile shell-redirect.
  * Dispatcher integration (sub-slice 1b.6): replace the Phase 1a
    stub with a real call into the client state machine.

---

## Commit(s) — wave 5 (shipped)

  1. `f7eaf6b feat(gep-45): Phase 1a — stado provider registry entry +
     acp prompt_mode`
  2. `21b994d feat(gep-45): Phase 1b foundation — ACP framing + message
     types`

Both pushed; CI not blocking per maintainer instruction. todo.md
ticket split: Phase 1a + 1b foundation marked done; remaining
sub-slices listed as separate P1 items so the next session has
clear targets.
