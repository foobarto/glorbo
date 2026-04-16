---
phase: 03-agents-routing-kernel-permissions-budgets
plan: 02
subsystem: routing, scheduling, budget-enforcement
tags: [router, scheduler, budget, crontab, ecto-upsert, acl-enforcement, audit-events, dep-injection]

requires:
  - phase: 03-agents-routing-kernel-permissions-budgets
    provides: "Plan 03-01 — Budget Ecto schema with composite unique index, ACLMapper pure module (parse_permission/1, check_action/2), TasksApprovalState schema, AUDIT_EVENTS.md registry, crontab ~> 1.2 dep"
provides:
  - "Glorbo.Budget.Ledger — pure module with atomic {agent_slug, year_month} upsert via Ecto on_conflict [inc: [...]], integer-cents cost computation, UTC month bucket, Repo.get_by fetch"
  - "Glorbo.Company.BudgetTracker — GenServer with check_budget/2 (ok/alert/stop triage), record/3 cast, reload_config/1, dep-injected budgets_fun/audit_fun/fs_fun; alert file idempotency via alerts_fired MapSet; pre-dispatch hard-stop (D-32)"
  - "Glorbo.Company.Scheduler — GenServer driving cron heartbeats via Crontab.CronExpression.Parser + Crontab.Scheduler.get_next_run_date with wall-clock recompute on every firing (Pitfall 3); dep-injected clock_fun/send_after_fun"
  - "Glorbo.Company.Router — GenServer with permission-checked routing (ACLMapper.check_action/2), channel appends with [:append, :sync], agent-inbox writes, @mention fanout, categorical agents:create block (AGT-05), sender-slug anti-spoof (T-03-12), rejection artifacts + triple audit emission"
  - "config/llm_rates.exs — per-{provider, model} USD/Mtok rate table covering claude-code, gemini-cli, codex"
  - "config/network_policy.exs — api-only base allowlist per provider (read by Plan 03-05 Proxy)"
affects:
  - plan-03-03-agent-server-dispatch
  - plan-03-04-bwrap-sandbox
  - plan-03-05-supervisor-wiring
  - phase-04-dashboard

tech-stack:
  added: []
  patterns:
    - "atomic-ecto-upsert-via-on-conflict-inc: DB-level arithmetic increment race-free against concurrent writers"
    - "dep-injected-io-callbacks: clock_fun, send_after_fun, audit_fun, budgets_fun, fs_fun map — enables unit tests without IO"
    - "wall-clock-recompute-at-fire-time: cron Process.send_after drift-self-healing pattern"
    - "categorical-block-before-permission-check: belt+braces for AGT-05 (agents:create reject regardless of sender perms)"
    - "append-plus-sync-for-channel-writes: OS-level serialization for concurrent channel appends"
    - "filesystem-first-alert-marker: alerts/<agent>-budget.md one-per-month idempotency"

key-files:
  created:
    - lib/glorbo/budget/ledger.ex
    - config/llm_rates.exs
    - config/network_policy.exs
    - test/glorbo/budget/ledger_test.exs
    - test/glorbo/company/budget_tracker_test.exs
    - test/glorbo/company/scheduler_test.exs
    - test/glorbo/company/router_test.exs
  modified:
    - lib/glorbo/company/router.ex
    - lib/glorbo/company/scheduler.ex
    - lib/glorbo/company/budget_tracker.ex
    - config/config.exs
    - test/glorbo/stubs_test.exs
    - .planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md

key-decisions:
  - "Cents-integer math — inherited from Plan 03-01 D-31; no float drift in SUM aggregation; Ledger.compute_cost_cents/4 uses trunc(x + 0.5) half-up rounding"
  - "Atomic upsert via Ecto on_conflict: [inc: [...]] with conflict_target [:agent_slug, :year_month] — 10-Task concurrent race test green"
  - "Pre-dispatch-only hard-stop (D-32) — once BudgetTracker.check_budget/2 returns :ok the dispatch runs to completion; mid-invocation kills out of scope for v0.0.1"
  - "Sender slug derived from outbox file path, not from body's from: field (T-03-12 anti-spoof); mismatch -> invalid_message:sender_mismatch"
  - "Categorical agents:create block (AGT-05) — Router rejects non-existent agent targets BEFORE permission check, even if sender has hostile agents:create:* permission"
  - "Scheduler wall-clock recompute on every firing (Pitfall 3) — prevents Process.send_after drift under long VM pauses"
  - "BudgetTracker is sole writer of budgets table in production — tests that need direct writes go through Ledger.record!/1 which uses the same atomic upsert"
  - "record/3 is GenServer.cast (not call) — fire-and-forget; dispatch pipelines return immediately; failures logged via Logger.error but GenServer survives"
  - "Missing {provider, model} in llm_rates returns 0 cents + Logger.warning, does NOT raise (D-30 user-accepted undercount tradeoff)"

patterns-established:
  - "Dep-injectable IO via keyword opts: BudgetTracker, Scheduler, Router all accept fun/map opts for audit, fs, clock, send_after — tests swap mocks without touching real IO"
  - "Filesystem-first alert markers: file presence = state-exists signal; MapSet cache gives fast in-memory check to avoid hammering FS on repeat dispatches"
  - "Audit event triple on rejection: message.reject (ops trail) + permission.denied (SEC-01 ledger) + agents.create_blocked (AGT-05 specific)"
  - "Path-based sender authority: slug derived from `agents/<slug>/outbox/` dir (Elixir-owned) not trusted body fields"
  - "Fire-and-forget cast + best-effort semantics for usage recording — never crash the dispatch pipeline; log failures and continue"

requirements-completed: [AGT-02, AGT-03, AGT-05, SEC-01, SEC-05]

duration: 13min
completed: 2026-04-16
---

# Phase 03 Plan 02: Router + Scheduler + BudgetTracker Summary

**Per-company brain GenServers filled in — permission-checked routing with one-way flow enforcement + categorical agents:create block, cron-driven heartbeat wake with wall-clock recompute, and pre-dispatch USD budget gate with atomic Ecto upsert and idempotent alert markers. Zero new dependencies; all state derivable from SQLite + filesystem.**

## Performance

- **Duration:** ~13 min
- **Started:** 2026-04-16T05:14:53Z
- **Completed:** 2026-04-16T05:27:18Z
- **Tasks:** 3
- **Files modified:** 12
- **Tests added:** 46 (14 ledger + 13 budget_tracker + 7 scheduler + 12 router)

## Accomplishments

- **Budget.Ledger** pure-logic module with DB-atomic `on_conflict: [inc: [...]]` upsert on `(agent_slug, year_month)` unique index — survives 10-Task concurrent-write race test with exactly one row and correctly summed totals. Integer-cents cost computation from `config/llm_rates.exs` rate table; missing {provider, model} returns 0 + warning per D-30.
- **BudgetTracker** GenServer with `check_budget/2` three-way triage (`:ok | {:alert, used, cap} | {:stop, used, cap}`) + once-per-month idempotent alert file + hard-stop audit on every denied dispatch. `record/3` cast computes cost via `Ledger.compute_cost_cents/4`, upserts via `Ledger.record!/1`, emits `budget.usage` audit. Crash-recovery verified: state rebuilds from Repo after `Process.exit(pid, :kill)`.
- **Scheduler** GenServer parsing cron via `Crontab.CronExpression.Parser.parse/1` (non-bang), arming one-shot `Process.send_after` timers, recomputing next-run from wall-clock on every firing (Pitfall 3 self-healing). Invalid cron emits `scheduler.invalid_cron` audit and returns `{:error, :invalid_cron}` — offending agent is skipped, Scheduler stays alive.
- **Router** GenServer with full pipeline (`validate → verify_sender_slug → parse_to → reject_broadcast → reject_agent_create → ACLMapper.check_action/2 → perform_routing → maybe_route_mentions → audit`). Channel writes use `[:append, :sync]` for OS-level race safety (20-Task concurrent-append test yields exactly 20 lines). Rejections produce a three-artifact trail: `history/<id>.rejected.md` + sender `inbox/rejections/<ts>-<id>.md` + audit triple. `@mention` regex fans out to target agents' `inbox/mentions/` with `agent.wake` audit.
- **AUDIT_EVENTS.md** extended with two new keys: `agents.create_blocked` (AGT-05 specific) and `scheduler.invalid_cron` (T-03-11).
- **Full regression:** 252/252 tests green (206 baseline + 46 new).

## Task Commits

1. **Task 1: Budget.Ledger + llm_rates config + atomic upsert coverage** — `c49e8db` (feat)
2. **Task 2: BudgetTracker GenServer (pre-dispatch check + alert + hard-stop)** — `264c243` (feat)
3. **Task 3: Scheduler + Router GenServers + AUDIT_EVENTS extension** — `d4785c2` (feat)

## Files Created/Modified

**Created:**
- `lib/glorbo/budget/ledger.ex` — Pure-logic upsert + cost computation (pattern: `on_conflict: [inc: [...]]` with `conflict_target: [:agent_slug, :year_month]`)
- `config/llm_rates.exs` — Rate table for claude-opus-4-6 ($15/$75), claude-sonnet-4-5 ($3/$15), gemini-2.5-pro ($1.25/$10), gemini-2.5-flash ($0.30/$2.50), gpt-5 ($10/$30), o3-mini ($3/$12)
- `config/network_policy.exs` — api-only base allowlist (api.anthropic.com, generativelanguage.googleapis.com, api.openai.com etc.) for Plan 03-05 Proxy
- `test/glorbo/budget/ledger_test.exs` — 14 tests (cost math, rounding, month bucket, atomic upsert under 10-Task concurrency)
- `test/glorbo/company/budget_tracker_test.exs` — 13 tests (gate triage, alert idempotency, hard-stop, crash recovery, 20-Task concurrent record)
- `test/glorbo/company/scheduler_test.exs` — 7 tests (register/unregister, invalid cron audit, send_after capture, heartbeat fire + re-arm, stateless-across-restarts)
- `test/glorbo/company/router_test.exs` — 12 tests (chat/agent routing, permission denial, agent-create block, mention fanout, sender spoofing, broadcast rejection, 20-Task concurrent append, rejection artifacts)

**Modified:**
- `lib/glorbo/company/router.ex` — Stub → full pipeline with 9 rejection reason codes
- `lib/glorbo/company/scheduler.ex` — Stub → cron-driven heartbeat with dep-injected clock
- `lib/glorbo/company/budget_tracker.ex` — Stub → full check_budget/record/reload_config API
- `config/config.exs` — Added `import_config "llm_rates.exs"` + `import_config "network_policy.exs"`
- `test/glorbo/stubs_test.exs` — Updated the Router `:not_implemented` assertion (Phase 1 stub) to a `function_exported?(:route, 2)` assertion now that Router is filled in
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` — Added `agents.create_blocked` + `scheduler.invalid_cron` rows

## Decisions Made

All five locked decisions from the plan's frontmatter are reflected in code:
- Cents-integer math throughout; `! grep -E 'Decimal\\.|Float\\.round' lib/glorbo/budget/ledger.ex` passes
- Router categorically rejects `agents:create` — `reject_agent_create/2` runs BEFORE `ACLMapper.check_action/2` regardless of sender permissions
- Scheduler recomputes next-run from wall-clock on every firing — `handle_info({:heartbeat, ...})` calls `arm_timer/4` which uses `state.clock_fun.()` fresh
- BudgetTracker is sole writer of `budgets` table — Ledger.record!/1 is the atomic primitive; tests prove concurrent writes summed correctly
- Hard-stop is pre-dispatch only — D-32 documented inline in BudgetTracker's `@moduledoc`

**Additional judgment calls made during execution:**
- Half-up rounding (`trunc(x + 0.5)`) chosen for `compute_cost_cents/4` over banker's-rounding — friendlier when alert thresholds round fractional cents up
- `record/3` is `GenServer.cast` not `call` — reasoned in `BudgetTracker.@moduledoc` (fire-and-forget; dispatch pipelines return immediately; failures logged but don't block)
- Router's `fs_fun` is an injectable map (not single function) — different ops (write, mkdir_p, exists?, open_append_sync) need different mock/real behaviors
- `handle_info({:rescan, _})` for BudgetTracker `alerts_fired` replay is deferred to Plan 03-05 supervisor wiring — v0.0.1 accepts that after crash the first check_budget per agent-month may re-write the alert file once (File.write! is content-idempotent)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Updated Phase-1 `not_implemented` assertion in stubs_test.exs**
- **Found during:** Task 3 (Router implementation)
- **Issue:** `test/glorbo/stubs_test.exs` asserted `Router.route(:anything, %{}) == {:error, :not_implemented}` — this was the Phase-1 stub's contract; now that Router is filled in, the assertion fails with a GenServer timeout (no registered process named `:anything`)
- **Fix:** Replaced with a `function_exported?(Router, :route, 2)` check — preserves the structural "module API is stable" intent of the original test; full behaviour is covered by the new `router_test.exs` with 12 cases
- **Files modified:** `test/glorbo/stubs_test.exs`
- **Verification:** `mix test` — 252/252 passing
- **Committed in:** `d4785c2` (Task 3 commit)

**2. [Rule 3 - Blocking] Fixed Scheduler test S3 expectation around crontab minute-precision**
- **Found during:** Task 3 (Scheduler tests)
- **Issue:** Test S3 used `~U[2026-04-16 12:00:00Z]` with `"*/30 * * * *"` expecting ~30min delay; crontab correctly returned the current moment because `12:00` matches `*/30` — delay=0ms, not ~1_800_000ms as asserted
- **Fix:** Changed test clock to `~U[2026-04-16 12:00:01Z]` (1s past aligned minute) so crontab's next match is `12:30:00` — delay ~1_799_000ms. Broadened the accept range to `> 1_700_000 and <= 1_800_000` to absorb minute-level precision
- **Files modified:** `test/glorbo/company/scheduler_test.exs`
- **Verification:** `mix test test/glorbo/company/scheduler_test.exs` — 7/7 green
- **Committed in:** `d4785c2` (Task 3 commit)

**3. [Rule 1 - Bug] Fixed BudgetTracker crash-recovery test link semantics**
- **Found during:** Task 2 (Test 11)
- **Issue:** Test used `start_link` directly to bypass supervisor (to test stateless-across-crashes D-45), but the link meant `Process.exit(pid, :kill)` cascaded to the test process
- **Fix:** Added `Process.unlink(pid)` after `start_link` so the `:kill` stays isolated to the GenServer
- **Files modified:** `test/glorbo/company/budget_tracker_test.exs`
- **Verification:** Test 11 now passes cleanly
- **Committed in:** `264c243` (Task 2 commit)

---

**Total deviations:** 3 auto-fixed (2 bugs + 1 blocking; all test-side; no production-code deviations)
**Impact on plan:** All three were test-infrastructure adjustments; plan's implementation scope was hit exactly. No scope creep.

## Issues Encountered

- **credo warnings on first pass:** two modules triggered `Path.dirname/1` unused-return and one `try do ... rescue` that could use implicit-try form. Refactored to assign `dir = Path.dirname(path)` before the `mkdir_p!` call and converted the explicit `try` to the implicit form. Clean on second pass.
- **Credo design suggestion for nested `Glorbo.Filesystem.Frontmatter` alias:** added `alias Glorbo.Filesystem.Frontmatter` to BudgetTracker and replaced the fully-qualified call site.
- **Pre-existing formatter drift:** `lib/glorbo/application.ex` and `lib/glorbo/filesystem/watcher.ex` had unrelated pre-existing multi-line/single-line formatter mismatches — absorbed into Task 1's commit since `mix format` reformatted them during the run.

## User Setup Required

None — no external services configured. `config/llm_rates.exs` + `config/network_policy.exs` are source-controlled defaults.

## Next Phase Readiness

**Ready for Plan 03-03 (Agent.Server + Dispatch + Skills):**
- `BudgetTracker.check_budget/2` is the gate Agent.Server calls pre-dispatch
- `BudgetTracker.record/3` is the cast Agent.Server calls post-dispatch after parsing CLI telemetry
- `Scheduler.register/3` is what AgentSupervisor will call during agent start-up

**Ready for Plan 03-05 (Supervisor + Watcher wiring):**
- Company.Supervisor will add the three new GenServers as children (AuditLog + Watcher already present → +Router + Scheduler + BudgetTracker + AgentSupervisor = 6 children)
- Watcher's outbox dispatch (currently `Logger.debug`) will call `Router.route/2`
- Router's `fs_fun.open_append_sync!` uses `File.open!/2 + [:append, :sync]` — this is the pattern Plan 03-05's integration test will exercise against live inotify events

**Deferred work properly tracked:**
- `handle_info({:rescan, _})` for BudgetTracker `alerts_fired` replay from `alerts/` dir on startup — Plan 03-05 supervisor wiring provides the init hook
- `perform_routing` for broadcast (`:broadcast` is currently rejected) — out of scope for v0.0.1 per plan locked decision
- netns + nftables for `api-only` — `config/network_policy.exs` allowlist is the handoff point; Plan 03-05 Proxy module will consume it

---

## Self-Check: PASSED

Verification of all claimed artifacts:

```
[x] /var/home/user/Documents/glorbo/lib/glorbo/budget/ledger.ex — FOUND
[x] /var/home/user/Documents/glorbo/config/llm_rates.exs — FOUND
[x] /var/home/user/Documents/glorbo/config/network_policy.exs — FOUND
[x] /var/home/user/Documents/glorbo/lib/glorbo/company/budget_tracker.ex — FOUND (filled)
[x] /var/home/user/Documents/glorbo/lib/glorbo/company/scheduler.ex — FOUND (filled)
[x] /var/home/user/Documents/glorbo/lib/glorbo/company/router.ex — FOUND (filled)
[x] Commit c49e8db — FOUND (feat(03-02): add Budget.Ledger with atomic upsert + llm_rates config)
[x] Commit 264c243 — FOUND (feat(03-02): implement BudgetTracker GenServer with pre-dispatch gate)
[x] Commit d4785c2 — FOUND (feat(03-02): implement Router + Scheduler GenServers + extend AUDIT_EVENTS)
[x] mix test — 252 tests, 0 failures (17 excluded)
[x] mix credo --strict on 4 plan modules — 0 issues
[x] mix format --check-formatted — clean
[x] AUDIT_EVENTS.md — agents.create_blocked present
[x] AUDIT_EVENTS.md — scheduler.invalid_cron present
```

---
*Phase: 03-agents-routing-kernel-permissions-budgets*
*Completed: 2026-04-16*
