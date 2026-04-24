# Pre-version release gate

Before every version cut (`mix.exs` bump + `git tag`), execute
this gate end-to-end. **No shortcuts; no silent deferrals.**

## The six steps

1. **Doc-drift pass** — read CHANGELOG, README, DESIGN,
   architecture.md, moduledocs on changed modules. Update
   anything stale. Stale docs that mislead new contributors
   are a P0 smell per [`docs/project-profile.md`](../project-profile.md).

2. **Graphify refresh** — run:

   ```sh
   graphify update lib
   mv lib/graphify-out/GRAPH_REPORT.md docs/knowledge-graph/
   rm -rf lib/graphify-out
   ```

   Append tacit-knowledge entries to
   [`docs/knowledge-graph/notes.md`](../knowledge-graph/notes.md)
   for anything surprising in the diff.

3. **`mix test`** — all green; integration-tag tests if the
   change touches that surface. Credo: `mix credo --strict`
   with `echo $?` checked explicitly (Credo doesn't exit
   non-zero on refactor warnings per past incident).

4. **E2E UAT** — walk [`docs/testing/uat.md`](../testing/uat.md)
   in a real browser. Green the cases that pass; note
   breakages. Shipping with broken UAT items requires an
   explicit deferral in the CHANGELOG.

5. **Security review** — review the open rows in
   [`docs/testing/threatmodel.md`](../testing/threatmodel.md).
   Every finding gets closed or explicitly deferred with
   rationale inline in that file. **Unresolved security
   findings past a version cut are P0.** If upstream fix
   isn't available, implement mitigation in our own code
   (extra filtering/checks, wrapping the vulnerable
   dependency's call sites) and document the mitigation in
   the threatmodel row.

6. **Release flow** — tag → signed GitHub Release + Burrito
   binaries + Homebrew tap formula regen. Full recipe at
   [`docs/releasing.md`](../releasing.md).

## Why this gate exists

Shortcuts caught during the gate are the whole point — the
gate exists because we know cutting versions is when they
surface. Walking it in order, top-to-bottom, keeps the
shipping story honest.

## Related

- [`docs/project-profile.md`](../project-profile.md) —
  defines the P0 criteria this gate enforces.
- [`six-phase-checklist.md`](six-phase-checklist.md) — phase
  6 (Ship) feeds into this gate at release time; phase
  5 (Review) has already run per-feature.
- [`ship-checklist.md`](ship-checklist.md) — the per-feature
  doc-update list that runs during phase 6 on every ship,
  not just at version cuts.
- [`docs/releasing.md`](../releasing.md) — concrete release
  mechanics (tagging, signing, tap publish).
