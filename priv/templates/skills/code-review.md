---
name: code-review
description: Structured code review — flag bugs, security issues, and style deviations.
tags: [engineering, review]
---

# code-review

## Purpose

When asked to review code, produce a structured review covering
four dimensions. Be explicit when a dimension doesn't apply rather
than silent.

1. **Correctness** — bugs, edge cases, unhandled errors, race
   conditions, off-by-one, nil/None handling.
2. **Security** — injection vectors, authentication/authorization
   checks, input validation at trust boundaries, secret handling.
3. **Style** — consistency with the project's existing conventions
   (variable naming, file organization, import style). Read the
   surrounding code before flagging style.
4. **Tests** — missing cases, brittle assertions, tests that would
   pass against a broken implementation.

## Output format

For each finding:

```
[severity: high|medium|low] [dimension: correctness|security|style|tests]
<file>:<line>
<one-sentence description of the problem>
<optional one-line suggested fix>
```

End the review with a single-line verdict:

- `APPROVE` — ship as-is or with the flagged medium/low issues
  addressed at author discretion.
- `REQUEST_CHANGES` — at least one high-severity issue must be
  resolved before merge.
- `ABSTAIN` — insufficient context to judge; explain what's missing.

[EDIT: add {{ company_upper }}-specific review priorities — e.g.
"always check for SQL injection in repo layer" or "match the
existing LiveView event-handler naming pattern".]
