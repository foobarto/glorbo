# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Glorbo shipped **v0.0.2** (Milestone 01 — CLI-agent runtime): Phoenix/LiveView dashboard, SQLite-backed Ecto, `glorbo` CLI (`up`/`down`/`doctor`/`init`/backup/restore), and Burrito single-binary release. Source lives under `lib/` (`glorbo`, `glorbo_web`). Agents are CLI-tool subprocesses (`claude`, `gemini`, `codex`) run under `bwrap`; no Python runtime and no container runtime — see GEP-5 D6 for the Podman-dropped decision.

`DESIGN.md` is the authoritative architectural spec; `README.md` is the user-facing pitch. When they disagree, `DESIGN.md` wins. `CHANGELOG.md` tracks what has actually shipped.

## Common commands

- **Setup:** `mix setup` (fetches deps, creates/migrates dev DB, installs esbuild).
- **Run dev server:** `mix phx.server` → `http://localhost:4000`. (Live-reload needs host `inotify-tools`; optional.)
- **Tests:** `mix test` (alias creates/migrates test DB first).
- **Format + lint gate:** `mix precommit` — compiles with `--warnings-as-errors`, prunes unused deps, formats, runs tests. Run this before committing non-trivial changes.
- **Credo (strict):** `mix credo --strict` — zero findings is the ship bar (see commit history).
- **Assets:** `mix assets.build` / `mix assets.deploy` (esbuild via Hex wrapper, no npm).
- **Release:** `mix release` (Burrito-wrapped single binary in `burrito_out/`).

Elixir/OTP pinned in `.tool-versions`: Elixir 1.18.4 / OTP 28.0.

## Architecture — load-bearing invariants

The full architecture is in `DESIGN.md`. These are the constraints that span multiple files and are easy to violate:

- **The kernel is the policy engine.** Permissions declared in `agent.md` frontmatter (resource:action:scope) must be enforced at *two* layers: the Elixir Router (application) and the Linux kernel via `bwrap` mount namespaces. Application-only checks are a design bug — if an agent lacks `projects:write:foo`, the filesystem must physically reject the write. Detail: **GEP-5**.
- **Filesystem is the source of truth.** `~/.glorbo/companies/` is user data and is never modified by upgrades. `~/.glorbo/glorbo.db` (SQLite) is **derived data**: `glorbo reindex` must be able to fully reconstruct it from the filesystem. Never store anything in SQLite that isn't rebuildable from markdown/JSONL on disk. Detail: **GEP-3**, **GEP-7**.
- **One-way inbox/outbox flow.** `agents/<name>/inbox/` is write-only for Elixir, read-only for the agent. `agents/<name>/outbox/` is write-only for the agent, read-only for Elixir. Agents never touch each other's directories directly — Elixir's Router mediates every transfer.
- **Audit log is append-only.** `audit/YYYY-MM.jsonl` entries are never modified or deleted. Ever.
- **No Python anywhere.** The pre-pivot plan to host a Python agent runtime inside Podman was dropped (GEP-5 D6). Glorbo wraps existing CLI tools; there is no Python on the host and none in any container. Adding Python deps to the Elixir side is off-spec.
- **Company isolation is absolute.** Each company's agents see only that company's directory through bwrap mount namespaces. There is no cross-company access mechanism at any layer.
- **Crash isolation follows the OTP supervision tree.** Agent crash → only that agent restarts. Company crash → only that company's agents restart. Dashboard and other companies are unaffected. Preserve this when wiring new supervisors.

## Tech stack

- **Orchestration/dashboard:** Elixir/OTP + Phoenix LiveView + Phoenix Channels, Ecto with `ecto_sqlite3`, `file_system` (inotify) for filesystem watching, `mix release` (Burrito-wrapped) for single-binary distribution.
- **Agent runtime:** existing CLI tools (`claude`, `gemini`, `codex`, etc.) invoked as `bwrap`-sandboxed subprocesses. Each CLI handles its own auth, model routing, tool-use, and telemetry. See GEP-4.
- **LLMs:** configured per-agent in `agent.md` via a `provider:` field referencing a CLI adapter. Auth lives in each CLI's own home dir (`~/.claude/`, `~/.gemini/`, `~/.codex/`), bind-mounted read-only into the sandbox.

## Design decisions — GEPs

Non-trivial design changes to Glorbo are captured as **GEPs (Glorbo Enhancement Proposals)** in `docs/geps/`. See `docs/geps/0001-gep-purpose-and-guidelines.md` for the full process and `docs/geps/README.md` for the index.

**When to propose a new GEP:**

- The user is **planning** a significant change — a new feature, a non-trivial refactor, a shift in architecture, a new public contract (CLI flag, config schema, on-disk layout, API surface), or anything that touches a load-bearing invariant documented in an existing GEP or `DESIGN.md`.
- The user has **already worked on** a significant change ad-hoc (without a prior GEP) and the decisions behind it are worth preserving. Retrofit as an Informational GEP capturing what shipped and why.
- The change reverses or materially extends an earlier decision.

**When NOT to propose a GEP:**

- Bug fixes, dependency bumps, refactors contained to one module that don't change behaviour, doc tweaks, performance work without API changes.

**How:** invoke the `glorbo-new-gep` skill. It walks the user through a Q&A covering scope, design, alternatives, and the decision log. The skill produces a well-formed GEP file in `docs/geps/`, updates the README index, and maintains bidirectional links with referenced GEPs.

Proactively suggest creating a GEP when the user describes work that meets the "when to propose" criteria — don't wait to be asked. If they decline, respect that; if they agree, start the skill.

## Historical planning artifacts

This project previously used GSD v1 planning under `.planning/`. As of 2026-04-17 the tree was archived and then deleted — the decisions it recorded are now captured in the GEPs above, and anything else that mattered lives in git history. If you ever genuinely need v0.0.1/v0.0.2 phase plans, `git log --all` + checking out a pre-2026-04-17 commit is the route. Don't create a parallel doc tree for historical reference; see GEP-11's "archaeology is best served with git" aphorism.

Do not run `/gsd-*` commands — GSD is disabled at the Claude Code level.

## Repo layout notes

- `.agents/skills/` (symlinked from `.claude/skills/`) contains external skill plugins installed from GitHub (see `skills-lock.json`). These are **not Glorbo source code** — they are tooling for Claude Code itself. Don't edit or document them as part of Glorbo.
- `assets/index.html` is the marketing/landing page, unrelated to the Phoenix app that will eventually live here.
- `.bg-shell/` is gitignored Claude Code runtime state.
