---
date: "2026-04-16"
promoted: false
---

# Retrofit-friendly GSD workflow for multi-contributor projects

## Problem

GSD's flagship loop is **plan → execute → verify → audit**, with numbered
phases living under `.planning/phases/NN-name/` and milestones in
`.planning/milestones/vX.Y-*`. That's a great fit for a solo dev (or a team
that's all-in on GSD) producing a coherent release cadence. It breaks down
when:

1. **Work arrives ad-hoc** — experiments, spikes, bug fixes, doc tweaks,
   dependency bumps. None of these want the discuss→research→plan ceremony.
2. **Outside PRs land** — GitHub contributors won't number their work into
   phase NN, won't write PLAN.md, may conflict with the next scheduled
   phase's number or milestone bucket.
3. **Implementation drifts ahead of planning** — you implement, then realise
   it should be captured. Today this means hand-writing PLAN.md to match
   already-shipped code. The "goal-backward" rigor is theatre at that point.
4. **Milestone versioning is rigid** — phases belong to exactly one
   milestone, numbered sequentially. An outside PR that implements something
   you'd have scoped into v0.0.3 Phase 2 doesn't slot cleanly anywhere.

## Observation: GSD's value is non-uniform

Not every part of GSD earns its cost on every change. Cost/value per
subsystem, rough take:

| Subsystem                         | Cost to use | Value    | Fit for PR-style work |
|-----------------------------------|-------------|----------|-----------------------|
| `/gsd-discuss-phase`              | medium      | high     | poor (ceremony)       |
| `/gsd-research-phase`             | medium/high | high     | poor (ceremony)       |
| `/gsd-plan-phase`                 | medium      | high     | poor (ceremony)       |
| `/gsd-execute-phase`              | high        | medium   | poor (phase-bound)    |
| `/gsd-verify-work`                | low         | **high** | **good**              |
| `/gsd-code-review`                | low         | **high** | **good**              |
| `/gsd-secure-phase`               | low         | high     | medium                |
| `/gsd-audit-milestone`            | low         | **high** | **good**              |
| `/gsd-map-codebase`, `gsd-intel`  | low         | high     | **good**              |
| `/gsd-cleanup`, `/gsd-complete-milestone` | low | medium   | good (housekeeping)   |

The **audit/review side** (verify, code-review, audit-milestone, map) is
cheap to run on any change and doesn't care whether planning preceded
implementation. The **planning side** (discuss/research/plan) is where the
ceremony cost lives and where it misfits ad-hoc or external work.

## Proposed workflow shape

### Tier 1 — Freeform (default)

Most work. Implement directly (manual, Claude Code, other AI, outside PRs).
No phase dirs. Commit atomically as you go. When the change is non-trivial,
run `/gsd-code-review` before merge. This is how ~70% of commits should feel.

### Tier 2 — Retrofitted (after the fact)

For work that ended up bigger than Tier 1 expected. After it ships:

1. `/gsd-map-codebase` or `/gsd-intel --refresh` to pick up the new surface.
2. Light "retrofit phase" drop-in: a phase dir with short `PLAN.md` +
   `REQUIREMENTS.md` describing **what shipped** and the UAT criteria you'd
   want to hold it to. Mark `retrofitted: true` in frontmatter.
3. `/gsd-verify-work`, `/gsd-code-review`, `/gsd-secure-phase` as audit
   gates.

A new `/gsd-retrofit-milestone` (or `/gsd-retrofit-phase`) command would
automate this: read git log since last tag, cluster commits into coherent
phases, scaffold the phase dirs with retrofit frontmatter, prompt the user
to fill in intent + UAT. Today you'd do it manually.

### Tier 3 — Full GSD (for big, deliberate work)

Reserved for milestones that justify the ceremony: v1.0 readiness, a major
refactor, a security-sensitive subsystem. Use the full
`/gsd-new-milestone → /gsd-plan-phase → /gsd-execute-phase` chain.

**Ratio guess:** 70% Tier 1, 20% Tier 2, 10% Tier 3.

## Handling outside PRs

External PRs are always Tier 1 from the contributor's perspective. Don't
ask them to number phases or write plans. The repo's side:

- `CONTRIBUTING.md` stays GSD-optional: "feel free to open a PR; we'll run
  audits on our end." No phase numbering requirement on contributors.
- CI runs the cheap audit gates on every PR: `/gsd-code-review`,
  `/gsd-secure-phase`-equivalent static checks, lint/test.
- On merge, the maintainer decides whether the PR graduates to Tier 2
  (retrofitted phase) or stays uncatalogued. Doc-only tweaks, dep bumps,
  obvious bug fixes stay uncatalogued forever and that's fine.
- Milestone audit at release time (`/gsd-audit-milestone`) covers the
  retrofitted phases plus whatever's uncatalogued but present in git log.
  Audit can flag "N commits on this release aren't catalogued — promote?"

## Versioning without phase collisions

- **Phases aren't numbered globally.** Drop sequential phase numbers for
  Tier 2 retrofits — use date-or-slug identifiers
  (`.planning/phases/2026-04-16-cli-autodetect/`). Numbering is a
  coordination tax that doesn't pay off once work is parallel.
- **Milestone = version**, not phase count. A milestone contains whatever
  phases (catalogued or retrofitted) landed in that semver window.
- Tier 3 work can still use `01-foo` etc. within its milestone if the
  sequential ordering matters there, but that's a local convention not a
  repo-wide one.

## What needs to change in GSD (or in your fork of it)

**New commands (would help):**

- `/gsd-retrofit-phase <slug>` — scaffold a phase dir from recent git
  history, prompt for intent/UAT.
- `/gsd-retrofit-milestone` — same, for a range of commits since the
  last tag. Clusters into phases, pre-fills from commit messages.
- `/gsd-tier <level>` on a phase dir — marks it Tier 1/2/3 in frontmatter
  so audit commands know what rigor to apply.

**Adjustments (nice to have):**

- `/gsd-audit-milestone` recognising retrofitted frontmatter and reporting
  "catalogued vs retrofitted vs uncatalogued commit" ratios.
- Non-numeric phase slug support throughout (some scripts currently assume
  `NN-name`).
- `/gsd-import --prd` or `--pr` mode for ingesting a GitHub PR description
  as the phase intent when retrofitting.

**Use today without changes:**

- The Tier 2 flow works manually right now. You write the phase dir,
  audit commands run against it. That's enough to validate the shape
  before investing in new GSD commands.

## Next step

Try Tier 2 on the next ad-hoc piece of work that ends up bigger than a
Tier 1 change (maybe the CLI auto-detect feature if it grows). Time the
retrofit step honestly. If it takes <15 min to backfill a phase dir,
this workflow is viable. If it takes an hour, GSD needs the new commands
before it's practical.

## Related notes

- `.planning/notes/2026-04-16-gsd-plan-only-workflow.md` — decoupling
  planning from implementation (same direction, different angle).
