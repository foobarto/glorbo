# 2026-06-13 — GEP-0063: goals as `goal/v1` files (file-canonical)

Implementing [GEP-0063](../geps/0063-goals-as-files-canonical.md) (Accepted).
Make `goals/<id>.md` the single canonical goal store; collapse the three
drifting `normalize_goal/1` readers into one hardened `Goals.list/1`; wire
`progress:` (explicit-wins-else-derive); atomic pre-1.0 cut of `company.md
goals:`.

## Task picked

`/clear` → "implement GEP-0063". On branch `gep/0063-goals-file-canonical`.

## Design calls I made without you

- **Form-field vocabulary follows D1 all the way.** D1 ("one identifier name,
  no two ways to identify a resource") drove me to rename the add-goal form
  fields too, not just the loader output: `goal[slug]` → `goal[id]`,
  `goal[title]` → `goal[name]` (matching the `goal/v1` frontmatter field names
  `id`/`name`). The form now collects exactly the file's frontmatter keys.
  Loader-output map keeps `title:` (a *display* field derived from `name ||
  id`) since that's a label, not an identifier — `title` vs `name` is not the
  `id`↔`slug` dual-naming D1 rejected.
- **`add_goal` error atoms renamed** `:slug_*`/`:title_*` → `:id_*`/`:name_*`
  (only consumer is GoalsLive's `goal_error_message/1`).
- **`add_goal/3` now takes the company *dir*** (was `company.md` path) and
  writes `goals/<id>.md` via `Formatter.format_content` + the existing atomic
  tmp+rename inside the HomeHistory Tx; uniqueness = `File.exists?`.
- **`progress` is loader-validated, not schema-validated.** The Validator has
  no numeric-range primitive (only enums/patterns/byte-caps); per the GEP's
  resolved note the loader is the authority — `safe_progress/1` accepts an
  integer in `0..100`, everything else → `nil` (derive). No new kind-specific
  validator clause (kept surgical; GoalMd `patterns` stays `%{}`).
- **Explicit-progress + zero-tasks** shows the bar with just `N%` (the
  `done/total` ratio prefix is `:if={task_count > 0}`), so an overridden goal
  with no linked tasks still renders a meaningful bar.

## What shipped

All 13 GEP touchpoints. `Glorbo.Company.Goals` rewritten: `list/1` (single
hardened loader the 3 LiveViews call) + `add_goal/3` (writes `goals/<id>.md`).
`GoalMd` +`:description`; `CompanyMd` −`:goals`. Three `normalize_goal/1`
readers collapsed. `progress:` wired (explicit-wins-else-derive). Form fields
`slug`/`title` → `id`/`name`. Docs regenerated + maximal-valid golden fixture.
GEP flipped Accepted → Implemented.

## Gates

- `mix precommit` — **green** (3265 passed, 45 excluded; compile-warnings-as-
  errors, format, docs-file-formats `--check`, full suite).
- `mix credo --strict` — **0 issues** (exit 0), incl. the custom
  `RawFilesystemWriteInLive` check (LiveView writes still route through the
  domain `Goals.add_goal`).
- `mix sobelow --exit` — **clean** (exit 0).
- Multi-agent adversarial review (4 dimensions × per-finding verify): 6
  confirmed findings, 3 refuted. **All 6 addressed:**
  - *(correctness)* Loader now requires `kind: goal/v1` — a scratch note (no
    frontmatter) or a misfiled `task/v1` in the agent-writable `goals/` dir no
    longer renders a phantom goal card. (Was a real regression vs the old
    `goals:`-list reader.)
  - *(security)* Loader filename gate tightened from `Slug.valid?` (loose) to
    the writer's strict `@id_regex` — `goals/123.md`, `-evil.md`, 500-char
    names no longer surface cards the form couldn't create. Loader + writer +
    `GoalMd` spec now agree on one id shape.
  - *(security, nit)* `@id_regex` switched `^…$` → `\A…\z` (kills the
    latent trailing-newline footgun).
  - *(test)* Added the `goal.create` HomeHistory round-trip test (real git
    versioning), the oversized-file silent-skip test, and the kind-gate /
    strict-slug-filename tests.
  - *(test/scope)* Overview deliberately keeps its task-rollup aggregate
    (explicit `progress:` is scoped to the per-goal *bars* on CompanyLive +
    GoalsLive per Design §"Progress source-of-truth" + touchpoint #6) — added
    a lock-in test pinning that explicit progress does NOT move the overview
    number. **Flagged for review below.**
  - Refuted (correctly): a traversal "finding" (no escape), a File.exists?
    symlink-squat (premise wrong), a scaffold help-text claim (factually
    wrong).

## Things I'd like your review

- **`uat.md` not committed.** It had pre-existing changes from the prior
  2026-06-13 web-UI-UAT sweep (77 of 81 added lines), so I left it out of the
  GEP-0063 commit rather than sweep that in. My 4-line K1/K1b doc update rides
  along in the working tree — fold it into the UAT-sweep commit when that lands.
- **`CLAUDE.md` invariant is local-only.** That file is gitignored
  (`/CLAUDE.md`), so the GEP's "update CLAUDE.md" touchpoint can't ship; the
  tracked canonical invariant is the new line in `docs/DESIGN.md`. Flag if you
  want CLAUDE.md un-gitignored.
- **Overview aggregate ignores explicit `progress:`** by design (GEP says
  "summary math unchanged") — the /companies card's % is still
  done-tasks/total-tasks across goals. Per-goal bars (Goals + Company views)
  honour explicit progress. Confirm that split is what you want.
