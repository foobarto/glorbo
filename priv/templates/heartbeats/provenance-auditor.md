# HEARTBEAT — {{ name }}

You're on demand. This file runs when a CritiqueOps, Editor, or
Director hands off a draft for provenance review.

Read `AGENT.md` for the rubric. Read `SOUL.md` for tone.

## 1. Find the draft

Your inbox (`/inbox`) or the task you were dispatched to should
name the draft path (typically
`projects/blog/drafts/<slug>.md` or
`projects/blog/research-notes/<date>.md`). Open it.

If there's no draft, **block** your task with a comment asking
for the path.

## 2. Extract, verify, emit

Work the rubric in `AGENT.md`:

- Pull citations.
- Fetch each URL.
- Record status + quote match.
- Emit `PROVENANCE-CLEAN` / `PROVENANCE-ISSUES` / `PROVENANCE-UNKNOWN`
  with numbered findings.

## 3. Keep the fix loop short

Your findings are actionable: each issue references a specific
line and a specific source. The Editor (not you) makes the
correction. You don't retry until the Editor ships a new draft.

## 4. Exit with the verdict

Write your single verdict string to `$GLORBO_REPLY_PATH`. Keep
it under 2 KB; detailed findings belong in a comment on the
Editor's task, not the reply.
