---
gep: 0043
title: ETS-first derived state with on-disk snapshots for cold boot
author: Glorbo Maintainers <security@example.invalid>
status: Placeholder
type: Standards
created: 2026-04-25
history:
  - date: 2026-04-25
    status: Placeholder
    note: |
      Reserved during the SQLite-vs-ETS sidebar that came up while
      diagnosing the broken `mix glorbo.build_local` (exqlite NIF
      can't find `erl_nif.h` under Burrito cross-compile). Maintainer
      decision: keep SQLite for now, patch Burrito at the env level,
      but pin this as a forward direction so it doesn't drift away.
      Most decisions explicitly open until GEP-34 lands and the
      derivation gaps it identifies are closed.
requires: [3, 7]
see-also: [34]
---

# GEP-43: ETS-first derived state with on-disk snapshots for cold boot

## Problem

`glorbo.db` (SQLite via Ecto) carries seven tables today:
`companies`, `agents`, `tasks`, `provider_models`, `audit_events`,
`budgets`, `tasks_approval_state`. Per GEP-7 these are *derived*
from `~/.glorbo/companies/*.md` + `audit/*.jsonl` and rebuildable
via `glorbo reindex`.

That story is broken in two specific places (per GEP-34): `budgets`
(running monthly aggregates + `alerts_fired` bitmap) and
`tasks_approval_state` (`resolved_at`, `reason` after the sentinel
is deleted). Neither has an on-disk counterpart; deleting
`glorbo.db` loses both.

Separately, the SQLite stack is the load-bearing reason
`mix glorbo.build_local` is currently broken — `exqlite` is a NIF
that needs Erlang headers, and Burrito's cross-compile environment
isn't passing `ERL_EI_INCLUDE_DIR` correctly. Every other Glorbo
runtime dependency is pure-Elixir.

The architectural question pinned by this GEP: **once GEP-34 makes
those two tables fully derivable from the audit log, do we still
need SQLite?**

## Goals

- Replace `glorbo.db` with **in-memory ETS tables** for the
  derived projections currently stored in SQLite.
- For the small set of values that genuinely need cold-boot
  durability (budget rolling totals, dedupe sets the audit log
  alone can't reconstruct cheaply), persist a **periodic
  snapshot** to disk — DETS or a flat JSON dump under
  `~/.glorbo/cache/derived/` so they survive a BEAM restart
  without a full audit-log replay.
- Keep `~/.glorbo/companies/*.md` + `audit/*.jsonl` as the
  authoritative source of truth (GEP-3 unchanged).
- Eliminate the `exqlite` NIF dependency — pure-Elixir Glorbo,
  no host-side build environment for `mix release`.

## Non-goals

- **Not a query-language layer.** ETS gives you `:ets.select/2`
  with match specs; LiveViews that currently use Ecto rewrite
  to that. No SQL emulation, no DSL.
- **Not a cross-host story.** Glorbo stays single-host
  (GEP-23 §Non-goals). ETS being node-local is fine.
- **Not a hot-path persistence layer.** Snapshots are *for cold
  boot*, not for ACID durability of every write. The audit log
  remains the durable event stream; snapshots are an
  optimisation to skip a full audit replay on startup.
- **Not blocking on GEP-34.** GEP-34 is a hard prerequisite, but
  this GEP doesn't try to do GEP-34's work — it composes on top
  once that lands.

## Settled decisions

### D1. Pin as a separate GEP, not folded into GEP-34

**Decided:** GEP-34 (reindex v2 — make `budgets` + `approvals`
fully derivable) and this GEP (ETS-replaces-SQLite) are two
separate forces. GEP-34 fixes a correctness bug in the current
architecture; GEP-43 pivots the architecture itself.

**Why:** GEP-34 is reachable today without architectural commitment.
GEP-43 touches every Repo callsite — LiveViews, scaffolders, the
Provider catalog, the audit query layer. Conflating them would
gate the correctness fix on a structural pivot. Better to ship
GEP-34 standalone, then pivot when there's appetite.

### D2. GEP-34 is a hard prerequisite

**Decided:** this GEP cannot ship until GEP-34 (or its equivalent)
makes `budgets` + `tasks_approval_state` fully derivable from the
audit log.

**Why:** without GEP-34, ripping out SQLite means losing those two
fields permanently. ETS would not — *cannot* — give them back.
The cost-benefit only flips once the on-disk source-of-truth
gap is closed.

## Open questions

- **DETS vs JSON snapshots vs both?** DETS is OTP-native, gives
  you a persistent term store with durability guarantees, and
  reads back as native Erlang terms. JSON is human-readable,
  diffable, and survives BEAM-version changes; but it's lossier
  (atoms become strings, structs become maps). Probably JSON
  for human-meaningful caches (provider catalog, model lists)
  and DETS for high-churn aggregates (budget totals). Decide
  per-table.

- **Snapshot cadence.** Every N audit events? Every 60 seconds?
  On graceful shutdown only? On every write that touches a
  durable field? Trades freshness against I/O. Lean toward
  "graceful-shutdown + periodic 5-minute" — graceful covers the
  happy path, periodic covers SIGKILL.

- **Cold-boot policy.** If the snapshot is missing or older than
  N hours, fall back to a full audit-log replay? Or hard-fail
  and force `glorbo reindex`? Replay is more user-friendly but
  hides snapshot bugs.

- **LiveView ergonomics.** Ecto's `where/order_by/preload` chains
  in `OverviewLive`, `AuditLive`, `BudgetsLive`, `ProvidersLive`
  rewrite to ETS folds. How much complexity does that add?
  Worth a spike before committing.

- **Migration path.** Atomic cut (rip + replace in one PR) vs
  parallel-run (both backing stores wired, switch via flag,
  deprecate Ecto)? Atomic is consistent with the project's pre-1.0
  posture but makes the diff huge.

- **Schema evolution post-1.0.** Ecto migrations are battle-tested
  for forward/backward compat. ETS + snapshots needs an
  equivalent — versioned snapshot files with migration code in
  the boot path. Real work, not a footnote.

- **Audit-log replay performance.** N companies × 12 months of
  audit JSONL is the worst case. At 100 events/day/company × 12
  months × 5 companies that's ~180K events; replay needs to be
  sub-second. Probably fine, but unmeasured.

- **Backup story.** `glorbo backup` includes `glorbo.db` today
  (audit log + filesystem reconstruct everything else). Post-
  GEP-43, the snapshots replace the .db blob; backup needs to
  decide whether snapshots are durable enough to skip
  (re-derivable from audit) or worth including (saves cold-boot
  replay cost).

- **What about the `Glorbo.Network.History` decision cache?**
  Already ETS-only with no persistence — survives this GEP
  unchanged. Same for `Glorbo.Network.ProxyTokens`.

## Prerequisites for promotion to Draft

Mechanical:

- GEP-34 lands (`budgets` + `approvals` derivable from audit log).
- A spike that converts ONE of the LiveView Ecto-using surfaces
  to ETS, to surface real query-ergonomics costs.
- A measured audit-log replay benchmark on representative data.

Design:

- Answer the per-table DETS-vs-JSON-vs-derived question for each
  of the seven SQLite tables.
- Decide snapshot cadence + cold-boot policy.
- Decide migration path (atomic vs parallel-run).
- Sketch the schema-evolution story for snapshots.

## Related

- **GEP-3** — filesystem as source of truth. This GEP composes
  on top: keeps GEP-3's invariant intact, just changes the shape
  of the *derived* layer.
- **GEP-7** — SQLite as derived data. This GEP is a candidate
  *successor* to GEP-7's storage choice. If accepted, GEP-7 gets
  superseded.
- **GEP-34** — reindex v2. Hard prerequisite per D2.
