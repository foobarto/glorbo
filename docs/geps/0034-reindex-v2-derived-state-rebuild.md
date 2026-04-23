---
gep: 0034
title: Reindex v2 — full derived-state rebuild from disk + audit JSONL
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
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

## Open questions

- **Where should resolved approvals' timestamp + reason live
  on-disk?** Options: resolution sentinels
  (`state/resolved-approval-<id>.md`) retained instead of deleted,
  OR replay from `audit/*.jsonl` (`approval.granted` /
  `approval.denied` events carry the fields already).
- **Budget state same question.** Audit JSONL carries
  `usage.recorded` events with tokens + cost. Rebuild from those,
  OR write a per-agent per-month budget ledger file.
- **Projection ordering.** If reindex rebuilds `companies/agents`
  first (current behaviour), then `audit_events`, then `budgets`,
  then `tasks_approval_state` — do we need a single pass or
  multiple? Streaming audit JSONL once per projection is OK at
  current scale but may matter at N companies × 12 months.
- **Backward compatibility.** Pre-1.0, we can break the reindex
  contract. Post-1.0 we probably cannot. How do we version the
  projection catalogue?

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
