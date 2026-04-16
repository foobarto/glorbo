---
status: partial
phase: 03-agents-routing-kernel-permissions-budgets
source: [03-VERIFICATION.md, 03-05-PLAN.md Task 5]
started: 2026-04-16T07:30:00Z
updated: 2026-04-16T07:30:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Claude Code round-trip inside bwrap (SC-2 + SC-8 + SC-9)

test: Create `test-engineer` agent with `provider: claude-code`, `network: api-only`; write task to its inbox; boot Glorbo (`iex -S mix`); tail `agents/test-engineer/stdout.log` + `audit/$(date +%Y-%m).jsonl`.
expected: Within ~1 min: session JSONL appears at `agents/test-engineer/workspace/.glorbo-claude/projects/...`; Director's `~/.claude/projects/` unchanged (session-dir redirect works); `Glorbo.Repo.get_by(Glorbo.Budget, agent_slug: "test-engineer", year_month: "2026-04")` returns a row with non-zero tokens; audit contains `agent.dispatch` + `agent.complete` + `budget.usage`.
result: [pending]

### 2. `--unshare-net` blocks egress (SC-5)

test: `bwrap --unshare-user-try --unshare-ipc --unshare-pid --unshare-net --die-with-parent --cap-drop ALL --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --symlink usr/sbin /sbin --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp -- /bin/sh -c 'curl --max-time 3 https://api.anthropic.com || echo EGRESS_BLOCKED'`
expected: Output contains `EGRESS_BLOCKED` (no network reached).
result: [pending]

### 3. Audit log shape + append-only (SC-3 + SC-6 + SC-7)

test: `cat ~/.glorbo/companies/acme/audit/$(date +%Y-%m).jsonl | jq -c '.action' | sort -u`; then check file mode + per-line integrity via jq on `.ts, .action`.
expected: actions subset from AUDIT_EVENTS.md (agent.wake, agent.dispatch, agent.complete, budget.usage, route.*, approval.*, scheduler.*); no "BAD LINE" output; file mode 0640 or stricter (no group/other write).
result: [pending]

## Summary

total: 3
passed: 0
issues: 0
pending: 3
skipped: 0
blocked: 0

## Gaps
