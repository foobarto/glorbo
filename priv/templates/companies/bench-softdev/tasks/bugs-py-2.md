---
kind: task/v1
id: bugs-py-2
title: Add dark-mode support to theme_controller.py
status: todo
assigned_to: engineer
priority: medium
---

# Add dark-mode support (Python)

`theme_controller.py` currently accepts only `"light"`. Extend
`set_theme()` to accept `"dark"` and have `current_theme()`
round-trip the value.

## Acceptance criteria

- `set_theme("dark")` then `current_theme()` returns `"dark"`.
- `set_theme("light")` then `current_theme()` returns `"light"`.
- Invalid theme (e.g. `"teal"`) raises `ValueError` with the
  offending value in the message.
- Two regression tests added in
  `fixtures/repo-py/tests/test_theme_controller.py`.

## Reviewer

Review should focus on error-handling quality + test coverage.
