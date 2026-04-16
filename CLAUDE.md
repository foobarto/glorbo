# Glorbo — Agent Operations Manual

## Quick Start for AI Agents

1. Read this file first
2. Read `.state/tasks.md` for current work
3. Read `.state/agents.md` for who's doing what
4. Read `DESIGN.md` for the full architecture you're building toward

## How This Works

Glorbo uses AI CLI tools (Claude Code, Gemini CLI, Codex CLI) as agents to build
itself. There are no containers, no Python workers, no Elixir runtime yet — those
are what we're building. Right now, the agents ARE the CLI tools, coordinated
through markdown files.

Any tool that can read and write files can participate as an agent.

### Principles

- **Markdown is the source of truth.** All coordination state lives in `.state/`.
  Tasks, test status, agent assignments, communication — all markdown files.
- **Skills define capabilities.** Reusable skill definitions live in `skills/`.
  They get injected into agent prompts when needed.
- **Slash commands are agent entry points.** `.claude/commands/` contains
  commands that activate agent personas and workflows.
- **Test status is tracked.** `.state/test-status.md` tracks what passes, what
  fails, and what's missing. Updated after every test run.
- **Activity is logged.** `.state/activity-log.md` records what agents did.
  Append-only. Human-readable history.

## Workspace Map

```
.claude/commands/         — Slash commands (agent personas + workflows)
.state/                   — Coordination state (markdown source of truth)
  tasks.md                — Task board: backlog, in-progress, done
  agents.md               — Agent registry: who's available, what they do
  test-status.md          — Test results: pass/fail/missing by component
  activity-log.md         — What happened: append-only log
  inbox.md                — Inter-agent messages and handoffs
  decisions.md            — Questions needing human input
skills/                   — Reusable skill definitions (injected into agents)
DESIGN.md                 — Full architecture document (what we're building)
README.md                 — Project README
assets/                   — Landing page
```

## Agent Roles

| Role | CLI Tool | Handles |
|------|----------|---------|
| **director** | Human | Decisions, priorities, approvals |
| **developer** | Claude / Codex / Gemini | Implementation, bug fixes, refactoring |
| **researcher** | Claude / Gemini | Architecture investigation, library evaluation |
| **tester** | Claude / Codex | Test writing, test running, coverage tracking |
| **reviewer** | Claude / Gemini | Code review, design review |

Any CLI tool can fill any role. The role defines the persona and responsibilities,
not the tool.

## Working With Tasks

Tasks live in `.state/tasks.md`. Each task has an ID, status, assignee, and
description.

### Task Lifecycle

```
backlog → in-progress → review → done
                ↓
            blocked (with reason)
```

### Before Starting Work

1. Read `.state/tasks.md` to find your assigned task
2. Update the task status to `in-progress`
3. Read any referenced files or dependencies
4. Do the work

### After Completing Work

1. Update the task status to `review` or `done`
2. If tests exist, run them and update `.state/test-status.md`
3. Append a summary to `.state/activity-log.md`
4. If handing off to another agent, add a message to `.state/inbox.md`

## Communication Protocol

### Inbox Messages

Agents communicate through `.state/inbox.md`. Messages follow this format:

```markdown
### MSG-{timestamp} | {from} → {to}
**Type:** {task-handoff | question | report | blocker}
**Task:** {task-id or n/a}

{message body}
```

### Decision Requests

When an agent needs human input, add to `.state/decisions.md`:

```markdown
### DEC-{timestamp} | {from}
**Status:** pending
**Task:** {task-id or n/a}
**Question:** {what needs deciding}
**Options:**
- Option A: ...
- Option B: ...
**Context:** {background}
```

## Test Status Tracking

`.state/test-status.md` tracks test results by component. Updated after every
test run.

```markdown
### {component}
- **Status:** pass | fail | missing | partial
- **Last run:** {timestamp}
- **Coverage:** {summary}
- **Failures:** {details if any}
```

## Code Conventions

These apply to the glorbo implementation as it gets built:

- Elixir: standard `mix format`, no compiler warnings
- TypeScript (if any): strict mode
- Tests: write tests alongside implementation
- Commits: clear messages describing what and why
- No secrets in files — API keys go in environment variables

## Commands (Slash Commands)

| Command | Purpose |
|---------|---------|
| `/developer` | Activate developer agent — pick up and implement tasks |
| `/tester` | Activate tester agent — write tests, run tests, track status |
| `/researcher` | Activate researcher agent — investigate approaches |
| `/reviewer` | Activate reviewer agent — review code and design |
| `/orchestrate` | Coordinate agents — assign tasks, check progress |
| `/standup` | Daily standup — summarize git, tasks, blockers |
| `/pick-up-work` | Find and start the highest-priority available task |
| `/ship` | Test, commit, push workflow |
| `/report` | Post a status report to activity log |
