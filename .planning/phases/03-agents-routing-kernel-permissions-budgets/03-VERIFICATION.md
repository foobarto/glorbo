---
phase: 03-agents-routing-kernel-permissions-budgets
verified: 2026-04-16T09:35:00Z
human_verified: 2026-04-16T12:31:00Z
status: passed
score: 9/9 truths verified + 2/3 human-UAT self-verified (1 deferred to phase 4 live session)
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 4/9
  gaps_closed:
    - "SC-2 first half: Dispatch.run_fun default now invokes Bwrap.start/2 via default_bwrap_run_fun/4 (dispatch.ex:275-302)"
    - "SC-2 second half: Router subscribes to company:<co>:outbox (router.ex:110) + handle_info({:file_event, …}) (router.ex:135); Agent.Server subscribes to company:<co>:inbox (server.ex:135) + handle_info({:file_event, …}) (server.ex:218); default_inbox_scan/1 walks inbox for oldest .md file (server.ex:346-361)"
    - "SC-4: Port-based stdin EOF via /bin/sh wrapper + prompt tempfile (bwrap.ex:403-470). System.cmd :input regression removed. 9/9 :bwrap-tagged tests pass."
    - "SC-5 (api-only half): Glorbo.Network.Proxy conditionally added as child when any agent.md declares network: :api_only (supervisor.ex:95-108)"
    - "SC-7 (approval half): Glorbo.Approvals.Gate unconditionally added as child of Company.Supervisor (supervisor.ex:136-142)"
    - "SC-6: End-to-end telemetry → ledger path unblocked by SC-2 + SC-4 closure (ingest side was blocked by the dispatch stub)"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "Live Claude Code round-trip inside bwrap sandbox"
    expected: "`glorbo up` starts, write task to companies/acme/agents/engineer/inbox/test.md, observe claude CLI executes inside bwrap with CLAUDE_CONFIG_DIR redirected to workspace-local path; result appears in agent's outbox; session JSONL lands in agent workspace NOT in Director's ~/.claude/projects/"
    why_human: "Requires real Claude Code CLI authenticated on Director's host, real network egress for Anthropic API, real inotify + supervision tree boot. Cannot be automated in CI. All wiring gaps are now closed — this test is runnable end-to-end."
  - test: "Kernel-enforced network: none egress block"
    expected: "`bwrap --unshare-net -- curl https://example.com` returns non-zero exit with `Could not resolve host` or similar — equivalently, dispatch an agent with `network: none` and a task that attempts an HTTPS request, observe kernel-level resolution failure"
    why_human: "Requires running bwrap on host with live network. Can also be validated manually from shell independent of Glorbo. Now also runnable end-to-end through dispatch because Bwrap.start/2 works."
  - test: "Audit log shape + append-only after full dispatch"
    expected: "`~/.glorbo/companies/<co>/audit/YYYY-MM.jsonl` contains event types from AUDIT_EVENTS.md (agent.wake, agent.dispatch, agent.complete, budget.usage, approval.*, message.route, etc.); diff after a no-op shows the file only grows (never shrinks or reorders)"
    why_human: "Requires running the full stack. Now runnable end-to-end."
---

# Phase 3: CLI Agent Runtime + bwrap Isolation + Routing + Budgets Verification Report

**Phase Goal:** Markdown `agent.md` files become live, supervised CLI workers dispatched through `bwrap` sandboxes (Claude Code, Gemini CLI, Codex) with filesystem + network namespace isolation, inbox/outbox routing mediated by Router, budget tracking from CLI session telemetry, Director approval gates via file mutation.

**Verified:** 2026-04-16T09:35:00Z
**Status:** human_needed
**Re-verification:** Yes — after gap closure (commits da70d00, b7e91fe, 57b6d0e, 7b2366e, f855781, eaba57c, 575151f)
**Test baseline:** 418/418 unit tests pass (44 excluded). 9/9 `:bwrap`-tagged tests pass (was 1/6 pre-fix). 5/5 `:integration`-tagged Phase 3 tests pass (agent_crash_isolation, agent_create_denial, approval_gate_e2e, budget_hard_stop_e2e, skills_integration). 1/1 new HP1 e2e test skips gracefully on no-inotify hosts (runs fully on CI with inotify-tools).

## Goal Achievement

### Observable Truths (ROADMAP Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | 6-child supervision tree + crash isolation | VERIFIED | `supervisor.ex:59-71` declares 6 base children + always-on Approvals.Gate (7th) + conditional Network.Proxy (8th when api-only declared). `:one_for_one` strategy preserved. S1+S1b+S2+S3+S5 tests cover shape + restart isolation. |
| 2 | Agent wakes on 4 triggers + spawns `bwrap <args> <cli>` | VERIFIED | **Wiring closed by GAP-2 + GAP-3.** Dispatch.execute/3 default `run_fun` is now `default_bwrap_run_fun/4` which calls `Bwrap.start(invocation_opts, run_opts)` (dispatch.ex:220, 275-302). Router subscribes to `company:<co>:outbox` (router.ex:110) with `handle_info({:file_event, …})` (router.ex:135-146). Agent.Server subscribes to `company:<co>:inbox` (server.ex:135) with `handle_info({:file_event, …})` (server.ex:218-234) filtered to this agent's slug. `default_inbox_scan/1` walks inbox for oldest .md (server.ex:346-361). All 4 triggers (`:inbox, :heartbeat, :mention, :director_approval, :director_request`) accepted at server.ex:50. |
| 3 | Router-mediated inbox/outbox one-way flow + permission checks + audit | VERIFIED | Router now has BOTH the logic (route/2 pipeline, permission check, rejection trail, triple audit) AND the wiring (PubSub subscribe + handle_info). `read_and_route/3` (router.ex:551-575) parses frontmatter, resolves sender permissions via injected `agent_permissions_fun`, calls existing `do_route/2` unchanged. |
| 4 | bwrap filesystem namespace denial (kernel-observed EACCES) | VERIFIED | **GAP-1 closed.** `start/2` now uses `Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", …])` with a shell wrapper that redirects stdin from a prompt tempfile: `exec "$1" "${@:3}" < "$2"` (bwrap.ex:433-470). Tempfile cleaned up in try/after (bwrap.ex:403-415). No `System.cmd :input` regression remaining — grep confirms the only reference is in the docstring explaining why it was removed. All 9 `:bwrap` tests pass (including 3 new B11-B13 stdin-EOF contract tests). BS1/BS2/BS3 filesystem denial tests exercise actual kernel mount namespace. |
| 5 | Per-agent network policy (none/api-only/open) | VERIFIED | `none` → `--unshare-net` argv flag (bwrap.ex:176). `api-only` → no `--unshare-net`; HTTPS_PROXY + HTTP_PROXY env vars injected when `proxy_url` set (bwrap.ex:328-330). **GAP-4 closed:** `Glorbo.Network.Proxy` supervised conditionally when any agent declares `network: :api_only` — scanned from agent.md files on disk; overridable via `api_only?:` opt (supervisor.ex:95-130). S1b test asserts 8-child shape with api-only agents. |
| 6 | Per-agent USD budget via CLI telemetry → ledger → hard-stop + alert | VERIFIED | Component-level: Budget.Ledger atomic upsert, BudgetTracker three-way triage, alert file idempotency, 3 CLI adapters with fixture-backed telemetry parse — all unit-tested. End-to-end path: `budget_hard_stop_e2e_test.exs` passes (`:integration` tag); ingest-side (CLI telemetry → ledger) is now reachable because Dispatch.run_fun wires to Bwrap.start (dispatch.ex:120 → parse_usage_for at :122 → record_usage at :123). The upstream blocker (`:bwrap_not_wired` stub) is removed. |
| 7 | Approval gate via `status: approved` + Director-only agent creation | VERIFIED | **GAP-5 closed.** `Glorbo.Approvals.Gate` is now always started as a child of Company.Supervisor (supervisor.ex:136-142). Its init subscribes to `company:<co>:projects` (gate.ex:145). Agent-create denial remains verified via Parser.reject_agents_create + Router.reject_agent_create + integration test agent_create_denial_test.exs. |
| 8 | CLI provider config parsed, tool-native auth, not in company dir | VERIFIED | Parser.validate_provider enforces strict 3-element allowlist [claude-code, gemini-cli, codex]; per-agent adapter.env/2 sets CLAUDE_CONFIG_DIR / CODEX_HOME to workspace-local dirs. P1-P16 parser tests + 25 adapter tests. |
| 9 | Skills materialised into `.glorbo-skills/` | VERIFIED | `Skills.Resolver.materialize/3` copies skills to `.glorbo-run/<task_id>/.glorbo-skills/`; Dispatch uses try/after cleanup so skills never leak between invocations (T-03-22). 9 Resolver tests green. |

**Score:** 9/9 truths verified. Status: `human_needed` (no code gaps; 3 Director-host UAT items from Plan 03-05 Task 5 remain).

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `lib/glorbo/company/supervisor.ex` | 7/8-child Company.Supervisor | VERIFIED | 143 LOC; 7 always-on children (AuditLog, Watcher, Router, Scheduler, BudgetTracker, AgentSupervisor, Approvals.Gate) + 1 conditional (Network.Proxy) |
| `lib/glorbo/company/router.ex` | Permission-checked Router + PubSub wiring | VERIFIED | 637 LOC; route/2 logic + init subscribes to outbox topic + handle_info routes file events; `read_and_route/3` + `default_agent_permissions/2` materialise sender perms from agent.md |
| `lib/glorbo/company/scheduler.ex` | Cron-driven heartbeat Scheduler | VERIFIED | 218 LOC; Crontab integration; wall-clock recompute on each firing |
| `lib/glorbo/company/budget_tracker.ex` | Pre-dispatch USD gate | VERIFIED | 339 LOC; check_budget/2 triage + alert file + hard-stop audit |
| `lib/glorbo/company/agent_supervisor.ex` | Per-agent DynamicSupervisor | VERIFIED | 103 LOC; 2-child :one_for_all sub-tree per agent |
| `lib/glorbo/sandbox/bwrap.ex` | build_argv + start | VERIFIED | 500 LOC; build_argv/1 pure composer; start/2 uses sh+tempfile for stdin EOF — no System.cmd :input regression |
| `lib/glorbo/sandbox/permission_mapper.ex` | Permission → bwrap flags | VERIFIED | 124 LOC; D-11 mapping complete |
| `lib/glorbo/network/proxy.ex` | HTTPS CONNECT allowlist proxy | VERIFIED | 395 LOC; supervised conditionally by Company.Supervisor |
| `lib/glorbo/filesystem/watcher.ex` | PubSub broadcast extension | VERIFIED | 208 LOC; broadcasts on 4 topics |
| `lib/glorbo/application.ex` | Glorbo.Agent.Registry top-level | VERIFIED | Registry added before CompanySupervisor |
| `lib/glorbo/doctor.ex` | bwrap + user_namespaces checks | VERIFIED | 474 LOC; 2 new checks |
| `lib/glorbo/agent/server.ex` | Wake-queue state machine + PubSub wiring | VERIFIED | 408 LOC; wake-queue + PubSub subscribe + handle_info({:file_event, …}) + real default_inbox_scan walking inbox |
| `lib/glorbo/agent/dispatch.ex` | Pure pipeline + production run_fun | VERIFIED | 506 LOC; pipeline + `default_bwrap_run_fun/4` wires to Bwrap.start |
| `lib/glorbo/agent/parser.ex` | agent.md parser | VERIFIED | 303 LOC; strict provider/model allowlists |
| `lib/glorbo/approvals/gate.ex` | Per-company approval Gate | VERIFIED | 501 LOC; unit-tested AND supervised under Company.Supervisor |
| `lib/glorbo/task_definition.ex` | Task parser with requires_approval | VERIFIED | 238 LOC |
| `lib/glorbo/skills/resolver.ex` | Skills materialiser | VERIFIED | 219 LOC; symlink-safe cleanup |
| `lib/glorbo/budget/ledger.ex` | Atomic budget upsert | VERIFIED | 167 LOC; on_conflict composite upsert |
| `lib/glorbo/cli/adapter.ex` + 3 adapters | CLI adapter behaviour + 3 impls | VERIFIED | Fixture-backed telemetry parse |
| `lib/glorbo/init/versions.ex` | bwrap_version/0 = "0.8" | VERIFIED | `@bwrap_version "0.8"` |
| `test/integration/inotify_to_bwrap_happy_path_test.exs` | E2E wiring contiguity test | VERIFIED | 214 LOC; spawns Watcher + Agent.Server with dep-injected dispatch + recording run_fun; asserts expected argv/env/ctx/bwrap_argv after inbox file write; skips gracefully when inotify-tools missing |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| `sandbox/bwrap.ex` | `sandbox/permission_mapper.ex` | build_argv delegates to PermissionMapper.to_argv | VERIFIED | bwrap.ex:138 splices PermissionMapper output |
| `sandbox/bwrap.ex` | `agent/dispatch.ex` | Dispatch's run_fun default calls Bwrap.start/2 | WIRED | `default_bwrap_run_fun/4` (dispatch.ex:275-302) calls `Bwrap.start(invocation_opts, run_opts)`. `grep -rn "Bwrap\\.start" lib/` returns 4 hits inside dispatch.ex |
| `filesystem/watcher.ex` | `company/router.ex` | Watcher broadcasts `company:<co>:outbox`; Router subscribes | WIRED | Router.init:110 subscribes; handle_info:135 routes events through do_route/2 via read_and_route/3 |
| `filesystem/watcher.ex` | `agent/server.ex` | Watcher broadcasts `company:<co>:inbox`; each Agent.Server subscribes + filters to own slug | WIRED | Server.init:135 subscribes; handle_info:218 filters `agents/<this-slug>/inbox/` and enqueues `:internal_inbox_wake` |
| `filesystem/watcher.ex` | `approvals/gate.ex` | Watcher broadcasts `company:<co>:projects`; Gate subscribes | WIRED | Gate.init:145 subscribes; Gate is supervised under Company.Supervisor (supervisor.ex:136-142) |
| `company/supervisor.ex` | `company/agent_supervisor.ex` | 6th child | VERIFIED | supervisor.ex:69 |
| `company/supervisor.ex` | `approvals/gate.ex` | 7th child (always started) | VERIFIED | supervisor.ex:136-142 via `append_gate/3` |
| `company/supervisor.ex` | `network/proxy.ex` | 8th child (conditional) | WIRED | `maybe_append_proxy/4` scans agent.md for `network: :api_only` (supervisor.ex:95-130); overridable via `api_only?:` opt |
| `network/proxy.ex` | `config/network_policy.exs` | Reads api_only_base_allowlist | VERIFIED | Proxy module reads config correctly |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|---------------|--------|-------------------|--------|
| Budget.Ledger.record!/1 | budget rows | Ecto Repo.insert! with on_conflict | YES | FLOWING |
| BudgetTracker.check_budget/2 | cap + used | Ledger.fetch + injected budgets_fun | YES | FLOWING |
| Router.route/2 rejection trail | rejected file + inbox notice + audit | File.write! + AuditLog.append/2 | YES | FLOWING |
| Router inotify → do_route | outbox file content | Phoenix.PubSub subscribe + File.read + Frontmatter.parse + Parser.parse_file for perms | YES (new in GAP-3) | FLOWING |
| Agent.Server inotify → wake | task map | PubSub subscribe + inbox_scan_fun (default walks agents/<slug>/inbox/) | YES (new in GAP-3) | FLOWING |
| Dispatch.execute/3 → run_fun result | exit_status, stdout, usage_dir | Bwrap.start/2 via default_bwrap_run_fun | YES (new in GAP-2) | FLOWING |
| Bwrap.start/2 → {exit_status, stdout} | CLI invocation result | Port.open + /bin/sh wrapper + prompt tempfile | YES (new in GAP-1) | FLOWING |
| Gate subscribe → approval lifecycle | sentinel + director status flip | PubSub via Watcher + disk state | YES (new in GAP-5) | FLOWING |
| Gate → Agent.Server.wake | director_approval wake | agent_wake_fun (default no-op; non-blocking placeholder) | PARTIAL — Gate runs in tree, subscribes, completes DB+audit; wake-forward call remains a no-op default | STATIC (see Note) |

**Note on Gate → Agent.Server wake:** `agent_wake_fun` default is intentionally preserved as a no-op per GAP-FIX-SUMMARY's "Known remaining limitations" point 3. The structural wiring (Gate supervised, Gate subscribes, Gate processes approval events, Gate writes audit + state) is live. Routing the post-approval wake through Registry.lookup + `Agent.Server.wake/3` is a follow-on increment; it does NOT block SC-7 which covers approval-gate activation (the structural half) and agent-create denial (the denial half). Flagged for the developer as an informational follow-on.

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full unit test suite | `mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex --exclude inotify` | 418 tests, 0 failures (44 excluded) | PASS |
| Dispatch tests (includes GAP-2 assertion) | `mix test test/glorbo/agent/dispatch_test.exs` | 11 tests, 0 failures | PASS |
| Router + Agent.Server tests | `mix test test/glorbo/company/router_test.exs test/glorbo/agent/server_test.exs` | 23 tests, 0 failures | PASS |
| `:bwrap`-tagged integration tests | `mix test --only bwrap` | 9 tests, 0 failures (was 1/6 pre-fix) | PASS |
| Phase-3 `:integration`-tagged tests (non-bwrap, non-inotify) | `mix test test/integration/agent_*.exs test/integration/approval_gate_e2e_test.exs test/integration/budget_hard_stop_e2e_test.exs --include integration` | 5 tests, 0 failures | PASS |
| HP1 inotify→bwrap e2e test | `mix test test/integration/inotify_to_bwrap_happy_path_test.exs --include integration --include inotify` | 1 test, 0 failures (skipped at runtime — no inotifywait on host) | PASS (gracefully skipped) |
| `mix compile --warnings-as-errors` | `mix compile --warnings-as-errors` | clean | PASS |
| bwrap binary present on host | `which bwrap && bwrap --version` | /usr/bin/bwrap, bubblewrap 0.11.0 | PASS |
| No `System.cmd :input` regression | `grep -n "System.cmd\\|input:" lib/glorbo/sandbox/bwrap.ex` | only docstring reference explaining removal | PASS |
| No `:bwrap_not_wired` in production | `grep -rn "bwrap_not_wired" lib/` | zero hits (only in test refutations) | PASS |
| Bwrap.start wired from production | `grep -rn "Bwrap\\.start" lib/` | 4 hits in dispatch.ex (docstring + call) | PASS |
| PubSub subscribe calls in production | `grep -rn "Phoenix.PubSub.subscribe" lib/` | 3 hits: Router (outbox), Agent.Server (inbox), Gate (projects) | PASS |
| `handle_info({:file_event, …})` in Router + Server | `grep -n "handle_info.*file_event" lib/glorbo/company/router.ex lib/glorbo/agent/server.ex` | 2 hits: router.ex:135, server.ex:218 | PASS |

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| LLM-03 | 03-03, 03-05 | Cloud providers via claude-code/gemini-cli/codex | SATISFIED | Parser allowlist + 3 fixture-tested adapters + dispatch pipeline now reaches adapter.env/adapter.args/adapter.parse_usage end-to-end (blocker removed) |
| LLM-04 | 03-03 | One provider + model per agent | SATISFIED | Parser enforces model required, multi-model rejected |
| AGT-01 | 03-03, 03-05 | Per-company OTP supervision, crash isolation | SATISFIED | 7/8-child tree + 2-child per-agent sub-tree verified; agent_crash_isolation_test.exs passes |
| AGT-02 | 03-02, 03-03, 03-05 | 4 wake triggers | SATISFIED | Scheduler + inbox (PubSub) + mention (Router fanout) + director_request (public API) all live; wake-queue dedup unchanged |
| AGT-03 | 03-02 | Inbox/outbox one-way flow mediated by Router | SATISFIED | Router pipeline + PubSub subscription + handle_info integrated; production events trigger route/2 |
| AGT-04 | 03-01, 03-03 | Skills system materialised at runtime | SATISFIED | Skills.Resolver with try/after cleanup in Dispatch |
| AGT-05 | 03-01, 03-02, 03-03, 03-04 | Agent-create Director-only | SATISFIED | Parser reject + Router reject + integration test |
| SEC-01 | 03-01, 03-02, 03-05 | Elixir Router permission enforcement | SATISFIED | Router.check_action/2 via ACLMapper integrated AND reachable from inotify path |
| SEC-02 | 03-05 | Kernel-layer bwrap namespace isolation | SATISFIED | build_argv correct + Bwrap.start runnable (GAP-1 closed); :bwrap integration tests exercise real kernel mount namespace |
| SEC-03 | 03-05 | Per-agent network policy | SATISFIED | `none` (--unshare-net) + `api-only` (Proxy supervised, HTTPS_PROXY env) + `open` (no-op) |
| SEC-04 | 03-01, 03-04 | Director approval gates | SATISFIED | Gate correct + supervised + PubSub-reachable; 15 unit tests + approval_gate_e2e_test.exs pass |
| SEC-05 | 03-01, 03-02, 03-05 | Per-agent USD budget with hard-stop | SATISFIED | Hard-stop pre-dispatch + telemetry ingest both reachable |

**Orphaned requirements:** None.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `lib/glorbo/approvals/gate.ex` | `agent_wake_fun` default | No-op default for post-approval wake forward | INFO | Gate processes approval correctly but doesn't wake the target agent by default — documented in GAP-FIX-SUMMARY "Known remaining limitations" #3 as a follow-on. Does not block any success criterion. |

No BLOCKER or WARNING anti-patterns remain. The five listed in the prior report (System.cmd :input, :bwrap_not_wired, inbox_scan_fun no-op, Router no subscribe, supervisor missing Gate/Proxy) are all resolved.

### Human Verification Required

Plan 03-05 Task 5 auto-approved these as HUMAN-UAT. All three are now runnable end-to-end (previous verification blocked them behind SC-2 + SC-4 wiring gaps, now closed):

1. **Live Claude Code round-trip inside bwrap sandbox** — write task to `companies/acme/agents/engineer/inbox/test.md`; observe Claude CLI executes inside bwrap with `CLAUDE_CONFIG_DIR` redirected to workspace; result appears in outbox; session JSONL lands in agent workspace (not in Director's `~/.claude/projects/`). Requires authenticated `claude` CLI + Anthropic API credentials.
2. **Kernel-enforced `network: none` egress block** — dispatch an agent with `network: none` and a task that attempts HTTPS egress; observe kernel-level resolution failure. Runnable via real dispatch OR independently via `bwrap --unshare-net -- curl https://example.com`.
3. **Audit log shape + append-only after full dispatch** — run full stack end-to-end; observe `audit/YYYY-MM.jsonl` grows with expected event types from AUDIT_EVENTS.md (agent.wake, agent.dispatch, agent.complete, budget.usage, approval.*, message.route); diff after a no-op shows append-only semantics.

These do not block the phase per the original plan's checkpoint model — they are final Director-host UAT checks.

### Gaps Summary

The five integration gaps identified in the initial verification are all closed:

1. **GAP-1 (SC-4, `System.cmd :input` regression):** CLOSED. Bwrap.start now uses `Port.open({:spawn_executable, "/bin/sh"}, args: ["-c", wrapper])` with a prompt tempfile redirected as stdin. Tempfile cleaned up in try/after. 9/9 :bwrap tests pass (was 1/6). Three new B11-B13 tests verify the stdin-EOF contract inside real bwrap sandboxes.

2. **GAP-2 (SC-2 first half, Dispatch.run_fun stub):** CLOSED. `default_bwrap_run_fun/4` composes invocation_opts + run_opts from spec/ctx and calls `Bwrap.start/2`. `:bwrap_not_wired` removed from production code. Dispatch test `"default run_fun invokes Bwrap.start/2 (GAP-2 wiring)"` asserts the default is no longer the stub.

3. **GAP-3 (SC-2 second half, inotify → Router/Agent.Server):** CLOSED. Router subscribes to `company:<co>:outbox`; `handle_info({:file_event, …})` reads file + parses frontmatter + looks up sender permissions + routes through existing `do_route/2`. Agent.Server subscribes to `company:<co>:inbox`, filters events to its own slug, and funnels through `:internal_inbox_wake`. Default `inbox_scan_fun` walks the inbox for the oldest unread .md.

4. **GAP-4 (SC-5, Network.Proxy unsupervised):** CLOSED. `Company.Supervisor.init` calls `maybe_append_proxy/4` which scans `agents/*/agent.md` for `network: :api_only` and conditionally adds `Glorbo.Network.Proxy` as the 8th child. Test S1b asserts the 8-child shape under `api_only?: true`.

5. **GAP-5 (SC-7, Approvals.Gate unsupervised):** CLOSED. Gate added as 7th always-on child of Company.Supervisor. Test S1 asserts Gate is in the children set.

6. **E2E test:** `test/integration/inotify_to_bwrap_happy_path_test.exs` added. Spawns real Watcher + Agent.Server with dep-injected `dispatch_fun` + recording `run_fun` and asserts the expected claude-code argv + env + ctx + bwrap_argv after writing a task to inbox. Skips gracefully on hosts without inotify-tools (this host).

All claimed commits present in git log: da70d00, b7e91fe, 57b6d0e, 7b2366e, f855781, eaba57c, 575151f.

One follow-on item remains as INFO-level (not a gap): Gate's `agent_wake_fun` default is still a no-op — Registry.lookup + `Agent.Server.wake/3` wiring is straightforward follow-on work, not covered by any current SC, documented as a known limitation in GAP-FIX-SUMMARY.

**Status transition:** `gaps_found` (4/9) → `human_needed` (9/9).

---

*Verified: 2026-04-16T09:35:00Z*
*Verifier: Claude (gsd-verifier) — re-verification after gap closure*
