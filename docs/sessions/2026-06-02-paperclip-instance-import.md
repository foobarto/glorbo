# Session — 2026-06-02 — paperclip instance-layout import

Goal for the session: import the paperclip "BLA" (Blade and Blaster)
company into Glorbo.

## Task — teach `glorbo import paperclip` the live-instance layout (GEP-54)

**Task picked.** "Import paperclip BLA company to glorbo." Investigation
showed the existing `glorbo import paperclip` importer
(`lib/glorbo/cli/import_paperclip.ex`) only handles the flat
`paperclipai/companies:main` git-template layout
(`<src>/<slug>/AGENTS.md`). A *running* paperclip install nests agents
deeper: `companies/<uuid>/agents/<uuid>/instructions/AGENTS.md`, with
UUID-named agent dirs and companion files inside `instructions/`.
Pointed at the live tree the importer silently scaffolds an **empty**
company (exit 0, "agents: 0"). So a raw import would not work.

"BLA" = **Blade and Blaster**, a progression-fantasy publishing company
living at `~/.paperclip/instances/default/companies/fd740b88…`, 9
agents: CEO, CMO, CTO, Head of People Ops, Riven March (writer),
SpecFicWriter, AudioOps, CritiqueOps, UXDesigner.

**Design calls I made without you (then confirmed via questions).**
- Surfaced the layout mismatch + the slug collision (a hand-made `bla`
  test scaffold already exists in `~/.glorbo/companies/`) before
  touching anything.
- You chose: **fix the importer** (not stage-and-import); **keep UUID
  agent slugs** (no prose-derived names — Director renames later);
  import as a **new `bladeandblaster` company**, leaving `bla`
  untouched; capture as a **short GEP**.

**What shipped (so far — Spec/Plan phases).**
- `docs/geps/0054-paperclip-instance-layout-import.md` — Standards GEP,
  status **Accepted**, 7-entry decision log. Auto-detect layout, UUID
  slugs, security parity on deeper paths, don't carry `memory/`/`life/`.
- Linked GEP-18 (agentcompanies/v1 interop placeholder) via
  `extended-by: [54]` + history note. GEP-54 carries `see-also: [18]`,
  `requires: [3, 7, 15]`.
- README GEP index: added GEP-0054 row **and** GEP-0053 (the latter was
  already missing from the index — drift from the prior session).

**Gates.**
- `mix gep.validate` → **All checks passed** (after the README fix).

**Skipped / not done (this entry).**
- Build/test/review/ship phases — next.
- Carrying paperclip `memory/`/`life/` dirs — explicit non-goal (GEP-54
  D5); flagged in the import report instead of silently dropped.

**Commit(s).** Pending — will commit GEP + README together, then code +
tests separately.

## Things I'd like your review

- (deferred to end of task)
