---
gep: 7
title: SQLite as Derived Data
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-17
implemented-in: v0.0.1
requires: [2, 3]
see-also: [6, 32]
extended-by: [33]
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit from DESIGN.md §4.5 and §3 Key Invariants.
  - date: 2026-04-17
    status: Accepted
    note: Canonical record of the SQLite-as-derived contract.
  - date: 2026-04-17
    status: Implemented
    version: v0.0.1
    note: Derived-data semantics and reindex contract held since v0.0.1. Retrofitted status.
---

# GEP-7: SQLite as Derived Data

## Purpose

Glorbo uses SQLite (`~/.glorbo/glorbo.db`, via Ecto + `ecto_sqlite3`)
as its dashboard query backend. This GEP records what SQLite holds,
what it must **not** hold, and how the "derived data" contract
(introduced in GEP-3) plays out in practice — schema shape, reindex
behaviour, migration discipline, and the queries SQLite exists to
serve.

This is the companion GEP to GEP-3 (filesystem as source of truth).
GEP-3 establishes the invariant ("the filesystem is authoritative;
SQLite is rebuildable"). This GEP covers the SQLite side of that
contract: what actually lives in the DB, why, and how we keep the
invariant honest.

## Role

SQLite exists for exactly one reason: **fast dashboard queries**.
Without it, rendering the overview page would require walking every
company's `audit/YYYY-MM.jsonl`, tallying by agent/day, and computing
budget burn on the fly. That doesn't fly for real-time LiveView
updates. SQLite caches the aggregates so the dashboard can serve a
page in milliseconds.

Every SQLite row corresponds to something already written to disk in
markdown or JSONL. The DB is a projection of filesystem state,
nothing more.

## What SQLite holds

Derived indexes and aggregates. Specifically:

- **Task index.** Status, assignee, project, due date, timestamps.
  Sourced from `projects/<slug>/tasks/*.md` frontmatter. The markdown
  is authoritative; SQLite enables "show me all in-progress tasks
  across all projects" without walking every file.
- **Budget ledger.** Per-invocation token usage and cost. Sourced
  from per-agent audit events and CLI session telemetry (parsed by
  per-provider modules — see GEP-4 and GEP-8). The events remain in
  `audit/YYYY-MM.jsonl`; SQLite aggregates them for dashboard
  rendering.
- **Agent status.** Last heartbeat, current state (`idle | waking |
  running | sleeping`), active task ID. Derived from runtime
  GenServer state at observation time. On restart, agents
  reconstruct from `agent.md` + latest inbox/outbox and SQLite gets
  rebuilt from that reconstruction.
- **Audit event index.** Searchable/filterable view over audit
  JSONL. Same events; SQLite adds indexes over `(timestamp,
  company, agent, event_type)` so the dashboard can run
  `WHERE agent = 'ceo' AND event_type = 'task.failed'` in ms instead
  of scanning JSONL.
- **Channel message index.** Indexes over the append-only markdown
  chat logs for search (`find all messages from the engineer agent
  containing "deadline"`).
- **Approval queue.** Index over pending approvals. The pending
  files themselves live on disk in `companies/<slug>/approvals/`
  with frontmatter carrying the status.

## What SQLite must NOT hold

Anything that can't be reconstructed from the filesystem by
`glorbo reindex`. If you catch yourself wanting to add a column
whose value can't be derived from disk, the design is wrong —
push the authoritative copy onto disk first.

Examples of fields that would violate the invariant and how to fix
them:

| Tempting field                   | Violation                             | Fix                                                                          |
|----------------------------------|---------------------------------------|------------------------------------------------------------------------------|
| "Last time user clicked X"       | UI state is not derivable from agents | UI state is client-side (browser local storage), never DB                    |
| "Agent's in-memory scratch note" | GenServer runtime state               | Put it in `agent.md` or workspace; or accept it as ephemeral (not persisted) |
| "Secret API key entered via UI"  | Auth belongs to providers (GEP-4)     | Write to `~/.glorbo/config.md`; re-key for next session                      |
| Counter that increments on read  | No filesystem event causes the change | This is a use-case smell — if the count matters, it should come from events  |

The test for any proposed column: "if I `rm glorbo.db && glorbo
reindex`, will this column come back with the same value?" If no,
the data belongs on disk or nowhere.

## The reindex contract

`glorbo reindex` is the load-bearing command for this invariant.
Its contract:

1. **Drops and recreates** the SQLite schema (via Ecto migrations).
2. **Walks** every `companies/<slug>/` tree deterministically.
3. **Parses** every markdown + JSONL artifact.
4. **Inserts** rows corresponding to the parsed state.
5. **On completion** the database is byte-semantically equivalent
   (for the queries Glorbo runs) to what it would have held if
   Glorbo had been running the whole time the files were being
   written.

Reindex isn't disaster recovery. It's a development primitive —
contributors delete and rebuild `glorbo.db` constantly when
experimenting. Any field that makes reindex slow, flaky, or
information-lossy is a red flag for schema health.

Empirically, reindex on a small company (~10 agents, a few hundred
audit events) runs in well under a second on dev hardware. As
companies grow, the target is sub-10s for "normal" sizes; past
that, the rebuild is still correct but the operation cost starts
mattering.

## Migrations

`glorbo migrate` runs Ecto migrations against `glorbo.db`.
Migrations are **additive** where possible — adding columns, new
tables, new indexes. Destructive migrations (drop columns, change
types, rename tables) are acceptable because the DB is disposable:
if the migration breaks, `rm glorbo.db && glorbo migrate && glorbo
reindex` is always the fallback.

This is a significant freedom. Most projects with a DB schema treat
migrations as irreversible commitments because the data in the DB is
authoritative. Glorbo's data is on disk; the DB is a cache; schema
churn is cheap.

**Upgrade flow:**

1. Replace the `glorbo` binary.
2. Run `glorbo migrate` — applies any new migrations.
3. If anything looks wrong, run `glorbo reindex` to rebuild from
   filesystem.
4. `~/.glorbo/companies/` is never touched during any of this.

## Concurrency and WAL

SQLite runs in WAL (write-ahead logging) mode, set during the phase 1
Phoenix skeleton. Multiple Elixir processes (LiveView mounts,
FileWatcher writes, BudgetTracker updates, reindex) can read and
write concurrently without blocking each other for dashboard
queries.

Constraints:

- **Single writer at a time.** Ecto's connection pool serializes
  writes; readers proceed concurrently.
- **No cross-company transactions.** Writes are scoped to a single
  company's data where possible, keeping conflict surface small.
- **Reindex is disruptive.** During a reindex, the DB is
  temporarily inconsistent — dashboards should either pause
  queries or tolerate partial state. In practice, reindex is run
  manually and the user tolerates a few seconds of "the dashboard
  is rebuilding."

## Why not Postgres (or anything else)?

- **Portability.** Glorbo is "one binary, one directory." Postgres
  requires a separate daemon, a systemd service, a password, and a
  user. That shatters the "copy a binary, run it" deployment story.
- **Backup/restore.** SQLite is a single file. `cp glorbo.db
  backup.db` is a complete snapshot; `cp backup.db glorbo.db` is a
  complete restore. Postgres requires `pg_dump`.
- **Concurrency needs.** Glorbo is a single-operator, single-host
  system (GEP-2 D1). SQLite's write-through-single-writer model is
  not a scaling concern at that size.
- **Derived data doesn't need a serious DB.** If the DB is
  disposable, the features that make Postgres worth its weight
  (MVCC, replication, advanced indexing, stored procedures) aren't
  paying rent.

SQLite is genuinely enough. No asterisk.

## Failure modes

### Filesystem and DB drift

If a user edits a file on disk while Glorbo is running, the
FileWatcher catches it via inotify and updates the corresponding
SQLite row. If the watcher is missing the event (filesystem-event
loss is rare but possible), the DB drifts behind the filesystem.
Fix: `glorbo reindex` resyncs. Treating drift as a bug rather than
a feature — if it happens often, the watcher has a gap that needs
fixing.

### DB corruption

SQLite WAL is robust against process crashes; a corrupted DB is
rare in practice. If it happens, `rm glorbo.db && glorbo reindex`
restores full state. No data loss because the DB was never the
source of truth.

### Schema migration failure

If `glorbo migrate` fails mid-flight (bug in the migration, disk
full, etc.), the user can: (a) fix the issue and re-run, or (b)
`rm glorbo.db && glorbo migrate` to apply migrations against an
empty DB, then `glorbo reindex`. Either path recovers.

## Relationship to other GEPs

- **GEP-3** (filesystem as source of truth): establishes the
  invariant. This GEP is its SQLite-specific counterpart.
- **GEP-2** (architecture overview): lists "no custom database" as
  a non-obvious choice. SQLite is the chosen boring-and-effective
  alternative.
- **GEP-6** (LiveView dashboard): reads SQLite via Ecto for fast
  queries. The dashboard's speed story assumes SQLite indexes are
  current.

## Decision log

### D1. SQLite specifically (not Postgres, DuckDB, or embedded KV)

- **Decided:** Glorbo uses SQLite via `ecto_sqlite3` as the derived
  query backend.
- **Alternatives:** Postgres; embedded Mnesia; DuckDB; LMDB / RocksDB
  for KV.
- **Why:** SQLite is one file, needs no daemon, ships in every OS
  already, speaks SQL (which Ecto translates into), and handles
  Glorbo's scale with room to spare. Postgres breaks the single-
  binary story. Mnesia is BEAM-local but its schema-migration and
  backup stories are worse. DuckDB is analytics-oriented; Glorbo's
  queries are transactional. KV stores would force us to reinvent
  indexes and joins.

### D2. WAL mode for concurrent reads + single writer

- **Decided:** SQLite runs in WAL mode from first Ecto start.
- **Alternatives:** default rollback-journal mode; memory-mode with
  periodic checkpoint.
- **Why:** WAL allows LiveView reads to proceed while FileWatcher
  writes land. Rollback-journal serializes everything and causes
  dashboard lag. Memory-mode loses durability; fine for tests but
  wrong for user state.

### D3. Destructive migrations are acceptable

- **Decided:** Ecto migrations can drop columns, rename tables,
  change types. The DB is disposable; user data is on disk.
- **Alternatives:** freeze the schema; require expand/contract
  migrations (add new, backfill, remove old); ship schema-migration
  tests.
- **Why:** the standard "never lose data in a migration" rule
  applies when the DB *is* the data. It isn't. Treating migrations
  as cheap keeps schema churn cheap; if a migration is genuinely
  wrong, `rm glorbo.db && glorbo reindex` is always available.

### D4. Reindex as first-class developer tool, not just recovery

- **Decided:** `glorbo reindex` is documented, fast, and expected
  to be run by developers and curious users.
- **Alternatives:** reindex only as a support / DR operation; hide
  it behind a debug flag.
- **Why:** if reindex is rarely run, the invariant silently rots.
  Making it routine turns it into a continuous test of the
  "SQLite is rebuildable" property and forces schema choices that
  keep it cheap.

### D5. Event aggregation in SQLite, events themselves in JSONL

- **Decided:** per-invocation usage events land in
  `audit/YYYY-MM.jsonl` as the authoritative record. SQLite's
  budget ledger is the aggregate projection.
- **Alternatives:** write events directly to SQLite as the primary
  store; dual-write (authoritative both places); write only to
  SQLite and regenerate JSONL on demand.
- **Why:** the JSONL-first approach keeps audit trail immutability
  (GEP-2 pillar; filesystem-authoritative per GEP-3) and makes
  reindex possible. Dual-write introduces consistency bugs. Primary-
  in-SQLite would force us to treat the DB as authoritative,
  breaking GEP-3.

### D6. Drop derived values that can't be rebuilt

- **Decided:** any field in SQLite that can't be reconstructed from
  filesystem state is a design bug. The fix is to either derive it
  properly or push the authoritative copy to disk.
- **Alternatives:** allow "SQLite-only" fields for things that are
  truly transient; mark them as "best-effort, non-reindexable."
- **Why:** allowing SQLite-only fields opens a door that never
  closes — every future PR is tempted to add more. Holding the line
  forces explicit choices: this data either matters (→ on disk) or
  it doesn't (→ GenServer state, not persisted).

### D7. Single-company writes preferred over cross-company transactions

- **Decided:** schema and code are structured to keep writes scoped
  to a single company where possible, avoiding cross-company
  transactions.
- **Alternatives:** rely on SQLite-wide transactions for
  correctness; serialise all writes through a single GenServer.
- **Why:** Glorbo's isolation model (GEP-2 pillar 3) extends to the
  DB layer. Keeping writes scoped keeps the conflict surface small
  and aligns with the company-supervisor subtree shape (GEP-2
  "Topology"). Single-GenServer serialisation creates a bottleneck.

## Related

- **GEP-2** — architectural overview (derived-data is one of the
  non-obvious choices).
- **GEP-3** — filesystem as source of truth (the invariant this GEP
  operationalises for SQLite).
- **GEP-6** — Phoenix LiveView dashboard (the primary consumer of
  SQLite queries).
- `DESIGN.md` §4.5 (SQLite — The Index), §3 Key Invariants.
- `lib/glorbo/repo.ex`, `priv/repo/migrations/` — implementation.

## Implementation reconciliation (2026-06-14)

This is an append-only record: per GEP-1, an Accepted/Implemented GEP's body is not rewritten — deviations between the §"What SQLite holds" prose and the shipped schema are recorded here rather than edited into the body above.

- **Task index — known-gap (body is stale).** GEP-7 §"What SQLite holds" (lines 59–62) claims SQLite holds a task index of status/assignee/project/due. No `tasks` table exists; migrations only define `companies, agents, audit_events, reindex_state, budgets, tasks_approval_state, provider_models, chunk_vectors, memory_index_enabled`. Task listings walk `projects/*/tasks/*.md` frontmatter directly (`Glorbo.Shell.Views.Tasks.Data`, `KanbanLive.load_tasks/2`), not SQLite. The one task-related table, `tasks_approval_state`, holds only the director-approval lifecycle (awaiting/approved/denied) per `(company_slug, task_path)` — not a general status/assignee/project/due index. The "across all projects" query the bullet promises is a filesystem walk, so this bullet overstates SQLite's role.

- **Channel message index — known-gap (body is stale).** GEP-7 lines 78–80 assert a SQLite index over chat logs for search. No channel/message/chat table exists in any migration. Channels are append-only markdown (`channels/<slug>.md`, `Glorbo.Actions.Channels`, `Glorbo.FileSpec.ChannelLogMd`) read off disk; there is no SQLite-backed message search. This bullet describes a capability that was never built.

- **Approval queue — as-shipped (body imprecise, not false).** GEP-7 lines 81–83 describe an "Approval queue" index over pending approvals living on disk in `approvals/`. The on-disk part is accurate (pending approvals are filesystem-resident; see `Glorbo.Approvals.Gate`). The SQLite side that exists is `tasks_approval_state`, which records per-task approval *state* and is reindex-rebuildable from the audit log (`Reindex.rebuild_tasks_approval_state/1`) — so an approval projection genuinely lives in SQLite, just not as a distinct "queue index" table. Disposition as-shipped; the prose conflates the disk queue with the state table.

- **Agent status — known-gap (body is stale; should be demoted to NOT-in-SQLite).** GEP-7 lines 68–72 list "Agent status" (last heartbeat, `idle | waking | running | sleeping`, active task ID) under "What SQLite holds." The `agents` table holds identity only — `name, role, provider, model, file_path` (migration `20260415120002_create_agents.exs`; schema `lib/glorbo/agent.ex:14`). No heartbeat/state/active-task columns exist. Runtime status is GenServer-only (`Glorbo.Agent.Server`), observed live and never persisted, which is consistent with GEP-7's own D6/the "counter that increments on read" smell. This bullet belongs under "What SQLite must NOT hold," not under what it holds.

- **Audit event index + Budget ledger — as-shipped (no action).** The two §"What SQLite holds" bullets the audit did not flag are accurate: `audit_events` (`company, actor, action, target, detail, ts`) backs the searchable audit index (GEP-7 lines 73–77) and `budgets` backs the budget ledger aggregate (lines 63–67). Both are real tables; these bullets need no change.

- **Schema enumeration in the finding's evidence — corrected-ref.** The finding listed the live tables as ending in `provider_mode`; the actual table is `provider_models` (`20260423190000_create_provider_models.exs`, schema `lib/glorbo/provider_model.ex`). The current schema also includes three tables the evidence omitted — the `chunks_fts` FTS5 virtual table, `chunk_vectors`, and `memory_index_enabled` (the **GEP-58** semantic-recall index, migration `20260612120000_create_memory_index.exs`, which creates `chunks_fts` first) — none of which is mentioned in GEP-7 §"What SQLite holds". `chunks_fts` + `chunk_vectors` are reindex-derived (and so belong in a future rewrite of that section); `memory_index_enabled` is the opt-in flag that is NOT rebuildable from disk (the GEP-3 rebuildability gap noted on GEP-3).
