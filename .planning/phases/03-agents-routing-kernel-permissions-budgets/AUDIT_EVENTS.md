# Phase 3: Audit Event Registry

Canonical reference for all Phase-3 audit event `action:` keys. Plans 02-05 MUST use these exact keys when calling `Glorbo.Company.AuditLog.append/2`.

Event keys are additive to Phase 2's set (which defined `init.*`, `reindex.*`, `doctor.*`).

## Event Table

| `action` | Actor | Fired By | Payload Schema |
|----------|-------|----------|----------------|
| `message.route` | sender_agent | Router | `from: string, to: string, msg_id: string, path: string` |
| `message.reject` | sender_agent | Router | `from: string, to: string, msg_id: string, reason: string, missing_permission: string` |
| `permission.denied` | sender_agent | Router | `from: string, target: string, requested_action: string, missing_permission: string` |
| `skill.missing` | system | Dispatch | `agent: string, skill_name: string` |
| `provider.unknown` | system | Dispatch | `agent: string, provider: string` |
| `budget.usage` | agent | BudgetTracker | `agent: string, task_id: string, prompt_tokens: integer, completion_tokens: integer, cost_usd_cents: integer, model: string` |
| `budget.alert` | system | BudgetTracker | `agent: string, year_month: string, used_cents: integer, cap_cents: integer, pct: integer` |
| `budget.hard_stop` | system | BudgetTracker | `agent: string, year_month: string, used_cents: integer, cap_cents: integer, attempted_task: string` |
| `approval.requested` | agent | Agent.Server | `agent: string, task_path: string, task_id: string` |
| `approval.granted` | director | Router | `agent: string, task_path: string, approved_at: string (ISO 8601)` |
| `approval.denied` | director | Router | `agent: string, task_path: string, denied_at: string (ISO 8601), reason: string` |
| `agent.wake` | system | Agent.Server | `agent: string, trigger: string` (trigger in: `inbox`, `heartbeat`, `mention`, `director-approval`, `director-request`) |
| `agent.dispatch` | system | Dispatch | `agent: string, task_path: string, provider: string, model: string, container_id: string` |
| `agent.complete` | agent | Dispatch | `agent: string, task_path: string, duration_ms: integer, exit_status: string` |
| `acl.reconcile` | system | Container startup | `company: string, agent_count: integer, rules_applied: integer` |
| `network.policy_applied` | system | Container startup | `company: string, agent: string, policy: string, allow_list_hash: string` |
| `agents.create_blocked` | sender_agent | Router | `from: string, attempted_target: string` |
| `scheduler.invalid_cron` | system | Scheduler | `agent: string, cron: string, reason: string` |

## Conventions

- **Actor:** `sender_agent` = the agent slug that triggered the event; `system` = Glorbo infrastructure; `director` = the human operator.
- **Timestamps:** Every audit entry carries a top-level `ts` field (UTC ISO 8601) added by `AuditLog.append/2` -- events do NOT include their own timestamp in the payload.
- **Append-only invariant:** These events are written via `Glorbo.Company.AuditLog.append/2` ONLY. No other code path may write to `audit/YYYY-MM.jsonl`. See CLAUDE.md invariant.
- **Naming:** `<noun>.<verb>` pattern. Nouns are stable across Phase 3; verbs may be extended in later phases but existing keys are never renamed or removed.

## Usage Example

```elixir
Glorbo.Company.AuditLog.append(company, %{
  action: "message.route",
  actor: "engineer",
  from: "engineer",
  to: "ceo",
  msg_id: "msg-2026-04-16-001",
  path: "agents/engineer/outbox/reply-001.md"
})
```
