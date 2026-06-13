---
gep: 0020
title: Director dashboard UX sweep — rounds 2+3
author: Glorbo Maintainers <security@example.invalid>
status: Implemented
type: Informational
created: 2026-04-20
history:
  - date: 2026-04-20
    status: Draft
    note: Retrofit GEP capturing the rounds-2+3 paperclip-gap sweep.
  - date: 2026-04-20
    status: Implemented
    note: All items documented here shipped in v0.0.3-dev by commit e8b6639.
see-also: [0003, 0006, 0007, 0008, 0010, 0018, 0019]
implemented-in: v0.0.3-dev
---

# GEP-0020: Director dashboard UX sweep — rounds 2+3

This is an **Informational** GEP that retrofits scope and design
around work already merged to `main` between commits `2af3c33` and
`e8b6639` (2026-04-20). The work itself was developed against the
gap inventory in `.reports/uat/paperclip-ux-gaps.md`, which was
produced from a live paperclip (agentcompanies) comparison run.
Shipping-then-documenting is allowed under GEP-1 § "When to
retrofit"; this is that retrofit.

## Problem

Glorbo's v0.0.2 dashboard shipped with paperclip-baseline runtime
parity (`.reports/uat/glorbo-vs-paperclip.md`): an opencode+qwen CEO
could file hire-request tasks and the Router would materialise
them. **But the director-facing UX was noticeably thinner** than
paperclip's. Gaps documented:

1. No actor avatars — every audit row was a flat grey text line.
2. New-company modal accepted duplicate slugs server-side only, no
   inline feedback.
3. No "Last 14 days" rollup tiles (runs/day, success rate, tasks
   by status/priority).
4. Agent config was read-only; editing required a YAML file editor.
5. Skills had no UI; only resolver logs showed what was available.
6. No command-palette entries for the new `/inbox` and `/skills`
   views or the director-initiated modals.
7. Goals were a frontmatter schema only — no dedicated view.
8. InboxLive's Archive tab was a TODO placeholder.
9. No channel/inbox actor avatars (only audit had them).
10. Tool-call counts never surfaced on agent runs despite being
    parseable from claude-code JSONL.
11. No wizard flow chaining company → agent → project creation.

`paperclip-ux-gaps.md` also flagged §6 (cost page), §8
(sub-issues), and §14 (Instructions tab rename) which the user
explicitly deferred or declined.

## Goals

Close all 18 paperclip-ux-gaps sections the user didn't defer,
within two rounds of focused commits that each:

- Land atomically (one gap per commit, independently revertible).
- Keep round 1's runtime parity intact (no provider / router
  changes).
- Respect the "filesystem as source of truth" invariant (GEP-3,
  GEP-7): any new on-disk state must be rebuildable from
  markdown/JSON on disk; no SQLite-only state.
- Pass `mix precommit` + `mix credo --strict` + CI green on every
  push.

## Non-goals

- Costs page (§6) — deferred by user.
- Sub-issues / blocker graph (§8) — declined by user; the task-id
  autolinker (`b25235c`) covers the common case.
- Instructions-tab rename (§14) — cosmetic churn across tests;
  AgentLive already has a workspace file tree.
- Opencode JSONL parser (§2 complement) — tool-use parsing ships
  for Claude-Code only; opencode users see `—` for now.

## Design

The sweep splits across two rounds. Each bullet is one commit.

### Round 2 — UX parity polish

**§15 actor avatars** (`2af3c33`). Two new public helpers on
`GlorboWeb.Components.AuditEntry`:

- `actor_initials/1` — slug → two-letter upper-case initials.
  Single word → first two chars; multi-word → first letter of
  each of the first two words; empty → `"??"`.
- `actor_kind/1` — `"system" | "director" | "board"` → atomised
  kind; everything else → `"agent"`.

The audit-row grid adds a 22 px avatar column between timestamp
and sentence. CSS `.gl-avatar` + `.gl-avatar--{system,director,
agent}` tints the badge.

**§18 inline slug-probe** (`661caaf`). New assign
`new_company_slug_status` (`:empty | :invalid | :taken |
:available`). A `phx-change="new_company_slug_input"` handler with
150 ms debounce updates it on every keystroke by testing
`File.dir?(Path.join([base_dir(), "companies", slug]))`. The UI
renders an inline hint + toggles `.gl-input--valid` / `.gl-input--
invalid` classes + disables the create button when taken.

**§4 14-day rollups** (`a38f7e5`). New `Glorbo.Activity.Rollup`
module with four functions: `runs_per_day/2`,
`success_rate_per_day/2`, `tasks_by_status/1`,
`tasks_by_priority/1`. The first two scan the last two monthly
audit JSONL files and bucket by calendar day; the latter two read
task frontmatter directly. New function component
`GlorboWeb.Components.StatBreakdown` renders a stacked-segment
bar with a colour-coded legend; palette is a curated map for
known statuses (`done` → accent-dim, `denied` → danger, etc) with
a six-token rotation for unknowns. CompanyLive renders a second
stat strip below the existing 4-card row; Spark component is
reused for the two time-series tiles.

**§5 AgentLive config form** (`356e3af`). New generic helper
`Glorbo.Filesystem.FrontmatterWriter.update_keys/3` that rewrites
allow-listed YAML frontmatter keys while preserving order,
comments, and indentation. Atomic via `.tmp` + `File.rename/2`.
AgentLive's config panel gains an `edit` button that flips the
`<dl>` read-only view to a structured form with provider, model,
reports_to, heartbeat, network fields. `save` writes those keys
back to AGENT.md without touching `skills:` or `permissions:`.
TaskDefinition still owns its editor-allowlist
`write_frontmatter/2` path; the new writer is adjacent rather
than a refactor.

**§9 SkillsLive** (`27004c2`). New `/companies/:co/skills` view
that enumerates builtin skills under `priv/templates/skills/`
alongside user overrides at `<base>/skills/`, classifying each as
`builtin | custom | shadowed`. Used-by counts are derived by
reading every agent's `skills:` frontmatter list. Click a row →
expand the raw markdown inline. Adding/editing remains a CLI
scaffold path (`./glorbo new skill`) so the filesystem stays the
source of truth.

**§13 create-company wizard** (`0e9bb62`). Rather than build a new
wizard component, the three existing modals (new-company on
OverviewLive; new-agent + new-project on CompanyLive) chain via
URL params:

- OverviewLive's new-company modal gets a `create + continue →`
  variant that sets `_guided=1`. On success the socket
  push_navigates to `/companies/:co?wizard=new_agent`.
- CompanyLive.handle_params treats `?wizard=new_agent` as
  `?modal=new_agent` plus stamps a `:wizard_step` assign.
- `new_agent_create`, on success, push_patches to
  `?wizard=new_project`.
- `new_project_create` clears the wizard and flashes the
  completion summary.

Each modal renders a 3-step breadcrumb at the top while a wizard
chain is active. **Zero new scaffold code.**

### Round 3 — remaining surface + coverage

**§16 command palette extension** (`eeb63c7`). The existing JS
palette (triggered by ⌘K / Ctrl-K) was enriched to emit:

- Inbox + Skills links per company.
- "+ new agent" / "+ new project" action rows that use
  CompanyLive's existing `?modal=` param channel.
- Projects collected from the sidebar's PROJECTS rail.

**§7 GoalsLive** (`b1fac61`). New `/companies/:co/goals` page.
Reads `company.md` frontmatter `goals:` list and buckets every
task under `goal: <slug>` (or `(no goal)` for unassigned). Each
card: title, description, status badge, total + open counts, and
a status-breakdown bar (reuses StatBreakdown). Deep link to
Kanban filtered by goal slug.

**Archive actions** (`732c316`). New `Glorbo.Inbox.Archive`
module persists a set of opaque string keys at
`<base>/companies/<co>/audit/_inbox_archive.json`. **Not part of
the audit contract** (non-append-only); kept in `audit/` because
it's scoped to one company and stays out of agent-readable state.
Approval rows get an `archive` button next to approve/deny;
audit rows get per-row archive. Archive tab lists archived items
with per-row `unarchive`. Archived rows are filtered out of
Mine/All/Recent so the feed stays actionable.

Keys are stable across reloads: `approval:<task_path>` for
sentinels, `audit:<ts>|<action>|<target>` for activity rows.

**Avatars extended** (`709027a`). `AuditEntry.actor_initials/1` +
`actor_kind/1` are reused in ChannelMessage (per-message author
badge) and InboxLive audit rows. Closes the avatar consistency
gap Round 2 intentionally left.

**§2 tool-call counts** (`e8b6639`). Extends
`Glorbo.CLI.Parsers.ClaudeJsonl` to count `tool_use` blocks
inside each assistant message's `content` list, keyed by tool
name (`Bash`, `Read`, `WebFetch`, …). The count map lands on
`usage.tool_calls` (optional field on the `usage()` type).
`Agent.Dispatch.emit_complete_audit/6` forwards the map onto the
`agent.complete` audit entry via `maybe_put_tool_calls/2`;
`RunLog.group_runs/2` surfaces it on each run record. AgentLive's
Runs tab shows `N tools` in the collapsed row (title attr carries
the per-tool breakdown) and `Bash×1, Read×2` in the expanded dl.

Codex + Gemini parsers + opencode's `parser = "none"` provider
all get `tool_calls: nil` today — UI renders `—` / hides the row.

## Migration / rollout

No migration. All work is additive:

- New files under `lib/glorbo/activity/`,
  `lib/glorbo_web/components/stat_breakdown.ex`,
  `lib/glorbo/filesystem/frontmatter_writer.ex`,
  `lib/glorbo_web/live/{goals,skills}_live.ex`,
  `lib/glorbo/inbox/archive.ex`.
- New routes `/companies/:co/goals` and `/companies/:co/skills`.
- New sidebar nav entries `:goals` and `:skills`.
- New assign on OverviewLive (`:new_company_slug_status`) and
  CompanyLive (`:wizard_step`).
- New optional frontmatter keys are none — `goals:` on
  `company.md` was already shipped in `d813894` (round 1).
- New on-disk state (`_inbox_archive.json`) is recoverable by
  deleting the file; nothing depends on it.

The only filesystem-visible new artefact is
`<base>/companies/<co>/audit/_inbox_archive.json`. It is
explicitly excluded from the audit contract (`AuditLog` is
unchanged — still append-only, still the sole writer of audit
JSONL).

## Failure modes

- **Archive file corrupt** — `Glorbo.Inbox.Archive.list/2`
  returns an empty `MapSet` on any JSON-decode error. Worst case
  the director loses their "handled" marks; the rows they acted
  on (approve/deny) still reflect the real action.
- **FrontmatterWriter on a file without fences** — returns
  `{:error, :no_frontmatter}`. AgentLive surfaces the error as a
  flash; the file is untouched.
- **Rollup reads a partial JSONL line** — each line is
  `Jason.decode/1`-attempted; failures are silently skipped. The
  rollup numbers stay approximately correct.
- **Wizard chain interrupted mid-flow** — the user can close any
  modal with Escape. The URL stays at `?wizard=...` until
  handle_params clears it; any subsequent click on a non-wizard
  link resolves cleanly.

## Test strategy

Every new surface has a unit test under `test/glorbo_web/live/`
and every new module under `test/glorbo/`. Full suite is
1027 tests passing after the sweep. Live smoke in
`test/integration/opencode_lmstudio_live_test.exs` still passes
(paperclip-baseline runtime parity preserved).

Live curl-level UAT run documented in
`.reports/uat-v3-live/report.md` — all 11 routes return HTTP 200
with expected content markers.

End-to-end timing benchmark documented in
`.reports/uat-v3-live/paperclip-benchmark-v3.md` — CEO dispatch
→ three hire-request tasks landing at Router-watched outbox dir
in **12 seconds** (vs paperclip's ~22 minutes for the same
bootstrap).

## Open questions

- **Cost page (§6)** — deferred. Budget data exists at
  `Glorbo.Budget.Ledger`; a dedicated `/costs` LV is the obvious
  follow-up.
- **Opencode JSONL parser** — today opencode runs with
  `parser = "none"`; tool counts + token counts are invisible.
  A future `opencode_jsonl.ex` parser is the single biggest
  remaining observability gap.
- **Inbox @-mention + assignment feeds** — InboxLive today
  carries approvals + filtered audit. Paperclip's /Inbox also
  surfaces @-mentions from channels and task-assignment events.
  Requires new PubSub topics per resource.
- **Full Goals CRUD** — GoalsLive is read-only; editing goals
  means editing `company.md` from the file editor. Inline CRUD
  would need a new "write_goal" path on Frontmatter writer.

## Decision log

### D1. Retrofit as Informational, not Standards

- **Decided:** Round 2+3 lands as a single Informational GEP
  capturing what shipped and why.
- **Alternatives:** One GEP per feature (24 GEPs), or no GEP at
  all.
- **Why:** The sweep is a cluster of UX polish against a shared
  reference (paperclip-ux-gaps.md). Individual features don't
  change load-bearing invariants; bundling them into one
  Informational GEP preserves the decision context without
  creating a fan-out of small GEPs.

### D2. Archive state is local UI state, not audit

- **Decided:** `_inbox_archive.json` lives in `audit/` but is
  explicitly **not** an audit file.
- **Alternatives:** Separate top-level dir `ui-state/`, or
  SQLite-only state.
- **Why:** The file is scoped to one company dir (matches the
  audit-file neighbourhood) but mutable. Separate top-level dir
  would need a new filesystem invariant; SQLite-only would break
  GEP-7 (derived data is rebuildable — lose the SQLite file and
  the archive is gone). Current layout is the least-new-invariant
  path.

### D3. FrontmatterWriter adjacent to TaskDefinition, not a refactor

- **Decided:** Ship a new generic frontmatter writer; leave
  `Glorbo.TaskDefinition.write_frontmatter/2` alone.
- **Alternatives:** Refactor TaskDefinition to use the new
  writer.
- **Why:** TaskDefinition.write_frontmatter is hot-path (kanban
  save, task comments, ACTIONS DSL writes); a refactor would
  churn code that many tests already exercise thoroughly. The
  new writer's allow-list semantics differ too (TaskDefinition
  has strict allowed keys; new writer allows any frontmatter
  key the caller names). Two surfaces, two disciplines, zero
  blast radius on the hot path.

### D4. Wizard as URL-param protocol, not a new component

- **Decided:** Chain the three existing modals via `?wizard=`
  query params + a small `:wizard_step` assign.
- **Alternatives:** A new `WizardLive` that holds state for all
  three steps.
- **Why:** A dedicated WizardLive would duplicate scaffolding
  logic that the existing modals already wrap (CLI
  `./glorbo new {company,agent,project}`). The URL-param protocol
  is two lines per modal + a breadcrumb component; any modal can
  be invoked outside the wizard the same way.

### D5. Tool-counts on `agent.complete` not a separate event

- **Decided:** Tool counts ride on the existing `agent.complete`
  audit entry's detail map.
- **Alternatives:** A new `agent.tool_use` audit action emitted
  per tool invocation; separate `tool_use.jsonl` per agent.
- **Why:** Aggregates are what the Runs tab needs; per-call
  resolution would bloat audit for features the UI doesn't
  surface. Individual tool-call trace lives in the agent's own
  stdout.log + session JSONL — the parser reads those anyway.

### D6. Archive keys are opaque strings, not a tagged union

- **Decided:** `"approval:<task_path>"` and
  `"audit:<ts>|<action>|<target>"` are plain strings in a JSON
  array.
- **Alternatives:** A structured
  `%{kind: "approval", task_path: ...}` record or a SQLite table.
- **Why:** The set is small, the keys are stable, the file is
  human-readable. JSON array + string keys round-trips cleanly
  through `Jason.encode!/1` / `Jason.decode/1` without
  serialiser work.

## Related

- `.reports/uat/paperclip-ux-gaps.md` — the gap inventory driving
  this sweep.
- `.reports/uat/glorbo-vs-paperclip.md` — round 1 parity
  comparison.
- `.reports/uat-v3-live/report.md` — round 2+3 UAT.
- `.reports/uat-v3-live/paperclip-benchmark-v3.md` — 22-min → 12-s
  bootstrap comparison.
- GEP-6 — Phoenix LiveView dashboard surface.
- GEP-7 — SQLite as derived data (invariant this sweep preserved).
- GEP-10 — Agent and skill templates (shipped the skill auto-
  injection that the CEO reads).
- GEP-19 — Director approval workflow (the InboxLive archive
  augments this pipeline).

## Implementation reconciliation (2026-06-14)

This is an append-only record appended under GEP-1: an Accepted/Implemented GEP's body is not rewritten in place; design deviations discovered after acceptance are logged here instead.

- **GoalsLive read source + Goals CRUD (§7, lines 170-176; Open Questions, lines 281-283) — as-shipped (body is stale).** Reproduced. GEP-0020 §7 specs GoalsLive as reading `company.md` frontmatter `goals:` and says GoalsLive is read-only with full CRUD deferred. The shipped code instead reads the canonical `goals/<id>.md` files via `Glorbo.Company.Goals.list/1` (lib/glorbo_web/live/goals_live.ex:6-7, lib/glorbo/company/goals.ex:72) and supports inline add-goal CRUD: the `new_goal_submit` handler (goals_live.ex:72-76) calls `Glorbo.Company.Goals.add_goal/3` (goals_live.ex:15, goals_live.ex:76; lib/glorbo/company/goals.ex:180), which writes a new `goals/<id>.md` file. This is the intended state after GEP-0063 made goal/v1 files canonical and added inline add-goal; GEP-0020's §7 prose and its "Full Goals CRUD … would need a new write_goal path" Open Question are correctly superseded, not a regression. The §7 design is **superseded by GEP-0063**: GoalsLive now reads canonical `goals/<id>.md` files and supports inline add-goal CRUD.
- **Missing bidirectional supersession link between GEP-0020 and GEP-0063 — known-gap (documentation cross-reference).** Reproduced. GEP-0020 frontmatter `see-also: [0003, 0006, 0007, 0008, 0010, 0018, 0019]` (docs/geps/0020-round-2-3-ux-sweep.md:15) omits 0063, and GEP-0063's `see-also: [6]` (docs/geps/0063-*.md:9) omits 0020, so neither GEP points at the other despite 0063 superseding §7's GoalsLive design. The fix is doc-only: add 0063 to GEP-0020's see-also and add 0020 to GEP-0063's see-also, plus the one-line supersession note in §7 and the "Full Goals CRUD" Open Question — exactly as this reconciliation record now captures.
