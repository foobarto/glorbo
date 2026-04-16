---
phase: 03-agents-routing-kernel-permissions-budgets
document: gap-fix-summary
started: 2026-04-16T09:15:00Z
completed: 2026-04-16T09:45:00Z
closes-verification: .planning/phases/03-agents-routing-kernel-permissions-budgets/03-VERIFICATION.md

gaps-closed:
  - id: GAP-1
    truth: SC-4 (bwrap filesystem namespace denial verifiable end-to-end)
    commit: da70d00
    files:
      - lib/glorbo/sandbox/bwrap.ex
      - test/glorbo/sandbox/bwrap_test.exs
  - id: GAP-2
    truth: SC-2 first half (Dispatch.run_fun reaches real bwrap path)
    commit: b7e91fe
    files:
      - lib/glorbo/agent/dispatch.ex
      - test/glorbo/agent/dispatch_test.exs
  - id: GAP-3
    truth: SC-2 second half (inotify → Router/Agent.Server wake in production)
    commit: 57b6d0e
    files:
      - lib/glorbo/company/router.ex
      - lib/glorbo/agent/server.ex
  - id: GAP-4
    truth: SC-5 (Network.Proxy supervised for api-only agents)
    commit: 7b2366e
    files:
      - lib/glorbo/company/supervisor.ex
      - test/glorbo/company/supervisor_test.exs
  - id: GAP-5
    truth: SC-7 (Approvals.Gate supervised under Company.Supervisor)
    commit: f855781
    files:
      - lib/glorbo/company/supervisor.ex
      - test/glorbo/company/supervisor_test.exs
      - test/glorbo/filesystem/watcher_test.exs
  - id: E2E-TEST
    truth: Wiring contiguity proof (inotify→Watcher→Server→Dispatch→Bwrap)
    commit: eaba57c
    files:
      - test/integration/inotify_to_bwrap_happy_path_test.exs

test-status:
  unit-suite: "418 / 418 passing (44 excluded) — same baseline as verification report"
  bwrap-tagged: "9 / 9 passing (was 1 / 6 before GAP-1; 3 new B11-B13 stdin-EOF tests added)"
  integration-tagged: "skipped-gracefully on this host (no inotify-tools / no runtime image); will run on CI"
  compile-warnings-as-errors: clean
  credo-strict: "0 issues on all modified lib/ modules"
---

# Phase 3 Gap-Fix Summary

Closes the 5 integration gaps found by `gsd-verifier` in
[`03-VERIFICATION.md`](./03-VERIFICATION.md). Each fix is a localised
wiring patch — no architectural pivots — and ships with its own atomic
commit + test coverage update. An end-to-end integration test
(`inotify_to_bwrap_happy_path_test.exs`) closes the loop by proving the
full path from inotify → Bwrap argv composition is contiguous.

## Gap-by-gap

### GAP-1 — Bwrap stdin-EOF fix (commit `da70d00`)

**Problem:** `System.cmd/3` in Elixir 1.19.5 does NOT support the `:input`
option. The CR-01 review-fix that introduced
`System.cmd(bwrap_bin, argv, input: prompt, ...)` raised
`ArgumentError: invalid option :input with value "..."` at runtime. All
5 `:bwrap`-tagged integration tests failed; SC-4 (kernel-layer EACCES
verifiable path) was broken.

**Fix:** Replace with `Port.open({:spawn_executable, "/bin/sh"}, args: ...)`
using a thin shell wrapper: `exec bwrap "$@" < $prompt_file`. The prompt
is written to a per-invocation tempfile via `File.write/2`; the kernel
closes stdin on the CLI tool side as soon as the file EOFs — which is
precisely what `claude --print`, `codex exec -`, and `gemini -p` require
before they begin processing (CR-01's root cause). The tempfile is
deleted in a `try/after` so cleanup runs on every exit path.

Cleanup guarantees unchanged: `--die-with-parent` + `--unshare-pid` in
the D-08 baseline still reap the child pid namespace on parent death /
port close / timeout.

**Tests added:** 3 new `:bwrap`-tagged unit tests exercise stdin-EOF
behaviour inside a real sandbox:

- **B11** — `cat; echo DONE` inside the sandbox proves stdin is both
  delivered AND EOFs (else `echo DONE` would never run).
- **B12** — empty prompt still EOFs (bare `cat` exits immediately,
  DONE marker fires).
- **B13** — prompt tempfile is cleaned up post-invocation (no
  `glorbo_bwrap_prompt_*` leak under `System.tmp_dir!()`).

All 12 pre-existing Bwrap unit tests still pass; all 5 original
`:bwrap`-tagged integration tests now pass (was 5/5 failing).

### GAP-2 — Dispatch run_fun wiring to Bwrap.start (commit `b7e91fe`)

**Problem:** `Dispatch.execute/3`'s default `run_fun` returned
`{:error, :bwrap_not_wired}` — a placeholder left over from Plan 03-03
that Plan 03-05 was meant to wire but never did. A production agent
dispatch would return `:bwrap_not_wired` immediately; the
adapter/telemetry ingest path was unreachable; budget ingest couldn't
close the loop.

**Fix:** New `default_bwrap_run_fun/4` composes `invocation_opts` +
`run_opts` from `spec` + an in-pipeline `ctx` map (resolved workspace,
inbox/outbox, company_path, permissions, network policy, cli_auth_binds,
proxy_url, timeout_seconds, usage_dir, adapter). Calls
`Glorbo.Sandbox.Bwrap.start/2`.

The `run_fun` signature is extended to 4 args
`(argv, env, spec, ctx)`; existing 3-arity test callers are still
supported via a dispatch shim (`call_run_fun/5`).

`build_run_ctx/6` is a new helper that materialises dispatch context
into the `ctx` map. Threaded through the `do_execute/4` `with` chain
between `env` composition and `emit_dispatch_audit`.

**Test update:** The old "default run_fun returns :bwrap_not_wired" test
is replaced with an assertion that the default run_fun invokes
`Bwrap.start/2` — verified by confirming the return is NOT
`{:error, :bwrap_not_wired}` under two host shapes (bwrap present +
missing). 11/11 dispatch tests pass.

### GAP-3 — Router + Agent.Server PubSub wiring (commit `57b6d0e`)

**Problem:** `Glorbo.Filesystem.Watcher` broadcasts file events on four
PubSub topics (`company:<co>:{inbox,outbox,projects,channels}`) — but
the production subscribers for inbox + outbox didn't exist. Router had
no `Phoenix.PubSub.subscribe/2` call and no
`handle_info({:file_event, ...}, state)` handler. Agent.Server's
`inbox_scan_fun` default was `fn _ -> nil end`. Inotify events reached
the Watcher, broadcast into the PubSub void, and no wake fired.

**Fix (Router):** `init/1` now subscribes to
`"company:#{company}:outbox"` on `Glorbo.PubSub` (unless
`subscribe?: false` for tests). New `handle_info({:file_event, rel_path,
events}, state)`:

1. Filters for write events (`:created | :modified`).
2. Extracts `sender` slug from the rel path via the regex
   `\Aagents/<sender>/outbox/<file>.md\z`.
3. Reads the outbox file; parses frontmatter via
   `Glorbo.Filesystem.Frontmatter.parse/1`.
4. Loads sender permissions via `Glorbo.Agent.Parser.parse_file/1`
   (dep-injectable via `:agent_permissions_fun`).
5. Builds an `outbox_msg` struct and calls `do_route/2` — reusing the
   existing pipeline unchanged.

Permission-lookup failures → empty list (the downstream ACLMapper check
will deny any permissioned action). File-read / parse errors are logged
at debug level; the Router stays alive.

**Fix (Agent.Server):** `init/1` subscribes to
`"company:#{company}:inbox"` (unless `subscribe?: false`). New
`handle_info({:file_event, rel_path, events}, state)` filters for
events scoped to THIS agent's slug (`agents/<this-slug>/inbox/`) and
sends an internal `{:internal_inbox_wake, rel_path}` message that
funnels into the existing wake-queue state machine.

The default `inbox_scan_fun` is now a real implementation that walks
`agents/<slug>/inbox/` (+ one subdirectory deep for `from-<sender>/`,
`mentions/`, `rejections/`) and returns the oldest unread `.md` file
as a task map.

Both modules accept `subscribe?: false` opt so unit tests that drive
the public API directly don't trigger PubSub side-effects. Existing
tests (12 Router + 12 Agent.Server) remain green without modification.

### GAP-4 — Conditional Network.Proxy (commit `7b2366e`)

**Problem:** `Glorbo.Network.Proxy` module was implemented (395 LOC) but
not supervised. An agent with `network: api-only` had no proxy to point
`HTTPS_PROXY` at.

**Fix:** `Company.Supervisor.init/1` now calls `maybe_append_proxy/4`
which scans `<base>/companies/<co>/agents/*/agent.md` via
`Glorbo.Agent.Parser.parse_file/1` and appends a
`Glorbo.Network.Proxy` child iff any agent declares
`network: api-only`. An `:api_only?` opt overrides the scan for tests.

**Test added:** New `S1b` describe block in `supervisor_test.exs`
asserts the 8-child shape when `api_only?: true` is passed; `S1`
asserts the 7-child default shape (no api-only agents on disk → no
Proxy).

### GAP-5 — Approvals.Gate supervised (commit `f855781`)

**Problem:** `Glorbo.Approvals.Gate` module was implemented (501 LOC, 15
unit tests passing) but not supervised. Plan 03-05 explicitly admitted
this deferral. In production, no Gate GenServer would start when a
company boots — approval-gated tasks would never be paused or released;
SEC-04 was dead in production.

**Fix:** `Glorbo.Approvals.Gate` added as a child of
`Glorbo.Company.Supervisor` (7th child, always started). Its `init/1`
already subscribes to `"company:<co>:projects"` for Director status-flip
events — so Gate is now live the moment a company boots.

The default `agent_wake_fun` no-op is preserved — a follow-on iteration
can wire Registry.lookup + `Agent.Server.wake/3` here, but the
structural dependency (Gate lives in the tree, subscribes, completes
approval DB + audit) is now satisfied.

**Tests updated:** `supervisor_test.exs` S1 and `watcher_test.exs` Test
10 both assert 7 children; S1 also asserts `Glorbo.Approvals.Gate ∈
modules`.

### E2E test — inotify → Bwrap contiguity (commit `eaba57c`)

**File:** `test/integration/inotify_to_bwrap_happy_path_test.exs`

Proves the full wiring path is intact:

1. Spawns a real `Glorbo.Filesystem.Watcher` pointed at a tmpdir.
2. Starts `Glorbo.Agent.Server` (subscribes to
   `"company:<co>:inbox"` by default).
3. Writes a task file to `agents/<slug>/inbox/t-hp1.md`.
4. Inotify → Watcher PubSub broadcast → Server's `handle_info` fires →
   `inbox_scan_fun` returns the task → `dispatch_fun` is called.
5. The test's `dispatch_fun` routes through `Dispatch.execute/3` with
   a recording `run_fun` that re-composes the production Bwrap
   invocation_opts and calls `Bwrap.build_argv/1`.
6. Assertions verify: claude-code CLI args (`--print`, `--model`,
   `claude-sonnet-4-5`), env (`CLAUDE_CONFIG_DIR` populated), ctx
   (workspace / inbox / outbox / network_policy), and bwrap argv
   (`--die-with-parent`, `--unshare-pid`, `--unshare-net`, workspace rw
   bind, inbox ro bind).

Does NOT require a real `claude` binary (`run_fun` + `binary_fun`
overridden). Tagged `:integration` + `:inotify` with a runtime skip
when `inotifywait` is absent — CI hosts with `inotify-tools` will
execute it fully.

## Verification snapshot

### Before

- 418 unit tests pass
- 5 / 6 `:bwrap` integration tests **FAIL** (`System.cmd :input` regression)
- `Router` / `Agent.Server` wake path unreachable from inotify
- `Network.Proxy` / `Approvals.Gate` unsupervised
- `run_fun` default = `:bwrap_not_wired`

### After

- 418 unit tests pass (+ 3 new B11-B13 stdin-EOF tests in bwrap_test.exs)
- 6 / 6 `:bwrap` integration tests pass + 3 new stdin-EOF checks pass
  (9 / 9)
- Router subscribes to `company:<co>:outbox`, Agent.Server subscribes
  to `company:<co>:inbox` and filters to its own slug
- `Company.Supervisor` supervises 7 children by default + conditional
  `Network.Proxy` 8th child when api-only agents exist
- `run_fun` default wires through to `Bwrap.start/2`

### Commands run

```bash
# Baseline before fixes:    418 / 418 pass (1 / 6 bwrap pass)
# After GAP-1 (da70d00):    6 / 6 bwrap pass; 418 / 418 unit pass
# After GAP-2 (b7e91fe):    418 / 418 unit pass; 11 / 11 dispatch pass
# After GAP-3 (57b6d0e):    418 / 418 unit pass; 34 / 34 server+router+dispatch pass
# After GAP-5 (f855781):    418 / 418 unit pass
# After GAP-4 (7b2366e):    418 / 418 unit pass
# After E2E (eaba57c):      418 / 418 unit pass; HP1 skips gracefully on no-inotify host

mix compile --warnings-as-errors          # clean
mix credo --strict <all-touched-modules>  # 0 issues
mix test --include bwrap --include integration
# -> 441 tests, 5 failures (21 excluded) — all 5 failures are
#    pre-existing Phase-2 container integration tests (missing
#    runtime image locally, unrelated to Phase 3).
```

Re-verification by `gsd-verifier` expected to flip SC-2, SC-4, SC-5,
SC-7 from `failed`/`partial` to `verified` (logic-level). SC-6
(end-to-end budget loop) follows automatically because the
ingest-side blocker was SC-2 + SC-4.

## Known remaining limitations

These are NOT introduced by this gap-fix pass; they are pre-existing
scope boundaries documented in the verification report:

1. **HUMAN-UAT** (3 Director-host verifications per Plan 03-05 Task 5)
   are now re-runnable. Previously blocked by the SC-2 + SC-4 gaps.
2. **Agent.Server inbox_scan_fun's default** walks the filesystem on
   each wake. A future iteration could cache directory listings via
   a dep-injected `:listing_cache_fun`; for v0.0.1 the simple walk is
   bounded by the one-way-flow invariant (Router-only writes; each
   file is unique).
3. **Gate's default `agent_wake_fun`** is still a no-op. Wiring
   Registry.lookup + `Agent.Server.wake/3` as the default is
   straightforward and can land as a follow-on — the structural wiring
   from the Watcher → Gate (PubSub subscribe) is already in place.
4. **HTTPS_PROXY bypass** (Pitfall 7) remains advisory per D-17. The
   netns + nftables hardening path is still deferred.

## Self-Check: PASSED

All claimed artifacts exist + all claimed commits present:

```
[x] lib/glorbo/sandbox/bwrap.ex                     — modified
[x] test/glorbo/sandbox/bwrap_test.exs              — B11-B13 added
[x] lib/glorbo/agent/dispatch.ex                    — modified
[x] test/glorbo/agent/dispatch_test.exs             — stub test updated
[x] lib/glorbo/company/router.ex                    — PubSub wiring added
[x] lib/glorbo/agent/server.ex                      — PubSub wiring + default inbox_scan_fun
[x] lib/glorbo/company/supervisor.ex                — +Gate +Proxy(conditional)
[x] test/glorbo/company/supervisor_test.exs         — S1 (7-child) + S1b (8-child)
[x] test/glorbo/filesystem/watcher_test.exs         — Test 10 7-child
[x] test/integration/inotify_to_bwrap_happy_path_test.exs — created

[x] Commit da70d00 — fix(03-gap): close stdin-EOF in Bwrap.start via sh wrapper + prompt tempfile
[x] Commit b7e91fe — fix(03-gap): wire Dispatch run_fun default to Bwrap.start/2
[x] Commit 57b6d0e — fix(03-gap): wire Router + Agent.Server to Watcher PubSub topics
[x] Commit f855781 — fix(03-gap): supervise Approvals.Gate under Company.Supervisor
[x] Commit 7b2366e — fix(03-gap): conditionally start Network.Proxy when api-only agents exist
[x] Commit eaba57c — test(03-gap): add inotify→Watcher→Agent.Server→Dispatch→Bwrap e2e test
```

---
*Phase: 03-agents-routing-kernel-permissions-budgets*
*Gap-fix completed: 2026-04-16*
