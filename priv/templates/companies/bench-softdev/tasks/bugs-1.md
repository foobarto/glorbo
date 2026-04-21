---
kind: task/v1
id: bugs-1
title: Fix session-token timeout constant in auth.ex
status: todo
assigned_to: engineer
priority: medium
---

# Fix session-token timeout constant

The `Auth.session_timeout/0` function in
`fixtures/repo/lib/auth.ex` currently returns `60 * 60 * 60`,
which is 216,000 seconds (60 hours), not the intended 60 minutes.

## Acceptance criteria

- `Auth.session_timeout/0` returns `60 * 60` (3,600 seconds).
- A regression test in `fixtures/repo/test/auth_test.exs`
  (add one if missing) asserts the return value is exactly 3600.
- The fix is one line of production code; don't touch adjacent
  code.

## Reviewer

Assign `reviewer` for the review round. Engineer files a diff;
reviewer verdict goes back on this task.
