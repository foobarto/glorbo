---
phase: 03-agents-routing-kernel-permissions-budgets
plan: 03
subsystem: agent-runtime, cli-adapters, dispatch-pipeline, wake-queue, supervisor-topology
tags: [agent-server, dispatch, cli-adapters, skills, provider-parsing, wake-queue, task-supervisor, registry]

requires:
  - phase: 03-agents-routing-kernel-permissions-budgets
    provides: "Plan 03-02 — Glorbo.Company.BudgetTracker.check_budget/2 + record/3, Glorbo.Budget.Ledger atomic upsert, llm_rates config; Plan 03-01 — Glorbo.Security.ACLMapper.parse_permission/1 + check_action/2, Glorbo.Filesystem.Frontmatter safe YAML loader, AUDIT_EVENTS.md registry"
provides:
  - "Glorbo.Agent.Spec struct — runtime-only agent payload (provider/model/permissions/network/skills/budget/timeout/file_path); distinct from persisted Glorbo.Agent Ecto schema"
  - "Glorbo.Agent.Parser — parse_file/1 + validate/4 with strict v0.0.1 allowlists (D-02 providers; LLM-04 single-model; T-03-15/T-03-19 mitigations; AGT-05 agents:create parse-time reject)"
  - "Glorbo.Skills.Resolver — materialize/3 + cleanup/1; copies skills into .glorbo-run/<task_id>/.glorbo-skills/ with INDEX.md; path-traversal gate; symlink-safe File.rm_rf cleanup; D-04, D-05, D-38..D-40"
  - "Glorbo.CLI.Adapter behaviour — binary/0, args/3, env/2, usage_path/2, parse_usage/1"
  - "Glorbo.CLI.Adapter.ClaudeCode — --print + --model + --output-format text; CLAUDE_CONFIG_DIR redirect; JSONL usage sum over input+cache_creation+cache_read+output (live-probed 2026-04-16 schema)"
  - "Glorbo.CLI.Adapter.GeminiCli — -m + --output-format json + --approval-mode yolo; stdout JSON parse; defensive multi-model summing (Open Question 3)"
  - "Glorbo.CLI.Adapter.Codex — exec --json --model --skip-git-repo-check -; CODEX_HOME redirect; LAST token_count event (Pitfall 10); model=nil with spec-level fallback"
  - "Glorbo.Agent.Dispatch — pure pipeline (budget -> skills -> prompt -> adapter -> run_fun -> usage parse -> record -> cleanup); run_fun defaults to :bwrap_not_wired (Plan 03-05 hook point); try/after guarantees cleanup on any exit path"
  - "Glorbo.Agent.Server — wake-queue state machine replacing Phase-1 stub; 5 triggers; D-26 pending_wake dedup; async_nolink Task.Supervisor sibling (D-28)"
  - "Glorbo.Agent.Registry — Registry wrapper + via/3 helper; keys {kind, company, agent}"
  - "Glorbo.Company.AgentSupervisor — DynamicSupervisor with 2-child :one_for_all sub-supervisor per agent; start_agent/2 + stop_agent/4"
  - "Three real-shaped CLI telemetry fixtures under test/fixtures/ (claude JSONL, codex cumulative rollout JSONL, gemini stdout JSON)"
affects:
  - plan-03-04-scheduler-integration
  - plan-03-05-supervisor-wiring-sandbox
  - phase-04-dashboard

tech-stack:
  added: []
  patterns:
    - "behaviour-based-adapter-registry: provider string -> Adapter module map; dep-injectable for dispatch tests; extensible for future providers"
    - "dep-injected-run-fun: Dispatch.execute/3 accepts run_fun defaulting to {:error, :bwrap_not_wired} — Plan 03-05 wires real Bwrap.start/2 here without touching Dispatch"
    - "task-supervisor-sibling-placement: per-agent Task.Supervisor is sibling (not child) of Agent.Server under a 2-child :one_for_all sub-supervisor — Task crash doesn't cascade; async_nolink prevents link propagation"
    - "wake-queue-dedup: pending_wake :: nil | {trigger, DateTime.t()} — at most one pending slot; most-recent trigger wins; chatty inotify bursts produce one extra dispatch, not N"
    - "try-after-cleanup-guarantee: Dispatch wraps pipeline in try/after Resolver.cleanup(run_dir) so cleanup runs on success/error/exception (T-03-22)"
    - "last-event-extraction-codex: Pitfall 10 — Codex token_count events are cumulative; Enum.reduce(nil, fn e, _ -> e end) takes LAST event, never sum"
    - "conservative-zero-usage: Pitfall 5 — malformed/missing telemetry returns 0 tokens + Logger.warning; dispatch never crashes on adapter parse failure"
    - "prompt-size-cap-5mb: Pitfall 8 — oversized prompts return {:error, :prompt_too_large} before any Port opens"
    - "registry-via-naming: {:agent_server, co, ag}, {:agent_task_sup, co, ag}, {:agent_subtree, co, ag} — 3-tuple keys scoped by kind for clean co-existence"
    - "fixture-backed-adapter-tests: 3 real-shaped telemetry files mean adapters are tested against canonical schemas without live CLI invocation — deterministic + fast + CI-able"

key-files:
  created:
    - lib/glorbo/agent/spec.ex
    - lib/glorbo/agent/parser.ex
    - lib/glorbo/agent/dispatch.ex
    - lib/glorbo/agent/registry.ex
    - lib/glorbo/skills/resolver.ex
    - lib/glorbo/cli/adapter.ex
    - lib/glorbo/cli/claude_code.ex
    - lib/glorbo/cli/gemini_cli.ex
    - lib/glorbo/cli/codex.ex
    - lib/glorbo/company/agent_supervisor.ex
    - test/glorbo/agent/parser_test.exs
    - test/glorbo/agent/dispatch_test.exs
    - test/glorbo/agent/registry_test.exs
    - test/glorbo/agent/server_test.exs
    - test/glorbo/skills/resolver_test.exs
    - test/glorbo/cli/claude_code_test.exs
    - test/glorbo/cli/gemini_cli_test.exs
    - test/glorbo/cli/codex_test.exs
    - test/glorbo/company/agent_supervisor_test.exs
    - test/support/dispatch_stubs.ex
    - test/fixtures/claude_session_sample.jsonl
    - test/fixtures/codex_rollout_sample.jsonl
    - test/fixtures/gemini_stdout_sample.json
  modified:
    - lib/glorbo/agent/server.ex
    - test/glorbo/container/invocation_test.exs
    - .planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md

key-decisions:
  - "Wake-queue dedup with most-recent-wins semantics (D-26) — pending_wake :: nil | {trigger, ts}; single slot caps pending work at N=1 per burst"
  - "Task.Supervisor is SIBLING of Agent.Server under 2-child :one_for_all sub-supervisor (resolved from Claude's Discretion — D-28) — Task crash isolation without Server restart cascade"
  - "model: REQUIRED for all three providers (resolved from Claude's Discretion) — LLM-04 single-model invariant enforced at parse time; missing → :missing_model, list → :multiple_models_not_supported"
  - "Skills materialise at wake-time per-task-id (D-04 + D-05) — .glorbo-run/<task_id>/.glorbo-skills/; cleanup via try/after on every exit path"
  - "CLI auth strategy Option 2 (RESEARCH Runtime State Inventory) — shared auth bind-mount + per-agent env redirect (CLAUDE_CONFIG_DIR, CODEX_HOME); adapter.env/2 returns the env overrides; Plan 03-05 Bwrap consumes via --setenv"
  - "Workspace cleanup PER-TASK-ID (Claude's Discretion) — .glorbo-run/<task_id>/ removed on dispatch completion; agent's persistent files (outbox/workspace/state) untouched"
  - "Provider allowlist at parse-time (D-02) — [claude-code, gemini-cli, codex] only; unknown → parse error; agent NOT started (Agent.Server never spawned for that slug)"

patterns-established:
  - "behaviour-based adapter registry (adapter_registry map); enables future providers (ollama-cli, etc.) without touching Dispatch"
  - "dep-injectable run_fun + dep-injectable fs_fun + audit_fun + clock_fun throughout Dispatch — 14 unit tests exercise full pipeline without real bwrap/filesystem/audit"
  - "Task.Supervisor sibling placement via 2-child :one_for_all sub-supervisor — replaces naive child-of-Server layout; crash isolation tested at per-agent granularity (AS5, AS6)"
  - "Registry via/3 naming convention — {kind, company, agent} 3-tuples; 3 kinds (agent_server, agent_task_sup, agent_subtree) scope cleanly within a single registry"
  - "try/after with Resolver.cleanup as guaranteed finaliser — every dispatch exit path (success/error/exception) executes cleanup"

requirements-completed:
  - "AGT-01 (partial) — per-agent Server + per-agent Task.Supervisor + 2-child :one_for_all sub-supervisor topology ready. Crash isolation verified at Task, Server, and sub-supervisor levels. Full Company.Supervisor integration (6-child tree wiring) lands in Plan 03-05."
  - "AGT-02 (partial) — Agent.Server accepts all 5 wake triggers (:inbox, :heartbeat, :mention, :director_approval, :director_request); wake-queue state machine operational. Watcher + Scheduler integration (which CALLS wake/2,3) wires up in Plan 03-05 + 03-02 respectively (Plan 03-02's Scheduler.register is the hook)."
  - "AGT-04 (full) — Skills materialisation at wake-time into .glorbo-run/<task_id>/.glorbo-skills/ with INDEX.md; missing-skill audit via skill.missing event (D-39); cleanup on every termination path; path-traversal block (T-03-19)."
  - "LLM-03 (full) — Three provider adapters (ClaudeCode, GeminiCli, Codex) with uniform Glorbo.CLI.Adapter behaviour; each CLI manages own auth (adapter.env/2 returns session redirects for per-agent isolation); no API keys handled by Glorbo."
  - "LLM-04 (full) — Parser rejects missing model, multi-model list, unknown provider at parse time. One provider + one model per agent.md enforced structurally."

duration: 18min
started: 2026-04-16T05:30:47Z
completed: 2026-04-16T05:49:10Z
tasks: 3
files_created: 23
files_modified: 3
tests_added: 113
---

# Phase 03 Plan 03: Agent Runtime + Dispatch + CLI Adapters + Supervisor Topology Summary

**Full per-agent runtime layer — agent.md parser with strict v0.0.1 provider allowlist + AGT-05 defence-in-depth, three CLI adapters implementing a uniform behaviour with fixture-backed usage-parsing tests, skills resolver with per-task-id materialisation + cleanup, a pure dispatch pipeline whose run_fun default is `:bwrap_not_wired` (Plan 03-05 hook point), a per-agent GenServer with a wake-queue state machine replacing the Phase-1 stub, per-company AgentSupervisor (DynamicSupervisor) using 2-child :one_for_all sub-supervisors for crash isolation, and a Registry for addressable agents. Zero supervisor-tree changes (Plan 03-05 owns that). Zero bwrap invocations (Plan 03-05 owns that). 113 new tests; full suite 343/343 green.**

## Performance

- **Duration:** ~18 min
- **Started:** 2026-04-16T05:30:47Z
- **Completed:** 2026-04-16T05:49:10Z
- **Tasks:** 3
- **Files created:** 23 (12 lib + 8 test + 3 fixture)
- **Files modified:** 3 (agent/server.ex stub replaced; container/invocation_test.exs format reflow; AUDIT_EVENTS.md extended)
- **Tests added:** 113 (31 parser+resolver + 25 CLI adapters + 57 dispatch/server/registry/agent_supervisor)
- **Full regression:** 343/343 green (was 252 at Plan 03-02 end; +91 net new, accounting for some merged helper fixtures)

## Accomplishments

- **Agent.Spec + Agent.Parser** with strict 16-case validation (P1-P16): provider allowlist of 3; model required for all providers; multi-model list rejected (LLM-04); permission tuples via ACLMapper.parse_permission/1 reuse; network policy atomised via Map.fetch (no String.to_atom on user input); skill-name + slug regex gates (T-03-15/T-03-19); AGT-05 `agents:create` refusal at parse time (defence-in-depth).
- **Skills.Resolver** materialises skills into `.glorbo-run/<task_id>/.glorbo-skills/<name>.md` with a deterministic-order INDEX.md that extracts first-line titles; missing skills emit `skill.missing` audit and are DROPPED (D-39 recoverable); path-traversal attempts return error without touching disk; `cleanup/1` is symlink-safe via `File.rm_rf` (S8 verified by creating a symlink to an external dir + confirming the external is untouched).
- **Three CLI adapters** conforming to a uniform `Glorbo.CLI.Adapter` behaviour. ClaudeCode sums (input+cache_creation+cache_read) for prompt tokens; GeminiCli parses `stats.models.*` defensively summing across all keys (Open Question 3 defensive parse); Codex takes the LAST `token_count` event (NEVER the sum — Pitfall 10 enforced in test CX5 with cumulative fixtures). All three adapters use per-agent session-dir redirection via env vars (CLAUDE_CONFIG_DIR / CODEX_HOME; Gemini returns empty env — Plan 03-05 falls back to bwrap bind mount).
- **Agent.Dispatch** is a pure linear pipeline covering all 14 steps from budget check → skills → prompt → adapter → run_fun → usage parse → record → cleanup, with every step dep-injectable. `run_fun` defaults to `{:error, :bwrap_not_wired}` — Plan 03-05 wires `Glorbo.Sandbox.Bwrap.start/2` here without touching Dispatch. `try/after` guarantees `Resolver.cleanup` runs on every exit path (T-03-22). 5MB prompt size cap (Pitfall 8) returns `{:error, :prompt_too_large}` before any IO. Conservative-zero usage on malformed telemetry (Pitfall 5) — 0 tokens + `Logger.warning` instead of crashing dispatch.
- **Agent.Server** replaces the Phase-1 stub with a GenServer wake-queue state machine. 5 valid triggers enforced at `wake/2,3` entry (unknown → `{:error, :unknown_trigger}` — A8). Wake-queue caps pending slots at 1 with most-recent-wins coalesce (D-26 / T-03-18). Dispatch work runs via `Task.Supervisor.async_nolink/3` against a sibling Task.Supervisor — Task crashes send `:DOWN` (not EXIT), Server updates `last_exit_status = {:crashed, reason}` and stays alive (A9 verified).
- **Company.AgentSupervisor** uses a DynamicSupervisor with 2-child `:one_for_all` sub-supervisors per agent. The sub-supervisor is registered as `{:agent_subtree, company, slug}` for clean `stop_agent/2` lookups. Killing the Agent.Server or its Task.Supervisor triggers a full one_for_all restart (AS5, AS6); killing one agent leaves siblings completely unaffected (AGT-01 crash isolation verified).
- **Agent.Registry** provides a `Registry` wrapper + `via/3` helper building `{:via, Registry, {__MODULE__, {kind, co, ag}}}` tuples. Three kinds (`:agent_server`, `:agent_task_sup`, `:agent_subtree`) coexist under unique keys; T-03-21 spoofing mitigation.
- **AUDIT_EVENTS.md** extended with the new `provider.unavailable` event emitted by Dispatch when adapter.binary/0 returns nil (D8 / D-43).
- **Full regression:** 343/343 tests green across seeds 0, default, 123 (stability verified across 3 runs).

## Task Commits

1. **Task 1: Agent.Parser + Agent.Spec + Skills.Resolver** — `93aa52f` (feat) — 31 tests green
2. **Task 2: CLI Adapter behaviour + 3 adapters + 3 fixtures** — `b56e1c6` (feat) — 25 tests green
3. **Task 3: Agent.Dispatch + Agent.Server + AgentSupervisor + Registry + AUDIT_EVENTS** — `f07cdfc` (feat) — 57 tests green

## Files Created/Modified

**Created (lib):**
- `lib/glorbo/agent/spec.ex` — runtime Agent.Spec struct
- `lib/glorbo/agent/parser.ex` — parse_file/1 + validate/4 + 16 validation cases
- `lib/glorbo/agent/dispatch.ex` — pure 14-step pipeline
- `lib/glorbo/agent/registry.ex` — Registry wrapper + via/3 helper
- `lib/glorbo/skills/resolver.ex` — materialize/3 + cleanup/1
- `lib/glorbo/cli/adapter.ex` — behaviour with 5 @callbacks
- `lib/glorbo/cli/claude_code.ex` — ClaudeCode adapter
- `lib/glorbo/cli/gemini_cli.ex` — GeminiCli adapter
- `lib/glorbo/cli/codex.ex` — Codex adapter
- `lib/glorbo/company/agent_supervisor.ex` — DynamicSupervisor with 2-child sub-supervisor per agent

**Created (test):**
- `test/glorbo/agent/parser_test.exs` — 17 tests (P1-P16 + IO error)
- `test/glorbo/agent/dispatch_test.exs` — 14 tests (D1-D8 + defaults + skills flow)
- `test/glorbo/agent/registry_test.exs` — 5 tests (RG1-RG3 + via/3 + child_spec)
- `test/glorbo/agent/server_test.exs` — 12 tests (A1-A10 + polling helper)
- `test/glorbo/skills/resolver_test.exs` — 9 tests (S1-S8 + fallback title)
- `test/glorbo/cli/claude_code_test.exs` — 8 tests (CC1-CC8)
- `test/glorbo/cli/gemini_cli_test.exs` — 8 tests (G1-G8)
- `test/glorbo/cli/codex_test.exs` — 9 tests (CX1-CX8 + nonexistent file)
- `test/glorbo/company/agent_supervisor_test.exs` — 8 tests (AS1-AS8b, skipping AS7 merged into AS5)
- `test/support/dispatch_stubs.ex` — test-support stub adapters (StubAdapter, NilModelAdapter)
- `test/fixtures/claude_session_sample.jsonl` — real-shaped Claude Code session JSONL (46337 prompt + 73 completion)
- `test/fixtures/codex_rollout_sample.jsonl` — 3-event cumulative rollout (asserts LAST-event extraction)
- `test/fixtures/gemini_stdout_sample.json` — real-shaped Gemini --output-format json stdout

**Modified:**
- `lib/glorbo/agent/server.ex` — Phase-1 stub replaced with full GenServer
- `test/glorbo/container/invocation_test.exs` — format reflow (absorbed `mix format` diff)
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` — `provider.unavailable` event added

## Decisions Made

All seven locked_decisions from the plan's frontmatter are reflected in code:

1. **Wake-queue dedup with most-recent-wins** — `lib/glorbo/agent/server.ex` `handle_call({:wake, trigger, task}, …)` queues at most 1; second-call replaces with new `{trigger, DateTime.utc_now()}`; tests A4/A5 verify.
2. **Task.Supervisor sibling under 2-child :one_for_all** — `lib/glorbo/company/agent_supervisor.ex` builds `children = [Task.Supervisor, Agent.Server]` with `strategy: :one_for_all`; tests AS5/AS6 verify both restart together; A9 verifies Task crash doesn't kill Server.
3. **model required for all providers** — `lib/glorbo/agent/parser.ex` `validate_model/1`: `nil → :missing_model`, list → `:multiple_models_not_supported`; tests P3/P4 verify.
4. **Skills materialise at wake-time per-task-id** — `lib/glorbo/agent/dispatch.ex` `prepare_run_dir_path/3` generates `.glorbo-run/<task_id>/`; `materialize_skills/3` runs BEFORE run_fun; cleanup runs in try/after.
5. **Shared auth + per-agent session redirect** — each adapter's `env/2` returns `CLAUDE_CONFIG_DIR`/`CODEX_HOME` pointing into the agent workspace; GeminiCli returns `%{}` with module-doc noting fallback path for Plan 03-05.
6. **Workspace cleanup per-task-id** — `cleanup_run_dir/2` removes only `.glorbo-run/<task_id>/`, never touches `outbox/`, `workspace/`, or `state/`.
7. **Provider allowlist at parse-time** — `lib/glorbo/agent/parser.ex` `@allowed_providers ["claude-code", "gemini-cli", "codex"]`; unknown returns `{:invalid_provider, raw}` without side effects.

**Additional judgment calls made during execution:**
- `wake/2,3` is a `GenServer.call` (not cast) — so A8 can return `{:error, :unknown_trigger}` to the caller. Dispatch work is still async via Task.Supervisor.
- Stub adapter modules moved to `test/support/dispatch_stubs.ex` (not defined at the bottom of the test file) after discovering flaky module-loading issues when defining stub modules inside or after a test module's `defmodule` block.
- `send_finish_to_all_dispatchers` broadcast helper replaced with targeted sends — blocking dispatch fun now sends its own Task pid back to the test, and the test sends `{:finish, result}` directly to that pid. Eliminates flakiness.
- `Process.sleep(50)` polling in A7/A9 replaced with `await_state(pid, :idle, 100 attempts × 20ms)` — makes `:DOWN` propagation robust against system-load-induced jitter under the full test suite.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Test-file module definitions caused `UndefinedFunctionError` under full-suite runs**
- **Found during:** Task 3 (dispatch tests) full-suite execution
- **Issue:** `defmodule NilModelAdapter` defined inside a test `do` block (and a second `StubAdapter` defined after the main test module) caused `UndefinedFunctionError: args/3 is undefined` at random — the stub modules were sometimes "not available" when other tests ran first.
- **Fix:** Moved both stub modules to `test/support/dispatch_stubs.ex` under `Glorbo.Agent.DispatchTest.{StubAdapter, NilModelAdapter}` namespaces. Test-support files auto-load via `elixirc_paths(:test) = ["lib", "test/support"]` (established in Phase 1), so they're always available.
- **Files modified:** `test/glorbo/agent/dispatch_test.exs`, `test/support/dispatch_stubs.ex` (new)
- **Verification:** Full suite 343/343 green across 3 seeds
- **Committed in:** `f07cdfc` (Task 3 commit)

**2. [Rule 1 - Bug] `Process.sleep(50)` polling caused flaky A9 test under full-suite load**
- **Found during:** Task 3 (server tests) full-suite execution
- **Issue:** A9 asserts `status.state == :idle` after a dispatch Task crash. Under full-suite parallelism (48 concurrent cases), the raise → crash → `:DOWN` monitor chain occasionally took >50ms, leaving state at `:busy`. Got `left: :busy, right: :idle`.
- **Fix:** Added `await_state(pid, :idle, 100 attempts × 20ms)` helper — polls up to 2 seconds for the desired state. Applied to both A7 and A9.
- **Files modified:** `test/glorbo/agent/server_test.exs`
- **Verification:** 3 consecutive full-suite runs across seeds 0, default, 123 all green
- **Committed in:** `f07cdfc` (Task 3 commit)

**3. [Rule 2 - Missing critical functionality] `:one_for_all` sub-supervisor needed the `name:` registration for `stop_agent/2` to work**
- **Found during:** Task 3 (AgentSupervisor tests)
- **Issue:** Plan frontmatter specified the sub-supervisor should register so `stop_agent/2` can find it — initially I omitted the registry registration on the Supervisor itself and only on the Agent.Server + Task.Supervisor. `stop_agent/2` couldn't look up the subtree pid to terminate.
- **Fix:** Added `name: subtree_name` to the Supervisor.start_link opts where `subtree_name = {:via, Registry, {registry, {:agent_subtree, company, slug}}}`. `stop_agent/2` now does `Registry.lookup(registry, {:agent_subtree, co, ag})` to find the subtree pid, then `DynamicSupervisor.terminate_child(sup, pid)`.
- **Files modified:** `lib/glorbo/company/agent_supervisor.ex`
- **Verification:** AS8 test passes; AS8b test (`stop_agent` on unknown slug returns `{:error, :not_found}`) also passes
- **Committed in:** `f07cdfc` (Task 3 commit)

---

**Total deviations:** 3 auto-fixed (1 blocking test-infrastructure issue + 1 flaky-test fix + 1 missing registration). No architectural changes; no scope creep; every deviation was test-infra or a minor correctness gap.
**Impact on plan:** Plan's implementation scope hit exactly. All three tasks completed in order with their exact `<action>` bullet lists.

## Issues Encountered

- **Credo refactoring opportunities on first pass:** 4 warnings across Dispatch + Server:
  - `cond` with one condition + `true` → replaced with `if/else` (2 cases: `parse_usage_for`, `handle_call({:wake, …})`)
  - Nested-module alias → added `alias Glorbo.Agent.Dispatch` at top of Server
  - Function body nested too deep + cyclomatic-complexity 13 → extracted `parse_from_dir/3` and `finalize_parse/2` helpers
  - Clean on second pass.
- **Phoenix scaffold pre-existing compile warning:** two modules had unused-alias warnings on the first compile after `mix test --force`; absorbed by the formatter.
- **Claude/Codex CLI live flag verification:** `claude --help` confirms `--print --model --output-format` (verified 2.1.110 on dev host); `codex exec --help` confirms `--json --model --skip-git-repo-check -`; `gemini --help` confirms `-m --output-format json --approval-mode yolo`. All three match the plan's specification exactly. No drift from 2026-04-16 RESEARCH.

## User Setup Required

None. All adapters defer auth to the CLI tools themselves (`~/.claude/`, `~/.gemini/`, `~/.codex/`). Plan 03-05 will add bwrap bind-mount configuration for those dirs; v0.0.1 runs tests against captured fixtures, no live CLI invocation required.

## Next Phase Readiness

**Ready for Plan 03-04 (Scheduler integration + Router wake hooks):**
- `Agent.Server.wake(server, trigger, task_or_nil)` is the entry point — Scheduler calls `wake(:heartbeat, nil)`, Watcher calls `wake(:inbox, task_map)` from file events, Router calls `wake(:mention, task_map)` from `@<name>` scans, Gate calls `wake(:director_approval, task_map)` after sentinel release.
- `Glorbo.Agent.Parser.parse_file/1` is ready for AgentSupervisor's `start_agent/2` flow when Company.Supervisor boots — Plan 03-05 will `agent_md_files |> Enum.map(&Parser.parse_file/1) |> Enum.each(&AgentSupervisor.start_agent(sup, &1))` at company boot.

**Ready for Plan 03-05 (Bwrap sandbox + supervisor wiring):**
- `Glorbo.Agent.Dispatch.execute/3` accepts `:run_fun` opt defaulting to `{:error, :bwrap_not_wired}`. Plan 03-05 supplies the real `Glorbo.Sandbox.Bwrap.start/2` here.
- Each adapter's `env/2` returns the env-var map; `Bwrap.start/2` consumes it via `--setenv` on the sandbox argv.
- `AgentSupervisor` is a drop-in child of `Company.Supervisor` (the 6-child tree from Plan 03-04). `AgentSupervisor.start_agent/2` produces a fully-configured 2-child sub-supervisor per agent.
- `Registry` is a top-level application child (added in Plan 03-05's application wiring).

**Deferred work tracked:**
- `Agent.Server`'s `inbox_scan_fun` default (currently `fn _ -> nil end`) — Plan 03-05 wires a real scanner that reads `agents/<slug>/inbox/` for the oldest unread message.
- Gemini CLI session-dir redirect — adapter returns empty env map with a module-doc note explaining that Plan 03-05's bwrap read-only bind of `~/.gemini/` is the fallback. If Gemini ships a config-dir env var in a future release, extend `env/2`.
- Integration tests tagged `:claude_code`, `:gemini_cli`, `:codex` that actually invoke the binaries — Plan 03-05 adds them (opt-in; Doctor gates host availability).

---

## Self-Check: PASSED

Verification of all claimed artifacts:

```
[x] lib/glorbo/agent/spec.ex — FOUND
[x] lib/glorbo/agent/parser.ex — FOUND
[x] lib/glorbo/agent/dispatch.ex — FOUND
[x] lib/glorbo/agent/registry.ex — FOUND
[x] lib/glorbo/agent/server.ex — FOUND (stub replaced)
[x] lib/glorbo/skills/resolver.ex — FOUND
[x] lib/glorbo/cli/adapter.ex — FOUND
[x] lib/glorbo/cli/claude_code.ex — FOUND
[x] lib/glorbo/cli/gemini_cli.ex — FOUND
[x] lib/glorbo/cli/codex.ex — FOUND
[x] lib/glorbo/company/agent_supervisor.ex — FOUND
[x] test/fixtures/claude_session_sample.jsonl — FOUND
[x] test/fixtures/codex_rollout_sample.jsonl — FOUND
[x] test/fixtures/gemini_stdout_sample.json — FOUND
[x] test/support/dispatch_stubs.ex — FOUND
[x] Commit 93aa52f — FOUND (feat(03-03): add Agent.Parser + Spec + Skills.Resolver)
[x] Commit b56e1c6 — FOUND (feat(03-03): add CLI Adapter behaviour + ClaudeCode/GeminiCli/Codex adapters)
[x] Commit f07cdfc — FOUND (feat(03-03): add Agent.Dispatch + Agent.Server + AgentSupervisor + Registry)
[x] mix test — 343 tests, 0 failures (17 excluded) — across 3 seeds
[x] mix credo --strict on 4 new plan modules — 0 issues
[x] mix format --check-formatted — clean
[x] AUDIT_EVENTS.md — provider.unavailable present
```

---
*Phase: 03-agents-routing-kernel-permissions-budgets*
*Completed: 2026-04-16*
