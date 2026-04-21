---
kind: company-template/v1
name: bench-tech-blog
version: 1
min_glorbo_version: 0.0.4
archetype: technical-blog
description: Researcher + editor agents drafting tech posts from a frozen news archive.
default_provider: claude-code
default_model: claude-sonnet-4-5
fixtures_dir: fixtures
tags: [benchmark, writing, research]
---

# bench-tech-blog — Technical Blog Benchmark

Scaffolds a two-agent publishing shop: a **researcher** who turns
the canned news archive under `fixtures/news/` into a post outline,
and an **editor** who polishes the draft.

Agents may consult online documentation (e.g. language specs,
standards), but they MUST NOT browse the actual "source" news —
every news item they cite has to come from `fixtures/news/`.
