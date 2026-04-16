Run a daily standup for the Glorbo project. Gather status from all sources
and produce a concise summary.

## Steps

1. **Git status:** Check recent commits, branches, uncommitted changes
2. **Tasks:** Read `.state/tasks.md` — what's in progress, blocked, done recently
3. **Test health:** Read `.state/test-status.md` — any failures or regressions
4. **Messages:** Read `.state/inbox.md` — any unhandled messages
5. **Decisions:** Read `.state/decisions.md` — any pending decisions
6. **Activity:** Read `.state/activity-log.md` — what happened recently

## Output Format

```
## Standup — {date}

### Done Since Last Standup
- {completed items}

### In Progress
- {current work and who's on it}

### Blocked
- {blockers and what's needed to unblock}

### Test Health
- {pass/fail summary}

### Needs Attention
- {unhandled messages, pending decisions, stale tasks}

### Next Up
- {highest priority items ready to start}
```

Keep it concise. Flag problems, don't bury them.
