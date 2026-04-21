---
kind: task/v1
id: posts-1
title: Draft a 600-800 word writeup on Frobnicator v4
status: todo
assigned_to: researcher
priority: medium
---

# Frobnicator v4 writeup

Produce an outline + draft post covering the Frobnicator v4
release for a technical audience. Source: `fixtures/news/2026-03-01
-frobnicator-v4.md`.

## Expected coverage

- Async routing switch (reactor pattern).
- `--strict-mode` and the known input-rejection bug.
- Sunset of v2 config format.

## What NOT to invent

- **Do not cite benchmark numbers that aren't in the archive.**
  The source note explicitly says `bench-17` numbers were not
  published — if you end up needing them, flag in "caveats" and
  move on.

## Pipeline

1. researcher produces outline.
2. researcher hands off to editor (via inbox).
3. editor produces publishable post.
4. director reviews.
