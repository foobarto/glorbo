---
gep: 63
title: Goals as `goal/v1` files (file-canonical store)
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
implemented-in: v0.27.0
type: Standards
created: 2026-06-13
requires: [3, 7, 13]
see-also: [6]
history:
  - date: 2026-06-13
    status: Draft
    note: |
      Filed from finding F1 of the 2026-06-13 browser E2E sweep: the goals UI
      (`GoalsLive`, `CompanyLive`, `OverviewLive`) reads goals ONLY from
      `company.md` frontmatter `goals:`, while the fully-specced `goal/v1`
      files (`goals/<id>.md`, `Glorbo.FileSpec.GoalMd`) the scaffold writes are
      never read by any UI — orphaned, with active doc drift (`goal_v1.md`
      claims the UI reads `progress:`; it does not). Operator chose option B2:
      make `goal/v1` files the single canonical store (file-canonical), an
      atomic pre-1.0 cut.
  - date: 2026-06-13
    status: Accepted
    note: |
      Operator decisions: D1 — REJECT the id→slug UI mapping; use `id` as the
      single identifier vocabulary throughout (rename the goals UI's internal
      `slug` usages to `id` — no two ways to identify a resource). D3 — no
      automated migrator; document the manual migration in CHANGELOG.md. Other
      recommendations accepted (progress validated 0..100; dangling-refs +
      CLI/MCP goal CRUD deferred to follow-up GEPs).
  - date: 2026-06-13
    status: Implemented
    note: |
      Shipped all 13 touchpoints. `Glorbo.Company.Goals` rewritten: `list/1`
      is the single hardened loader the three LiveViews call; `add_goal/3`
      writes `goals/<id>.md` via `FileSpec.Formatter` + atomic tmp+rename in a
      HomeHistory `goal.create` Tx. `GoalMd` gained `:description`; `CompanyMd`
      lost `:goals` (stray `goals:` is now an `unknown_key` finding). Form
      fields renamed `slug`/`title` → `id`/`name` (D1 all the way). Progress is
      loader-validated (`integer 0..100` wins, else derive) — the Validator has
      no numeric-range primitive, so no kind-specific check was added; GoalMd
      `patterns` stays `%{}`. Docs regenerated; maximal-valid golden fixture
      added. Full precommit + Credo + Sobelow green. Manual migration documented
      in CHANGELOG (D3). Note: the `CLAUDE.md` invariant lives only locally
      (that file is gitignored) — the tracked canonical invariant is in
      `docs/DESIGN.md`.
---

# GEP-63: Goals as `goal/v1` files (file-canonical store)

## Problem

Glorbo has **two disconnected goal representations**, and the one the UI reads
is the inconsistent one:

1. **`company.md` frontmatter `goals:`** — a list of `{slug, title, …}` maps. This
   is the *de-facto* store: read by `GoalsLive`, `CompanyLive`, and
   `OverviewLive` (each with its own near-duplicate `normalize_goal/1`), and
   written by `Glorbo.Company.Goals.add_goal/3` via fragile textual frontmatter
   splicing.
2. **`goals/<id>.md` `goal/v1` files** — a fully-specced format
   (`Glorbo.FileSpec.GoalMd`, registered in `file_spec.ex`, validated +
   formatted + doc-generated), created by `Glorbo.Init.ExampleCompany.scaffold!`
   (`goals/q3-2026.md`) and version-tracked by `home_history`. **No UI code
   reads it.**

Consequences:

- The scaffolded `goals/q3-2026.md` **never appears** in the goals UI — a fresh
  `glorbo init` shows only the "(no goal)" bucket (the F1 finding).
- **Active doc drift:** `docs/file-formats/goal_v1.md` states "Progress bars on
  CompanyLive + GoalsLive read `progress:` when present; falls back to deriving
  progress from linked tasks" — a reader that **does not exist**.
- Goals are the **only first-class entity not stored as one-file-per-entity**.
  Tasks, agents, projects, channels, and skills are each their own file
  (GEP-3, GEP-13); goals-in-frontmatter is the odd one out, and it forces the
  brittle splice writer and three drifting readers.

## Goals

- Make `goal/v1` files (`companies/<co>/goals/<slug>.md`) the **single canonical
  goal store**, consistent with the one-file-per-entity model and "filesystem
  is source of truth" (GEP-3).
- Collapse the three duplicated readers into **one shared loader**
  (`Glorbo.Company.Goals.list/1`) so they cannot drift again.
- Wire the long-promised **`progress:` field** (explicit-wins-else-derive),
  making the `goal_v1.md` doc true for the first time.
- Replace the `company.md` frontmatter-splice writer with a clean
  one-file-per-goal writer reusing the existing atomic tmp+rename + HomeHistory
  transaction machinery.
- Provide a one-shot migrator for existing on-disk `company.md goals:` data.

## Non-goals

- A queryable goals SQLite table. `reindex` already falls through `goals/*.md`
  to `:ok`; goals stay a pure filesystem read for the UI. (A future GEP can add
  a `goals` projection if cross-company goal queries are wanted — it must be
  rebuildable from disk per GEP-7.)
- A CLI / MCP goal-CRUD surface. The `add_goal` `actor:` seam anticipates it,
  but exposing a verb/tool is a separate GEP.
- Surfacing dangling `goal:` task refs (an "(unknown goal)" bucket / validator
  check). Adjacent but out of scope.
- `owner:` / `due:` UI rendering. These goal/v1 fields stay parsed-but-unused
  until a future GEP gives them a surface.

## Design

### Canonical store

`companies/<co>/goals/<slug>.md`, one file per goal, `kind: goal/v1`.
`Glorbo.FileSpec.GoalMd` already specs/validates/formats it — only the UI
ignored it.

Post-cut `GoalMd` schema:

- **Required:** `kind`, `id`
- **Optional:** `status`, `name`, `description` *(new)*, `owner`, `due`,
  `progress`
- `status` enum: `active | paused | done | cancelled`
- canonical key order: `kind, id, name, description, status, owner, due, progress`

`id` is the canonical identifier (**Decision D1**), MUST equal the filename
basename (one-file-per-entity), and MUST satisfy the slug regex
`^[a-z][a-z0-9-]{0,63}$` — so it doubles as filename, task-join key, and a
`Slug.valid?` Kanban-filter value.

### Field model + task linkage

The shared loader normalises each file to a UI map keyed on **`id`** — the
single identifier vocabulary (Decision D1: no `id`↔`slug` dual-naming). This
renames the goals UI's existing internal `slug` key/usages to `id` (templates,
the deep-link param value, the task-rollup join key):

```
%{id: <id>, title: <name || id>, description: <description || "">,
  status: <status || "active">, progress: <progress | nil>}
```

Tasks link via `task/v1` `goal: <value>` — the *value* is unchanged (matched by
exact string equality against the goal `id`); only the Elixir variable/key name
changes from `slug` to `id`. Because `id == filename`, a task with
`goal: q3-2026` resolves to `goals/q3-2026.md`. The Kanban `?goal=<id>`
deep-link value is unchanged. All four match sites (GoalsLive / CompanyLive /
OverviewLive rollups + KanbanLive filter) keep their string-equality logic; the
slug→id rename is mechanical.

### Progress source-of-truth (explicit-wins-else-derive)

The aggregator reads `progress:`. If it is a non-nil integer in `0..100`, that
value is authoritative for the bar (and its colour state). Otherwise
`progress_pct = div(done * 100, total)` from linked tasks (0 when `total == 0`),
exactly as today. `task_count` / `done_count` still come from linked tasks for
the "N of M tasks done" label even when `progress_pct` is overridden.

### Shared loader + security

`Glorbo.Company.Goals.list/1` is the single source the three LiveViews call. It
enumerates `goals/*.md` and — because this is a **newly-enumerated,
agent-writable directory** — applies the same hardening as the task readers:
`Slug.valid?` per filename, `lstat`/`real_directory?` on `goals/` (mirroring the
Codex PR#38 symlink-ancestor guard), `AgentWritableFile.read_bounded` (1 MiB
cap), and safe-scalar coercion on every field. Malformed / symlinked / oversized
files are **silently skipped** (T9 no-crash guarantee), never rendered as broken
cards. A missing `goals/` dir yields `[]`.

## Migration

Pre-1.0 **atomic cut — no dual-read shim, no back-compat** (per the project's
"no kid gloves" stance). After the cut nothing reads `company.md goals:` and
`CompanyMd` no longer blesses the key (a stray `goals:` becomes an
`unknown_field` Validator finding — intended).

Touchpoints (all grounded in the goal-model map):

1. `file_spec/goal_md.ex` — add `:description`; insert it into the key order;
   keep (and sharpen) the `progress:` doc.
2. `company/goals.ex` — **rewrite `add_goal/3`**: drop the frontmatter-splice
   machinery; take the company *dir*; write `goals/<slug>.md` (uniqueness =
   `File.exists?`) via `Formatter.format_content` + the existing
   `atomic_open_and_rename` inside the HomeHistory Tx; rename action
   `company.add_goal` → `goal.create`; `mkdir_p` `goals/`. Keep the `actor:` seam.
3. `company/goals.ex` — **add `list/1`** (the hardened shared loader, above).
4. `goals_live.ex` — read via `Goals.list/1`; delete local `normalize_goal/1`;
   honour explicit `progress`; repoint `add_goal` to the dir; rewrite moduledoc
   + empty-state + header copy ("declared in company.md" → goal files).
5. `company_live.ex` — read via `Goals.list/1`; delete the duplicate
   `normalize_goal/1`; honour explicit `progress`. Task-side rollup
   (`collect_goal_task_counts`, already symlink-hardened) unchanged.
6. `overview_live.ex` — `company_goals/1` reads via `Goals.list/1`; summary math
   + CompanyCard nil-to-hide contract unchanged.
7. `file_spec/company_md.ex` — **remove `:goals`** from schema + key order +
   docs + example. Regenerate `company_v1.md`.
8. `file_spec/formatter.ex` — comment-only: `budget:` becomes the sole
   list-of-maps shape once `:goals` leaves `CompanyMd`.
9. `init/example_company.ex` — remove the `goals:` block from `@company_md`;
   keep `@goal_md` (now the canonical, *read* example); optionally add a
   `description:`.
10. `cli/scaffold/company.ex` — add `goals` (and `skills`) to the scaffolded
    subdir list.
11. `CHANGELOG.md` — document the manual migration under the version's
    `### Changed` (see below). **No automated migrator** (Decision D3).
12. `docs/DESIGN.md` + `CLAUDE.md` — describe goals as files; add the invariant
    "`goals/<slug>.md` is the canonical goal store; `company.md` carries no
    `goals:` list."
13. `mix glorbo.docs.file_formats` — regenerate `goal_v1.md` + `company_v1.md`
    (never hand-edit the autogenerated files).

**Existing on-disk data — documented manual migration, no automated migrator
(Decision D3).** Per-goal recreation is trivial and the live data set is small,
so the upgrade is handled by a `CHANGELOG.md` note rather than a `mix` task. The
note instructs operators who have `company.md goals:` entries to, for each goal,
create `companies/<co>/goals/<slug>.md`:

```yaml
---
kind: goal/v1
id: <slug>          # = the old goals: slug, and the filename basename
name: <title>       # = the old goals: title
status: active      # one of: active | paused | done | cancelled
---
```

then delete the `goals:` block from `company.md`. (Equivalently: re-add each goal
through the dashboard's add-goal form, which now writes the file directly.) An
off-enum `status:` simply won't validate — operators map it to a valid value.
Not folded into `glorbo reindex` either (reindex stays a pure derived-state
read, GEP-3/7).

## Failure modes

- **Malformed / symlinked / oversized `goal/v1` file** → skipped silently by the
  loader (no broken card, no crash); surfaced only via the existing Validator on
  `glorbo validate`.
- **Off-enum `status:` in migrated data** (old path allowed free-form) → the
  migrator must map unknown → a valid enum (see open questions); a raw off-enum
  file fails `GoalMd` Validator.
- **`id` ≠ filename** → loader trusts the filename basename as the join key;
  a mismatched `id:` field is normalised away (filename wins) to preserve the
  task-link invariant.
- **Stray `company.md goals:` after the cut** → `unknown_field` Validator
  finding (intended signal to run the migrator).

## Test strategy

- `company/goals_test.exs` — **full rewrite**: assert `add_goal` writes a
  `goals/<slug>.md` `goal/v1` file (kind/id/name/status/description), uniqueness
  via `File.exists?`, HomeHistory Tx targets the goal file with `goal.create`.
- `goals_live_test.exs` / `overview_live_test.exs` / `company_live_test.exs` —
  re-seed goals as `goal/v1` files; add an explicit-`progress:`-override case +
  a derive-from-tasks case; the `name`-as-title test becomes native; the T9
  malformed-input test moves to per-file frontmatter and asserts silent-skip.
- `example_company_test.exs` — keep the `goals/q3-2026.md`-exists assertion (now
  load-bearing); assert `company.md` has no `goals:` key; optionally assert
  GoalsLive renders q3-2026 (the canary that the file is now read).
- `validator_test.exs` — swap the `goals: [`-as-syntax-error vehicle to a neutral
  key; add a case asserting a stray `company.md goals:` is an `unknown_field`.
- Golden fixtures — add a `goal_v1/maximal_valid/` fixture exercising every
  optional field (incl. `description`/`progress`) for round-trip + key-order.
- *(No migrator test — D3 dropped the `mix` task in favour of a documented
  CHANGELOG migration.)*

## Open questions

1. **Dangling `goal:` refs** — surface (validator / "(unknown goal)" bucket) or
   keep today's silent-vanish? Recommend: follow-up GEP.
2. **CLI/MCP goal CRUD** — in scope here or a separate GEP? Recommend separate.

*Resolved 2026-06-13: D1 — use `id` as the single identifier (rename the UI's
internal `slug`→`id`), operator rejected the dual-naming mapping. `progress:`
validated `integer 0..100` (loader treats out-of-range/non-integer as
unspecified → derive). D3 — migration is a documented `CHANGELOG.md` note, not a
`mix` task, so "does real data have `goals:` blocks?" and "off-enum status
mapping" no longer gate the design (operators hand-map per the CHANGELOG).*

## Decision log

### D1. Use `id` as the single identifier vocabulary *(operator-decided 2026-06-13)*

The operator rejected the lower-churn `id → slug` UI mapping: "not a fan of using
two ways for identifying resources." So `goal/v1`'s `id` is the one identifier
name everywhere — the goals UI's internal `slug` key/usages are renamed to `id`
(GoalsLive/CompanyLive/OverviewLive maps + templates, the task-rollup join key,
the deep-link param value). The `goal/v1` FileSpec is unchanged (`id` was already
its required field). Higher mechanical churn, accepted for consistency.

### D2. Atomic cut — no dual-read shim *(proposed)*

Pre-1.0 ([[feedback_pre_1_0_no_kid_gloves]] stance). No transition window where
both stores are read; `CompanyMd` stops blessing `goals:` immediately.

### D3. Documented manual migration in `CHANGELOG.md`, no automated migrator *(operator-decided 2026-06-13)*

The live `company.md goals:` data set is small and per-goal recreation is
trivial, so the upgrade is a documented `CHANGELOG.md` note (the goal/v1 file
template + "delete the `goals:` block", or just re-add via the dashboard form)
rather than a `mix glorbo.migrate_goals` task. Keeps the change lean. (Not
folded into `glorbo reindex` regardless — reindex must stay a pure
derived-state read, GEP-3/7.) Supersedes the originally-proposed one-shot mix
migrator.

### D4. Progress = explicit-wins-else-derive *(proposed)*

Honours an explicit `progress:` (`0..100`) when present; otherwise derives from
linked tasks. Makes the `goal_v1.md` doc claim true for the first time.

### D5. Add `description:` to `goal/v1` *(proposed)*

The add-goal form already collects it and the UI already renders `g.description`;
give it a frontmatter home (after `name`) rather than the markdown body.

### D6. One shared loader `Goals.list/1` *(proposed)*

Collapse the three duplicated `normalize_goal/1` readers so they can't drift —
the root cause of F1.

## Related

- **GEP-3** Filesystem as Source of Truth — goals join the one-file-per-entity model.
- **GEP-7** SQLite as Derived Data — reindex stays a pure read; no goal mutation.
- **GEP-13** Project-prefixed Task IDs — the `mix glorbo.migrate_tasks` precedent
  this migrator mirrors.
- **GEP-6** Phoenix LiveView dashboard — the three readers being unified.
- Finding **F1** (2026-06-13 browser E2E sweep) — the orphaned-`goal/v1` + doc-drift
  discovery that motivated this GEP.
