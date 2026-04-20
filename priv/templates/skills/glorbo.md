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

## What you can and can't do today

Glorbo is filesystem-first. Today you have these action surfaces:

### ✅ Your reply (primary channel to the Director)

Everything you write to `$GLORBO_REPLY_PATH` is visible to the
Director in the UI's AgentLive Runs tab, as the audit
`agent.complete` event's `reply_preview`. Use the reply for:

- Status updates ("all green").
- Hire requests ("I need a Researcher — here's the role spec").
- Questions that need Director decision.
- Links to work you did in `/workspace/` (Director can browse).

The reply is your main outbound channel. Make it dense and
actionable.

### ✅ Writing to /workspace

Your `/workspace/` is rw — use it freely for drafts, notes,
research caches, etc. The Director can browse it via the AgentLive
file tree. Things you put here are visible but not "routed" —
they just sit in your private area.

### ✅ Writing to /outbox

`/outbox/` is also rw but NOT currently routed — it's a staging
area for files you'd like to share. Today the Director can only
see them by opening your agent page. Future versions will route
it; for now treat `/outbox/` and `/workspace/` as interchangeable.

### ✅ ACTIONS DSL (embedded in reply body)

Your reply body may include an `ACTIONS:` block that the Router
parses and executes:

```
ACTIONS:
  reassign_to: <agent-slug>
  status: <todo | in-progress | review | done | pending | approved | denied>
```

Limited today — just status + reassign. Mostly useful when you're
handed a task (`GLORBO_TASK_ID` set) and want to change its state.

### ❌ Direct channel / task writes (not available to agents)

You CANNOT directly:
- Append to `companies/<co>/channels/<ch>.md`.
- Create files under `projects/<proj>/tasks/`.
- Create new agents.
- Comment on other agents' tasks.

All of that happens through the Director — who reads your reply
and takes action. Write clear, actionable replies.

### How to request a hire

Include it in your reply:

> I need a Researcher reporting to me. Role: scan HN/PH/Reddit for
> SaaS opportunities. Use adapter `opencode`, model
> `lmstudio/qwen/qwen3.6-35b-a3b`, heartbeat `"* * * * *"`.

The Director reads this and runs `glorbo new agent <co>/researcher`.

### How to "message" another agent

Write your message into the reply body and name the target agent.
The Director will route it, or @-mention them from a channel. You
cannot create mention files directly.

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
