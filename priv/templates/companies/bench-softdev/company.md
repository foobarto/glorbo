---
kind: company/v1
slug: {{ slug }}
name: {{ name }}
mission: Benchmark how agents solve software-engineering tasks against a frozen mini-codebase.
template: bench-softdev
template_version: 1
provider_pin: {{ provider }}
model_pin: {{ model }}
---

# {{ name }}

Software-development benchmark company (bench-softdev). Engineer +
reviewer agents work on a small Elixir codebase in
`fixtures/repo/`.

**Scaffolded from `bench-softdev/v1`** — the fixtures are immutable
across runs. To compare providers, scaffold this template multiple
times with different `--provider` flags and run the canonical tasks
on each.

See `priv/templates/companies/bench-softdev/template.md` for the
manifest and GEP-26 for the broader design.
