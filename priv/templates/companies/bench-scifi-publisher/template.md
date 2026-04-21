---
kind: company-template/v1
name: bench-scifi-publisher
version: 1
min_glorbo_version: 0.0.4
archetype: creative-writing
description: Worldbuilder + writer drafting chapter openings consistent with a canon bible.
default_provider: claude-code
default_model: claude-sonnet-4-5
fixtures_dir: fixtures
tags: [benchmark, writing, creative]
---

# bench-scifi-publisher — Creative Writing Benchmark

Scaffolds a two-agent fiction shop. The **worldbuilder** vets
chapter outlines against the canon bible in `fixtures/canon/`; the
**writer** drafts the prose.

Fixture tests agents' ability to respect a static worldbuilding
document without inventing contradictory lore.
