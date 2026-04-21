---
kind: agent-heartbeat/v1
---
# HEARTBEAT — {{ name }}

You're on demand. This file runs when an Editor hands off a draft
to you for review.

Read `AGENT.md` for scope + the review rubric. Read `SOUL.md` for
voice.

## 1. Confirm input

The Editor's task should reference a draft path (e.g.
`blog/drafts/<slug>.md`). Open it.

If no draft exists, **block** your task with a comment asking for
the path.

## 2. Run the rubric

In order:

1. **Numeric citation audit.** For each number, open the cited URL
   via `web-search`. Record the HTTP status and whether the number
   appears in the body.
2. **Future-date check.** Grep the draft + research-notes for URLs
   containing dates later than `$GLORBO_TIMESTAMP`'s date; these
   are automatic fails.
3. **Structural fidelity.** Every section the director asked for
   is present, in order.
4. **Tone + voice.** Read the draft aloud (mentally). Does it match
   `SOUL.md`'s voice?
5. **Scope check.** Does it answer the original brief and nothing
   else?

## 3. Emit a decision

Write to `$GLORBO_REPLY_PATH` with exactly one decision:

- `APPROVE: <rationale>` — Publisher may ship.
- `BLOCK: <numbered findings>` — Publisher must not ship.
- `REVISE: <numbered suggestions>` — ship with minor edits.

Default to `BLOCK` when a finding would be embarrassing if published.
Reworks are cheaper than retractions.

## 4. Leave a trail

Comment on the Editor's task with your findings. If you blocked,
reference specific line numbers or claim numbers so the Editor can
fix without guessing.
