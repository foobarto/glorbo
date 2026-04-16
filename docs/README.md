# Glorbo Docs

This directory holds written artifacts that live alongside the code:
design records, conventions, and anything too long-form for CLAUDE.md
or inline comments.

## Layout

```
docs/
├── README.md          — you are here
└── geps/              — Glorbo Enhancement Proposals (design records)
    ├── README.md      — index of all GEPs + status legend
    ├── 0000-template.md
    ├── 0001-…         — GEP-N, one file per proposal
    └── …
```

## Subdirectories

### `geps/` — Glorbo Enhancement Proposals

Numbered, append-only design records capturing the *what* and *why*
of non-trivial changes. Modelled after Python PEPs and Rust RFCs. See
[`geps/README.md`](./geps/README.md) for the index and
[`geps/0001-gep-purpose-and-guidelines.md`](./geps/0001-gep-purpose-and-guidelines.md)
for the full process.

Quick-start for proposing a GEP: open a GitHub issue labelled
`gep-proposal` first, wait for maintainer triage, then open a GEP PR
as either `Placeholder` (idea parked, open questions flagged) or
`Draft` (design worked out, ready for review). See
[CONTRIBUTING.md §2](../CONTRIBUTING.md) for the full contributor
flow.

## What does NOT live here

- **Living architectural reference** — `DESIGN.md` at the repo root.
- **User-facing pitch** — `README.md` at the repo root.
- **Shipped-change log** — `CHANGELOG.md` at the repo root.
- **Contributor guide** — `CONTRIBUTING.md` at the repo root.
- **Claude Code guidance** — `CLAUDE.md` at the repo root (automatic
  context for AI sessions).
- **Security policy** — `SECURITY.md` at the repo root.
- **Historical GSD planning artifacts** — removed 2026-04-17; recover
  via `git log --all --diff-filter=D -- .planning/` if ever needed.

## Adding new top-level sections

If you need a new subdirectory under `docs/` (e.g. `guides/`,
`adr/`, `api/`), the bar is: **is this something a contributor or
user needs to read regularly, and would it clutter the repo root or
the GEP tree?** If yes, add it with a short explanation in this
README. If it's a one-off note, consider a GEP or a comment in the
code instead.
