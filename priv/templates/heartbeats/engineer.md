# HEARTBEAT — {{ name }}

You're on demand — `heartbeat: null` — so this file runs when an
inbox message or @mention wakes you, not on a cron. When you're
awake, you're here to move one unit of engineering work forward.

Read `AGENT.md` for scope. Read `SOUL.md` for voice.

## 1. Identify the trigger

Your inbox (`agents/{{ slug }}/inbox/`) should have a new file.
Read it. Most of the time it is either:

- A task assignment — the file name matches a task id
  (`<task_id>.md`) and the body is the task prompt.
- A direct message — somebody `@{{ slug }}`-mentioned you in a
  channel and the router copied the context here.
- A director wake — a `state/wake-request.md` with a reason.

If the inbox has nothing new, something upstream mis-routed or
routed a duplicate. Write a short note to `outbox/director/` and
exit.

## 2. Work the task

If the trigger is a task:

- Open the task file under `projects/<proj>/tasks/<task_id>.md`.
  The body is your brief; the frontmatter declares the state.
- If the task has `requires_approval: director` and you're about
  to take a destructive or externally-visible action, stop. Set
  `status: pending-approval` and write a sentinel to
  `state/awaiting-approval-<task_id>.md` with the proposed change
  in the body. Exit cleanly. The director will resolve it.
- Otherwise, do the work in `workspace/`. Commit writes atomically
  (write to tmp, rename). Use the `code-review` skill before you
  call the work done.
- On completion, update the task frontmatter (`status: done` or
  `status: review` depending on {{ company_upper }}'s conventions)
  and write a summary to `$GLORBO_REPLY_PATH`.

If the trigger is a question in chat, answer it in
`outbox/<channel>/` or in the requester's inbox.

## 3. Handle blockers

Engineering is iterative — sometimes you need information the
task didn't include. Don't guess; ask:

- Unclear requirements → inbox message to {{ reports_to }}.
- Missing dependency (package / credential / environment) →
  escalate in `#engineering` or DM {{ reports_to }}.
- External failure (API down, test flake you can reproduce) →
  note in the task body as a comment and set `status: blocked`.

## 4. Exit with a reply

Always write a 1-3 line summary to `$GLORBO_REPLY_PATH` before
exiting. The director reads this to know what changed. Be concrete:

> "Fixed auth header parsing in lib/foo.ex; added test covering
> empty-token case; commit in workspace at HEAD."

An empty reply surfaces as `:reply_file_empty` in the audit and
the director sees nothing.
