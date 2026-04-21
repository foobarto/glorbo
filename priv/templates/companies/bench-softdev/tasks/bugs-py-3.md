---
kind: task/v1
id: bugs-py-3
title: Sanitize HTML in comment_renderer.py
status: todo
assigned_to: engineer
priority: high
---

# Sanitize HTML in comment_renderer.py

`comment_renderer.render()` currently emits raw HTML. That's an
XSS vector.

## Acceptance criteria

- Comments rendered via `render()` escape `<`, `>`, `"`, `'`, and
  `&` in the body before string formatting.
- Regression test verifies
  `render({"body": "<script>alert(1)</script>", "author": "mal"})`
  escapes the script tag.
- URLs pre-wrapped via `wrap_link()` remain clickable — don't
  escape the ("safe", "<a …>") tuple.

## Reviewer

Security-sensitive. Reject any approach that doesn't cover all
five HTML metacharacters (`<` `>` `"` `'` `&`).
