# Planning Archive

This directory was `.planning/` — the GSD v1 planning workspace used through
v0.0.2. As of 2026-04-16 the project is stepping off the GSD workflow to try
lighter approaches. These artifacts are kept for historical reference only.

## Status: frozen

- No active phase work lives here.
- Contents may be outdated relative to the current codebase.
- Idea captures under `notes/` from 2026-04-16 include candidate workflow
  directions (retrofit-friendly GSD, plan-only, etc.) and may be revisited
  if GSD is re-enabled later.

## What this was

- `PROJECT.md` — top-level project context GSD used to seed agents.
- `MILESTONES.md`, `milestones/` — milestone roadmaps and archived phase
  dirs (v0.0.2 artifacts live under `milestones/v0.0.2-*`).
- `phases/` — intentionally empty after cleanup; active phase dirs were
  archived into `milestones/v0.0.2-phases/`.
- `codebase/`, `intel/` — cached codebase analysis produced by GSD mapper
  agents; likely stale now.
- `notes/` — ad-hoc idea captures; these remain genuinely useful even
  without GSD.

## Re-enabling GSD

If the project returns to GSD:

1. Restore `~/.claude/settings.json` from the pre-disable backup
   (`~/.claude/settings.json.backup-pre-gsd-disable-*`).
2. `git mv .planning.archive .planning`.
3. Run `/gsd-intel --refresh` and `/gsd-map-codebase` to rebuild stale
   snapshots.
4. Audit `notes/` for anything worth promoting into the live roadmap.

## Why archived, not deleted

The milestone audits, phase plans, and requirements docs captured real
design decisions for v0.0.1 / v0.0.2. Throwing them away loses the "why
did we do it this way" trail. Keep as read-only history.
