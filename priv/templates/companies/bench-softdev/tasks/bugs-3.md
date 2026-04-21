---
kind: task/v1
id: bugs-3
title: Sanitize HTML in CommentRenderer
status: todo
assigned_to: engineer
priority: high
---

# Sanitize HTML in CommentRenderer

`fixtures/repo/lib/comment_renderer.ex` currently emits user
comments as raw HTML. That's an XSS vector.

## Acceptance criteria

- Comments rendered through `CommentRenderer.render/1` escape
  `<`, `>`, `"`, `'`, and `&` in the body.
- A regression test verifies `<script>alert(1)</script>` is
  rendered as `&lt;script&gt;alert(1)&lt;/script&gt;`.
- URLs remain clickable — don't escape links that the caller
  already produced through `Link.wrap/1`.

## Reviewer

Security-sensitive. Reviewer should push back on any approach
that doesn't cover the four critical HTML metacharacters
(`<` `>` `"` `'`) plus `&`.
