Find and start the highest-priority available task.

## Steps

1. Read `.state/tasks.md`
2. Read `.state/inbox.md` for any task assignments directed to you
3. Find the highest-priority task that is:
   - In **Backlog** status
   - Not blocked (all `blocked-by` dependencies are in **Done**)
   - Matches your skills (or is unassigned)
4. Update the task to **In Progress** with yourself as assignee
5. Update `.state/agents.md` with your current task
6. Read any referenced design docs, existing code, or skills
7. Begin working on the task
8. When done:
   - Move task to **In Review** or **Done**
   - Run tests and update `.state/test-status.md`
   - Append summary to `.state/activity-log.md`
   - Post handoff message to `.state/inbox.md` if needed
