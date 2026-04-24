# CLAUDE.md

Guidance for Claude Code (and other LLM assistants) working in
this repo. Kept deliberately short — load-bearing detail lives
in `docs/`. This file is the map; the wiki is the territory.

## Project status

Glorbo is at **v0.7.0** (pre-1.0). Source under `lib/`
(`glorbo`, `glorbo_web`). No Python runtime, no container
runtime.

## Governing principles (the backbone)

Four principles, adapted from
[Karpathy's guidelines](https://karpathy.bearblog.dev/dev/),
that override the "move fast" impulse:

1. **Think before coding.** State assumptions, surface
   tradeoffs. Pick interpretations visibly, not silently.
2. **Simplicity first.** Minimum that solves the problem.
3. **Surgical changes.** Every changed line traces to the
   user's request.
4. **Goal-driven execution.** Define success concretely;
   loop until verified, not until you *feel* done.

Full text + six-phase interweave in
[`docs/workflow/governing-principles.md`](docs/workflow/governing-principles.md).
When any other rule in this file conflicts with a principle,
the principle wins.

## Session rhythm

This project uses the [cairn](https://github.com/foobarto/cairn)
workflow. Every working session touches:

| When | Update |
|---|---|
| Session start | Read today's `docs/sessions/<date>-<topic>.md` if any; skim `docs/project-profile.md` (stance) + `docs/knowledge-graph/notes.md` (gotchas). |
| As you work | Append to today's `docs/sessions/<date>-<topic>.md`. |
| Notice something worth tracking | `docs/todo.md` under the right priority tier. |
| Stance settles | `docs/project-profile.md`. |
| Feature finished | Every doc the change affects — see [`docs/workflow/ship-checklist.md`](docs/workflow/ship-checklist.md). |

**Session journal format:** per-task entries with *Task
picked* / *What shipped* / *Design calls I made without you*
/ *Gates* / *Skipped / not done* / *Commit(s)* blocks, then a
`## Things I'd like your review` list at the end. Write as you
go, not retroactively. Tracked in git — session journals are
shared history, not ephemeral scratch.

## Feature development — six-phase checklist

| # | Phase | Artifact |
|---|---|---|
| 1 | **Spec**   | GEP draft in `docs/geps/` (see `glorbo-new-gep` skill) |
| 2 | **Plan**   | GEP accepted with concrete implementation details |
| 3 | **Build**  | Code + adjacent doc updates |
| 4 | **Test**   | Unit green + UAT checklist updated |
| 5 | **Review** | Self-review + quality + security + second opinion |
| 6 | **Ship**   | Commit + push, and update every doc the change affects |

Bug fixes, doc tweaks, and dep bumps may collapse phases 1–2
(no GEP) but still need 3–6.

Full detail at [`docs/workflow/six-phase-checklist.md`](docs/workflow/six-phase-checklist.md).
Phase-6 doc-update list at [`docs/workflow/ship-checklist.md`](docs/workflow/ship-checklist.md).

## Pre-version release gate

Before every `mix.exs` bump + `git tag`, walk
[`docs/workflow/release-gate.md`](docs/workflow/release-gate.md)
end-to-end. Unresolved security findings past a version cut
are P0 per [`docs/project-profile.md`](docs/project-profile.md).

## Autonomous work — round vs loop

- **Round** — one bounded cycle, stop when done.
- **Loop** — repeating cycles until a stop criterion
  (3-commit soft checkpoint, 5-commit hard stop).

Protocol + autonomy menu (L0–L4, default **L2**) + hard rules
at [`docs/workflow/autonomous-protocol.md`](docs/workflow/autonomous-protocol.md).

## Review phase

Phase 5 of the six-phase checklist. **Quality pass and
security pass are both mandatory**; second opinion (codex,
peer review) on non-trivial diffs. Security posture for this
project is **Paranoid** per
[`docs/project-profile.md`](docs/project-profile.md) — when
tools are absent, fall back to manual OWASP review. Never
skip the security step.

## The wiki — `docs/`

Browsable knowledge base. Read these when you need depth
this file intentionally doesn't carry:

| Need | Go to |
|---|---|
| **Architecture map + graph caveats (READ FIRST)** | **`docs/architecture.md`** |
| **Machine-generated navigation map (READ FIRST)** | **`docs/knowledge-graph/GRAPH_REPORT.md`** |
| **Project values / stances (READ FIRST for stance calls)** | **`docs/project-profile.md`** |
| **Tacit knowledge: findings, gotchas, false positives** | **`docs/knowledge-graph/notes.md`** |
| Governing principles (full text) | `docs/workflow/governing-principles.md` |
| Six-phase checklist (detailed) | `docs/workflow/six-phase-checklist.md` |
| Ship checklist (phase 6 doc updates) | `docs/workflow/ship-checklist.md` |
| Pre-version release gate | `docs/workflow/release-gate.md` |
| Autonomous-work protocol (round + loop) | `docs/workflow/autonomous-protocol.md` |
| Authoritative architecture spec | `docs/DESIGN.md` |
| Design decisions (what & why) | `docs/geps/README.md` |
| Browser UAT checklist | `docs/testing/uat.md` |
| End-user manual test plan | `docs/testing/testplan.md` |
| Rolling punch list | `docs/todo.md` |
| Release mechanics (tag, sign, tap) | `docs/releasing.md` |
| Release verification (cosign) | `docs/verifying-releases.md` |
| Detailed runtime log — session notes | `docs/sessions/` |
| On-disk file format specs | `docs/file-formats/` |
| Archived design artifacts | `docs/archived/` |

**Consult the knowledge base before reading source files.**
The three files marked READ FIRST exist specifically to save
tokens on "where is X?" / "what calls Y?" / "how does Z fit?"
questions. Reading them is ~75× cheaper than grep-and-read
across 200+ modules.

## Context management — graphify + notes

Two-layer memory system under `docs/knowledge-graph/`:
`GRAPH_REPORT.md` (machine-generated, refresh on module
change) + `notes.md` (hand-curated gotchas, append dated
entries when you discover something non-obvious). Full
rhythm + graph caveats at
[`docs/knowledge-graph/README.md`](docs/knowledge-graph/README.md).

## Common commands

- **Setup:** `mix setup` (deps + db + esbuild)
- **Dev server:** `mix phx.server` → `http://localhost:4000`
- **Tests:** `mix test`
- **Precommit gate:** `mix precommit` (compile-warn-as-err,
  format, docs check, tests)
- **Credo:** `mix credo --strict` — zero findings is the
  ship bar (check `echo $?`; Credo doesn't exit non-zero on
  refactor warnings)
- **Release:** `mix release` (Burrito single binary in
  `burrito_out/`)

Elixir/OTP pinned in `.tool-versions`: Elixir 1.18.4 / OTP 28.0.

## GEP workflow

Non-trivial features go through GEPs at `docs/geps/`. Open
`docs/geps/0001-gep-purpose-and-guidelines.md` for the process
or invoke the `glorbo-new-gep` skill which walks the Q&A.

**Proactively suggest a GEP** when the user describes a
change that touches on-disk layout, CLI surface, permission
model, or a load-bearing invariant. Don't wait to be asked.

## Load-bearing invariants

The full architecture is in `docs/DESIGN.md`. These are the
constraints spanning multiple files that are easy to violate:

- **The kernel is the policy engine** — every permission
  enforced at BOTH the Elixir Router (application) AND the
  Linux kernel via `bwrap` mount namespaces. Application-only
  checks are a design bug. (GEP-5.)
- **Filesystem is source of truth** — `~/.glorbo/companies/`
  is user data, never modified by upgrades. SQLite
  (`glorbo.db`) is derived and must be rebuildable from disk
  via `glorbo reindex`. (GEP-3, GEP-7.)
- **One-way inbox/outbox flow** — Elixir writes to inbox,
  agent reads. Agent writes to outbox, Elixir reads. Never
  the other direction, never cross-agent.
- **Audit log is append-only** — `audit/YYYY-MM.jsonl`
  entries are never modified or deleted.
- **No Python anywhere** — neither on the host nor in any
  container. GEP-5 D6.
- **Company isolation is absolute** — no cross-company
  access at any layer.
- **Crash isolation follows the OTP supervision tree** —
  agent crash → only that agent restarts; company crash →
  only that company.

## Browser UAT — Bazzite workaround

Playwright MCP + agent-browser daemon both misbehave on
Bazzite. Workaround (manual chromium + `--cdp 9222`) lives
in `docs/testing/uat.md` §Bazzite.

## Off-topic

- `.agents/skills/` (symlinked from `.claude/skills/`)
  contains external Claude Code skills — not Glorbo source.
- `assets/index.html` is the marketing landing page,
  unrelated to the Phoenix app.
- Historical GSD v1 planning under `.planning/` was
  archived 2026-04-17; decisions are in GEPs + git history.
  Do not run `/gsd-*` commands.
