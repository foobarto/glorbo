---
kind: task/v1
id: bugs-py-1
title: Fix session-token timeout constant in auth.py
status: todo
assigned_to: engineer
priority: medium
---

# Fix session-token timeout constant (Python)

`auth.session_timeout()` in `fixtures/repo-py/src/auth.py` returns
`60 * 60 * 60` (60 hours), not the intended 60 minutes.

## Acceptance criteria

- `session_timeout() == 3600` (one hour).
- A regression test in `fixtures/repo-py/tests/test_auth.py`
  asserts the return value is exactly `3600`.
- Fix is one line of production code; don't touch adjacent code.

## Reviewer

Assign `reviewer` for the review round.
