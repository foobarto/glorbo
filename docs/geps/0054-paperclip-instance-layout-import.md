---
gep: 0054
title: Import the live paperclip-instance on-disk layout
author: Bartosz Ptaszynski <foobarto@gmail.com>
status: Implemented
type: Standards
created: 2026-06-02
requires: [3, 7, 15]
see-also: [18]
history:
  - date: 2026-06-02
    status: Draft
    note: |
      Initial draft. Captures the operator's brainstormed decisions for
      teaching `glorbo import paperclip` the live paperclip-instance
      directory layout (deep, UUID-named, companion files under
      `instructions/`) in addition to the flat git-template layout it
      already handles. Motivated by importing the real "Blade and
      Blaster" company, which the importer silently scaffolded as empty.
  - date: 2026-06-02
    status: Accepted
    note: |
      Approved by the operator after design review. Slug strategy locked
      to "import under UUID dir names, no prose derivation" (D2);
      captured as a short GEP rather than a bare bug fix because it
      changes documented CLI import behaviour.
  - date: 2026-06-02
    status: Accepted
    note: |
      Implemented + codex security review folded in (see D8): destination
      leaf writes hardened against symlink redirection on `--force`; the
      `agents/`-container heuristic disambiguated from a flat agent named
      `agents`; symlinked `<src>` accepted by design. End-to-end verified
      against the live "Blade and Blaster" paperclip company (10 agents
      imported, `reindex` indexed=38 skipped=0).
  - date: 2026-06-02
    status: Accepted
    note: |
      Live import into the real `~/.glorbo` exposed that the PR #38
      destination guard false-positives on `/home -> /var/home` (atomic
      Fedora). Fixed by scoping the guard to at/below the glorbo home
      (D9). Live import succeeded (10 agents); company is DB-visible
      after reindex. The same flaw in the shared SymlinkGuard (reindex /
      sandbox) is logged in docs/todo.md as out-of-scope follow-up.
  - date: 2026-06-03
    status: Implemented
    note: |
      Flipped to Implemented as part of the v0.25.0 cut. A pre-release
      review noted that the D9 narrowing also stops lstat-checking the
      glorbo-home *leaf* itself (only segments strictly below it) — a
      symlinked `~/.glorbo` would be followed. This is a deliberate,
      now-documented trade-off (see D9): exploiting it requires write
      access to the operator's home, at which point files can be written
      directly, so it is not an escalation. Logged in docs/todo.md as an
      optional follow-up (lstat the leaf, refusing only a symlinked final
      component without re-introducing the `/home -> /var/home` ancestor
      false-positive).
---

# GEP-0054: Import the live paperclip-instance on-disk layout

## Problem

`glorbo import paperclip <src>` was written against the flat
`paperclipai/companies:main` git-template layout, where each agent is a
direct child of `<src>` and its contract files sit at the agent-dir
root:

    <src>/<agent-slug>/AGENTS.md   (+ HEARTBEAT.md, SOUL.md, TOOLS.md)

A **running** paperclip install does not look like that. Its on-disk
shape (observed against `~/.paperclip/instances/default` on 2026-06-02)
nests agents one level deeper, names every agent directory by UUID, and
keeps the contract files inside an `instructions/` sub-directory:

    companies/<company-uuid>/
      agents/
        <agent-uuid>/
          instructions/AGENTS.md   (+ HEARTBEAT.md, SOUL.md, TOOLS.md)
          memory/  life/  ...
        _templates/                (scaffolding, not a real agent)

Pointed at this tree, `discover_agents/1` finds zero entries with a
direct `AGENTS.md` and the importer **silently scaffolds an empty
company** — exit 0, "agents: 0", no error. The first real attempt to
import a company ("Blade and Blaster", 9 agents) produced nothing and
gave no signal that the layout was the problem.

## Goals

- Auto-detect both layouts from the same `glorbo import paperclip
  <src>` invocation; no new flag or subcommand.
- Import every agent from a live paperclip company directory, reading
  its contract files from wherever they actually live.
- Keep the flat-template path byte-for-byte unchanged (existing tests
  stay green).
- Preserve every existing supply-chain security guard (C-098 lstat /
  symlink refusals) on the new, deeper paths.
- Make an empty result loud instead of silent.

## Non-goals

- **No human-readable slug derivation.** Agents import under their UUID
  directory names; the Director renames later (D2).
- **No carrying of `memory/`, `life/`, or `state/`.** The importer's
  contract is AGENTS/HEARTBEAT/SOUL/TOOLS only (D5).
- **No reading of paperclip's Postgres DB or HTTP control plane.** The
  importer stays filesystem-only.
- **No new CLI flags or subcommands.** Same surface:
  `glorbo import paperclip <src> [--as <slug>] [--force]`.
- **No write-side convergence on the `agentcompanies/v1` schema.** That
  remains GEP-18's open question; this GEP only reads a vendor layout.

## Design

The change is confined to `Glorbo.CLI.ImportPaperclip`
(`lib/glorbo/cli/import_paperclip.ex`). Four local adjustments:

1. **Agent-container resolution.** Before discovery, resolve the
   directory that holds agent dirs: if `<src>/agents/` is a real
   directory, descend into it (so the Director points at the paperclip
   *company* dir, e.g. `…/companies/<uuid>`); otherwise treat `<src>`
   itself as the container (today's flat behaviour). Entries whose name
   starts with `_` or `.` are skipped (excludes `_templates`).

2. **Per-agent instruction-dir resolution.** For each candidate agent
   dir, resolve where its `AGENTS.md` lives:
   `<dir>/instructions/AGENTS.md` (instance) **or** `<dir>/AGENTS.md`
   (flat). The resolved directory becomes the read root for the
   companion files too. A dir with neither is skipped.

3. **Slug = source dir basename.** Unchanged from today. In the
   instance layout that basename is a UUID, which already satisfies the
   `[a-z0-9-]+` slug guard, so it is used verbatim as
   `agents/<uuid>/`.

4. **Security parity.** The resolved `instructions/` directory and
   every file read from it pass through the existing `real_dir?/1`,
   `real_file?/1`, `read_source_file!/1`, and `ensure_real_dest_dir!/1`
   guards. No guard is relaxed for the deeper path.

The wrap-on-copy logic (`wrap_agent_md/3`, `wrap_companion_md/2`), the
ALLCAPS contract-file names (`AGENT.md`, `HEARTBEAT.md`, `SOUL.md` per
GEP-15), the `kind:` frontmatter discriminators, the audit events, and
the destination-symlink hardening are all reused as-is.

The import report gains one line: if a resolved agent dir carried a
`memory/` or `life/` sub-tree, note that it was **not** carried over
(so the omission is visible, not silent), and if **zero** agents were
imported, say so prominently with the resolved container path.

## Migration / rollout

Pure addition. The flat-template detection branch is unchanged, so
existing imports and the existing test fixtures behave identically.
There is no on-disk migration and, pre-1.0, no compat shim is owed.
The motivating import ("Blade and Blaster" → company `bladeandblaster`)
runs after this lands and is non-destructive: it writes a new company
directory and leaves any existing company (including the unrelated
`bla` test scaffold) untouched, honouring GEP-3's "Glorbo never
modifies `companies/<slug>/` without explicit Director action".

## Failure modes

- **Neither layout matches** → 0 agents. Previously silent; now the
  report states "0 agents imported from `<container>`" so the Director
  knows the path or layout is wrong.
- **Agent dir basename isn't `[a-z0-9-]+`** → that agent is skipped via
  the existing `agent_skipped` audit path (UUIDs always match, so this
  is the flat-layout edge only).
- **Symlinked `instructions/` or `instructions/AGENTS.md` pointing
  outside the source tree** → refused by the lstat guards with a clear
  `:eloop` error, exactly as a symlinked flat `AGENTS.md` is today.

## Test strategy

- **Unit** (`test/glorbo/cli/import_paperclip_test.exs`): a new
  instance-layout fixture — two UUID-named agent dirs with
  `instructions/AGENTS.md` + companions, plus a `_templates` dir that
  must be excluded. Assert: agents imported under their UUID slugs,
  `AGENT.md` written ALLCAPS with Glorbo frontmatter, companions copied
  from `instructions/`, `_templates` skipped, and the existing
  flat-layout assertions still pass unchanged.
- **Security**: a fixture with a symlinked `instructions/AGENTS.md` is
  refused (extends existing C-098 coverage to the deeper path).
- **End-to-end / UAT**: import the real paperclip "Blade and Blaster"
  company into a throwaway `GLORBO_HOME`, run `glorbo reindex`, and
  confirm the company plus all 9 agents surface — verifying the on-disk
  shape this GEP writes is fully absorbed by reindex (GEP-7).

## Open questions

- If UUID rosters prove annoying in practice, a future opt-in
  `--derive-slugs` could parse the `"You are X."` line into a
  human-readable slug. Deferred — UUID-then-rename is sufficient now.
- Whether to carry `memory/` for higher-fidelity migration is left to a
  follow-up GEP if the fleet asks for it.

## Decision log

### D1. Auto-detect the layout instead of adding a `--layout` flag

- **Decided:** sniff the source tree shape (presence of an `agents/`
  sub-dir and of `instructions/AGENTS.md`) and pick the branch
  automatically.
- **Alternatives:** an explicit `--layout instance` flag; a separate
  `import paperclip-instance` subcommand.
- **Why:** the two layouts are structurally distinguishable with no
  ambiguity, so detection is reliable; a flag pushes incidental
  knowledge onto the Director and grows the CLI surface for nothing.

### D2. Import agents under their UUID dir names; no slug derivation

- **Decided:** the agent slug is the source directory basename — a UUID
  in the instance layout — used verbatim.
- **Alternatives:** derive a human-readable slug from the `"You are
  X."` opening line of `AGENTS.md`; require an explicit UUID→name map.
- **Why:** prose parsing is heuristic and fragile, and there is **no
  on-disk metadata** to read from — paperclip keeps display names only
  in its Postgres DB, which this importer deliberately does not touch.
  UUID names are deterministic and collision-free; the Director renames
  a dir with one `mv` + `glorbo reindex`, which GEP-3 explicitly treats
  as a legitimate state change. The honest trade-off is a less readable
  roster until the Director renames.

### D3. Accept the paperclip *company* dir as `<src>`; descend into `agents/`

- **Decided:** if `<src>/agents/` is a real directory, treat it as the
  agent container; otherwise treat `<src>` itself as the container.
- **Alternatives:** require the Director to point at `agents/`
  directly; require instance-root + company-UUID arguments.
- **Why:** pointing at `…/companies/<uuid>` is the natural mental model
  and a single path; descending exactly one known level is unambiguous
  and keeps the flat-layout call site working with no special case.

### D4. Resolve AGENTS.md and companions from one per-agent "instruction dir"

- **Decided:** for each agent dir, find `AGENTS.md` at
  `<dir>/instructions/AGENTS.md` or `<dir>/AGENTS.md`, and read the
  companion files from that same resolved directory.
- **Alternatives:** hardcode `instructions/`; search recursively for
  any `AGENTS.md`.
- **Why:** a single resolved dir covers both layouts with no recursion.
  Recursion risks importing an unrelated nested `AGENTS.md` (e.g. under
  `memory/`) as if it were the agent's contract.

### D5. Don't carry `memory/`, `life/`, `state/`; surface the omission

- **Decided:** import only the AGENTS/HEARTBEAT/SOUL/TOOLS contract
  files, matching the importer's existing promise, and add a report
  line when `memory/`/`life/` were present but not carried.
- **Alternatives:** copy `memory/` verbatim; copy the whole agent
  sub-tree.
- **Why:** paperclip's memory format is not a Glorbo contract, and
  Glorbo agents reconstruct working memory from their own
  inbox/outbox + memory conventions. Silently dropping the dirs would
  mislead, hence the explicit report line. Carrying them is a clean
  follow-up if the fleet wants it (YAGNI now).

### D6. Preserve every security guard on the deeper paths

- **Decided:** the resolved `instructions/` dir and its files go
  through the same lstat/symlink guards used for the flat layout; no
  guard is relaxed because a parent was already checked.
- **Alternatives:** trust the deeper path once the agent dir lstat'd
  clean.
- **Why:** a paperclip tree is operator-supplied but may be
  attacker-authored (the C-098 supply-chain threat the importer already
  defends against). The deeper layout is exactly where a symlinked
  `instructions/AGENTS.md → ~/.glorbo/config.md` could hide a secret
  exfiltration.

### D7. Exclude `_`- and `.`-prefixed source entries

- **Decided:** skip directories whose basename starts with `_` or `.`
  (e.g. `_templates`).
- **Alternatives:** rely on "no AGENTS.md found" to skip them
  implicitly.
- **Why:** explicit exclusion is clearer and prevents importing a
  scaffolding bundle (`_templates/base-bundle`) as a live agent if the
  resolver ever reaches one whose `AGENTS.md` placement happens to
  match.

### D8. Harden destination leaf writes; bound the `agents/` heuristic

- **Decided:** (a) all destination file writes (`AGENT.md`, companions,
  `company.md`) go through a `safe_write!/2` that refuses to write
  through a pre-existing symlink / non-regular file (regular files are
  still overwritten on `--force`); (b) `<src>/agents/` is treated as the
  instance container only when it is not itself a flat agent (no direct
  `AGENTS.md`); (c) a symlinked `<src>` typed by the operator is
  followed as operator intent.
- **Alternatives:** (a) keep plain `File.write!` (PR #38 only guarded
  the dest *directories*); (b) treat any real `agents/` as a container;
  (c) refuse a symlinked `<src>`.
- **Why:** surfaced by a codex security review. (a) D6 promises every
  guard holds on the deeper paths — leaving the leaf writes
  symlink-followable made that false (a planted `agents/<a>/AGENT.md`
  symlink would redirect a `--force` write outside the company tree).
  (b) removes a misclassification where a flat agent named `agents`
  would shadow its siblings. (c) the C-098 threat is untrusted *content
  within* the tree (still lstat-guarded per entry), not the path the
  operator explicitly named; refusing a symlinked `<src>` would break
  legitimate setups (e.g. `~/paperclip` being a symlink).

### D9. Scope the destination guard to at/below the glorbo home

- **Decided:** `ensure_real_dest_dir!` walks and lstat-checks only the
  path segments at or below the glorbo home (the trust boundary), not
  the OS ancestors above it. Paths outside the home are refused
  fail-closed.
- **Alternatives:** keep walking from `/` (PR #38's shape); canonicalise
  the home via realpath before walking.
- **Why:** discovered during the live "Blade and Blaster" import. The
  PR #38 guard walked from `/` and refused any symlinked ancestor —
  which false-positives on `/home → /var/home`, the standard layout on
  atomic Fedora (Silverblue/Bazzite/Kinoite), making `glorbo import
  paperclip ~/.glorbo` hard-fail. The threat model is a symlink planted
  *inside* the glorbo home (still lstat-guarded per segment); OS dirs
  above the home are operator-owned and may legitimately be symlinks.
  Realpath-canonicalising the base was rejected as more invasive and
  unnecessary once the trust boundary is drawn at the home.

  Known narrowing: the walk now starts *at* the home leaf and only
  lstat-checks segments strictly below it, so the home leaf itself
  (e.g. a symlinked `~/.glorbo`) is no longer checked (it was, under
  PR #38's walk-from-`/`). This is an accepted trade-off — a symlinked
  config root implies the operator's home is already attacker-writable,
  at which point the import guard is moot. An optional hardening (lstat
  only the leaf, refusing a symlinked final component without re-walking
  the OS ancestors) is tracked in docs/todo.md.

  Note: the shared `Glorbo.Sandbox.SymlinkGuard` used by `reindex`,
  `company_boot`, and the sandbox mappers has the *same* walk-from-`/`
  false-positive against `/home → /var/home`. That is out of scope here
  (load-bearing security code, GEP-5) and tracked in `docs/todo.md`;
  glorbo currently sidesteps it by running against the canonical
  `/var/home/...` path.

## Related

- GEP-18 — agentcompanies/v1 interop placeholder; this GEP is the first
  concrete step in the paperclip-interop space it opened (read-side
  only).
- GEP-3 — Filesystem as Source of Truth; the importer writes new files
  and never mutates existing company data.
- GEP-7 — SQLite as Derived Data; the imported on-disk shape must be
  fully reconstructable by `glorbo reindex`.
- GEP-15 — ALLCAPS convention; wrapped contract files are written
  `AGENT.md` / `HEARTBEAT.md` / `SOUL.md`.
- `lib/glorbo/cli/import_paperclip.ex` — the module changed by this GEP.
