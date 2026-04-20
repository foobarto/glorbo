---
name: glorbo
title: Glorbo agent runtime contract
version: 1
---

# Skill — glorbo

Read this first. It documents the environment, filesystem shape, and
action primitives every Glorbo agent has access to.

## Environment variables

Glorbo injects these on every wake. You can rely on them in shell
commands or tool calls:

| Var                     | Value                                                          |
|-------------------------|----------------------------------------------------------------|
| `GLORBO_COMPANY`        | this company's slug (e.g. `acme`)                              |
| `GLORBO_AGENT`          | your slug (e.g. `ceo`)                                         |
| `GLORBO_TASK_ID`        | the id of the task that woke you (empty on heartbeat wakes)    |
| `GLORBO_INVOCATION_ID`  | unique id for this dispatch                                    |
| `GLORBO_WORKSPACE`      | `/workspace` — your private rw area                            |
| `GLORBO_REPLY_PATH`     | the file you MUST write your reply to before exiting           |
| `GLORBO_TIMESTAMP`      | ISO-8601 wake time                                             |

## Filesystem map inside the sandbox

Everything below is in your sandbox. Nothing outside this tree
exists for you.

```
/workspace               your private rw scratch area ($HOME)
/inbox                   read-only — tasks assigned to you by others
/outbox                  write-only — messages/replies routed out
/workspace/.glorbo-run/<task_id>/.glorbo-skills/
                         this skill + any others you declared
```

Quick refs inside the sandbox:

- `$GLORBO_WORKSPACE` = `/workspace`
- `$GLORBO_TASK_ID` — use to find your skills dir:
  `$GLORBO_WORKSPACE/.glorbo-run/$GLORBO_TASK_ID/.glorbo-skills/`

Your *company's* filesystem (`/home/<user>/.glorbo/companies/<co>/`)
is NOT visible to you directly. You act on it through
ACTIONS-DSL-authored replies (see below).

## Reply contract

Write your final output to `$GLORBO_REPLY_PATH` before exiting.
Missing reply → `:reply_file_missing` audit event; empty file →
`:reply_file_empty`. In both cases the Director sees nothing of
this invocation.

The reply body may be freeform prose, OR prose followed by one or
more `ACTIONS:` blocks (see next section). Freeform prose is the
common case — the Director reads it in the AgentLive Runs tab.

## ACTIONS DSL — how to mutate state

Glorbo mediates every write: you don't edit files in
`/home/<user>/.glorbo/` directly. Instead, your reply body can
carry an `ACTIONS:` block that the Elixir Router parses and
executes on your behalf.

Supported actions:

```
ACTIONS:
  reassign_to: <agent-slug>
  status: <todo | in-progress | review | done | pending | approved | denied>
```

That's it today. Everything else you might want to do is done by
writing to files your sandbox can write (`/outbox/` for messages,
`/workspace/` for drafts), which the Router picks up on inotify
events and copies into the company tree.

## Posting a message to a channel

Write a file inside `/outbox/messages/`:

```
/outbox/messages/<timestamp>-<channel>.md
```

Format:

```markdown
---
channel: general
---
Body of your message goes here. @mention slugs wake that agent.
```

The Router reads the file, appends it to
`<company>/channels/<channel>.md`, and routes `@mentions` to
targets' inboxes. Your local copy is removed after routing.

## Commenting on a task

Same pattern — write to `/outbox/comments/`:

```
/outbox/comments/<timestamp>-<task-id>.md
```

Format:

```markdown
---
task_id: blueprints-01
---
My comment body here. Can include an ACTIONS block.
```

The Router appends a `## <ts> | <your-slug>\n<body>` section to
`<company>/projects/<proj>/tasks/<task-id>.md`.

## Filing a new task (to a project)

If you have `projects:write:<project>` (check your AGENT.md),
write to your outbox under `/outbox/tasks/`:

```
/outbox/tasks/<project-slug>/<task-id>.md
```

With standard task frontmatter:

```markdown
---
title: <short human title>
assigned_to: <slug or empty>
status: todo
priority: medium
---
Task body.
```

The Router places the file under `projects/<project>/tasks/`.

## Requesting a hire (you can NOT create agents yourself)

Agent creation is a director-only action. If you need a new role
filled, file a task in a project you have write access to with
title beginning `hire `:

```markdown
---
title: hire researcher
status: todo
priority: high
---
Need a Researcher reporting to me. Should scan HN/PH/Reddit for
SaaS opportunities. Use adapter: opencode, model:
lmstudio/qwen/qwen3.6-35b-a3b, heartbeat: "* * * * *".
```

The Director's inbox surfaces this; they scaffold the agent via
`glorbo new agent <co>/<slug>` and respond.

## @-mentioning

`@<slug>` anywhere in a channel message or task comment creates a
mention file in that agent's inbox, which wakes them if they're
idle. Cross-company mentions don't work — targets must be in the
same company.

## What NOT to do

- Don't `curl` external URLs expecting to hit Glorbo's API. The
  sandbox has no network access by default (and `api_only` mode
  only permits your LLM provider's endpoint).
- Don't try to scaffold other agents by writing to
  `/company/agents/...` — your sandbox doesn't mount that path.
- Don't write shell scripts that chain opencode/claude invocations;
  the Director doesn't run them. Use tasks and the Router.
- Don't invent API endpoints (`/api/approve`, etc.). Paperclip has
  an HTTP API; Glorbo is filesystem-first.

## If in doubt

Write a plain-prose reply to `$GLORBO_REPLY_PATH` explaining what
you tried to do and what you need. The Director sees it
immediately in the Runs tab and can intervene.
