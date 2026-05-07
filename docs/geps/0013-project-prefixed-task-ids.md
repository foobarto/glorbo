---
gep: 0013
title: Project-prefixed task IDs
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Standards
created: 2026-04-17
updated: 2026-04-17
history:
  - date: 2026-04-17
    status: Draft
    note: Initial draft — problem + two naming-scheme candidates.
  - date: 2026-04-17
    status: Implemented
    note: >-
      KanbanLive.next_task_id/3 now emits `<project>-NN`, accepts both
      shapes on read, TaskDefinition.canonicalize_ref/2 ships,
      `mix glorbo.migrate_tasks[ --dry-run]` lands for opt-in cleanup.
extended-by: [47]
---

# GEP-13: Project-prefixed task IDs

## Problem

Tasks are identified by their filename stem today — `t-01.md` →
`task_id: "t-01"`. The `t-` prefix is a convention, not a constraint,
and the number restarts at 01 for every project. Consequences:

- Two projects with independent task numbers collide on the *human*
  axis — "pick up t-03" is ambiguous across `website` and `demo`.
- The audit log stores the full `task_path` (`projects/website/tasks/t-01.md`)
  so the on-disk identifier is unambiguous, but the UI surfaces the
  bare `task_id`, which isn't.
- The kanban `+ new task` flow has to scan a single project's `tasks/`
  directory to pick the next number; if a task moves between projects
  (a rename on disk), ID uniqueness breaks.

A project-scoped prefix fixes all three. The proposed filename is
`<project-slug>-<NN>.md` — e.g. `website-01.md`, `website-42.md`,
`demo-01.md`.

## Goals

- Every task is human-identifiable on sight: `website-42` self-describes.
- Task ID uniqueness *within* a project is trivial (filename is unique
  by filesystem); task ID uniqueness *across* a company is trivial
  because the prefix segregates namespaces.
- `glorbo new task …` can compute the next number by scanning only the
  one project's `tasks/` directory (no change from today, but the
  generated filename carries the prefix).
- Existing task files can be migrated in place (rename) without
  breaking audit links — the audit log's `target:` field stores
  `projects/<proj>/tasks/<id>.md`, so the rename is a coordinated
  filesystem + audit-replay step.

## Non-goals

- Cross-project task moves. A task's project is declared by the
  directory it lives in; moving it means renaming the file AND
  updating any references. That's a separate feature.
- Replacing the `task_path` as canonical identifier. The path stays
  authoritative; only the human-readable `task_id` slug shape changes.
- Stable external IDs. `website-42` is a human label, not a UUID — if
  a task is deleted and a new one is created later, `website-42` can
  in principle be reused. Tests / audit correlation should key off
  the creation timestamp in frontmatter, not the slug.

## Design

### Filename shape

```
projects/<project-slug>/tasks/<project-slug>-<NN>.md
```

- `<project-slug>` must match `~r/\A[a-z][a-z0-9-]*\z/` (same as the
  existing slug validator).
- `<NN>` is a zero-padded sequence (`01`, `02`, …, `99`, `100`, `101`).
  Pad to 2 for the first 99; drop padding after.
- The slug portion between prefix and number is a single `-`. Project
  slugs may *contain* hyphens (`website-redesign`), which means the
  parser needs to pick the last `-<digits>$` pair as the split point.

### TaskDefinition changes

- `derive_task_id/1` (currently filename stem) stays the same — the
  task_id IS the filename stem, which now includes the project prefix.
- `derive_project/1` currently parses `task_path` (not the task_id).
  No change; stays authoritative.
- No change to `Glorbo.TaskDefinition.write/2` or the frontmatter
  schema.

### KanbanLive new-task scaffolding

`next_task_id/3` currently returns `t-<NN>`. Change to return
`<project-slug>-<NN>`. The scan still looks at the project's `tasks/`
directory; the regex broadens from `t-(\d+)\.md` to
`#{project}-(\d+)\.md`.

### CLI — `glorbo new task <company>/<project>/<title>`

Scaffolds `<project>-<NN>.md` under `companies/<co>/projects/<proj>/tasks/`
with the next free number. Existing scaffolding that emits `t-01.md`
needs the same change.

## Migration / rollout

v0.0.3 tasks on existing installs are `t-NN.md`. Two options:

**(a) Soft migration** — leave old `t-*.md` files alone; only new
tasks use the new shape. Parser accepts both. Ugly long-term but
zero user action required.

**(b) Explicit migration** — a `glorbo migrate tasks` CLI verb that:
1. Walks every `projects/<proj>/tasks/t-NN.md` file.
2. Renames to `<proj>-NN.md`.
3. Greps the audit log for `target: "projects/<proj>/tasks/t-NN.md"`
   and writes a one-time `task.migrate` audit event linking old path
   to new path. Audit remains append-only; existing rows are not
   rewritten.
4. `glorbo reindex` after to refresh SQLite's `task_path` column.

Proposed: ship (a) first (zero-risk), and add (b) as an opt-in verb
in the same release. Users upgrading from v0.0.2 / v0.0.3 can run
`glorbo migrate tasks --dry-run` to preview.

## Failure modes

- **Audit orphans after migration.** Old audit rows reference
  `t-01.md`; new ones reference `website-01.md`. The UI must resolve
  either form when building "history for task X". Helper:
  `Glorbo.TaskDefinition.canonicalize_ref/2` that accepts either
  shape and returns the current on-disk path.
- **Project rename.** If `website` becomes `site`, all `website-*.md`
  tasks need to become `site-*.md`. Out of scope for v0.0.3; flagged
  as an open question.
- **Slug collision.** `project-123` and a task numbered `123`
  collide. Mitigated by the `-<digits>$` parser rule (project slug
  must not end in `-<digits>`) — reject such project slugs at
  creation time.

## Test strategy

- `TaskDefinitionTest` — parse `website-42.md` with the new prefix,
  assert `task_id == "website-42"`, `project == "website"`.
- `TaskDefinitionTest` — parse `website-redesign-07.md`, assert the
  project-slug / sequence split works (`project == "website-redesign"`,
  task_id == `website-redesign-07`).
- `KanbanLive` test — `+ new task` under project `website` writes
  `website-01.md` (not `t-01.md`). Incrementing to `website-02` works.
- CLI — `glorbo new task acme/website/Ship v3` writes the expected
  filename.
- Migration — unit test for `canonicalize_ref/2` across both shapes.

## Open questions

1. **Do we cap the number?** File-system scaling has no hard cap, but
   UI density does. A company with 9,999 tasks per project will look
   weird. Leave uncapped; worry later.
2. **Do we allow manual renames?** If a user renames `website-01.md` to
   `website-001.md` via the filesystem, the scan regex has to handle
   it. Proposed: accept any `<project>-<digits>.md` shape on read;
   only generate the default shape on write.
3. **Project rename cascade.** Not solved here. Sketched above.

## Decision log

### D1. Prefix is the project slug, not an abbreviation

- **Decided:** Task files use the full project slug as the prefix.
  `website-redesign-01.md`, not `wr-01.md`.
- **Alternatives:** A separate `task_prefix` field in `project.md`
  frontmatter (e.g. `WEB-01`). Shorter and familiar (Jira), but adds
  a mapping the user has to maintain and breaks "slug on disk ==
  slug in URL" invariant.
- **Why:** The slug is already unambiguous, already in the path. One
  namespace, one spelling.

### D2. Zero-padded to 2, then natural

- **Decided:** `01..09`, `10..99`, `100..`. No padding beyond 99.
- **Alternatives:** Always 3 digits (`001`). Always natural (`1`).
- **Why:** The 2-digit pad keeps a folder of 10-99 tasks lexically
  sortable, which matters because `File.ls/1` sorts alphabetically
  (used in the kanban reloader + audit tail). Beyond 99, lexical
  sort breaks anyway; accept it.

### D3. Soft migration first, explicit verb second

- **Decided:** Parser accepts both old `t-NN.md` and new
  `<project>-NN.md` on read. Generators only emit the new shape.
  Opt-in `glorbo migrate tasks` verb for users who want to clean up.
- **Alternatives:** Auto-migrate on first boot after upgrade.
- **Why:** The filesystem is the user's data. Auto-mutating files
  at upgrade time violates CLAUDE.md's "filesystem as source of
  truth, never modified by upgrades" invariant.

## Related

- [GEP-3](./0003-filesystem-as-source-of-truth.md) — filesystem as
  source of truth; task files are user data.
- [GEP-7](./0007-sqlite-as-derived-data.md) — audit/SQLite derived
  from filesystem; reindex must handle both ID shapes during the
  transition.
