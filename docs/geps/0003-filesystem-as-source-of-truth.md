---
gep: 3
title: Filesystem as Source of Truth
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-17
implemented-in: v0.0.1
requires: [2]
see-also: [7, 32]
extended-by: [21, 22, 25]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit from DESIGN.md §3 Key Invariants.
  - date: 2026-04-17
    status: Accepted
    note: Canonical record of the derived-data contract.
  - date: 2026-04-17
    status: Implemented
    version: v0.0.1
    note: Invariant held since v0.0.1 shipped; v0.0.2 did not regress it. Retrofitted status.
---

# GEP-3: Filesystem as Source of Truth

## Purpose

Glorbo treats the filesystem as the authoritative record of every
user-visible artifact — company config, agent definitions, tasks, chat
logs, audit events — and treats SQLite as a rebuildable index. This GEP
captures why that inversion matters, what it means in practice, and
what constraints it imposes.

This is an Informational GEP: it documents an invariant that already
holds in v0.0.1/v0.0.2, not a proposed change. The GEP exists because
several downstream design choices (backup/restore, upgrade, multi-host
portability, audit, the one-way inbox/outbox flow) are only
understandable against this baseline.

See also **GEP-7** for how SQLite specifically behaves under this
model, and **GEP-2** §"Architectural pillar 2" for the one-paragraph
summary.

## The invariant

> Every piece of Glorbo state that a user owns — agent config, chat
> history, task list, budget, audit log — lives as markdown or JSONL on
> disk. SQLite (`~/.glorbo/glorbo.db`) holds derived views of that
> state. Running `glorbo reindex` must be able to reconstruct the
> SQLite database from the filesystem alone, byte-for-byte equivalent
> in semantics.

Corollaries:

- Nothing in SQLite that can't be rebuilt from disk is allowed. If you
  catch yourself storing a field that can't be reconstructed, that's a
  design bug — push the authoritative copy to the filesystem first.
- `glorbo.db` is disposable. `rm glorbo.db && glorbo reindex` should
  always work.
- Filesystem edits done with a text editor are legitimate. A user who
  hand-edits `agent.md` is making a real state change; the next
  reindex (or file watcher notification) picks it up.

## Why this shape

### 1. Auditability

A human can open any file, any time, and understand system state
without running the app. `ls -la companies/acme/agents/ceo/inbox/`
tells you exactly what tasks the CEO has queued. `tail
audit/2026-04.jsonl` tells you exactly what happened this month. No
DB query, no JOIN, no admin UI.

### 2. Portability without export/import ceremony

Backup = `tar czf glorbo.tar.gz ~/.glorbo/companies/`.
Restore = `tar xzf glorbo.tar.gz -C ~/.glorbo/ && glorbo reindex`.
Move to a new machine = `scp`. Version-control a company = `git init
~/.glorbo/companies/acme && git add . && git commit`.

Nothing special. No "glorbo export" subcommand that needs to stay in
sync with evolving schemas. No CSV dump that loses structure.

### 3. Upgrades never touch user data

The `glorbo` binary is stateless. Upgrading = replacing the binary.
Schema changes = `glorbo migrate`, which only rewrites SQLite. User
data (`companies/`, `audit/`, `channels/`, etc.) is never touched by
an upgrade. This makes rollback safe and trivial — run the old
binary, everything works.

### 4. Debuggable by humans

"Why did the agent not receive the task?" becomes:

```
$ ls companies/acme/agents/ceo/inbox/
$ cat companies/acme/agents/ceo/outbox/task-2026-04-17-abc.md
```

You can see the problem with two commands. If the answer lived in a
SQLite row, you'd need to know the schema, run a query, understand
the ORM that wrote it, and potentially run the whole app to get
reasonable output.

### 5. Enables kernel-level permission enforcement (GEP-5)

Filesystem as truth composes cleanly with filesystem-level permissions
(POSIX ACLs, mount namespaces). If the authoritative state is files,
then per-user/per-agent filesystem permissions are the enforcement
layer — the exact invariant GEP-5 describes. Had state lived in
SQLite, enforcement would have had to live in application code,
because SQLite has no equivalent of ACLs.

## On-disk layout

From DESIGN.md §3, the canonical shape. This GEP doesn't redefine it
— it records the shape the "source of truth" label applies to:

```
~/.glorbo/
├── config.md                       # Global settings
├── glorbo.db                       # DERIVED
├── companies/<slug>/
│   ├── company.md                  # Mission, budget, global settings
│   ├── agents/<name>/
│   │   ├── agent.md                # Identity, role, permissions
│   │   ├── inbox/                  # Tasks queued for the agent
│   │   ├── outbox/                 # Agent's produced messages
│   │   ├── workspace/              # Agent's scratch space
│   │   ├── stdout.log              # CLI-tool stdout capture
│   │   └── history/                # Rotated inbox/outbox
│   ├── channels/<channel>.md       # Append-only chat logs
│   ├── projects/<slug>/
│   ├── goals/<slug>.md
│   ├── skills/<slug>.md
│   └── audit/YYYY-MM.jsonl         # Append-only audit events
└── logs/                           # Application logs (DERIVED / rotatable)
```

Everything under `companies/<slug>/` is **user data, never touched by
upgrades, never deleted by Glorbo without explicit Director action**.
Everything else is either derived (SQLite, logs) or infrastructure
(binaries, container cache).

## Formats

Every authoritative file is either **markdown with YAML frontmatter**
or **JSONL**. Nothing else (no binary sidecars, no custom formats, no
sqlite auxiliary files).

### Markdown + YAML frontmatter

Used for human-authored or human-auditable content: `agent.md`,
`company.md`, `task-*.md`, `channel-*.md`, `project.md`, `skill.md`.
The frontmatter carries structured data (role, budget, permissions,
status); the body carries prose (mission statement, task description,
reasoning, chat).

Why: humans edit these. YAML frontmatter gives just enough structure
for programs to parse without losing readability. Markdown body is
what an LLM would produce naturally anyway.

### JSONL (newline-delimited JSON)

Used for append-only event streams: `audit/YYYY-MM.jsonl`, CLI session
telemetry. One event per line, never modified or deleted.

Why: cheap to append (no file parse), cheap to tail, cheap to replay.
Grep and jq are both effective tools. Rotating = closing the old file
and opening a new one with a different name.

### Prohibited formats

- **Binary files** for authoritative state. Too opaque, can't be
  diffed, can't be git-tracked sensibly. Images and other binary
  artifacts are stored under `projects/*/artifacts/` and are treated
  as opaque blobs — their *metadata* (`artifact.md` with frontmatter)
  is authoritative, not the binary contents themselves.
- **Custom DSLs** for config. YAML frontmatter is the limit.
- **SQLite as primary storage.** SQLite is always derived.

## The reindex contract

`glorbo reindex` is the load-bearing command for this invariant. It:

1. Drops and recreates the SQLite schema.
2. Walks every `companies/<slug>/` tree, parsing every markdown +
   JSONL file.
3. Emits a row (or rows) to SQLite for each parsed artifact.
4. On completion, SQLite state is byte-semantically equivalent to
   whatever state it would hold if Glorbo had been running the whole
   time the files were being written.

**Test of the invariant:** `rm glorbo.db && glorbo reindex` produces
a DB that passes the same queries the original would. If that test
fails for any field, that field should not have been in SQLite —
either move it to disk, or drop it.

Reindex isn't a rare disaster-recovery operation. It's a development
primitive: contributors delete and recreate `glorbo.db` routinely
when experimenting. Any field that makes reindex slow, brittle, or
information-lossy is load-bearing for system health and should have
its schema questioned.

## Implications for v0.0.2 and beyond

### Budget ledger

`companies/<slug>/audit/YYYY-MM.jsonl` records every token-usage
event. The SQLite `budget_ledger` table aggregates these for fast
dashboard queries, but the JSONL is the source. `glorbo reindex` can
reconstruct the full ledger from scratch.

### Approval state

Pending approvals live as markdown files under
`companies/<slug>/approvals/` with YAML frontmatter. SQLite tracks
their status for dashboard listings but is rebuildable.

### Agent state

Each agent's GenServer holds runtime state in memory (current task,
stdout stream position, supervisor refs). None of it is persisted.
On restart, the agent reads `agent.md` + latest `inbox/` + latest
`outbox/` and reconstructs its state from disk.

### Skills

`companies/<slug>/skills/*.md` are authoritative. Materialisation into
agent workspaces at wake-time (copy under `.glorbo-skills/`) is
derived scratch — deleted after the run.

## Decision log

### D1. Filesystem is authoritative, SQLite is derived

- **Decided:** markdown/JSONL on disk is the source of truth; SQLite
  rebuildable from it.
- **Alternatives:** DB-first (everything in SQLite, files as
  projections); hybrid (some state in each); event-sourced log with
  materialised views.
- **Why:** Glorbo's philosophy is "a directory you can tar up."
  DB-first would make user data opaque and force every interaction
  through the app. Hybrid produces synchronisation bugs (which copy
  is authoritative this week?). Event-sourcing is an overcomplicated
  answer to "what do we put in SQLite" at Glorbo's scale. Files are
  the simplest thing that works.

### D2. Markdown + YAML frontmatter, not a custom DSL

- **Decided:** authoritative user-editable files are markdown with
  optional YAML frontmatter.
- **Alternatives:** a custom config DSL; TOML; JSON; proprietary text
  format.
- **Why:** LLMs write markdown natively. Humans read it without
  training. Tooling is everywhere. YAML frontmatter adds just enough
  structure for programs to parse. TOML/JSON are fine for *pure*
  config (see GEP-8 for the provider registry) but not for mixed
  structure-plus-prose content like `agent.md` or a chat channel.

### D3. JSONL for append-only event streams

- **Decided:** audit logs and session telemetry are newline-delimited
  JSON, one event per line.
- **Alternatives:** SQLite events table; rolling JSON array files;
  custom binary append-only log.
- **Why:** JSONL is append-friendly (no parse needed to append),
  crash-safe (incomplete last line is trivially detectable), tool-
  friendly (jq, grep), and rotates cleanly. SQLite would make events
  the "authoritative" copy in the DB — violating the invariant.
  Arrays need rewrite-on-append.

### D4. Reindex as a first-class primitive, not a disaster-recovery tool

- **Decided:** `glorbo reindex` is supported, fast enough for regular
  use, and expected to be run by developers and curious users.
- **Alternatives:** reindex only as part of upgrades; reindex only on
  request from support.
- **Why:** if reindex is rarely run, it will silently break. The
  invariant ("SQLite is rebuildable") is only real if it's
  continuously verified. Making reindex routine turns it into a test
  of the invariant and forces schema choices that keep it cheap.

### D5. No binary files as authoritative state

- **Decided:** authoritative state is markdown or JSONL. Binary
  artifacts (images, PDFs, compiled outputs) are opaque blobs under
  `projects/*/artifacts/` with markdown metadata describing them.
- **Alternatives:** allow binary sidecars with sidecar format specs
  per type; inline base64 blobs in markdown.
- **Why:** binary files break every downstream benefit of this
  invariant — they're not diffable, not grep-able, not git-friendly,
  and not reviewable by humans or LLMs. Keeping the *metadata* as
  markdown while treating the binary as an opaque artifact preserves
  the benefits for everything that matters.

### D6. User data is untouchable across upgrades

- **Decided:** `glorbo` binary upgrades never modify `companies/`.
- **Alternatives:** allow schema migrations that rewrite user data;
  require per-upgrade migration scripts.
- **Why:** if upgrades can touch user data, users cannot safely
  rollback by reverting the binary. It also couples feature velocity
  to migration pain. Forcing additive schema changes in the DB
  (always rebuildable from current file formats) keeps both sides
  free: files evolve on their own cadence, DB can be dropped and
  recreated.

## Related

- **GEP-2** — architectural overview (see "Filesystem is the source of
  truth" pillar).
- **GEP-7** — SQLite as derived data (the specific contract SQLite
  operates under).
- **GEP-5** — sandboxing (kernel-level permission enforcement composes
  with this invariant).
- `DESIGN.md` §3 (Directory Structure), §3 Key Invariants.
