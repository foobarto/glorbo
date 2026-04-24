# Ship checklist (phase 6)

Phase 6 of the [six-phase checklist](six-phase-checklist.md) —
after commit + push, walk this list and update every
artefact the change touched.

"Ship" is not done until the docs that lie about the code
have been updated. Stale docs compound into technical debt
fast.

## Docs to check on every ship

Not all apply to every change. Skim, apply what fits, move
on.

| Artefact | Update when |
|---|---|
| `CHANGELOG.md` | Every shipping change. `[Unreleased]` section grows; rolls into the versioned section at release time. |
| `README.md` | User-facing pitch, install story, feature list changed. |
| `docs/DESIGN.md` | Architecture, invariants, or tech stack changed. |
| `docs/architecture.md` | Module map changes (new subsystem, new god node, new invariant). |
| `docs/knowledge-graph/GRAPH_REPORT.md` | Any module added / renamed / deleted. Regen via: `graphify update lib && mv lib/graphify-out/GRAPH_REPORT.md docs/knowledge-graph/ && rm -rf lib/graphify-out`. |
| `docs/knowledge-graph/notes.md` | Session uncovered a gotcha, graph false-positive, load-bearing invariant, or surprising call chain. Append a short dated entry. |
| `docs/geps/NNNN-*.md` | GEP's implementation landed — flip status `Accepted → Implemented`, add `implemented-in: vX.Y.Z`. |
| `docs/todo.md` | Cross off the item this change addressed, or move between priority tiers. |
| `docs/testing/uat.md` | Change added a UI surface that needs manual UAT coverage. |
| `docs/project-profile.md` | Cross-cutting stance settled or refined. |
| `CLAUDE.md` | Project-specific guidance changed (commands, invariants, conventions). |

## Commit hygiene

- Conventional-commit subject (`feat(scope):`, `fix(security):`,
  `docs(session):`, etc.).
- Body explains *why* when non-obvious. Reference GEP
  numbers, session-log dates, issue numbers where relevant.
- One concern per commit; bundled commits get hard to
  review + hard to revert.

## When to also run the pre-release gate

Phase 6 runs on every feature ship. The
[`release-gate.md`](release-gate.md) runs only at version
cuts (tag + GH release). Both exist so that small ships
don't slow down on release-only mechanics, but release-time
catches anything the per-feature ship missed.
