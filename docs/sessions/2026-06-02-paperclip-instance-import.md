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

**Build / Test (TDD).** Confined to `Glorbo.CLI.ImportPaperclip` +
its test. RED→GREEN: layout auto-detect (`agent_container/1` descends
into `agents/` unless it's itself a flat agent; `resolve_instr_dir/1`
finds AGENTS.md in `instructions/` or the dir root), UUID slugs,
`_`/`.`-entry exclusion, memory/life report note, loud zero-agent
report. 21 importer tests; full suite **3015, 0 failures**; credo
`--strict` exit 0; `mix gep.validate` clean.

**Review (codex) — 3 findings, all handled.**
- HIGH: dest leaf writes used plain `File.write!` (PR #38 guarded only
  dirs) → added `safe_write!/2` refusing writes through a symlink on
  `--force`. Fixed + regression test.
- LOW: any real `agents/` treated as instance container → disambiguate
  (only descend if `agents/` isn't itself a flat agent). Fixed + test.
- MED: symlinked `<src>` followed → accepted by design (operator-typed
  path; intra-tree content still lstat-guarded). Documented.

**Live import — found a real environment bug.** First live import into
`~/.glorbo` hard-failed: the importer's PR #38 dest guard walks from `/`
and refuses `/home` because `/home → /var/home` (atomic Fedora). Fixed
by scoping the guard to at/below the glorbo home (GEP-54 **D9**) + 2
regression tests. Re-ran: **10 agents** imported into
`companies/bladeandblaster/`, `bla` scaffold + all other companies
intact. `reindex` (canonical path) **indexed=124 skipped=0**; DB shows
`bladeandblaster` + 10 agents.

**Design calls I made without you (build phase).**
- Closed the codex HIGH + LOW + the D9 dest-guard bug autonomously
  (clear security/hygiene fixes blocking the deliverable).
- Left the **shared** `SymlinkGuard` `/home`-symlink bug (reindex /
  sandbox / company_boot) **unfixed** — load-bearing security (GEP-5),
  out of scope; logged in `docs/todo.md` P1 as likely-needs-a-GEP.

**Gates.** precommit (3015 tests, 0 failures), credo exit 0,
gep.validate clean.

**Skipped / not done.**
- Carrying paperclip `memory/`/`life/` — explicit non-goal (D5);
  flagged in the report.
- Systemic `SymlinkGuard` fix — out of scope (see todo P1).

**Commit(s).** `8170aaa` (feature + GEP + docs); guard-fix +
doc-updates commit follows.

## Things I'd like your review

1. **Systemic `/home → /var/home` SymlinkGuard bug** — reindex/sandbox
   reject every file when run against the default `~/.glorbo` on atomic
   Fedora. Want me to open a GEP + fix it next (scope the shared guard
   to at/below the home, mirroring GEP-54 D9)? It currently only works
   via the canonical `/var/home` path. **(yes/no)**
2. **UUID agent dir names in `bladeandblaster`** — as you chose. Want me
   to rename them to human slugs (ceo, cmo, riven-march, …) now via
   `mv` + reindex, or leave that to you? **(rename / leave)**
3. **Push GEP-54 + the fix to remote?** Committed locally only, per your
   default. **(push / hold)**
