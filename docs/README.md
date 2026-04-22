# Glorbo wiki

Browsable knowledge base for Glorbo. `CLAUDE.md` at the repo root is
the lean high-level map; this directory is where the depth lives.
Read these when you need architectural detail, historical context,
or domain-specific conventions that don't belong in inline
comments.

## Layout

```
docs/
├── README.md                      ← you are here (wiki index)
├── DESIGN.md                      ← authoritative architecture spec
├── todo.md                        ← rolling punch list
├── verifying-releases.md          ← cosign verification for tagged releases
│
├── geps/                          ← Glorbo Enhancement Proposals
│   ├── README.md                     — index of every GEP + status
│   ├── 0001-gep-purpose-and-guidelines.md
│   └── 0NNN-…                        — one file per proposal
│
├── file-formats/                  ← on-disk file specs (auto-generated)
│   └── …                             — one per FileSpec module
│
├── testing/
│   ├── testplan.md                   — end-user manual acceptance plan
│   └── uat.md                        — browser UAT checklist
│
├── sessions/                      ← autonomous-session logs
│   └── 2026-04-21-autonomous-round.md
│
└── archived/                      ← historical artifacts (read-only)
    ├── plan-2026-04-21.md
    └── review-v0.0.3.md
```

## What's in each area

### `DESIGN.md` — authoritative architecture

The single architectural reference for Glorbo. If `DESIGN.md`
disagrees with a stale comment or a half-decayed note, `DESIGN.md`
wins. Updated whenever GEPs ship that change the architecture (see
CLAUDE.md §"Feature development — six-phase checklist" step 6).

### `geps/` — Glorbo Enhancement Proposals

Numbered, append-only design records capturing the *what* and *why*
of non-trivial changes. Modelled after Python PEPs and Rust RFCs.

- Entry point: [`geps/README.md`](./geps/README.md) — table of every
  GEP with status.
- Process: [`geps/0001-gep-purpose-and-guidelines.md`](./geps/0001-gep-purpose-and-guidelines.md).
- Shortcut: invoke the `glorbo-new-gep` skill in Claude Code to walk
  the Q&A.

### `file-formats/` — on-disk file specs

Generated from the `Glorbo.FileSpec.*` modules by
`mix glorbo.docs.file_formats`. Each spec documents frontmatter
schema, canonical key order, path regex, and validation rules for a
given file kind (e.g. `task_v1.md`, `proposal_v1.md`, `agent_v1.md`).

Don't hand-edit. Regenerate with `mix glorbo.docs.file_formats`; the
precommit gate catches drift.

### `testing/` — manual verification

- `testplan.md` — end-user-oriented acceptance pass (is the product
  usable from a first-time operator's perspective?).
- `uat.md` — rolling browser UAT checklist. Exercised per UX change.
  Includes the Bazzite-specific `agent-browser` workaround for
  running the browser automation locally.

Updated every time a UI surface ships.

### `sessions/` — autonomous-session logs

When Claude runs autonomously (via `/loop` or similar), session-level
design decisions that weren't appropriate for a full GEP live
here. One file per major session, named
`YYYY-MM-DD-<slug>.md`. Read-only once the session closes.

### `archived/` — past artifacts kept for history

Files that captured a plan or review at a point in time and were
then superseded by shipping work. Kept so the reasoning is
discoverable without digging through git. Read-only.

### `todo.md` — rolling punch list

Items noticed but not yet shipped. Updated at the end of every
working cycle. Not a roadmap — a scratch buffer between
observation and the next GEP or commit.

## What does NOT live here

Root-level files — standard open-source conventions:

| File                  | What it is                                 |
|-----------------------|--------------------------------------------|
| `README.md`           | User-facing pitch + install story          |
| `CHANGELOG.md`        | Canonical log of what's shipped            |
| `CONTRIBUTING.md`     | Contributor guide                          |
| `SECURITY.md`         | Security policy                            |
| `LICENSE`             | Legal (Apache-2.0)                         |
| `CLAUDE.md`           | Lean map for LLM assistants                |
| `AGENTS.md`           | 3-line redirect to `CLAUDE.md`             |

## Growing the wiki

New top-level subdirectories under `docs/` land when:

1. A specific area needs regular reference (not a one-off note).
2. It doesn't already fit under `geps/` or `file-formats/`.
3. It would clutter the repo root.

Add a short description to this file when you add a new subdir, so
the map stays in sync with the territory.

For one-off notes: prefer a GEP (if it's a decision worth
preserving) or an inline comment (if it's code-adjacent). Don't
scatter loose markdown.
