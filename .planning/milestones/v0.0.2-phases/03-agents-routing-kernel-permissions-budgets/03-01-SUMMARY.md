---
phase: 03-agents-routing-kernel-permissions-budgets
plan: 01
subsystem: security, database, runtime
tags: [ecto, posix-acl, uid-allocator, litellm, crontab, budget, approval, usage-report]

requires:
  - phase: 02-filesystem-foundation-container-runtime-local-llm
    provides: "Ecto schemas (companies, agents, audit_events, reindex_state), FastAPI worker (/run, /cancel), WorkerClient, ContainerManager"
provides:
  - "Budget Ecto schema with composite unique index for monthly upsert"
  - "TasksApprovalState Ecto schema for approval gate lifecycle"
  - "permissions_hash column on agents table for ACL-change detection"
  - "ACLMapper pure module: parse_permission/1, check_action/2, acl_entries/2"
  - "UidAllocator: subuid_base/1, allocate/3, current_allocations/1"
  - "Worker usage.py: write_usage_report with litellm.completion_cost"
  - "Worker skills_resolved injection via context.py"
  - "AUDIT_EVENTS.md: 16 canonical Phase-3 audit event keys"
  - "crontab ~> 1.2 dep for Plan 02 Scheduler"
affects: [plan-02-router-scheduler-budget, plan-03-dispatch-skills-approval, plan-04-agent-server-supervision, plan-05-acl-network-kernel]

tech-stack:
  added: [crontab 1.2]
  patterns: [pure-module-with-dep-injectable-IO, additive-python-schema-extension, audit-event-registry-as-cross-plan-reference, cents-integer-math-for-budget]

key-files:
  created:
    - lib/glorbo/budget.ex
    - lib/glorbo/tasks_approval_state.ex
    - lib/glorbo/security/acl_mapper.ex
    - lib/glorbo/runtime/uid_allocator.ex
    - containers/glorbo-runtime/worker/usage.py
    - containers/glorbo-runtime/tests/test_usage.py
    - containers/glorbo-runtime/tests/test_routes.py
    - priv/repo/migrations/20260416120001_create_budgets.exs
    - priv/repo/migrations/20260416120002_create_tasks_approval_state.exs
    - priv/repo/migrations/20260416120003_add_permissions_hash_to_agents.exs
    - .planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md
  modified:
    - mix.exs
    - mix.lock
    - containers/glorbo-runtime/worker/routes.py
    - containers/glorbo-runtime/worker/dispatch.py
    - containers/glorbo-runtime/worker/context.py
    - containers/glorbo-runtime/tests/test_worker.py
    - test/integration/airplane_mode_test.exs
    - test/glorbo/filesystem/hierarchy_test.exs

key-decisions:
  - "OQ1 resolved: UidAllocator reads /etc/subuid for Director user; uid_base = subuid_base + 100*ordinal (D-02 literal 100000 reinterpreted as relative offset)"
  - "OQ2 resolved: --cap-add NET_ADMIN narrowly scoped to api-only containers only; negative tests assert absence for none/open"
  - "OQ3 resolved: nftables + pre-resolved CIDR for Phase 3; tinyproxy/UDS deferred to v1.1"
  - "Cents (integer) for budget arithmetic — no float drift in SUM aggregations"
  - "Deterministic ACL entry ordering (sorted by path) for stable permissions_hash"
  - "agent_slug required in /run body — usage report path is deterministic, not guessed from task_path"

patterns-established:
  - "Pure-module + dep-injectable-IO pattern: ACLMapper has zero IO, UidAllocator injects subuid_path/sidecar_path via opts keyword"
  - "Additive Python schema extension: new fields with defaults preserve Phase 2 D-36 stability invariant"
  - "AUDIT_EVENTS.md as cross-plan canonical reference: Plans 02-05 look up action keys here, not inline"
  - "Usage report allow-list keyed schema: only permitted fields serialized, never free-form response.dict()"

requirements-completed: [SEC-01, SEC-05, AGT-04]

duration: 13min
completed: 2026-04-16
---

# Phase 03 Plan 01: Wave-0 Foundations Summary

**Pure ACL mapper + UID allocator + budget/approval Ecto schemas + worker usage reporting + skills injection + 16-event audit registry -- zero new runtime processes**

## Performance

- **Duration:** 13 min
- **Started:** 2026-04-16T01:45:48Z
- **Completed:** 2026-04-16T01:58:48Z
- **Tasks:** 3
- **Files modified:** 20

## Accomplishments

- Three Ecto migrations + two schemas (Budget with monthly upsert index, TasksApprovalState with unique task_path) + permissions_hash column on agents
- ACLMapper: pure permission-to-ACL-tuple mapper covering all 7 verb families (projects r/w, chat r/w, agents message/create, tasks update) with T-03-01 mitigation (no atom creation from user input)
- UidAllocator: reads /etc/subuid, assigns 100-UID blocks per company, tombstones removed agents (D-04), writes sidecar with chmod 0600 (T-03-02)
- Worker extended: usage.py writes allow-list keyed JSON reports with litellm.completion_cost + None->0.0 coercion; skills_resolved injected into system prompt; agent_slug required field; all additive to Phase 2 contract
- AUDIT_EVENTS.md documents all 16 Phase-3 audit event keys with actor, firing module, and payload schema

## Task Commits

1. **Task 1: Migrations + Ecto schemas + crontab dep** - `8186912` (feat)
2. **Task 2: Pure ACLMapper + UidAllocator + AUDIT_EVENTS.md** - `ae4485b` (feat)
3. **Task 3: Worker /run extends with skills_resolved + usage report** - `5ce465c` (feat)

## Files Created/Modified

- `lib/glorbo/budget.ex` - Budget Ecto schema with changeset validation (cents, non-negative)
- `lib/glorbo/tasks_approval_state.ex` - TasksApprovalState Ecto schema (awaiting/approved/denied)
- `lib/glorbo/security/acl_mapper.ex` - Pure permission parser + ACL entry generator
- `lib/glorbo/runtime/uid_allocator.ex` - /etc/subuid reader + per-company UID block allocator
- `containers/glorbo-runtime/worker/usage.py` - Usage report writer (litellm cost + allow-list schema)
- `containers/glorbo-runtime/worker/routes.py` - Added skills_resolved, agent_slug, outbox_root + usage call
- `containers/glorbo-runtime/worker/dispatch.py` - Returns _response_obj for cost computation
- `containers/glorbo-runtime/worker/context.py` - skills_resolved injection into system prompt
- `priv/repo/migrations/20260416120001_create_budgets.exs` - budgets table + unique index
- `priv/repo/migrations/20260416120002_create_tasks_approval_state.exs` - tasks_approval_state table
- `priv/repo/migrations/20260416120003_add_permissions_hash_to_agents.exs` - nullable column add
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` - 16 event keys
- `test/glorbo/budget_schema_test.exs` - 8 tests for Budget changeset + constraints
- `test/glorbo/tasks_approval_state_test.exs` - 6 tests for approval state + constraints
- `test/glorbo/security/acl_mapper_test.exs` - 20 tests covering all permission verbs
- `test/glorbo/runtime/uid_allocator_test.exs` - 8 tests for UID allocation + tombstone + chmod
- `containers/glorbo-runtime/tests/test_usage.py` - 4 Python tests for usage report
- `containers/glorbo-runtime/tests/test_routes.py` - 6 Python tests for schema + skills
- `containers/glorbo-runtime/tests/test_worker.py` - Back-edited for agent_slug requirement
- `test/integration/airplane_mode_test.exs` - Back-edited for agent_slug + outbox_root
- `test/glorbo/filesystem/hierarchy_test.exs` - Back-edited for permissions_hash column

## Decisions Made

- OQ1/OQ2/OQ3 locked in plan frontmatter -- all three open questions from research resolved
- Budget uses integer cents (cost_usd_cents) -- avoids float drift in SQLite SUM
- ACL entries sorted by path for deterministic permissions_hash computation
- agent_slug required (not optional) in /run body -- usage report path must be explicit
- Usage report filename keyed by request_id (not task_id) for retry uniqueness

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed hierarchy_test.exs schema parity assertion**
- **Found during:** Task 3 (worker extensions)
- **Issue:** Phase 2 schema parity test asserted exact column set for agents table; adding permissions_hash broke it
- **Fix:** Added "permissions_hash" to expected column set in hierarchy_test.exs
- **Files modified:** test/glorbo/filesystem/hierarchy_test.exs
- **Verification:** mix test -- 206 tests, 0 failures
- **Committed in:** 5ce465c (Task 3 commit)

**2. [Rule 1 - Bug] Fixed test_worker.py /run endpoint test for required agent_slug**
- **Found during:** Task 3 (worker extensions)
- **Issue:** Existing test_worker.py test_run_endpoint_404_on_missing_task omitted agent_slug, now required
- **Fix:** Added agent_slug: "ceo" to test request body
- **Files modified:** containers/glorbo-runtime/tests/test_worker.py
- **Verification:** All worker tests pass
- **Committed in:** 5ce465c (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs from back-edit)
**Impact on plan:** Both fixes anticipated by plan (airplane_mode_test + test_worker back-edits). No scope creep.

## Issues Encountered

- credo nesting depth violation in UidAllocator.subuid_base/1 -- refactored `with` to `case` + extracted `find_user_subuid/2` helper
- Operator precedence in UidAllocator test (`&&&` vs `==`) -- added parentheses
- Python test venv created locally for running worker tests (gitignored; production tests run inside container image)

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All Plan 02-05 dependencies exist: ACLMapper exports, Budget schema, UidAllocator API, worker usage.py, AUDIT_EVENTS.md, crontab dep
- Plan 02 (Router + Scheduler + BudgetTracker) can import ACLMapper.check_action/3 and upsert Budget schema
- Plan 03 (Dispatch + Skills + Approval) can use skills_resolved worker field and TasksApprovalState schema
- Plan 05 (ACL reconciliation + Network policy) can use UidAllocator.allocate/3 and ACLMapper.acl_entries/2
- Pre-existing credo issue in lib/glorbo/filesystem/reindex.ex (Phase 2) noted but out of scope

---
*Phase: 03-agents-routing-kernel-permissions-budgets*
*Completed: 2026-04-16*
