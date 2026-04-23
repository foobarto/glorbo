---
gep: 0026
title: Benchmark company templates and provider A/B comparison
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-21
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft — cross-provider A/B benchmarking. Phase-A (templates) to ship with this GEP; Phase-B (UI scoring) tracked as D9 follow-up.
  - date: 2026-04-23
    status: Draft
    note: |
      Phase A is on `main` — `priv/templates/companies/{bench-softdev,
      bench-tech-blog,bench-scifi-publisher}/`, `glorbo new company
      --template`, `glorbo bench list`, and `Glorbo.CLI.Bench` dispatcher.
      Phase B (side-by-side dispatch + blind scoring UI +
      `benchmarks/runs/<id>/scores.md` persistence) is queued; the stub
      message in `glorbo bench run` stays in place until the Live view
      ships.
requires: [2, 4, 8, 10, 25]
see-also: [16, 18, 19, 20]
---

# GEP-26: Benchmark company templates and provider A/B comparison

## Problem

Glorbo can already scaffold a company, wire up agents to a chosen
provider, and route tasks through dispatch — but there is **no
repeatable way to compare how different providers do the same work**.
A director evaluating claude-sonnet vs gemini-pro vs opencode-qwen
currently has to:

1. Hand-author three companies with near-identical `AGENT.md`s (drift
   is inevitable — one will accidentally differ in permissions or
   skills).
2. Paste the same task body three times.
3. Eyeball three audit logs to compare outputs — no side-by-side, no
   blind scoring, and source inputs differ across runs (web search
   doesn't return the same results twice).

Two concrete consequences:

- **No fair comparison.** If two agents produced different outputs
  because they pulled different web search results in the same
  minute, the ranking is noise, not signal.
- **No reusable fixture.** A bench run for "accounting agent
  reconciling a CSV" should be the same bench run next month on a
  new provider — today it's a one-shot.

This GEP addresses both: **benchmark company templates** with fully
static inputs, and **cross-provider A/B comparison UI** that
dispatches one task to N providers and lets the director score
outputs blind.

## Goals

- **Repeatable bench fixtures.** A named template (e.g.
  `bench-softdev`) scaffolds a company where every input an agent
  might consult is a static file committed to
  `priv/templates/companies/<name>/fixtures/`. No live web calls for
  source material; no dates "now"; nothing that shifts between
  runs.
- **Multiple archetypes shipped.** Three reference templates at
  minimum:
    * `bench-softdev` — software engineering (engineer + reviewer
      agents, a small codebase in `fixtures/repo/` as input, tasks
      to fix bugs / add features).
    * `bench-tech-blog` — technical blog author (researcher + editor
      agents, `fixtures/news/*.md` as "sources", tasks to draft posts
      based on the stash).
    * `bench-scifi-publisher` — creative writing agency
      (worldbuilder + writer agents, `fixtures/canon/*.md` as the
      canon bible, tasks to draft chapters that respect canon).
  Each template carries agents + projects + tasks, **including at
  least one task already "in progress"** so the dashboard shows a
  realistic workspace after init (not a blank kanban).
- **Provider-swappable per task.** Each template's agents use
  `provider: ${BENCH_PROVIDER}` (or similar templating variable) so
  one scaffold instance pins to one provider; to compare N providers
  the director scaffolds N copies with different `BENCH_PROVIDER`
  settings.
- **Phase-B: side-by-side dispatch + blind scoring.** A bench run
  records `{task, [providers_tried]}`, dispatches the task to every
  provider at once under a fresh company per provider, collects
  outputs to a single comparison artefact, and renders them
  un-attributed in the UI for the director to rank. Scores persist
  under `benchmarks/runs/<run-id>/scores.md` for later aggregation.

## Non-goals

- **Not a benchmarking *platform*.** Glorbo isn't trying to become
  HELM, lm-eval-harness, or BenchBench. Outputs stay in the
  filesystem; there is no centralised leaderboard, no cloud sync, no
  standardised score rubric beyond "director preference."
- **Not auto-scoring.** The scoring is explicitly human-in-the-loop
  (blind A/B). Future GEPs can propose LLM-as-judge layers on top of
  the stored outputs, but this GEP commits to *director-driven*
  scoring.
- **No synthetic test fixtures for CI.** Bench templates are for
  directors to run locally or in pairwise A/B. Template correctness
  has unit tests, but we aren't wiring benches into CI.
- **No cross-session history beyond the filesystem.** Runs are
  durable markdown + JSONL under `benchmarks/` — not a separate
  SQLite table, not a sync'd "benchmark history" service.
- **No model-version pinning enforcement.** If the director edits an
  agent's `model:` between runs, that is their mistake to catch (the
  `benchmarks/runs/<run-id>/manifest.md` records provider+model so
  audit trail is preserved, but we don't freeze or error out).

## Design

### Layer 1 — company templates (Phase A, ships with GEP)

A company template is a directory under
`priv/templates/companies/<template-name>/` with this shape:

```
priv/templates/companies/bench-softdev/
├── template.md           # manifest (kind: company-template/v1)
├── company.md            # {{ slug }}/{{ provider }} placeholders
├── agents/
│   ├── engineer/
│   │   ├── AGENT.md
│   │   ├── HEARTBEAT.md
│   │   └── SOUL.md
│   └── reviewer/
│       ├── AGENT.md
│       ├── HEARTBEAT.md
│       └── SOUL.md
├── projects/
│   └── bugs/
│       └── project.md
├── tasks/                # one per file, mapped to <project>/tasks/
│   ├── bugs-1-fix-login-timeout.md   (status: todo)
│   ├── bugs-2-add-dark-mode.md       (status: in-progress)
│   └── bugs-3-migrate-sqlite-3.md    (status: todo)
├── fixtures/             # bind-mounted read-only at runtime
│   ├── repo/             # mini codebase for bugs-1..3 to work against
│   │   ├── mix.exs
│   │   ├── lib/auth.ex
│   │   └── ...
│   └── README.md         # what's in here + why
└── MEMORY.md             # empty; director populates over time
```

Every file in the template carries GEP-25 `kind:` frontmatter. The
**manifest** (`template.md`) declares:

```yaml
---
kind: company-template/v1
name: bench-softdev
version: 1
description: Software-dev bench company — engineer + reviewer agents
              working on a static mini-codebase.
archetype: software-development
default_provider: claude-code
default_model: claude-sonnet-4-5
fixtures_dir: fixtures
network: proxy                     # every agent in this company
                                      # gets this default; agents can
                                      # narrow via their own `network:`
required_skills: []                   # optional declared skills
tags: [benchmark, software, engineering]
---

# Benchmark — Software Development

This template scaffolds a small engineering shop. Use it to compare
how different providers handle bug-fix and feature-add tasks against
an identical static codebase.
```

**Static-inputs invariant.** Fixtures are the *only* authorised input
source for source material. Agents can `WebFetch` documentation
(e.g. language docs, library refs), but MUST NOT fetch the dataset
they are reasoning over. Enforced softly: the template's `AGENT.md`
permissions whitelist specific hosts via GEP-23 egress allowlists
(`allowed_hosts: [docs.python.org, elixir-lang.org, ...]`); the
fixture directory is bind-mounted RO into the sandbox, the rest of
the workspace has the agent's normal mount policy.

**Pre-populated in-progress task.** Each template has ≥1 task in
`status: in-progress`, so on first open the kanban doesn't look
empty. Those tasks also have short seeded comments
(`## <ts> | engineer`) so the task timeline has content — a bench
run resumes a realistic mid-stream workspace, not a blank one.

### CLI surface

Extends existing `glorbo new company`:

```
glorbo new company <slug>                                # unchanged
glorbo new company <slug> --template bench-softdev       # new
glorbo new company <slug> --template bench-softdev \
    --provider codex --model gpt-4o                      # new
glorbo bench list                                         # lists
                                                          # templates
```

`glorbo bench list` enumerates `priv/templates/companies/*.md`
manifests and prints name/archetype/description. (Note: under GEP-10
there's already a template mechanism for *agents*, but it's 1:1 —
one file → one agent. Company templates are 1:many and need a
different scaffolder; D3.)

### Layer 2 — bench runs + A/B dispatch (Phase B, follow-up)

A **bench run** dispatches one task to N providers in parallel. On
disk:

```
~/.glorbo/benchmarks/
├── runs/
│   └── 2026-04-21T1430Z-bench-001/
│       ├── manifest.md         (kind: benchmark-run/v1)
│       ├── task.md             (the task body — copy of the
│                                 template task, frozen)
│       ├── providers/
│       │   ├── claude-code/
│       │   │   ├── output.md   (final reply)
│       │   │   └── runlog.md   (stdout + timings)
│       │   ├── codex/
│       │   └── gemini-cli/
│       └── scores.md           (director-entered; blind ranking +
│                                 free-text rationale)
```

`manifest.md` frontmatter:

```yaml
---
kind: benchmark-run/v1
run_id: 2026-04-21T1430Z-bench-001
template: bench-softdev
task: bugs-1-fix-login-timeout
providers: [claude-code, codex, gemini-cli]
started_at: 2026-04-21T14:30:00Z
completed_at: 2026-04-21T14:37:12Z
status: scored
---
```

Dispatch: `glorbo bench run <template> <task-id> --providers a,b,c`
forks N transient "shadow" companies (`_bench-<run-id>-<provider>/`)
rooted at the template, pins each to one provider, fires the task,
waits for completion, then copies outputs into `benchmarks/runs/<run-
id>/providers/<provider>/`. Shadow companies are cleaned up on
success; left in place on failure for debugging.

**BenchLive** (new LiveView): `/benchmarks/<run-id>` shows N output
panels side-by-side **without provider labels** (randomised order).
Below each output, an "outputs differ" diff indicator and a scoring
row: `1st · 2nd · 3rd · …` radio buttons. Director submits; provider
labels unmask. Scores append to `scores.md` (free-text rationale
optional).

Aggregates: `/benchmarks` lists runs, filterable by template + task;
total bench-level leaderboard is just a tally across scores.md
files — no separate rank table.

### Fixture-isolation invariants

1. Template fixtures are bind-mounted **read-only** into the
   sandbox. Agents can read but not write (mutation goes to the
   company workspace).
2. Template `AGENT.md` `network:` defaults to `proxy` with a
   narrow allowlist in the agent frontmatter. The per-company GEP-23
   proxy enforces at the kernel layer.
3. Bench run manifest records the exact fixtures tree SHA (hash of
   sorted file hashes) so a run can be verified as "same inputs as
   before."
4. Each template declares a minimum Glorbo version. `glorbo new
   company --template X` rejects if the installed Glorbo predates the
   template's schema. (D8 — templates may evolve independently.)

### Template-authoring workflow

To add a new template (D7):

1. Copy an existing template dir.
2. Edit `template.md` manifest + agents + projects/tasks.
3. Drop static inputs under `fixtures/`.
4. Run `mix glorbo.bench.verify <name>` (new task) — lints the
   manifest, checks every task references a valid assignee, runs
   formatter idempotence on every file, confirms fixtures/ contains
   no binary >10MB (bench templates ship in the release).
5. Commit + optionally propose via PR.

## Migration / rollout

- **No existing data to migrate.** Benchmarks are a new subtree
  (`~/.glorbo/benchmarks/`). Companies scaffolded from non-bench
  templates continue to work.
- **`company-template/v1`** is a new `kind:` (registered in GEP-25).
  Adding it requires no changes to existing file writers — it's
  read-only template metadata consumed by the scaffolder.
- **Phase A ships the template format + 3 exemplars + CLI.** Phase
  B (bench runs + scoring UI) follows in a later release. The
  file-format contract for `benchmark-run/v1` is fixed here so Phase
  A users can manually produce runs by hand if they want, and Phase
  B consumers don't have to re-break it.

## Failure modes

| Failure | Surfaced how |
|---------|--------------|
| Template manifest invalid `kind:` or schema | `glorbo new company` refuses with `invalid template manifest` + path + field |
| Template refers to an agent not in `agents/` | Scaffolder emits `orphan task.assigned_to: <slug>` warning, still scaffolds |
| Fixtures dir contains binary > 10 MB | `mix glorbo.bench.verify` rejects; not caught at scaffold time |
| Provider unavailable at bench run time | Bench run marks that provider's panel `status: skipped`, records the error in `runlog.md`, continues with remaining providers |
| Two bench runs collide on `_bench-<run>-<provider>/` shadow company | Shadow-company creator includes millisecond timestamp + rand suffix; collision is vanishingly small and caught by `refuse_if_exists` |
| Director deletes a run while scoring | Archive-after-delete: `_deleted/<run-id>/` retains artifacts for 7 days |

## Test strategy

**Phase A (this GEP):**

- Manifest validation: `FileSpec.Validator` validates every
  shipped template's `template.md` + agents + tasks against the
  spec on every `mix test` run (new test file
  `test/glorbo/templates/bench_templates_test.exs`).
- Scaffolder round-trip: scaffold each bench template into a tmp
  dir, assert file tree matches expected shape, every file passes
  `glorbo validate`.
- Task-body variable rendering: `{{ slug }}`, `{{ provider }}`,
  `{{ model }}` substitution covered by existing
  `Glorbo.CLI.Scaffold.Renderer` tests, one new test per template.

**Phase B (follow-up):**

- Multi-provider dispatch unit test with stubbed providers.
- Blind-rendering test: BenchLive outputs provider labels hidden
  until score submitted.
- Score persistence round-trip.
- E2E: Scaffold bench-softdev → fire `bench run` with 2 stub
  providers → assert `scores.md` has 2 panels to score.
- **Multi-hop reasoning test (`bench-paperclip-parity`).** A
  dedicated template whose canonical task requires the full
  agent-routing chain — director → ceo (route) → researcher
  (with a clarification question back to ceo) → ceo (clarifies)
  → researcher (finalizes) → ceo (assigns to writer) → writer
  → critiqueops (review + fix request) → writer (corrects) →
  critiqueops (approves) → director (reviews). This exercises:
  router inbox/outbox transitions, director-approval gates at
  the hand-off points, follow-up-question semantics, and multi-
  round critique. Shipped as its own template so the bench can
  be compared against `paperclip.ai`'s equivalent agent graph
  (GEP-18 interop). Expected per-provider scoring dimensions:
  *task-completion fidelity*, *routing correctness*, *clarification
  quality*, *revision response quality*.

## Open questions

- **Fixtures in the binary.** Burrito bundles `priv/`; fixtures add
  weight. `bench-softdev`'s `fixtures/repo/` is target ≤2 MB.
  `bench-scifi-publisher`'s canon bible is target ≤1 MB. Total
  template overhead should stay under 10 MB. If one template needs
  a larger fixture (e.g. real dataset), we'll ship it via
  `glorbo bench fetch <name>` that pulls from a GitHub release
  asset on first use — deferred to Phase B.
- **Provider cost budgeting in bench runs.** Phase B must decide
  whether bench runs honour the per-company budget cap or have
  their own bench-wide cap. Probably the latter, to prevent a
  multi-provider run from exhausting one company's monthly budget.
- **LLM-as-judge.** Obvious next layer — a "judge" agent scores
  N panels instead of the director. Deferred to a future GEP;
  `scores.md` schema is designed to be extendable (`scorer: director`
  now, could become `scorer: agent:critiqueops` later).
- **Template versioning + upgrade.** If `bench-softdev/v2` ships
  with different fixtures, do existing `_bench-*` companies
  break? Probably not — they're self-contained post-scaffold.
  But runs referencing `template: bench-softdev` in manifests
  become ambiguous. Consider recording `template_version: 1`
  in manifests from day one. (D10)

## Decision log

### D1. Company templates are a new `kind:`, not agent-template clusters

- **Decided:** new `kind: company-template/v1` with its own
  scaffolder (`Glorbo.CLI.Scaffold.CompanyTemplate`), distinct
  from the per-agent template system in GEP-10.
- **Alternatives:**
  (a) A company template is "a bundle of agent templates" — the
      existing GEP-10 scaffolder iterated over a list.
  (b) Use a single tarball per template, unpack at scaffold time.
- **Why:** (a) loses manifest-level metadata (archetype,
  fixtures_dir, default_provider). (b) makes `mix glorbo.bench.
  verify` opaque — the formatter, validator, and `glorbo fmt` all
  need to operate on individual files, not a tarball. The
  tree-on-disk approach keeps every template file a first-class
  Glorbo-owned file that `glorbo validate` + `glorbo fmt` cover for
  free.

### D2. Fixtures are bind-mounted read-only, not copied

- **Decided:** template scaffold creates a `fixtures/` symlink
  (or copy on macOS where RO bind-mounts aren't free) in the
  scaffolded company, and the sandbox bind-mounts the *template's*
  `fixtures/` dir RO at runtime.
- **Alternatives:**
  (a) Copy fixtures into the company workspace; agent sees them
      as company-owned data.
  (b) Leave fixtures in `priv/` and teach agents to read from an
      install-dir path.
- **Why:** (a) lets the agent modify fixtures, invalidating
  repeatability — the agent's cache mutation of a CSV the next
  run would see. (b) hardcodes a path that varies between
  Burrito-unpacked installs and dev-mode. Bind-mount RO gives us
  repeatability + path stability in one move. macOS degrades to a
  copy + chmod RO when bind-mount unavailable (see GEP-5 D6 /
  GEP-17).

### D3. CLI adds `--template <name>` flag, not a new `bench` subcommand

- **Decided:** `glorbo new company <slug> --template <name>`.
  `glorbo bench list` + (Phase B) `glorbo bench run` exist under
  `bench`, but company creation stays under `glorbo new company`.
- **Alternatives:**
  (a) `glorbo bench init <slug>` as a fully separate verb.
  (b) `glorbo bench scaffold-company <slug> <template>`.
- **Why:** a bench-template company IS a company — same directory
  layout, same supervision tree, same dashboard routes. Scaffolding
  it via a different verb would imply a different runtime kind,
  which it isn't. Discovery via `glorbo bench list` keeps the verb
  surface tidy.

### D4. Two-phase implementation, shipped back-to-back (not deferred)

- **Decided:** this GEP is implemented in two phases. Phase A
  (templates + CLI + 3 exemplars) lands first; Phase B (multi-
  provider dispatch + blind A/B scoring LiveView) follows
  **immediately** as the next increment in the same work stream —
  not deferred to a later release.
- **Alternatives:**
  (a) Ship both at once in one commit (risk: Phase B is 3-5×
      Phase A in code; one big-bang review).
  (b) Split into GEP-26 (templates) and GEP-27 (scoring UI) so
      Phase B lives on its own schedule.
- **Why:** templates + scoring are one user-visible feature; the
  director can't do blind A/B without both. Shipping Phase A then
  pausing drops half the feature on the floor. (a) stacks too
  much into one review. (b) creates artificial GEP churn. A
  two-commit sequence keeps each commit small while delivering
  the feature end-to-end.

### D5. Blind-A/B, not side-by-side-with-labels

- **Decided:** Phase B's BenchLive masks provider identity until
  the director submits ranking. Panels are displayed in
  randomised-but-stable order (`run_id` seeds the shuffle).
- **Alternatives:**
  (a) Show labels up front, let the director score anyway.
  (b) Mask permanently — director never sees which was which.
- **Why:** the director's bias toward known providers
  (either positive or negative) is the dominant source of noise
  the blind-A/B mitigates. (a) reintroduces it. (b) prevents
  learning "claude is good at X" which is the whole point.
  Unmask-on-submit splits the difference.

### D6. Scores live in `scores.md` (markdown), not SQLite

- **Decided:** director-entered scores are appended to
  `benchmarks/runs/<run-id>/scores.md` as markdown sections. Each
  section is one scoring event (director ranking + rationale).
- **Alternatives:**
  (a) `scores.jsonl` — line-oriented, easier to grep.
  (b) SQLite `benchmark_scores` table.
- **Why:** (b) violates the filesystem-is-truth invariant (GEP-3 +
  GEP-7). (a) loses the free-form rationale affordance —
  directors will want to explain their ranking in prose, and JSONL
  fields for long prose are clunky. Markdown is the native Glorbo
  format; we already compose audit logs from markdown+JSONL pairs,
  so scores.md doesn't introduce a new pattern.

### D7. Template authoring workflow is "copy + verify"

- **Decided:** adding a new template is `cp -r` an existing one,
  edit in place, run `mix glorbo.bench.verify <name>`, optionally
  PR. No template scaffolder-scaffolder (meta!).
- **Alternatives:**
  (a) `glorbo bench new-template <name>` that emits a minimal
      bench-template skeleton.
  (b) Separate `glorbo-templates` repo under foobarto/ that
      community-contributed templates can PR into.
- **Why:** (a) is premature — we ship 3 exemplars; adding a 4th
  via `cp -r` is a 10-minute exercise. If templates grow to many
  more, revisit. (b) is nice to have but needs a contribution
  workflow we haven't designed; shipping in-tree is simpler while
  the feature is new.

### D8. Templates declare minimum Glorbo version

- **Decided:** `template.md` manifest includes
  `min_glorbo_version:` (semver). Scaffolder refuses if installed
  Glorbo is older.
- **Alternatives:**
  (a) Pin templates to a Glorbo version 1:1 (template version == Glorbo
      version).
  (b) No version check; let old Glorbos fail opaquely on new
      template features.
- **Why:** templates ship in `priv/templates/` so they're coupled
  to Glorbo's own release, but (a) is over-restrictive — a
  template that only uses v0.0.4 features shouldn't refuse to
  scaffold on v0.0.5. Explicit `min_glorbo_version:` is the
  industry-standard pattern; keeps surface small.

### D9. Provider pin is a scaffold-time concern, not a bench-run-time concern

- **Decided:** each scaffolded bench company is pinned to one
  provider at scaffold time (`--provider`). A bench *run* in Phase
  B spins up N **shadow companies** (one per provider), rather
  than asking a single company to dispatch to multiple providers.
- **Alternatives:**
  (a) One company, task declares `providers: [a, b, c]`, router
      dispatches N times.
  (b) One company, agent declares `provider_policy: round-robin`.
- **Why:** (a) + (b) violate the "one agent, one provider"
  invariant GEP-8/GEP-16 are built on. Shadow companies are a
  cleaner approach: they reuse every existing mechanism (dispatch,
  audit, sandbox) instead of adding branching throughout the
  pipeline. Shadow-company isolation also guarantees that
  provider-specific state (e.g. one agent caches something the
  other doesn't) can't pollute another provider's run.

### D10. Bench-run manifests record template version

- **Decided:** `manifest.md` for every run records
  `template_version: N` + `glorbo_version: X.Y.Z` +
  `fixtures_sha: <hex>` so reruns are verifiable.
- **Alternatives:**
  (a) Record only `template: <name>` (current state).
  (b) Freeze the template contents into the run artifact
      (copy every fixture).
- **Why:** (a) silently shifts under the director when a template
  is updated between runs. (b) duplicates data and bloats the
  bench artefact. A SHA is 40 bytes; reruns can self-verify by
  recomputing.

## Related

- **GEP-2** — architectural baseline.
- **GEP-4** — CLI-tool agents (providers bench runs compare).
- **GEP-8** — provider registry (`--provider <name>` semantics).
- **GEP-10** — agent/skill templates (this extends to company
  templates).
- **GEP-19** — director approval workflow (bench runs don't need
  approval by default, but dispatching to N providers may want
  opt-in per-run approval — open question in Phase B).
- **GEP-23** — egress proxy (fixture-isolation invariant relies on
  per-agent allowlists).
- **GEP-25** — file format specs (company-template/v1 and
  benchmark-run/v1 are registered kinds).
