---
phase: 03
slug: agents-routing-kernel-permissions-budgets
authored: 2026-04-16
nyquist_compliant: true
wave_0_complete: true
status: approved
---

# Phase 03: Validation Strategy

**Transcribed from:** `03-RESEARCH.md` §"Validation Architecture" (verified against live dev host 2026-04-16).

## Test Framework

| Property | Value |
|----------|-------|
| **Framework** | `ExUnit` (Elixir 1.18) + Python `pytest` (containers/ runtime — DORMANT in v0.0.1) |
| **Config file** | `test/test_helper.exs` (exists, from Phase 1+2) |
| **Quick run command** | `mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex` |
| **Full suite command** | `mix test` (runs everything including `:bwrap` tag if bwrap available) |
| **Estimated runtime** | Quick: ~5-15 sec; Full: ~60-120 sec (local) / skipped tagged tests in CI |

## Sampling Rate

| Trigger | Command |
|---------|---------|
| **Per task commit** | `mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex` (unit only; seconds) |
| **Per wave merge** | `mix test --exclude claude_code --exclude gemini_cli --exclude codex` (integration + bwrap; skip CLI-dependent) |
| **Phase gate** | Full `mix test` on host with all three CLI tools authenticated + `bwrap` installed |

## Per-Requirement Verification Map

| Plan-Task | Plan | Task | Req ID | Threat Ref | Expected Behavior | Test Type | Automated Command |
|-----------|------|------|--------|-----------|-------------------|-----------|-------------------|
| 03-02-01 | 02 | 1 | SEC-01, AGT-03 | T-03-02-01 | Router rejects messages lacking permission; one-way flow enforced | unit | `mix test test/glorbo/company/router_test.exs` |
| 03-02-01 | 02 | 1 | AGT-02, AGT-05 | T-03-02-02 | Router rejects `agents:create`-class routing; `@mention` wakes agent via Router | unit | `mix test test/glorbo/company/router_test.exs` |
| 03-02-02 | 02 | 2 | AGT-02 | T-03-02-03 | Scheduler fires cron on schedule; recomputes from wall-clock across pauses | unit | `mix test test/glorbo/company/scheduler_test.exs` |
| 03-02-03 | 02 | 3 | SEC-05 | T-03-02-04 | BudgetTracker hard-stop returns `{:stop, used, cap}` pre-dispatch; alert marker at threshold | unit | `mix test test/glorbo/company/budget_tracker_test.exs test/glorbo/budget/ledger_test.exs` |
| 03-03-01 | 03 | 1 | LLM-03, LLM-04 | T-03-03-01 | Agent parser enforces single provider+model; rejects list syntax / missing model | unit | `mix test test/glorbo/agent/parser_test.exs` |
| 03-03-02 | 03 | 2 | LLM-03 | T-03-03-02 | Claude Code / Gemini / Codex adapters parse telemetry correctly against fixtures | unit | `mix test test/glorbo/cli/claude_code_test.exs test/glorbo/cli/gemini_cli_test.exs test/glorbo/cli/codex_test.exs` |
| 03-03-02 | 03 | 2 | AGT-04 | T-03-03-03 | `Skills.Resolver.materialize/3` copies skills + INDEX.md; cleanup removes `.glorbo-skills/` | unit | `mix test test/glorbo/skills/resolver_test.exs` |
| 03-03-03 | 03 | 3 | AGT-01, AGT-02 | T-03-03-04 | Per-agent GenServer wake-queue coalesces; Dispatch pipeline in order | unit | `mix test test/glorbo/agent/server_test.exs test/glorbo/agent/dispatch_test.exs` |
| 03-04-01 | 04 | 1 | SEC-04, AGT-05 | T-03-04-01 | TaskDefinition parses `requires_approval: director`; AGT-05 smuggled-agent-def rejection | unit | `mix test test/glorbo/approvals/task_definition_test.exs` |
| 03-04-02 | 04 | 2 | SEC-04 | T-03-04-02 | Gate sentinel lifecycle: approval wakes agent; denial moves to history | unit | `mix test test/glorbo/approvals/gate_test.exs` |
| 03-05-01 | 05 | 1 | SEC-02 | T-03-05-01 | `Glorbo.Sandbox.Bwrap.build_argv/2` argv composition: `--die-with-parent --unshare-pid --symlink usr/bin /bin` etc. | unit | `mix test test/glorbo/sandbox/bwrap_test.exs test/glorbo/sandbox/permission_mapper_test.exs` |
| 03-05-02 | 05 | 2 | SEC-03 | T-03-05-02 | `Glorbo.Network.Proxy` CONNECT allowlist; allowlisted hosts pass, others 403 | unit | `mix test test/glorbo/network/proxy_test.exs` |
| 03-05-03 | 05 | 3 | AGT-01 | T-03-05-03 | 6-child supervisor: `AuditLog + Watcher + Router + Scheduler + BudgetTracker + AgentSupervisor`; crash isolation preserved | unit | `mix test test/glorbo/company/supervisor_test.exs` |
| 03-05-04 | 05 | 4 | SEC-02 | T-03-05-04 | Kernel-observed filesystem denial: sandboxed CLI write to denied path returns EACCES | integration | `mix test test/integration/sandbox_filesystem_test.exs --include bwrap` |
| 03-05-04 | 05 | 4 | SEC-03 | T-03-05-05 | `--unshare-net` blocks egress (policy `none`); `api-only` proxy allows allowlisted only | integration | `mix test test/integration/sandbox_network_none_test.exs test/integration/sandbox_network_api_only_test.exs --include bwrap` |
| 03-05-04 | 05 | 4 | SEC-04 | T-03-05-06 | Approval gate round-trip: task status-flip wakes paused agent | integration | `mix test test/integration/approval_gate_test.exs --include integration` |
| 03-05-04 | 05 | 4 | SEC-05 | T-03-05-07 | End-to-end budget hard-stop: CLI usage → ledger → check → reject with inbox notice | integration | `mix test test/integration/budget_hard_stop_test.exs --include integration` |
| 03-05-04 | 05 | 4 | AGT-05 | T-03-05-08 | Agent-create denial end-to-end: malicious outbox trying to write agents/<new>/agent.md rejected | integration | `mix test test/integration/agent_create_denial_test.exs --include integration` |
| 03-05-04 | 05 | 4 | AGT-02 | T-03-05-09 | Inbox inotify wake end-to-end: new file in inbox/ triggers agent GenServer wake | integration | `mix test test/integration/agent_wake_inbox_test.exs --include integration` |
| 03-05-04 | 05 | 4 | AGT-01 | T-03-05-10 | Agent crash isolation end-to-end: kill one agent, assert only that restarts | integration | `mix test test/integration/agent_crash_isolation_test.exs --include integration` |

## Manual-Only Verifications (Plan 05 Checkpoint)

| Item | Success Criterion | Manual Command | Expected Result |
|------|-------------------|----------------|-----------------|
| CC round-trip in bwrap | SC-2 (4 wake triggers) + SC-8 (CLI provider) + SC-9 (skills) | `glorbo up && echo '<task>' > companies/acme/agents/engineer/inbox/test.md && tail -f agents/engineer/stdout.log` | CLI tool executes inside bwrap sandbox, writes result to outbox; session JSONL redirected to workspace-local path; skills in `.glorbo-skills/` referenced in output |
| Network isolation proof | SC-5 | `bwrap --unshare-net ... -- curl https://example.com` | `curl: (6) Could not resolve host` or timeout |
| Audit shape + append-only | SC-3 (routing audit) + SC-6 (budget audit) + SC-7 (approval audit) | `jq -c . < ~/.glorbo/audit/$(date +%Y-%m).jsonl \| tail -20` | 16 Phase-3 event keys from AUDIT_EVENTS.md appear; no out-of-order timestamps; `diff` after no-op shows file only grew |

## Wave 0 Test Gap Inventory

All Wave-0 test files are authored by Wave-1 plans (03-02 / 03-03 / 03-04) as they build the modules they test. Plan 03-05 Task 4 contributes the 10 integration tests.

**Unit tests (per-module, authored inline with implementation):**
- [ ] `test/glorbo/company/supervisor_test.exs` — extend for 6-child shape (Plan 05)
- [ ] `test/glorbo/company/router_test.exs` — new (Plan 02)
- [ ] `test/glorbo/company/scheduler_test.exs` — new (Plan 02)
- [ ] `test/glorbo/company/budget_tracker_test.exs` — new (Plan 02)
- [ ] `test/glorbo/budget/ledger_test.exs` — new (Plan 02)
- [ ] `test/glorbo/agent/parser_test.exs` — new (Plan 03)
- [ ] `test/glorbo/agent/server_test.exs` — new (Plan 03)
- [ ] `test/glorbo/agent/dispatch_test.exs` — new (Plan 03)
- [ ] `test/glorbo/skills/resolver_test.exs` — new (Plan 03)
- [ ] `test/glorbo/cli/claude_code_test.exs` — new (Plan 03)
- [ ] `test/glorbo/cli/gemini_cli_test.exs` — new (Plan 03)
- [ ] `test/glorbo/cli/codex_test.exs` — new (Plan 03)
- [ ] `test/glorbo/approvals/task_definition_test.exs` — new (Plan 04)
- [ ] `test/glorbo/approvals/gate_test.exs` — new (Plan 04)
- [ ] `test/glorbo/sandbox/bwrap_test.exs` — new (Plan 05)
- [ ] `test/glorbo/sandbox/permission_mapper_test.exs` — new (Plan 05)
- [ ] `test/glorbo/network/proxy_test.exs` — new (Plan 05)

**Integration tests (tagged `:integration` / `:bwrap` / `:claude_code`):**
- [ ] `test/integration/agent_crash_isolation_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/agent_wake_inbox_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/inbox_isolation_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/sandbox_filesystem_test.exs` (Plan 05, `:bwrap`)
- [ ] `test/integration/sandbox_network_none_test.exs` (Plan 05, `:bwrap`)
- [ ] `test/integration/sandbox_network_api_only_test.exs` (Plan 05, `:bwrap`)
- [ ] `test/integration/approval_gate_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/budget_hard_stop_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/agent_create_denial_test.exs` (Plan 05, `:integration`)
- [ ] `test/integration/claude_code_invocation_test.exs` (Plan 05, `:claude_code`)

**Fixtures (captured from real host, 2026-04-16):**
- [ ] `test/fixtures/claude_session_sample.jsonl` — real Claude Code session shape
- [ ] `test/fixtures/codex_rollout_sample.jsonl` — real Codex rollout shape
- [ ] `test/fixtures/gemini_stdout_sample.json` — real Gemini `--output-format json` shape

## Environment Dependencies

| Dependency | Required By | Available (dev host) | Version | Fallback |
|------------|------------|---------------------|---------|----------|
| `bwrap` binary | SEC-02, SEC-03, AGT-02 dispatch | YES | 0.11.0 | Block at Doctor; no runtime fallback |
| Kernel user namespaces | bwrap `--unshare-user-try` | YES | `max_user_namespaces=254351` | Graceful fallback + `namespace.fallback` audit |
| `claude` CLI | `provider: claude-code` agents | YES | 2.1.110 | `provider.unavailable` audit + no-wake (D-43) |
| `gemini` CLI | `provider: gemini-cli` agents | YES | (inspected) | Same pattern |
| `codex` CLI | `provider: codex` agents | YES | (inspected) | Same pattern |
| `crontab` Hex | Scheduler | YES (Plan 03-01) | 1.2.x | No fallback needed |
| `muontrap` Hex | Port cleanup | YES | 1.6.x | No fallback needed |
| `file_system` Hex | inotify triggers | YES (Phase 2) | 1.0.x | Phase 2 already operational |
| SQLite WAL | Budget + approval persistence | YES (Phase 1) | — | No fallback |
| Phoenix.PubSub | Watcher → Router/Gate events | YES (Phase 1) | — | No fallback |

## Sign-Off Checklist

- [x] Test framework identified (ExUnit, `test/test_helper.exs`)
- [x] Per-requirement test commands mapped for all 12 required IDs
- [x] Wave-0 test gaps enumerated (17 unit files + 10 integration files + 3 fixture sets)
- [x] Sampling rates defined (per-commit / per-wave / phase-gate)
- [x] Manual checkpoint verifications specified (Plan 05 Task 5)
- [x] Environment dependencies mapped with fallback behaviour
- [x] Integration test tags defined (`:integration`, `:bwrap`, `:claude_code`, `:gemini_cli`, `:codex`)

**Approval:** approved 2026-04-16
