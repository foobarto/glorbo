---
kind: task/v1
id: bugs-go-3
title: Sanitize HTML in comment_renderer.go
status: todo
assigned_to: engineer
priority: high
---

# Sanitize HTML in comment_renderer.go

`Render()` currently emits raw HTML. XSS vector.

## Acceptance criteria

- Render escapes `<`, `>`, `"`, `'`, and `&` in the Body field.
- A regression test verifies
  `Render(Comment{Body: "<script>alert(1)</script>", Author: "mal"})`
  escapes the script tag.
- Links pre-wrapped via `WrapLink` remain clickable — don't
  escape the `SafeLink.HTML` payload.

## Reviewer

Security-sensitive. Reject any approach that doesn't cover all
five HTML metacharacters.
