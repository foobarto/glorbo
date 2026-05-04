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

## Commit(s)

Three atomic commits coming up:

  1. `fix(cli): glorbo serve/up now bind port 4000` —
     bug 1 (Phoenix endpoint enable) + the CHANGELOG entry.
  2. `fix(test): replace flaky debounce sleeps with deterministic poll` —
     bug 2 (the aarch64 CI flake + tx_test.exs flake +
     up_test.exs nice-to-have) + CHANGELOG entry.
  3. `feat(doctor): migrations_pending check + 'run glorbo migrate' hint` —
     the doctor enhancement + its CHANGELOG entry.

Then push origin main, monitor CI for green.
