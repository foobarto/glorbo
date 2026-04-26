---
gep: 0034
title: Reindex v2 — full derived-state rebuild from disk + audit JSONL
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-24
history:
  - date: 2026-04-24
    status: Placeholder
    note: |
      Captured after the round-2 whole-repo reviews (codex + opencode)
      flagged that `glorbo reindex` violates the filesystem-as-source-
      of-truth invariant for two tables: `budgets` (running token +
      cost aggregates) and `tasks_approval_state` (approval lifecycle
      + resolved_at + reason). Neither rebuilds from markdown; the
      `audit_events` projection is explicitly scoped out by the
      reindex contract. `glorbo.db` cannot be deleted + rebuilt
      losslessly.
  - date: 2026-04-26
    status: Draft
    note: |
      Phase 1 landed: `audit_events` is now rebuilt from
      `companies/<co>/audit/*.jsonl` + `<base>/audit/*.jsonl` during
      `Reindex.run/1`. Implementation streams JSONL line-by-line via
      `File.stream!([], :line)`, decodes with `Jason`, batches 500
      rows per `Repo.insert_all`, and skips malformed / oversize
      (> 64 KiB) lines with a warning. Test coverage in
      `test/glorbo/filesystem/reindex_test.exs` covers the happy path,
      idempotency (re-running wipes the table first), `_system`
      events, malformed lines, and the 64-KiB cap. Remaining gaps
      identified in this GEP — `budgets` running aggregates and
      `tasks_approval_state.resolved_at` / `reason` — are still open
      and need their own audit-log replay logic.
  - date: 2026-04-26
    status: Draft
    note: |
      Phase 2 landed: `tasks_approval_state` is now rebuilt by
      folding `approval.requested` / `approval.granted` /
      `approval.denied` lines chronologically per `target` (task
      path). Per-company JSONL files are read in filename order
      (YYYY-MM.jsonl sorts chronologically); within each file
      `File.stream!` preserves append order. The fold builds a
      `task_path => state` map and bulk-inserts the final state via
      `Repo.insert_all` chunks of 100 rows (7 columns × 100 stays
      well under SQLite's 999-bind-parameter ceiling). Resolution
      events without a matching `requested` line synthesize a row
      using the resolution timestamp as `requested_at`, so a
      retention-truncated audit log still surfaces the resolution.
      Decision on the open Phase 2 question (sentinel retention):
      went audit-only — the `Approvals.Gate` continues to delete
      resolved sentinels, since audit JSONL is authoritative and the
      dashboard already streams the same info. Result map gains a
      `:tasks_approval_state` count. 8 new tests cover awaiting,
      grant, deny+reason, missing-request synthesis, cross-month
      fold, idempotency, non-approval-line filtering, and the 64-KiB
      oversized-line cap. Only `budgets` remains.
  - date: 2026-04-26
    status: Implemented
    note: |
      Phase 3 landed: `budgets` is now rebuilt by summing
      `budget.usage` audit lines per
      `{company_slug, agent_slug, year_month}` (year_month derived
      from each line's `ts` via `Budget.Ledger.month_bucket/1`,
      matching the writer). 8-column bulk insert chunked at 100
      rows. Discovered the spec's `usage.recorded` audit-action name
      doesn't match the actual writer (`Company.BudgetTracker`
      emits `budget.usage`); replay uses the actual name. The
      spec's worry about `alerts_fired` bitmap reconstruction is
      moot — that bitmap lives in `BudgetTracker` GenServer state,
      not in the `budgets` schema, and is already rehydrated on
      tracker boot from `alerts/*.md`. Result map gains a
      `:budgets` count. 8 new tests cover single-event,
      multi-event sum, multi-month split, multi-agent split,
      cross-company isolation, idempotent re-run, non-budget-line
      filtering, and missing/invalid-token defaulting. With Phase 3
      shipped, every gap-table identified in the GEP is now
      derived from the on-disk source — `glorbo.db` is fully
      rebuildable. Status flipped to **Implemented**.
see-also: [3, 7, 19]
---

# GEP-34: Reindex v2 — full derived-state rebuild

## Problem

CLAUDE.md §Load-bearing invariants:

> **Filesystem is source of truth** — `~/.glorbo/companies/` is user
> data, never modified by upgrades. SQLite (`glorbo.db`) is derived
> and must be rebuildable from disk via `glorbo reindex`.

Today that is false for three tables:

1. **`budgets`** — `Glorbo.Budget.Ledger` writes running
   `{company, agent, year_month}` totals. No on-disk counterpart
   exists. Deleting `glorbo.db` loses every budget alert's history
   and the `alerts_fired` bitmap that prevents duplicate pages.
2. **`tasks_approval_state`** — `Glorbo.Approvals.Gate` writes
   `status`, `requested_at`, `resolved_at`, `reason`. Sentinel files
   under `state/` are deleted on resolution, so the resolution
   timestamp + reason exist only in SQLite.
3. **`audit_events`** — explicitly scoped out of reindex
   ([reindex.ex:11-12](../../lib/glorbo/filesystem/reindex.ex#L11-L12)).
   But the `audit/YYYY-MM.jsonl` files under each company ARE the
   source of truth — the projection is a pure stream parse. No
   fundamental reason it can't rebuild.

The mismatch is visible in code, tests, and docs all at once —
[reindex.ex:1-12](../../lib/glorbo/filesystem/reindex.ex#L1-L12),
[test/integration/reindex_roundtrip_test.exs:3-9](../../test/integration/reindex_roundtrip_test.exs#L3-L9),
[docs/DESIGN.md:493-495](../DESIGN.md#L493-L495),
[docs/geps/0003-filesystem-as-source-of-truth.md:186-199](./0003-filesystem-as-source-of-truth.md),
[docs/geps/0007-sqlite-as-derived-data.md:51-53](./0007-sqlite-as-derived-data.md),
[docs/geps/0019-director-approval-workflow.md:119-123](./0019-director-approval-workflow.md).

## Goals

- Make `glorbo reindex` produce a `glorbo.db` that is byte-
  identical (modulo row IDs / timestamps) to one built by
  observing every event live. After `rm glorbo.db && glorbo
  reindex`, no derived field is missing.
- Cover the three known gaps incrementally — a single PR per
  table — so each phase is reviewable and shippable on its own.
- Keep streaming bounded: a 12-month audit log with N companies
  must reindex without OOM. Budget enforcement: < 100 MB peak
  RSS during reindex.

## Non-goals

- **Not a watcher hot-path replacement.** Reindex is a recovery /
  cold-boot tool, not the live event stream. The runtime
  observers (`AuditLog.append/1`, `Budget.Ledger.record/3`, etc.)
  remain the steady-state writers; reindex is the
  rebuild-from-source path.
- **Not a generic projection framework.** Each gap-fixing module
  knows its source events (`approval.granted` / `usage.recorded`)
  and its target schema. We're not building an
  event-sourcing-CRDT framework, just a few imperative replayers.
- **Not GEP-43.** Replacing SQLite with ETS+snapshots is a
  separate architecture decision; this GEP just makes the
  *current* SQLite-derived shape fully derivable.

## Design

Three phases, one per gap-table. Each phase is its own PR.

### Phase 1 — `audit_events` *(landed 2026-04-26)*

`Reindex.run/1` walks `companies/<co>/audit/*.jsonl` and
`<base>/audit/*.jsonl`. Each line is decoded via `Jason`,
filtered by minimum required keys (`actor`, `action`, valid
`ts`), and inserted via `Repo.insert_all` in batches of 500.
Lines exceeding 64 KiB or failing JSON decode are skipped with
a warning — JSONL stays authoritative, the SQLite mirror is
best-effort. Wipes the whole table first so re-running is
idempotent.

Implementation: `lib/glorbo/filesystem/reindex.ex` —
`rebuild_audit_events/1`, `import_audit_dir/2`,
`import_audit_file/2`, `decode_audit_line/3`,
`build_audit_row/2`. Result map gains an `:audit_events` count.

### Phase 2 — `tasks_approval_state` *(landed 2026-04-26)*

`Reindex.run/1` folds `approval.requested` / `approval.granted` /
`approval.denied` audit lines chronologically per `target` (task
path). Per-company JSONL files are read in filename order
(YYYY-MM.jsonl sorts chronologically); within each file
`File.stream!` preserves append order. The fold builds a
`task_path => state` map and bulk-inserts the final state via
`Repo.insert_all` chunks of 100. Resolutions without a matching
`requested` line synthesize a row using the resolution timestamp
as `requested_at`, so retention-truncated audit logs still surface
resolutions.

Sentinel-retention question: went audit-only. The
`Approvals.Gate` continues to delete `state/awaiting-approval-<id>.md`
on resolution — audit JSONL is authoritative and the dashboard
already streams the same info. No second on-disk source is needed.

Implementation: `lib/glorbo/filesystem/reindex.ex` —
`rebuild_tasks_approval_state/1`, `fold_approval_dir/2`,
`fold_approval_file/2`, `fold_approval_line/3`,
`apply_approval_event/3`, `update_resolution/5`,
`insert_approval_rows/1`. Result map gains a
`:tasks_approval_state` count.

### Phase 3 — `budgets` *(landed 2026-04-26)*

`Reindex.run/1` sums `budget.usage` audit lines (the writer's
actual action name — the spec's `usage.recorded` was an early
draft that never matched the writer) per
`{company_slug, agent_slug, year_month}`. The `year_month`
string is derived from each line's `ts` via
`Budget.Ledger.month_bucket/1` so the replay format always
matches the writer. Per-line fields used: `agent`,
`prompt_tokens`, `completion_tokens`, `cost_usd_cents`, `ts`.
Bulk insert in 100-row chunks (8 cols × 100 = 800 binds).

The `alerts_fired` MapSet that the spec worried about is NOT
in the `budgets` schema — it lives in `Company.BudgetTracker`
GenServer state and rehydrates on boot by scanning
`alerts/*.md` (per its moduledoc). Reindex doesn't touch it.

Implementation: `lib/glorbo/filesystem/reindex.ex` —
`rebuild_budgets/1`, `sum_budget_dir/3`, `sum_budget_file/3`,
`sum_budget_line/4`, `apply_budget_usage/3`,
`insert_budget_rows/1`. Result map gains a `:budgets` count.

## Migration

Pre-1.0: reindex's contract changes silently — `Reindex.run/1`'s
result map gains new keys (`:audit_events`, eventually
`:approvals`, `:budgets`). All callers in the tree pattern-match
on the previously-known keys (`indexed`, `skipped`, `deleted`)
and ignore extras, so no consumer break.

Post-1.0: each phase becomes a new minor-version feature; the
result map keys are additive and well-named. No projection
catalogue versioning is needed at the file-format level — the
JSONL line format is GEP-19 / audit-log stable.

## Open questions

- **Phase 2 storage choice — sentinel retention vs audit-only
  replay?** *Resolved 2026-04-26 — audit-only.* The
  `Approvals.Gate` continues to delete the `awaiting-approval-<id>.md`
  sentinel at resolution; the audit JSONL is authoritative. Adding
  a second on-disk write at resolution time would couple the gate
  to a redundant artifact for forensics that the dashboard already
  surfaces by streaming audit lines.
- **Phase 3 alerts_fired bitmap reconstruction.** *Resolved
  2026-04-26 — moot.* The `alerts_fired` MapSet is GenServer
  state inside `Company.BudgetTracker`, not a column on the
  `budgets` schema, and is already rehydrated from
  `alerts/*.md` files on tracker boot. Reindex never needed to
  re-evaluate threshold ladders. The audit action name was also
  wrong in the spec — the writer emits `budget.usage`, not
  `usage.recorded`.
- **Projection ordering.** Phase 1 runs `audit_events` last —
  after `companies` / `agents`. Phase 2 + 3 must run AFTER
  Phase 1 since they may want to dedupe against
  `audit_events`. Single-pass per phase is enough at current
  scale (~180K events / 12 months / 5 companies); chunked
  insert covers SQLite's bind-parameter ceiling.
- **Backward compatibility.** Pre-1.0, we can break the reindex
  contract. Post-1.0 we probably cannot. How do we version the
  projection catalogue? Defer to GEP-43 if it ships first; else
  simple `:reindex_version` row in a `meta` table.

## Decision log

### D1. Phase split — three PRs, not one

**Decided** 2026-04-26. Each gap-table is its own PR with its
own tests. Phase 1 (`audit_events`) shipped first because the
audit log is the *input* to phases 2 and 3 — so its replay
infrastructure is the foundation.

**Why:** a single mega-PR would touch three unrelated schemas,
add three sets of replay logic, and risk a partial revert if
any phase has a bug. Splitting keeps each diff under
reviewable size.

### D2. Best-effort line decoding

**Decided** 2026-04-26 (Phase 1). Malformed JSONL lines, lines
without required keys (`actor`, `action`, `ts`), and lines >
64 KiB are *skipped with a warning*, not crashes.

**Why:** the JSONL file is authoritative — if SQLite reindex
crashes on a bad line, the user is stuck. Skipping preserves
recovery while logging the issue. The 64 KiB cap matches
`AgentWritableFile.read_bounded`'s philosophy: bound the worst
case so a corrupted multi-GB line cannot OOM the BEAM.

### D4. Audit-only replay for `tasks_approval_state`

**Decided** 2026-04-26 (Phase 2). The `Approvals.Gate` continues
to delete the `awaiting-approval-<id>.md` sentinel on resolution;
no resolved-approval sentinel is written. Replay folds
`approval.{requested,granted,denied}` lines from JSONL.

**Why:** the audit JSONL line carries every field the schema
needs (`agent`, `target`, `ts`, `denial_reason`); writing a second
file at resolution time would couple the gate to a redundant
forensic artifact already surfaced by the dashboard's audit
stream. One source of truth beats two.

### D6. Sum-fold for `budgets`, no chronological dependency

**Decided** 2026-04-26 (Phase 3). The `budgets` rebuild folds
per-event token / cost deltas into per-`{company, agent,
year_month}` aggregates. Order does not matter — addition is
commutative — so we don't sort filenames or lines.

**Why:** Phase 2's chronological fold was load-bearing (a
later resolution event must overwrite an earlier `awaiting`
state). Phase 3's fold is just summation. Skipping the sort
keeps the code simpler and the cross-month behaviour falls out
naturally because each event's `ts` carries its own
`year_month` bucket.

### D7. Use writer's `month_bucket/1`, don't reinvent

**Decided** 2026-04-26 (Phase 3). The replay imports
`Glorbo.Budget.Ledger.month_bucket/1` and calls it on each
event's `ts`. The format ("YYYY-MM") is the same one the
writer uses to populate the `year_month` column in live
recording, so replay rows are bind-for-bind identical to live
rows.

**Why:** if reindex computed `year_month` differently (e.g.
direct `String.slice/3` on the ISO 8601 string), a future
writer-side change to `month_bucket/1` would silently desync
live rows from replayed rows. Importing the same helper makes
the coupling explicit.

### D5. Chronological fold via filename + line order

**Decided** 2026-04-26 (Phase 2). The fold relies on
`YYYY-MM.jsonl` filenames sorting chronologically when sorted
lexicographically, plus `File.stream!` preserving append order
within each file.

**Why:** the on-disk audit format already enforces this ordering
(GEP-19 / append-only). Adding an explicit ts-sort on every
streamed line would force the fold to materialize all lines
before processing — defeating the bounded-memory goal in §Goals.
The fold is correct as long as the writer respects append
ordering, which it does.

### D3. Wipe-and-rebuild, not incremental

**Decided** 2026-04-26 (Phase 1). `Reindex.run/1` calls
`Repo.delete_all(AuditEvent)` before re-importing.

**Why:** reindex's invariant is "after a run, the table matches
the on-disk source." Incremental import (only new lines since
last reindex) is faster but adds drift risk: if a JSONL line is
hand-edited or rolled, the table goes out of sync. Wipe-and-
rebuild trades runtime for correctness — which is the right
trade for a recovery tool.

## Open design surfaces

## Open design surfaces

- `Glorbo.Filesystem.Reindex.run/1` — current projector is
  linear + per-table. V2 needs a projection DSL so each table's
  rebuild is a distinct module (`Glorbo.Projections.Budgets`,
  `Glorbo.Projections.Approvals`, `Glorbo.Projections.AuditEvents`)
  orchestrated by a common runner.
- Stream API for `audit/*.jsonl` — there is no unified reader today.
  Callers grep the file tree manually.
- SQLite bind-parameter ceiling — already hit once in
  `cleanup_vanished/1`; a full audit-log replay with thousands of
  events needs to chunk inserts.

## Related

- GEP-3 — Filesystem as source of truth (the invariant this GEP
  repairs)
- GEP-7 — SQLite as derived data (the policy this GEP enforces)
- GEP-19 — Director approval workflow (the approval state whose
  rebuild is broken)
