---
gep: 64
title: Backup / Restore portability (`glorbo backup` · `glorbo restore`)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-06-14
requires: [3, 7]
see-also: [33, 34, 61]
history:
  - date: 2026-06-14
    status: Implemented
    note: |
      Retroactive governance GEP. `glorbo backup` / `glorbo restore`
      (`lib/glorbo/backup.ex`, `lib/glorbo/restore.ex`) shipped earlier
      under archived GSD-v1 planning (D-19..D-26, threat IDs T-05-*) with
      no governing GEP — surfaced by the 2026-06-14 reconciliation audit
      as a security-critical subsystem lacking a design record. This GEP
      documents the as-built contract; it is descriptive, not a change.
---

# GEP-64: Backup / Restore portability

## Problem

Glorbo's home (`~/.glorbo/`) is "just a folder", so the marketing promise is
`glorbo backup | scp | glorbo restore` reproduces a working install on a fresh
host (README). That promise is load-bearing user data movement, and `restore`
extracts an attacker-or-operator-supplied `tar.gz` — a classic archive-attack
surface (path traversal, symlink races, archive bombs). The two verbs shipped
with a careful contract but no GEP recording it, so the invariants below were
undocumented and at risk of silent regression.

## Design — the as-built contract

### `glorbo backup` (`Glorbo.Backup`)

- **Allowlist, not denylist.** The archive contains exactly `companies/`,
  `config.md`, `audit/`, and `glorbo.db`. Derived / re-downloadable trees
  (`bin/`, `models/`, `containers/`, `runtime/`, `run/`) are excluded.
- **Quiescence precondition (D-21).** Refuses to run while glorbo is up
  (pidfile present and live) unless `:force_live` is set, so the archived
  `glorbo.db` is not torn mid-write.
- **WAL checkpoint (T-05-10).** `PRAGMA wal_checkpoint(TRUNCATE)` runs before
  archiving so the captured `glorbo.db` is not stale relative to its WAL.
- **Safe output (T-05-06).** The archive is written to a private temp path,
  `chmod 0600`, then atomically renamed into place. Symlinks are preserved as
  symlinks (no `:dereference`).

### `glorbo restore` (`Glorbo.Restore`)

Three sequential refusal gates run over `:erl_tar.table/2` **before** any
`:erl_tar.extract/2`:

1. **Path traversal (T-05-01).** Entries beginning with `/` or containing `..`
   segments are rejected.
2. **Link entries (PR #36 round-4).** Symlink / hardlink entries are refused
   outright — `:erl_tar.extract` materialises entries in archive order, so a
   crafted `evil` (symlink → `/tmp`) + `evil/payload` pair could write outside
   the tree *during* extract, before any post-extract walk. The refusal is
   **fail-closed**: it does not try to distinguish a "safe" symlink from a
   hostile one. **Known limitation / tension (D2):** `Glorbo.Backup` archives
   without `:dereference`, so a symlink living under an allowlisted tree
   (`companies/`, `audit/`) is stored as a tar link entry — which `restore`
   then refuses. So a backup of a home that contains such a symlink will not
   restore. This is the deliberate, security-first trade-off below; the proper
   fix (have `backup` either refuse or dereference symlinks so the round-trip
   is total) is tracked as follow-up work, not yet shipped.
3. **Uncompressed size cap (WR-03).** Total uncompressed bytes ≤ 10 GiB
   (archive-bomb guard).

Archive bytes are copied into a private O_EXCL staging file under `base` before
either pass reads them, closing the staging↔extract TOCTOU (PR #36 round-4).

After a clean extract, the post-extract chain `migrate → reindex →
doctor --fix` (D-22) rebuilds the derived SQLite schema + index from the
restored filesystem (consistent with GEP-3/7: the DB is derived).

## Decisions

- **D1. Allowlist the durable subset.** Mirrors the GEP-33 home-history
  tracked scope and GEP-3's "filesystem is the source of truth"; derived state
  is rebuilt on restore, never archived as authoritative.
- **D2. Fail-closed on any link entry.** Cheaper and safer than trying to make
  symlink extraction safe. Trade-off accepted: because `backup` preserves
  symlinks (no `:dereference`), a home with a symlink under an allowlisted tree
  produces an archive `restore` will reject — so the backup→restore round-trip
  is **not total** for such homes. Closing that gap (refuse-or-dereference at
  backup time) is follow-up work; the security refusal at restore stays
  fail-closed regardless.
- **D3. Migrations, then reindex on restore.** The schema is owned by
  migrations (GEP-7), not by the archive, so a restore onto a newer binary
  self-migrates.

## Security

The restore path is the primary untrusted surface and is covered by the three
gates + O_EXCL staging above (threat IDs T-05-01/06/10, WR-03, PR #36 round-4).
Backups inherit the on-disk file modes; the archive itself is `0600`.

## Related

- **GEP-3 / GEP-7** — filesystem-as-truth + SQLite-as-derived (why only the
  durable subset is archived and the DB is rebuilt on restore).
- **GEP-33** — git history layer (overlapping "tracked durable scope").
- **GEP-34** — reindex v2 (the rebuild that runs post-restore).
- `lib/glorbo/backup.ex`, `lib/glorbo/restore.ex`; `glorbo backup|restore`.
