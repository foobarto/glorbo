---
kind: company-template/v1
name: bench-softdev
version: 1
min_glorbo_version: 0.0.4
archetype: software-development
description: Engineer + reviewer agents working on a small static codebase.
default_provider: claude-code
default_model: claude-sonnet-4-5
fixtures_dir: fixtures
tags: [benchmark, software, engineering]
---

# bench-softdev — Software Development Benchmark

Scaffolds a small engineering shop: an **engineer** agent who
implements code changes, and a **reviewer** agent who critiques the
engineer's patches. They work against a frozen mini-codebase under
`fixtures/repo/`.

Use this template to compare how different CLI-tool providers handle
everyday software tasks against identical inputs.

Fixtures are bind-mounted read-only at runtime — agents can read the
codebase, but the canonical copy under `priv/templates/` is never
mutated between runs.
