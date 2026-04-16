Post a status report to the activity log.

## Steps

1. Gather context:
   - What task were you working on?
   - What did you accomplish?
   - What's the current state?
   - Any blockers or follow-ups?

2. Append to `.state/activity-log.md` (most recent at top, below the `## Log` header):

```markdown
### {YYYY-MM-DD} | {agent-role}
**Action:** {task-completed | progress-update | blocker-report | handoff}
**Task:** {task-id}
**Summary:** {1-3 sentences of what happened}
**Next:** {what should happen next, or "none"}
```

3. If handing off to another agent, also post to `.state/inbox.md`:

```markdown
### MSG-{YYYYMMDD-HHMM} | {you} -> {recipient}
**Type:** task-handoff
**Task:** {task-id}

{What you did, what's left, what they need to know}
```
