---
gep: 25
title: On-disk file format specs, `glorbo validate`, `glorbo fmt`
author: Glorbo Maintainers <security@example.invalid>
status: Draft
type: Standards
created: 2026-04-21
requires: [2, 3]
see-also: [7, 10, 12, 13, 14, 15, 19, 21, 24]
history:
  - date: 2026-04-21
    status: Draft
    note: Initial draft.
  - date: 2026-04-23
    status: Draft
    note: |
      Majority of the GEP landed on `main`; staying in Draft until the
      R26.2b parser enforcement sweep closes. Shipped: `Glorbo.FileSpec`
      behaviour + 22 per-kind spec modules, `classify_by_path/1`,
      `FileSpec.Validator` with 10 check codes + NDJSON output,
      `FileSpec.Formatter` with idempotent canonical key ordering,
      `glorbo validate` + `glorbo fmt` CLI verbs (with `--check` /
      `--write` / `--json` / `--summary` / `--kind` / `--severity`),
      `mix glorbo.docs.file_formats` generator wired into precommit,
      `kind:` discriminator on every Glorbo writer, Router-boundary
      `kind:` enforcement on task + memory outboxes, and per-kind
      golden fixtures for 12 kinds (agent/task/company/project/
      agent-memory/sentinel-approval/braindump/agent-heartbeat/
      agent-soul/channel-log/goal/skill). Still open: the
      `TaskDefinition.parse_file` / `Agent.Parser.parse_file`
      `kind:` enforcement sweep (gated on migrating ~50 inline test
      fixtures); maximal-valid + per-error-condition fixture variants;
      and fixtures for the 4 remaining kinds (audit-event, inbox-archive,
      sentinel-stuck, sentinel-resolution).
---

# GEP-25: On-disk file format specs, `glorbo validate`, `glorbo fmt`

## Problem

Glorbo's filesystem-is-truth invariant (GEP-3) means every piece of
user state lives as markdown-with-frontmatter or JSONL on disk.
Across twelve existing file kinds (`company.md`, `AGENT.md`,
`project.md`, `<project>-NN.md` tasks, `HEARTBEAT.md`, `SOUL.md`,
`MEMORY.md` + `memory/<type>_<topic>.md`, state sentinels like
`awaiting-approval-*.md` / `stuck-on-*.md` / `resolved-*-*.md`,
`brain-dump-*.md`, `channels/*.md` rolling logs, `audit/YYYY-MM.jsonl`,
`_inbox_archive.json`), the authoritative schema of each is only
documented in the parser that reads it. Three problems follow:

1. **Discovery debt.** A director hand-editing `AGENT.md` or
   `company.md` can't look up the expected frontmatter keys without
   reading Elixir source. R25 caught one concrete symptom: GoalsLive
   required `title:` under `goals:` entries, but directors reach for
   `name:` (the convention on every other `company.md` field). The
   bug was silent — `slug · slug` rendered where the title should
   have been. There are probably more.

2. **No workspace health check.** `glorbo doctor` validates host
   preconditions (bwrap, inotify, kernel version). There is nothing
   that answers "is my `~/.glorbo/` directory internally consistent?"
   — no check that every task has a recognised `status:`, that every
   agent references a real provider, that every memory file matches
   its type/filename convention, that archive-JSON files parse.

3. **Drift between writers.** Several file kinds are written by more
   than one code path (task frontmatter via `TaskDefinition.write`,
   task frontmatter via `FrontmatterWriter.update_keys`, memory via
   outbox routing, etc.). Without a canonical spec, the paths slowly
   diverge on key ordering, optional-field defaults, and whitespace.

This GEP documents every schema, pins them into a machine-readable
spec module, and ships the two tools those specs enable.

## Goals

- Document the authoritative on-disk schema of every file Glorbo
  reads or writes under `~/.glorbo/`. One reference per file kind,
  versioned in `docs/file-formats/`.
- Provide a machine-readable counterpart (`Glorbo.FileSpec` + per-kind
  behaviour) so the validator, formatter, docs generator, and parsers
  all read the same source.
- Ship `glorbo validate [PATH…]`: reports schema violations by file,
  exits non-zero on any error. Human + JSON output modes.
- Ship `glorbo fmt [PATH…] [--check|--write]`: normalises frontmatter
  key order, whitespace, and `---` fences. Idempotent; never touches
  the markdown body; defaults to `--check`.

## Non-goals

1. **Schema migrations.** Renaming a field or splitting a file is
   out of scope — that's a separate GEP per change (like
   GEP-13 did for task IDs).
2. **Semantic auto-fix.** `glorbo fmt` is syntactic: key ordering,
   whitespace, fence normalisation. It does NOT add missing required
   fields, fill defaults, or rename files. Semantic fixes remain
   user work.
3. **External formats.** opencode session JSONL, provider-CLI homes
   (`~/.claude/`, `~/.codex/`), LM Studio logs, skills.sh payloads —
   anything written by a third party is parsed defensively and is
   explicitly not under `FileSpec`.
4. **Pre-commit / pre-save hooks.** This GEP ships CLI only. No
   editor integration, no git hook, no LiveView real-time validation.
   Downstream tools can consume the JSON output; wiring them is a
   follow-up.

## Design

### `kind:` field — the discriminator

Every markdown-with-frontmatter file carries a required top-of-file
`kind:` declaration:

```yaml
---
kind: company/v1
slug: acme
name: Acme
...
---
```

Shape: `kind: <name>/<version>`. Name is a kebab-case noun; version
is `v1`, `v2`, …. Initial kinds (all `v1`):

| File kind                             | `kind:` value              |
|---------------------------------------|----------------------------|
| `company.md`                          | `company/v1`               |
| `AGENT.md`                            | `agent/v1`                 |
| `project.md`                          | `project/v1`               |
| `<project>-NN.md` (task)              | `task/v1`                  |
| `HEARTBEAT.md`                        | `agent-heartbeat/v1`       |
| `SOUL.md`                             | `agent-soul/v1`            |
| `memory/<type>_<topic>.md`            | `agent-memory/v1`          |
| `memory/MEMORY.md`                    | `agent-memory-index/v1`    |
| `state/awaiting-approval-<task>.md`   | `sentinel-approval/v1`     |
| `state/stuck-on-<task>.md`            | `sentinel-stuck/v1`        |
| `state/resolved-<decision>-<task>.md` | `sentinel-resolution/v1`   |
| `braindump/<ts>.md`                   | `braindump/v1`             |
| `channels/<channel>.md`               | `channel-log/v1`           |

JSONL and JSON files:

| File kind                    | Discriminator                            |
|------------------------------|------------------------------------------|
| `audit/YYYY-MM.jsonl`        | per-line `kind: "audit-event/v1"`        |
| `audit/_inbox_archive.json`  | top-level `"kind": "inbox-archive/v1"`   |

Classification:

1. `FileSpec.classify/1` reads frontmatter (or first JSON line for
   JSONL); dispatches on `kind:`.
2. Path-based matching is a fallback for legacy files only, kept
   narrow and deleted once soft-migration is over.
3. Mismatch between `kind:` and path (e.g., a file claiming
   `kind: task/v1` sitting at `agents/ceo/AGENT.md`) is an error —
   the path is the filesystem's opinion, `kind:` is the content's
   opinion, and they must agree.

Versioning: `kind: task/v1` today. If the schema evolves in a
backward-incompatible way (adding required fields, changing enum
values), the new version is `task/v2` and a migration GEP specifies
the reader's behaviour for `v1` files (read-compatible vs. migration
required).

**No soft-migration.** Glorbo has zero external users at the time
this GEP lands (v0.0.4 shipped 2026-04-21, pre-1.0). Every existing
file in-repo fixtures, templates, seed data, live workspaces is
rewritten by the implementation PR to carry `kind:`. Validator
treats a missing `kind:` as an error. Formatter refuses to rewrite
a file without `kind:`; the scaffolder always emits it.

### Spec registry

```
Glorbo.FileSpec                          # behaviour + registry
├── FileSpec.CompanyMd                   # companies/<co>/company.md
├── FileSpec.AgentMd                     # companies/<co>/agents/<slug>/AGENT.md
├── FileSpec.ProjectMd                   # projects/<slug>/project.md
├── FileSpec.TaskMd                      # projects/<slug>/tasks/<slug>-NN.md
├── FileSpec.HeartbeatMd                 # agents/<slug>/HEARTBEAT.md
├── FileSpec.SoulMd                      # agents/<slug>/SOUL.md
├── FileSpec.MemoryIndexMd               # agents/<slug>/memory/MEMORY.md
├── FileSpec.MemoryEntryMd               # agents/<slug>/memory/<type>_<topic>.md
├── FileSpec.ChannelLogMd                # channels/*.md (rolling, append log)
├── FileSpec.BrainDumpMd                 # braindump/<ts>.md
├── FileSpec.SentinelAwaitingApprovalMd  # agents/<slug>/state/awaiting-approval-*.md
├── FileSpec.SentinelStuckOnMd           # agents/<slug>/state/stuck-on-*.md
├── FileSpec.SentinelResolvedMd          # agents/<slug>/state/resolved-*-*.md
├── FileSpec.AuditMonthJsonl             # audit/YYYY-MM.jsonl
└── FileSpec.InboxArchiveJson            # audit/_inbox_archive.json
```

Each module implements the `FileSpec` behaviour:

```elixir
@callback match?(path :: Path.t()) :: boolean()
@callback kind() :: atom()
@callback frontmatter_schema() :: %{
  required: [atom()],
  optional: [atom()],
  enums: %{optional(atom()) => [binary()]},
  patterns: %{optional(atom()) => Regex.t()},
  caps: %{optional(atom()) => non_neg_integer()}
}
@callback body_rules() :: keyword()
@callback canonical_key_order() :: [atom()]
@callback docs() :: %{title: binary(), summary: binary(), examples: [binary()]}
```

`FileSpec.classify/1` walks the path and dispatches to the first
module whose `match?/1` returns true. Unclassified paths return
`{:unknown, path}` — **info** severity, not an error (per non-goal
#3).

### Validator (`Glorbo.FileSpec.Validator`)

Public API:

```elixir
@spec validate_path(Path.t(), opts :: keyword()) ::
        %{findings: [finding()], stats: map()}

@type finding :: %{
        severity: :error | :warning | :info,
        file: Path.t(),
        line: non_neg_integer() | nil,
        code: atom(),
        message: binary()
      }
```

Checks per kind (not exhaustive — each spec module owns its rules):

| Check code               | Severity | Meaning                                |
|--------------------------|----------|----------------------------------------|
| `:yaml_parse_error`      | error    | frontmatter YAML won't parse           |
| `:missing_required_key`  | error    | e.g. `slug:` on `company.md`           |
| `:enum_out_of_range`     | error    | e.g. `network: potato`                 |
| `:pattern_mismatch`      | error    | e.g. slug that doesn't match regex     |
| `:cap_exceeded`          | error    | body bigger than GEP-21/14 limits      |
| `:type_filename_mismatch`| error    | memory file prefix ≠ frontmatter type  |
| `:unknown_key`           | warning  | key not in required ∪ optional         |
| `:non_canonical_order`   | info     | keys present but out of canonical order|
| `:orphan_sentinel`       | warning  | sentinel whose task no longer exists   |
| `:unknown_file`          | info     | path Glorbo doesn't recognise          |
| `:soft_migration`        | info     | `agent.md` vs `AGENT.md`, old task ID  |

Output modes:

- Default: human-readable (one line per finding, severity-coloured).
- `--json`: newline-delimited JSON, one finding per line. Stable field
  names for CI consumption.
- `--summary`: exits with counts only; zero-finding runs are silent.

Exit code: `0` if no errors; `1` if any `:error`; `0` if only
warnings/infos (matches `mix format --check-formatted` shape).

### Formatter (`Glorbo.FileSpec.Formatter`)

Public API:

```elixir
@spec format_file(Path.t()) :: {:ok, :unchanged | :changed, binary()} | {:error, term()}
@spec check_path(Path.t()) :: {:ok, [Path.t()]} | {:error, term()}
@spec write_path(Path.t()) :: {:ok, %{changed: [Path.t()], unchanged: non_neg_integer()}} | {:error, term()}
```

Rules (apply in order, all idempotent):

1. **Fence normalisation.** Frontmatter opens on line 1 with `---\n`,
   closes with `\n---\n`. No leading blank lines; exactly one
   trailing newline between `---` and body.
2. **Key ordering.** Keys within frontmatter follow
   `canonical_key_order/0` for that file kind. Unknown keys
   (warning-level from validator) are preserved and placed after all
   known keys, sorted alphabetically for stability.
3. **YAML dialect.** Values written in the dialect `YamlElixir` round-
   trips to: block-scalar for lists, flow-scalar for scalars, no
   quotes unless required, 2-space indent.
4. **Body preserved byte-for-byte.** The formatter never touches
   what's below the closing `---`. Task bodies, agent instructions,
   channel messages — all untouched.
5. **Trailing newline.** File ends with exactly one `\n`.

`--check` mode: compares disk bytes to what the formatter would
produce; exits `0` if identical, `1` otherwise, prints the list of
files that differ. Never writes.

`--write` mode: applies the formatted output via the standard
atomic tmp+rename pattern used elsewhere in the codebase
(`FrontmatterWriter`, `Agent.Memory.Writer`). Writes are logged to
audit as `fileformat.formatted` (actor: `director`).

### CLI surface

Added to `Glorbo.CLI.Dispatcher`:

- `glorbo validate [PATH…]` — alias `v`.
  - Default PATH: `~/.glorbo/`.
  - Flags: `--json`, `--summary`, `--severity <level>` (filter),
    `--kind <kind>` (restrict to one file kind).
- `glorbo fmt [PATH…]` — alias `f`.
  - Flags: `--check` (default), `--write`, `--diff` (show unified
    diff of what `--write` would change).

Both verbs are read-only by default and take only explicit
`--write`. Permission implications: `--write` goes through the same
atomic write path as other filesystem writers — no new privilege,
no bwrap interaction.

### Docs generation

`mix glorbo.docs.file_formats` walks every `FileSpec.*` module and
emits `docs/file-formats/<kind>.md`, using the `docs/0` callback
output. Run as part of `mix precommit`; CI fails if
`docs/file-formats/` is out of sync with the specs. Same strategy as
existing auto-generated artifacts in the repo.

## Migration / rollout

Glorbo has zero external users at the time this GEP lands
(v0.0.4 shipped 2026-04-21, pre-1.0). That makes "just do it right,
right now" the cheapest option — no soft-migration code paths, no
dual-reader support, no versioned parsers. The implementation PR:

1. **Adds `FileSpec` behaviour + per-kind modules** with schemas,
   canonical key ordering, docs.
2. **Adds `kind:` to every writer** — `TaskDefinition.write`,
   `FrontmatterWriter.update_keys`, scaffolders
   (`lib/glorbo/init/orchestrator.ex`, `glorbo init` templates),
   Router outbox handlers, AuditLog, `Agent.Memory.Writer`,
   `Inbox.Archive`, every sentinel writer.
3. **Adds `kind:` to every fixture** — test fixtures, seed data,
   example company, `priv/templates/` agent + skill templates.
4. **Adds parser enforcement** — existing parsers (e.g.
   `TaskDefinition.parse_file`) start requiring `kind:` at a matching
   value. Mismatch is a parse error.
5. **Ships `glorbo validate` + `glorbo fmt` CLI verbs.** Wires
   `glorbo fmt --check` into `mix precommit`.
6. **Generates `docs/file-formats/`** from the specs; wires into
   `mix precommit` as an "is-this-generator-output-stale?" check.

Soft-migration shapes documented in GEP-13 (`t-NN.md` ↔
`<project>-NN.md`) and GEP-15 (`agent.md` ↔ `AGENT.md`) are
likewise obsoleted by this PR — those soft-migration windows close,
and the implementation scrubs every `t-NN.md` and `agent.md`
leftover out of the tree.

**Everything lands together.** A GEP-25 PR that updates half the
writers but not the other half would leave the tree in a state
where `glorbo validate` fails on its own seed data. Atomic cut.

## Failure modes

- **Unknown file path.** Classifier returns `{:unknown, path}`;
  validator emits `:unknown_file` at info level. Directors can keep
  arbitrary notes under `~/.glorbo/` without validator noise.
- **Third-party JSONL in audit dir.** External appenders are not
  the intended writers (GEP-3: AuditLog is the sole writer). The
  `AuditMonthJsonl` spec validates only schema per line; unknown
  action codes are `:unknown_action` at warning level, not error —
  the audit log invariant is "every line is valid JSON", not "every
  action is known".
- **YAML parse error in a sentinel.** Sentinels are write-only-by-
  Elixir (GEP-19). A corrupt sentinel means something scribbled over
  it; validator emits `:yaml_parse_error` error-level. Formatter
  refuses to format a file that won't parse — no lossy rewrite.
- **Cap exceeded.** GEP-14 (10 KiB HEARTBEAT.md), GEP-21 (8 KB memory
  body, 100 KB total memory dir) already emit audit events at
  runtime; validator surfaces the same conditions at check time.
  Formatter does not truncate; over-cap files error out.
- **Concurrent writer during `--write`.** Atomic tmp+rename is our
  standard (Router, AuditLog, FrontmatterWriter). If another process
  races and mutates the file between `format_file/1` reading and
  `write_path/1` writing, the rename still produces a consistent
  file — the other process's changes may be lost, which is the same
  behaviour as any text editor.

## Test strategy

- **Per-kind unit tests.** One test module per `FileSpec.*` with
  golden fixtures under `test/fixtures/file-formats/<kind>/`:
  one minimal valid example, one maximal valid example, one per
  failure mode (missing key, wrong enum, pattern miss, cap exceeded,
  etc.). Each case exercises validator + formatter round-trip.
- **Formatter idempotence property.** For every fixture:
  `format(format(input)) == format(input)`.
- **Validator output stability.** JSON mode schema is pinned with
  a fixture the CLI compares against; changes require explicit
  fixture update.
- **Integration test.** Walk a seeded workspace under `test/fixtures/
  file-formats/workspace/` with ~30 files representing every kind.
  Assert finding counts per severity.
- **Precommit regression.** `mix glorbo.docs.file_formats` regenerates
  `docs/file-formats/*.md` and fails if git diff is non-empty — keeps
  docs pinned to specs.
- **CLI smoke tests.** `glorbo validate` / `glorbo fmt --check` both
  exit with the expected codes against known-good and known-bad
  workspaces.

## Open questions

- **Q1.** Should `glorbo fmt --write` audit each formatting change to
  `fileformat.formatted`, or stay silent? Leaning audit (consistency
  with other mutations) but it will spam logs on first-run cleanup
  of a large workspace. Revisit once the first real-world `--write`
  invocation happens.
- **Q2.** Should `_inbox_archive.json` have a strict schema
  (whitelist of archive key formats) or stay permissive (any string
  array)? The current reader is permissive; tightening could reject
  legitimate archive entries written by future features. Implementation
  starts permissive; tighten if drift shows up.
- **Q3.** Should the formatter sort YAML list entries (e.g.
  `skills: [b, a, c]` → `[a, b, c]`)? Stability vs. author intent
  trade-off. Current leaning: no — ordered lists may carry priority
  meaning (e.g. provider chain).
- **Q4.** When the first `kind: <name>/v2` arrives, what's the
  migration contract? `glorbo reindex` bumps? Separate `glorbo
  migrate` verb? This GEP commits to `v1` everywhere; a follow-up
  GEP handles the first `v2` and sets precedent.

## Decision log

### D1. One module per file kind, shared behaviour

- **Decided:** `FileSpec` as a behaviour, one module per file kind
  implementing it. Classification is a dispatch over `match?/1`.
- **Alternatives:** (a) single giant `FileSpec` module with a map
  keyed by `:kind`; (b) ad-hoc validation embedded in each existing
  parser.
- **Why:** 12+ file kinds with distinct frontmatter schemas is too
  much for one module to stay legible. A single-module map works
  for enum cases but loses compile-time dispatch and makes adding a
  new kind editable-in-one-file at the cost of editing-every-other-
  kind every time. Behaviour + per-kind module gives Elixir-native
  compile errors when a kind forgets a callback and keeps each
  schema visually scannable.

### D2. Validator non-strict on unknown kinds

- **Decided:** unrecognised paths yield `:unknown_file` at **info**
  severity; the validator's exit code is unaffected.
- **Alternatives:** (a) error out on unknown paths; (b) silently
  ignore them.
- **Why:** `~/.glorbo/` is a user directory. Directors keep notes,
  README files, `.gitignore`, dotfiles — Glorbo doesn't own the
  space, it lives in it (GEP-3 D6 preserves user data untouchable).
  Erroring makes the validator unusable on real workspaces; silently
  ignoring hides problems (a file the director thinks IS an AGENT.md
  but isn't named right). Info-level flags the file without blocking.

### D3. Formatter syntactic-only, never semantic

- **Decided:** `glorbo fmt` rewrites frontmatter key order, whitespace,
  fences, and trailing newlines. It does not add missing required
  fields, fill defaults, rename files, or rewrite body content.
- **Alternatives:** (a) auto-add missing required fields with
  placeholder values; (b) "upgrade" old task IDs or lowercase
  contract files.
- **Why:** auto-fix is coupled to schema migration (non-goal #1),
  and migrations want explicit Mix tasks (GEP-13 precedent:
  `mix glorbo.migrate_tasks`). A formatter that quietly invents
  content violates the filesystem-is-truth spirit even if
  technically correct. Let the validator identify the gap; let the
  director fix it explicitly.

### D4. `--check` as the default mode for `glorbo fmt`

- **Decided:** running `glorbo fmt` with no flags checks and reports;
  `--write` is required to modify files.
- **Alternatives:** (a) default to `--write` (matches some gofmt
  invocations); (b) no explicit flag — require interactive
  confirmation.
- **Why:** `glorbo fmt` hits every file under `~/.glorbo/` by
  default. A silent rewrite of a freshly-cloned workspace is a
  memorable first experience. `--check` first, `--write` as opt-in
  matches `mix format --check-formatted` ergonomics and makes it
  safe to integrate in `mix precommit` (check only) without fear of
  surprise diffs. Interactive prompts don't compose with CI.

### D5. Docs are generated from specs, not the other way around

- **Decided:** `docs/file-formats/<kind>.md` is generated by
  `mix glorbo.docs.file_formats` from each spec module's `docs/0`.
  `mix precommit` regenerates and fails on drift.
- **Alternatives:** (a) hand-written docs with the validator as a
  test gate; (b) auto-generate into a single `file-formats.md`
  monolith.
- **Why:** two sources of truth drift within a release. Generating
  from the spec closes that gap by construction. The split-per-kind
  layout matches the module layout so a reader grepping for a file
  kind lands in one place whether they're reading source or docs.

### D6. JSON output is newline-delimited, one finding per line

- **Decided:** `--json` emits NDJSON (`application/x-ndjson`) with
  one finding per line, no wrapping array.
- **Alternatives:** (a) a single JSON array covering all findings;
  (b) a structured document with metadata header + findings array.
- **Why:** NDJSON streams — consumers can read findings as the
  validator emits them on very large workspaces; tools like `jq -c`
  process them line-by-line without loading the whole file. A
  single array works until a workspace has thousands of findings;
  wrapper headers leak the validator's shape into every consumer.
  The stats summary can be emitted as a trailing line with
  `"type": "summary"` if needed without breaking line-level
  consumers.

### D7. `_inbox_archive.json` is the only non-markdown/JSONL file

- **Decided:** the spec registry documents `_inbox_archive.json` as
  an exception to the "markdown + YAML frontmatter OR JSONL only"
  rule from GEP-3 D2/D3/D5.
- **Alternatives:** (a) move archive state into a JSONL stream;
  (b) store archive state in SQLite only (violates D5 of GEP-7).
- **Why:** archive is a whole-set mutation (add/remove one key at
  a time), not an append. JSONL would need compaction; SQLite
  violates the filesystem-is-truth rule. Retain the existing JSON
  blob, document it formally, and treat it as the single admitted
  exception. GEP-3 isn't superseded — the exception is narrow and
  scoped.

### D8. `kind:` as required filesystem-independent discriminator

- **Decided:** every markdown-with-frontmatter file carries a
  `kind: <name>/<version>` field (k8s-inspired). JSONL files carry
  `kind:` in each line's JSON object; JSON files carry a top-level
  `"kind"`. Classification dispatches on `kind:` first, falls back
  to path only for the narrow "file pasted in isolation" case.
  Mismatch between `kind:` and the file's path is a validator error.
- **Alternatives:** (a) path-only classification (the Q1 shape of
  this GEP); (b) path first, `kind:` as optional informational
  field; (c) Kubernetes' separate `apiVersion` + `kind` pair.
- **Why:** path-only classification fails the moment a file moves
  or is read in isolation (pipe to `glorbo fmt -`, paste into a
  review tool, forward an LLM agent a file by content). A required
  discriminator makes classification a property of the content,
  not the location, and closes the latent bug class where a file
  at the wrong path silently "becomes" another kind. The combined
  `name/version` (vs. k8s's split) is smaller visual surface and
  survives the scale Glorbo operates at (a few dozen kinds, not
  thousands of CRDs).

### D9. No soft-migration, atomic cut

- **Decided:** the implementation PR rewrites every existing file
  with `kind:` in-place. Validator rejects files without `kind:`
  as errors from day one. Parser enforcement is strict. The
  soft-migration windows GEP-13 (task IDs) and GEP-15 (ALLCAPS)
  kept open are closed by this PR's atomic sweep.
- **Alternatives:** (a) phased rollout with `kind:` starting
  optional, then warning-level, then error-level over three
  releases; (b) keep soft-migration windows open forever.
- **Why:** zero external users means zero migration cost. Glorbo
  shipped v0.0.4 on 2026-04-21 still pre-1.0. Phased rollouts
  exist to protect external users from breaking changes; we
  don't have any. Dual-reader code paths are carrying cost with
  no beneficiary. The atomic cut costs one coordinated PR and
  removes every soft-migration branch from the codebase. "We'll
  never get a better window to do this" — this GEP takes that
  window.

## Related

- GEP-2 — architecture overview, invariants.
- GEP-3 — filesystem-is-truth, format universe (markdown + JSONL).
- GEP-7 — SQLite-as-derived-data, reindex composability.
- GEP-10 — agent/skill templates, `{{ var }}` placeholder dialect.
- GEP-12 — no user-input atoms, closed-enum parsing discipline.
- GEP-13 — project-prefixed task IDs, soft-migration precedent.
- GEP-14 — HEARTBEAT.md caps and semantics.
- GEP-15 — ALLCAPS contract files, soft-migration precedent.
- GEP-19 — approval sentinel frontmatter, audit event shapes.
- GEP-21 — memory file caps, type/filename agreement rule.
- GEP-24 — `schedule:` frontmatter, keyword-alias enum.
