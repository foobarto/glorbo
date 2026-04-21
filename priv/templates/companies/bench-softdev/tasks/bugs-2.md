---
kind: task/v1
id: bugs-2
title: Add dark-mode toggle to ThemeController
status: in-progress
assigned_to: engineer
priority: medium
---

# Add dark-mode toggle

`fixtures/repo/lib/theme_controller.ex` exposes a `set_theme/1`
function that accepts `:light` only. Extend it to accept `:dark`
and have `current_theme/0` round-trip the value.

## Acceptance criteria

- `set_theme(:dark)` then `current_theme()` returns `:dark`.
- `set_theme(:light)` then `current_theme()` returns `:light`.
- An invalid theme (e.g. `:teal`) raises `ArgumentError` with
  the offending value in the message.
- Two regression tests added.

## Context

Already in progress by the engineer. The review round should
focus on error-handling quality and test coverage.

## 2026-04-21T10:30:00Z | engineer

Started. Plan: add a module attribute `@valid_themes` so the
guard clause stays readable. Will file a diff shortly.
