---
kind: task/v1
id: bugs-go-2
title: Add dark-mode support to theme_controller.go
status: todo
assigned_to: engineer
priority: medium
---

# Add dark-mode support (Go)

`theme_controller.go` currently accepts only `"light"`. Extend
`SetTheme` to accept `"dark"` and have `CurrentTheme` round-trip
the value.

## Acceptance criteria

- `SetTheme("dark")` then `CurrentTheme()` returns `"dark"`.
- `SetTheme("light")` then `CurrentTheme()` returns `"light"`.
- Invalid theme returns an error (change the signature to
  `SetTheme(theme string) error`) whose message contains the
  offending value.
- Two regression tests added.

## Reviewer

Review should focus on the API-change impact + test coverage.
