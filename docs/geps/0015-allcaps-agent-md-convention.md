---
gep: 0015
title: ALLCAPS convention for agent-facing markdown files
author: Glorbo Maintainers <security@example.invalid>
status: Accepted
type: Informational
created: 2026-04-17
history:
  - date: 2026-04-17
    status: Accepted
    note: >-
      Retrofit: AGENT.md + HEARTBEAT.md landed as ALLCAPS alongside
      GEP-14's scheduler hook. Captured here as the ongoing convention.
---

# GEP-15: ALLCAPS convention for agent-facing markdown files

## Problem

Glorbo has two distinct populations of markdown files under a company
tree:

1. **Data files** — `company.md`, `channels/general.md`,
   `projects/<proj>/<proj>-NN.md`, `goals/q3-2026.md`,
   `audit/*.jsonl` (JSONL but same slot). These are *data the user
   types about* — company name, chat logs, task prose. Their
   filenames are lowercase-with-hyphens slugs.
2. **Contract files** — `AGENT.md`, `HEARTBEAT.md`, and whatever else
   the runtime wires into an agent's wake path. These are *instructions
   the agent reads*. They're shaped like README-in-a-repo: one per
   agent, sit at the top of the agent's directory, and have a
   well-known name the runtime looks for.

Before this GEP, both populations used lowercase (`agent.md`). That's
fine in isolation, but it leaves the runtime-contract files visually
indistinguishable from user data when you `ls` an agent directory.
The convention on most Unix trees (`README.md`, `LICENSE`, `NOTICE`,
`CODE_OF_CONDUCT.md`) is the opposite — contract-with-your-reader
files are ALLCAPS precisely because they're the first thing the eye
should land on.

## Convention

All agent-facing markdown files — the ones the runtime looks for by
name and delivers into the agent's execution context — use **ALLCAPS
with a `.md` extension**. Specifically:

| File           | Where                                    | Purpose                                        |
|----------------|------------------------------------------|------------------------------------------------|
| `AGENT.md`     | `companies/<co>/agents/<slug>/`          | identity, permissions, provider, cron          |
| `HEARTBEAT.md` | `companies/<co>/agents/<slug>/`          | GEP-14; cron-wake instructions                 |
| `SKILLS.md`    | `companies/<co>/agents/<slug>/` (future) | placeholder — per-agent skill index if needed  |

User data files stay lowercase: `company.md`, `channels/general.md`,
task filenames under GEP-13 (`<project>-NN.md`), audit JSONL. This
GEP does not rename any of those — mixing ALLCAPS for contracts with
lowercase-slug for data is the signal, not a bug.

## Rules

### 1. Writers always emit ALLCAPS

Every code path that **creates or updates** an agent-facing file
writes ALLCAPS — `AGENT.md`, not `agent.md`; `HEARTBEAT.md`, not
`heartbeat.md`. This applies to:

- Scaffolders (`glorbo new agent`, `Glorbo.Init.ExampleCompany`).
- Test fixtures (`test/support/glorbo_fixtures.ex`,
  `test/support/portability_fixtures.ex`).
- Any future programmatic writer.

### 2. Readers accept both cases during the soft-migration window

Existing installs carry `agent.md` from v0.0.1 / v0.0.2. Readers use
`Glorbo.Agent.FileLayout.agent_md/1`, which returns `AGENT.md` when
present and falls back to `agent.md` when not. This keeps old installs
functional without forcing a migration CLI.

Once the fleet has naturally converged (either through user edits or
via an opt-in `mix glorbo.migrate_agent_md` task — not written yet,
deferred until the fleet size justifies it), the fallback can be
deleted without a schema change.

### 3. Path parsing matches both

`Glorbo.Agent.Parser.derive_slug/1` and `derive_company/1` pattern-match
on *either* `AGENT.md` or `agent.md` at the path tail so the same
parser handles both populations without duplication.

### 4. Reindex treats them as one domain

`Glorbo.Filesystem.Reindex` classifies
`/agents/<slug>/(?:AGENT|agent)\.md$` as the same `path_kind: 1`
(agent-file) ordering key. The derived SQLite row stores the actual
on-disk path — no normalisation, the FS is ground truth (GEP-3).

## Non-goals

- **Forced migration.** We don't walk existing installs and rename
  `agent.md` → `AGENT.md` at upgrade time. Filesystem is user data
  (GEP-3); upgrades don't mutate it. A future opt-in
  `mix glorbo.migrate_agent_md [--dry-run]` is the right place for
  that if the legacy tail grows too long.
- **Case-insensitive everywhere.** The rule is narrow: two specific
  filenames (`AGENT.md`, `HEARTBEAT.md`) have a case-insensitive read
  path. Arbitrary case-twiddling (`Agent.md`, `AgenT.Md`) is not
  supported — those fail the parser regex.
- **Renaming data files.** `company.md` stays lowercase, task filenames
  stay lowercase. The convention is specifically for *contract* files.
- **A lint rule to enforce it.** Credo/format don't check filesystem
  names. The scaffolders and fixtures are the single source of truth;
  new contract files added in future GEPs must spell themselves
  ALLCAPS by convention.

## Failure modes

- **Both files present simultaneously.** If an agent directory carries
  both `AGENT.md` and `agent.md`, `FileLayout.agent_md/1` returns
  `AGENT.md` (first in the candidate list). The legacy `agent.md` is
  silently ignored. Users who end up in this state (e.g. they renamed
  by hand and then an old script re-created the lowercase) see the
  ALLCAPS file win; they should delete the leftover.
- **User creates a third case variant.** `Agent.md` (mixed case) on a
  case-sensitive filesystem is treated as an unrelated file — the
  regex doesn't match, reindex classifies it as "other". On a
  case-insensitive filesystem (APFS, NTFS default, Windows-hosted
  sync tools) the underlying filesystem collapses variants; whichever
  case was created first wins. Not Glorbo's problem — the host
  filesystem's semantics are authoritative.

## Decision log

### D1. ALLCAPS for contract files, lowercase for data

- **Decided:** Agent-facing contract files are ALLCAPS; user-data
  markdown files stay lowercase-slug.
- **Alternatives:** (a) Everything lowercase (prior state — visually
  flat). (b) Everything ALLCAPS (noisy, and `COMPANY.md` or
  `GENERAL.md` for a chat channel reads like shouting).
  (c) Prefix convention (`_agent.md`, `_heartbeat.md`).
- **Why:** The ALLCAPS convention has ~40 years of Unix precedent
  (`README`, `COPYING`, `NOTICE`, `CODE_OF_CONDUCT`). Readers already
  parse "this is the contract" from the casing. Using it for
  agent-facing contracts lines us up with that signal without
  inventing a Glorbo-specific prefix.

### D2. Readers accept both; writers emit only the new shape

- **Decided:** Soft migration. `FileLayout.agent_md/1` returns
  `AGENT.md` preferred, `agent.md` fallback. All writers emit
  `AGENT.md`.
- **Alternatives:** Hard cutover at v0.0.3 — mass-rename on first
  boot. Or a required `glorbo migrate` verb.
- **Why:** CLAUDE.md invariant — the filesystem is user data and is
  never modified by upgrades. Auto-mutating files at boot time to
  fit a new naming convention violates that. A soft migration with
  both shapes accepted lets existing installs keep working while
  new writes converge on the convention. (Same rationale as GEP-13
  §D3 for task IDs.)

### D3. No opt-in migration CLI yet

- **Decided:** Don't ship a `mix glorbo.migrate_agent_md` verb until
  the fleet needs it.
- **Alternatives:** Ship it now alongside the convention (parallel to
  GEP-13's `mix glorbo.migrate_tasks`).
- **Why:** GEP-13's migration was worth it because task IDs affect
  human readability on sight (`website-42` self-describes, `t-42`
  doesn't). `AGENT.md` vs `agent.md` is an aesthetic / alignment
  win, not a functional one. The fallback keeps old installs
  working indefinitely, and the rename is one line for any user
  who wants to clean up: `mv agent.md AGENT.md`. The migration CLI
  is scope we can defer.

## Related

- [GEP-3](./0003-filesystem-as-source-of-truth.md) — filesystem as
  source of truth; upgrades never mutate user data.
- [GEP-13](./0013-project-prefixed-task-ids.md) — parallel naming
  convention change (task filenames); used the same soft-migration
  shape.
- [GEP-14](./0014-agent-heartbeat-semantics.md) — introduced
  `HEARTBEAT.md`, the second ALLCAPS contract file and the one that
  made the inconsistency with `agent.md` visible.
