---
phase: 03-agents-routing-kernel-permissions-budgets
plan: 04
subsystem: approval-gate, task-parsing, pubsub-subscriber, director-gate
tags: [approvals, sentinel, task-parsing, pubsub-subscriber, director-gate, requires-approval]

requires:
  - phase: 03-agents-routing-kernel-permissions-budgets
    provides: "Plan 03-01 — Glorbo.TasksApprovalState Ecto schema with unique task_path index; Plan 03-02 — Glorbo.Company.AuditLog.append/2 + AUDIT_EVENTS.md registry foundation; Phase 2 — Glorbo.Filesystem.Frontmatter safe YAML loader with 10 MB cap + yamerl safe mode"

provides:
  - "Glorbo.TaskDefinition — task.md parser with strict requires_approval coercion (:director | nil), lenient status (any string), task_id derivation from filename stem, task_path derivation relative to company dir, path_outside_company defence, and inherited Phase 2 safe YAML loader"
  - "Glorbo.Approvals.Gate — per-company GenServer subscribing to Phoenix.PubSub topic 'company:<slug>:projects'; sentinel-file lifecycle (write/remove); TasksApprovalState upserts on request + grant + deny; dep-injected agent_wake_fun + audit_fun for Plan 03-05 supervisor wiring; File.rename atomic move to history/tasks/ on denial; approval.spurious audit on pre-approval without sentinel"
  - "AUDIT_EVENTS.md extensions — approval.spurious, approval.parse_error, approval.rename_failed"

affects:
  - plan-03-05-supervisor-wiring-watcher-pubsub-extension
  - phase-04-dashboard (approval-queue consumer)

tech-stack:
  added: []
  patterns:
    - "pubsub-subscribe-in-init-with-dep-inject-bypass: Gate subscribes to company:<slug>:projects at init/1; tests drive events via direct send(pid, {:file_event, ...}) without touching real Watcher"
    - "db-indexed-sentinel-correlation: sentinel discovery via Repo.get_by(TasksApprovalState, task_path: rel, status: \"awaiting\") — O(1) via unique index — not filesystem glob"
    - "strict-requires-approval-lenient-status: requires_approval pattern-matched against fixed [\"director\"|:director|nil|false|\"false\"] allowlist; status kept as opaque string since only approved/denied trigger Gate action"
    - "file-rename-atomic-move-on-denial: File.rename/2 is atomic within a filesystem; on failure emits approval.rename_failed audit, DB state still records the denial"
    - "path-prefix-defense-against-self-feedback: Gate filters file_events against ~r{\\Aprojects/.+/tasks/.+\\.md\\z} so its own sentinel-file writes can't trigger re-resolution"
    - "safe-wake-tolerates-:noproc: agent_wake_fun wrapped in rescue + catch :exit — Gate always completes approval state + sentinel removal even if the agent process is dead"
    - "dep-inject-keyword-audit-wake-repo-pubsub: every cross-boundary call is a dep-injected fn or module name — enables unit tests against DataCase sandbox without real PubSub/Registry"

key-files:
  created:
    - lib/glorbo/task_definition.ex
    - lib/glorbo/approvals/gate.ex
    - test/glorbo/task_definition_test.exs
    - test/glorbo/approvals/gate_test.exs
  modified:
    - .planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md
    - lib/glorbo/agent/server.ex

key-decisions:
  - "D-34 sentinel file shape — agents/<name>/state/awaiting-approval-<task_id>.md with frontmatter (agent, task_path, task_id, requested_at, requesting_trigger) + body explaining how to approve/deny"
  - "D-35 approval detection mechanism — Gate subscribes to Phoenix.PubSub topic 'company:<slug>:projects'; Plan 03-05's Watcher will extend to emit broadcasts on this topic for projects/**/*.md events"
  - "D-36 per-company Gate — minimal state (company, base, repo, audit_fun, agent_wake_fun, pubsub); crash-resumable from filesystem + SQLite with no replay"
  - "D-37 denial flow — status: denied triggers upsert denied + approval.denied audit + File.rename task to history/tasks/<task_id>.md + sentinel removal; denial_reason optional frontmatter field preserved in audit + DB reason column"
  - "Agent.Server integration (AGT-05 Director-only) — Gate emits :director_approval trigger via agent_wake_fun; default is a no-op in Plan 03-04 (Plan 03-05's supervisor wires Registry lookup + Agent.Server.wake/3)"
  - "TasksApprovalState upsert is atomic — on_conflict: [set: [status, resolved_at, reason]] with conflict_target: [:task_path] prevents duplicate rows; request path uses on_conflict: :nothing so a prior awaiting row isn't overwritten"

patterns-established:
  - "PubSub subscribe-in-init with subscribe?: false bypass for tests — mirrors the dep-injectable-IO-callbacks pattern from Plan 03-02 BudgetTracker"
  - "DB-indexed sentinel correlation via tasks_approval_state.task_path unique index (not filesystem glob) — scales to 50 agents per company"
  - "File.rename atomic move for denial — preserves denied task content at history/tasks/<task_id>.md for post-hoc review while removing it from active projects/ tree"
  - "Strict requires_approval coercion vs lenient status — security-critical fields strict (requires_approval has only 2 meaningful states), operational fields lenient (status has many valid values)"
  - "safe_wake wrapper with rescue + catch :exit — Gate completes approval flow even if Registry/Agent.Server absent or crashed"

requirements-completed:
  - "SEC-04 (full) — Tasks with requires_approval: director pause execution via Gate.request_approval (sentinel + DB + audit). Director edits task.md status → Gate resolves via Watcher/PubSub (pattern complete; integration wiring in Plan 03-05). Full audit trail: approval.requested / approval.granted / approval.denied / approval.spurious / approval.parse_error / approval.rename_failed."
  - "AGT-05 (partial — reinforcement only) — TaskDefinition parser has no code path for 'agent creation task'; approval flow is scoped to projects/**/*.md only. Plan 03-02's Router remains the primary AGT-05 enforcement; this plan's parser doesn't widen the surface."

duration: 8min
started: 2026-04-16T05:54:09Z
completed: 2026-04-16T06:02:02Z
tasks: 2
files_created: 4
files_modified: 2
tests_added: 31
---

# Phase 03 Plan 04: Approval Gate + TaskDefinition Parser Summary

**Per-company approval gate (SEC-04) pauses Director-approved tasks via filesystem sentinels, watches Phoenix.PubSub 'company:<slug>:projects' for status-flip events, and resolves via atomic DB upsert + audit + agent wake or File.rename to history/. TaskDefinition parser strict on requires_approval, lenient on status, with path_outside_company defence. Two modules + 31 tests; no supervisor wiring (Plan 03-05 owns that); all 374 full-suite tests green.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-04-16T05:54:09Z
- **Completed:** 2026-04-16T06:02:02Z
- **Tasks:** 2
- **Files created:** 4 (2 lib + 2 test)
- **Files modified:** 2 (AUDIT_EVENTS.md + agent/server.ex clause ordering)
- **Tests added:** 31 (16 TaskDefinition + 15 Gate)
- **Full regression:** 374/374 green (was 343 at Plan 03-03 end; +31 net new)

## Accomplishments

- **Glorbo.TaskDefinition** parses `projects/**/tasks/*.md` files into a canonical struct with:
  - Strict `requires_approval` coercion (`"director" | :director` → `:director`; `nil | false | "false"` → `nil`; anything else → `{:error, {:invalid_requires_approval, raw}}`).
  - Lenient `status` string kept verbatim (many valid values across phases; only `"approved"` / `"denied"` drive Gate behaviour).
  - `task_id` derived from filename stem (`Path.basename/2` with `.md`).
  - `task_path` derived by stripping `<base>/companies/<company>/` prefix — canonical relative path used in SQLite, PubSub, audit payloads.
  - `path_outside_company` defence rejects a caller passing a `file_path` outside the specified company's dir.
  - Inherits Phase 2's safe YAML loader (10 MB cap, yamerl safe mode) — billion-laughs and `!!tag` payloads blocked upstream.
  - `requires_approval?/1` one-liner helper for Gate decisions.

- **Glorbo.Approvals.Gate** GenServer with:
  - `init/1` subscribes to `"company:<slug>:projects"` on `Glorbo.PubSub` (default; `subscribe?: false` for unit tests).
  - `request_approval/2` writes sentinel file at `agents/<name>/state/awaiting-approval-<task_id>.md` with `(agent, task_path, task_id, requested_at, requesting_trigger)` frontmatter; upserts `%TasksApprovalState{status: "awaiting"}` via `on_conflict: :nothing`; emits `approval.requested` audit. **Idempotent** — second call short-circuits on `File.exists?` check (no duplicate audit, no duplicate row).
  - `handle_info({:file_event, rel_path, events}, state)` filters for `:modified` AND `rel_path =~ ~r{\Aprojects/.+/tasks/.+\.md\z}`. Defence-in-depth against feedback loops (sentinel writes / audit writes) supplementing Plan 03-05's upstream Watcher path-prefix routing.
  - On `status: approved` with matching sentinel: upsert `state = "approved"`, `approval.granted` audit, call `agent_wake_fun(agent, :director_approval, task_map)` (safe-wrapped against `:noproc` + `:exit`), remove sentinel.
  - On `status: denied`: upsert `state = "denied"` (preserves `denial_reason`), `approval.denied` audit, atomic `File.rename/2` task file → `history/tasks/<task_id>.md` (creates dir if needed), remove sentinel. `approval.rename_failed` audit on IO error (DB state still denied; disk inconsistency visible on reindex).
  - On `status: approved | denied` with NO matching sentinel: `approval.spurious` audit (Director pre-approved; legitimate per D-35 extension).
  - On parse error: `approval.parse_error` audit, Gate stays alive (Pitfall-T-03-27 mitigation).
  - `resolve_approval/3` test-facing shortcut that synthesises the PubSub event via `send(server, {:file_event, ...})` + `:sys.get_state` flush.

- **AUDIT_EVENTS.md** extended with three new event keys:
  - `approval.spurious` — director actor; Gate fired; payload `%{agent, task_path, status}`.
  - `approval.parse_error` — system actor; Gate fired; payload `%{task_path, error}`.
  - `approval.rename_failed` — system actor; Gate fired; payload `%{task_path, target, error}`.

- **agent/server.ex** cleanup — reordered `handle_call` clauses so `handle_call(:status, ...)` sits next to the `:wake` clauses (not after the private `handle_wake_idle/3`). Silences the `--warnings-as-errors` "clauses with the same name and arity should be grouped together" warning that was blocking the plan's compile verification gate. Pre-existing issue from Plan 03-03; no behavioural change.

## Task Commits

1. **Task 1: TaskDefinition parser** — `43bacea` (feat) — 16 tests green, credo clean
2. **Task 2: Approvals.Gate GenServer + AUDIT_EVENTS extension** — `aad11ca` (feat) — 15 tests green, credo clean

## Files Created/Modified

**Created:**
- `lib/glorbo/task_definition.ex` — Parser with strict requires_approval coercion, task_id + task_path derivation, path_outside_company defence
- `lib/glorbo/approvals/gate.ex` — Per-company GenServer with PubSub subscription, sentinel lifecycle, atomic DB upsert, rename-on-deny, dep-injected wake/audit funs
- `test/glorbo/task_definition_test.exs` — 16 tests (T1-T16 covering all locked behaviours: valid parse, requires_approval coercions, missing/corrupt/oversized YAML, task_id derivation, task_path + path_outside_company, denial_reason round-trip, status lenience, requires_approval?/1 helper)
- `test/glorbo/approvals/gate_test.exs` — 15 tests (G1-G15 covering start, request_approval with idempotency, approve/deny/spurious status flips, path-prefix filtering, parse-error resilience, :noproc wake tolerance, resolve_approval shortcut, crash-restart statelessness, isolated concurrent requests, concurrent request+resolve consistency, subscribe?: true PubSub integration)

**Modified:**
- `.planning/phases/03-agents-routing-kernel-permissions-budgets/AUDIT_EVENTS.md` — Added approval.spurious, approval.parse_error, approval.rename_failed rows
- `lib/glorbo/agent/server.ex` — Reordered handle_call clauses to silence pre-existing grouping warning

## Decisions Made

All six locked decisions from the plan's frontmatter are reflected in code:

1. **D-34 sentinel shape** — `lib/glorbo/approvals/gate.ex` `write_sentinel/4` writes the exact frontmatter spec: `agent, task_path, task_id, requested_at (ISO 8601), requesting_trigger` + human-readable body.
2. **D-35 PubSub-driven approval** — Gate subscribes to `"company:<co>:projects"` in `init/1`; tests inject via `send(pid, {:file_event, ...})` directly.
3. **D-36 per-company Gate** — Minimal state (`company, base, repo, audit_fun, audit_server, agent_wake_fun, pubsub`); no in-memory pending map.
4. **D-37 denial flow** — `resolve_denied/3` upserts state `"denied"` + audits + `File.rename/2` to `history/tasks/<task_id>.md` + sentinel removal; `denial_reason` preserved in audit payload AND `tasks_approval_state.reason` column.
5. **Agent.Server integration (AGT-05)** — `agent_wake_fun` dep-injected; default is a safe no-op; Plan 03-05's supervisor wires real Registry lookup + `Glorbo.Agent.Server.wake/3`. `safe_wake/4` tolerates `:noproc` and exceptions.
6. **TasksApprovalState atomic upsert** — `resolve_granted` / `resolve_denied` use `on_conflict: [set: [status, resolved_at, reason]]` + `conflict_target: [:task_path]`; `request_approval` uses `on_conflict: :nothing` to preserve the first awaiting record under concurrency. SEC-04 invariant "single resolution per task" enforced at DB level via unique index.

**Additional judgment calls made during execution:**

- **`resolve_approval/3` implementation** — chose `send/2` + `:sys.get_state/1` synchronisation instead of a separate `handle_call`. Keeps the test shortcut on the SAME code path as the real PubSub-driven `handle_info`, so behaviour parity is guaranteed.
- **`default_agent_wake/3` in Plan 03-04** — chose `:ok` no-op default (not Registry.lookup + Agent.Server.wake/3) because Plan 03-05's supervisor is the wiring point. Tests that need a real wake inject their own fn; production dep-inject at Gate start_link in Plan 03-05.
- **`upsert_awaiting` uses `on_conflict: :nothing`** — if the task is already `awaiting` (re-request), keep the original row intact (preserves `requested_at`). If somehow already `approved`/`denied` (shouldn't happen in practice — agent was already resolved), also leave alone; the next status-flip will re-resolve.
- **`safe_wake` catches `:exit`** — `GenServer.call` raises :exit on :noproc / timeout; our safe wrapper must handle both `rescue` (for raise) and `catch :exit, reason` (for call failures).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] `mix compile --warnings-as-errors` failed on pre-existing handle_call clause ordering in agent/server.ex**
- **Found during:** Task 2 (running Gate tests against the full compile gate specified in plan verification)
- **Issue:** `lib/glorbo/agent/server.ex` had `handle_call(:status, _from, state)` defined AFTER a private `handle_wake_idle/3` helper, which sat between two `handle_call` clauses. Elixir emits `warning: clauses with the same name and arity ... should be grouped together`. Plan 03-03 didn't catch this because that plan's verification ran `mix compile` without `--warnings-as-errors`. The Gate plan's verification requires `--warnings-as-errors` clean, so this blocks.
- **Fix:** Reordered the clauses so all three `handle_call` clauses (`:wake` with guard, `:wake` without guard, `:status`) sit together, with `handle_wake_idle/3` private helper moved AFTER them. No behavioural change.
- **Files modified:** `lib/glorbo/agent/server.ex`
- **Verification:** `mix compile --warnings-as-errors` clean; `mix test` 374/374 still green; agent server tests unaffected (12/12 still pass).
- **Committed in:** `aad11ca` (Task 2 commit, bundled with Gate changes since they share the compile gate)

**2. [Rule 1 - Bug] `refute File.exists?(sentinel_path)` raced with Gate's handle_info completion in G4/G10**
- **Found during:** Task 2 (first full run of gate_test.exs)
- **Issue:** After the test process's `assert_receive {:wake, ...}` fires, the Gate's `handle_info` may not have completed yet — `safe_wake` sends the message BEFORE `File.rm`. The test then immediately checked `refute File.exists?(sentinel_path)` and failed intermittently because the rm hadn't landed.
- **Fix:** Inserted `_ = :sys.get_state(pid)` between the `assert_receive {:wake, ...}` and the `refute File.exists?`. This round-trips a call through the GenServer, which by OTP semantics cannot return until the prior `handle_info` fully completes. Deterministic synchronisation without `Process.sleep`.
- **Files modified:** `test/glorbo/approvals/gate_test.exs`
- **Verification:** G4 + G10 pass deterministically across 3 consecutive runs (seeds 0, default, 727318). Full 15/15 Gate tests green.
- **Committed in:** `aad11ca` (Task 2 commit)

**3. [Rule 1 - Bug] Acceptance criterion `! grep -E 'String\.to_atom|String\.to_existing_atom' lib/glorbo/task_definition.ex` matched a docstring mention**
- **Found during:** Task 2 final verification
- **Issue:** My `@moduledoc` for `TaskDefinition` explicitly noted "No `String.to_atom/1` on user input" as a safety note — the literal string `String.to_atom` in the docstring caused the plan's negative grep to match, signaling (incorrectly) that the code calls `String.to_atom`.
- **Fix:** Rephrased the docstring to "No atom coercion on user input" — preserves the safety note while satisfying the literal grep criterion. Zero code change; just documentation wording.
- **Files modified:** `lib/glorbo/task_definition.ex`
- **Verification:** Grep now returns nothing; safety note intact in docstring.
- **Committed in:** `aad11ca` (Task 2 commit, bundled as it was a final-verification touch)

---

**Total deviations:** 3 auto-fixed (1 blocking compile gate + 1 flaky test + 1 docstring wording). No architectural changes; no scope creep.
**Impact on plan:** Implementation scope hit exactly. All 16 TaskDefinition behaviours and all 15 Gate behaviours specified in the plan's `<behavior>` sections are covered by tests.

## Issues Encountered

- **Pre-existing credo clean file modification warning:** `mix format` reformatted `test/glorbo/approvals/gate_test.exs` after the initial write (ran formatter to normalise helper fn signatures). Absorbed by the formatter.
- **Registry-lookup default wake path not yet wired:** Plan 03-04 ships with `default_agent_wake/3` as a no-op; Plan 03-05's supervisor will replace this at Gate start_link time. Tests pass explicit `agent_wake_fun` to cover the wake-path behaviour.

## User Setup Required

None — no external services configured. Gate is pure Elixir + SQLite; all dep-injected for tests.

## Next Phase Readiness

**Ready for Plan 03-05 (Supervisor wiring + Watcher PubSub extension):**

- `Glorbo.Approvals.Gate` is a drop-in child of `Glorbo.Company.Supervisor`. Add as 7th child under Router (or as its own sibling — plan will decide). Pass `agent_wake_fun:` that does `Registry.lookup(Glorbo.Agent.Registry, {:agent_server, company, agent}) |> Glorbo.Agent.Server.wake(pid, trigger, task_map)`.
- `Glorbo.Filesystem.Watcher` (Phase 2) needs extending to broadcast `{:file_event, rel_path, events}` on topic `"company:<co>:projects"` for `projects/**/*.md` events. Plan 03-04 laid the contract; Plan 03-05 ships the extension. Until then, Gate tests use direct `send(pid, ...)` or `Phoenix.PubSub.broadcast/3`.
- `TaskDefinition.parse_file/2` is ready for `Glorbo.Filesystem.InboxScanner` (Plan 03-05) that reads agent inbox markdown messages or tasks and feeds them to `Agent.Server.wake(pid, :inbox, task_map)`.

**Ready for Agent.Server dispatch pipeline (Plan 03-03 already shipped):**

- `Agent.Server.wake(pid, :director_approval, task_map)` is the call Gate makes after approval. Task_map includes `task_id, task_path, prompt, trigger: :director_approval`. Plan 03-03's Dispatch pipeline will emit `agent.wake` audit with `trigger: "director-approval"` matching AUDIT_EVENTS.md registry.

**Deferred work tracked:**

- Router integration with approval flow — Agent.Dispatch currently calls `:bwrap_not_wired`; Plan 03-05 wires the real `Glorbo.Sandbox.Bwrap.start/2`. When dispatching an approved task, the Task_map with `:director_approval` trigger flows through the existing Dispatch pipeline unchanged.
- "Reopen denied task" flow — D-37 specifies denied tasks move to `history/tasks/` one-way. If a Director wants to retry, they manually move the file back. Out of scope for v0.0.1.
- Multi-approver workflow — `requires_approval: producer` et al. are parse-time errors in v0.0.1. Only `director` is supported (D-02 family).

---

## Self-Check: PASSED

Verification of all claimed artifacts:

```
[x] /var/home/user/Documents/glorbo/lib/glorbo/task_definition.ex — FOUND
[x] /var/home/user/Documents/glorbo/lib/glorbo/approvals/gate.ex — FOUND
[x] /var/home/user/Documents/glorbo/test/glorbo/task_definition_test.exs — FOUND
[x] /var/home/user/Documents/glorbo/test/glorbo/approvals/gate_test.exs — FOUND
[x] Commit 43bacea — FOUND (feat(03-04): add Glorbo.TaskDefinition parser)
[x] Commit aad11ca — FOUND (feat(03-04): add Glorbo.Approvals.Gate with PubSub-driven status resolution)
[x] mix test test/glorbo/task_definition_test.exs — 16 tests, 0 failures
[x] mix test test/glorbo/approvals/gate_test.exs — 15 tests, 0 failures
[x] mix test (full suite) — 374 tests, 0 failures (17 excluded)
[x] mix credo --strict lib/glorbo/task_definition.ex lib/glorbo/approvals/gate.ex — 0 issues (43 mods/funs)
[x] mix compile --warnings-as-errors — clean
[x] mix format --check-formatted — clean
[x] AUDIT_EVENTS.md — approval.spurious present
[x] AUDIT_EVENTS.md — approval.parse_error present
[x] AUDIT_EVENTS.md — approval.rename_failed present
```

---
*Phase: 03-agents-routing-kernel-permissions-budgets*
*Completed: 2026-04-16*
