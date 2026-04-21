---
kind: task/v1
id: bugs-go-1
title: Fix session-token timeout constant in auth.go
status: todo
assigned_to: engineer
priority: medium
---

# Fix session-token timeout constant (Go)

`SessionTimeout()` in `fixtures/repo-go/auth.go` returns
`60 * 60 * 60` (60 hours), not the intended 60 minutes.

## Acceptance criteria

- `SessionTimeout() == 3600`.
- A regression test in `fixtures/repo-go/auth_test.go` asserts
  the return value is exactly `3600`.
- Fix is one line; don't touch adjacent code.
