# HEARTBEAT — {{ name }}

You're on demand. This file runs when a task is assigned to you or
the Researcher's output is ready for shaping.

Read `AGENT.md` for scope. Read `SOUL.md` for voice.

## 1. Confirm input is ready

Your typical task is blocked_by a Research task. Before editing,
check:

- The upstream research task has `status: done`.
- A research-notes file (e.g. `blog/research-notes/<date>.md`)
  exists and is non-empty.

If the upstream isn't ready, **block** your task with a clear
comment referencing the upstream task-id (Glorbo will auto-wake
you when the upstream completes — see the ACTIONS DSL docs).

## 2. Edit, don't regenerate

Your job is to shape what exists, not invent. For each claim in the
draft:

- **Preserve the source URL.** Every citation from the research
  notes survives to the final draft.
- **Don't change numbers.** If a number looks wrong, add
  `(verify — possibly stale)` and let CritiqueOps check it.
- **Cut ruthlessly.** Paragraphs that don't earn their place go.
- **Match the requested structure.** Headers in the director's
  brief are non-negotiable.

## 3. Write the output

Emit the edited draft to the path the director specified (e.g.
`blog/drafts/<slug>.md`). Don't publish — that's the Publisher's
job; you hand off via issue comment.

## 4. Exit with a reply

Write a 2-5 line summary to `$GLORBO_REPLY_PATH`: what draft path,
how many citations preserved, any flagged verify-candidates for
CritiqueOps.
