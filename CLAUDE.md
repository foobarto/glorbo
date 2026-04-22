# CLAUDE.md

Guidance for Claude Code (and other LLM assistants) working in this
repo. Kept deliberately short — load-bearing detail lives in
`docs/`. This file is the map; the wiki is the territory.

## Project status

Glorbo is at **v0.0.4** (pre-1.0). Source under `lib/` (`glorbo`,
`glorbo_web`). No Python runtime, no container runtime.

## Feature development — six-phase checklist

Every non-trivial feature moves through these six phases, in order.
Skipping phases is how we get to a half-shipped feature three times
in a row.

| # | Phase      | Artifact                                                    |
|---|------------|-------------------------------------------------------------|
| 1 | **Spec**   | GEP draft in `docs/geps/` (see `glorbo-new-gep` skill)      |
| 2 | **Plan**   | GEP approved with concrete implementation details           |
| 3 | **Build**  | Code changes + any doc-adjacent updates                     |
| 4 | **Test**   | Unit tests green + UAT checklist updated (`docs/testing/uat.md`) |
| 5 | **Review** | Self-review (see principles below) + second opinion (codex) |
| 6 | **Ship**   | Commit + push, **AND** update every doc the change affects  |

**Step 6 — docs you must consider updating whenever something ships:**

- `CHANGELOG.md` — what shipped, always
- `README.md` — if the user-facing pitch or install story changes
- `docs/DESIGN.md` — if architecture, invariants, or tech stack changes
- `docs/geps/NNNN-…` — flip status if the GEP's implementation landed
- `docs/todo.md` — cross off whatever this change addressed
- `docs/testing/uat.md` — if the change adds a UI surface that needs UAT

Bug fixes, doc tweaks, and dep bumps may collapse phases 1–2 (no
GEP) but still need 3–6.

## Coding discipline

Four principles (adapted from Karpathy's guidelines). They override
the "move fast" impulse.

1. **Think before coding.** State assumptions, surface tradeoffs.
   When a request has multiple interpretations, pick one visibly —
   don't silently choose. Ask if the ambiguity is load-bearing.
2. **Simplicity first.** Minimum code that solves the problem. No
   speculative abstractions, no unrequested configurability, no
   defensive handling for impossible scenarios.
3. **Surgical changes.** Touch only what you must. Preserve existing
   style. Don't rename / reformat / "improve" unrelated sections
   while passing through. Every changed line should trace to the
   user's request.
4. **Goal-driven execution.** Define success concretely before
   implementing. Loop until the test passes / the diff is closed,
   not until you *feel* done.

Success looks like: fewer churned lines, no collateral rewrites,
clarifying questions ahead of implementation rather than reverted
commits after it.

## The wiki — `docs/`

Browsable knowledge base. Read these when you need depth CLAUDE.md
intentionally doesn't carry:

| Need | Go to |
|---|---|
| Authoritative architecture spec  | `docs/DESIGN.md` |
| Design decisions (what & why)    | `docs/geps/README.md` |
| Browser UAT checklist            | `docs/testing/uat.md` |
| End-user manual test plan        | `docs/testing/testplan.md` |
| Rolling punch list               | `docs/todo.md` |
| Release verification (cosign)    | `docs/verifying-releases.md` |
| Past autonomous-session logs     | `docs/sessions/` |
| Archived design artifacts        | `docs/archived/` |
| On-disk file format specs        | `docs/file-formats/` |

Top-level conventions that stay in the root:

| File              | Purpose                                        |
|-------------------|------------------------------------------------|
| `README.md`       | User-facing pitch + install                    |
| `CHANGELOG.md`    | Shipped-release log                            |
| `CONTRIBUTING.md` | Contributor guide                              |
| `SECURITY.md`     | Security policy                                |
| `LICENSE`         | Legal                                          |

## Common commands

- **Setup:** `mix setup` (deps + db + esbuild)
- **Dev server:** `mix phx.server` → `http://localhost:4000`
- **Tests:** `mix test`
- **Precommit gate:** `mix precommit` (compile-warn-as-err, format,
  docs check, tests)
- **Credo:** `mix credo --strict` — zero findings is the ship bar
- **Release:** `mix release` (Burrito single binary in `burrito_out/`)

Elixir/OTP pinned in `.tool-versions`: Elixir 1.18.4 / OTP 28.0.

## GEP workflow

When about to build a non-trivial feature, open
`docs/geps/0001-gep-purpose-and-guidelines.md` for the process, or
invoke the `glorbo-new-gep` skill which walks the Q&A.

**Proactively suggest a GEP** when the user describes a change that
touches on-disk layout, CLI surface, permission model, or a
load-bearing invariant. Don't wait to be asked.

## Load-bearing invariants

The full architecture is in `docs/DESIGN.md`. These are the
constraints spanning multiple files that are easy to violate:

- **The kernel is the policy engine** — every permission enforced at
  BOTH the Elixir Router (application) AND the Linux kernel via
  `bwrap` mount namespaces. Application-only checks are a design bug.
  (GEP-5.)
- **Filesystem is source of truth** — `~/.glorbo/companies/` is user
  data, never modified by upgrades. SQLite (`glorbo.db`) is derived
  and must be rebuildable from disk via `glorbo reindex`.
  (GEP-3, GEP-7.)
- **One-way inbox/outbox flow** — Elixir writes to inbox, agent reads.
  Agent writes to outbox, Elixir reads. Never the other direction,
  never cross-agent.
- **Audit log is append-only** — `audit/YYYY-MM.jsonl` entries are
  never modified or deleted.
- **No Python anywhere** — neither on the host nor in any container.
  GEP-5 D6.
- **Company isolation is absolute** — no cross-company access at any
  layer.
- **Crash isolation follows the OTP supervision tree** — agent crash
  → only that agent restarts; company crash → only that company.

## Browser UAT — Bazzite workaround

The Playwright MCP server can't find Chrome on Bazzite, and
`agent-browser`'s daemon mode breaks on HTTP nav. Full workaround
(manual chromium launch + `--cdp 9222` attach + `npx agent-browser`)
lives in `docs/testing/uat.md` §Bazzite.

## Historical planning artifacts

Previously used GSD v1 planning under `.planning/`. Archived
2026-04-17; decisions are now in the GEPs above, remainder in
git history. Do not run `/gsd-*` commands.

## Off-topic

- `.agents/skills/` (symlinked from `.claude/skills/`) contains
  external Claude Code skills — not Glorbo source code.
- `assets/index.html` is the marketing landing page, unrelated to
  the Phoenix app.
