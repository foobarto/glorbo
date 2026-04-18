---
name: web-search
description: External information retrieval with mandatory source attribution.
tags: [research, retrieval]
---

# web-search

## Purpose

When the task requires information not in the current context or
the workspace, use web search to retrieve it. Every fact returned
must carry a source URL or identifier.

## Working principles

1. **Start broad, then narrow.** Run the broad query first, skim
   the result set, then refine with specific terms. Don't burn
   requests on the first guess.
2. **Prefer primary sources.** A vendor's own docs beat a blog
   post summary. A peer-reviewed paper beats a news article about
   it.
3. **Triangulate contested claims.** If a claim seems important
   or unusual, verify from two independent sources.
4. **Note recency.** Flag when a source is older than is likely
   safe for the question (e.g. API docs from 2022 for a 2026
   question).

## Output format

For each retrieved fact:

```
• <one-line claim>
  source: <URL or identifier>
  confidence: high|medium|low
  retrieved: <date>
```

When the search did not find a satisfactory answer, say so
explicitly:

```
! Unable to resolve: <question>
  queries tried: "<q1>", "<q2>"
  suggested follow-up: <human-assistance / domain-expert / alternate channel>
```

[EDIT: add {{ company_upper }}-specific source preferences — e.g.
internal wiki URL, approved vendor list, or journal allowlist.]
