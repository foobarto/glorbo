# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Glorbo shipped **v0.0.2** (Milestone 01 — CLI-agent runtime): Phoenix/LiveView dashboard, SQLite-backed Ecto, `glorbo` CLI (`up`/`down`/`doctor`/`init`/backup/restore), and Burrito single-binary release. Source lives under `lib/` (`glorbo`, `glorbo_web`). Python runtime inside Podman is **not** yet wired for v0.0.2 — container-runtime restoration is slated for the next milestone.

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

- **The kernel is the policy engine.** Permissions declared in `agent.md` frontmatter (resource:action:scope) must be enforced at *two* layers: the Elixir Router (application) and POSIX ACLs inside the company container (kernel). Application-only checks are a design bug — if an agent lacks `projects:write:foo`, the filesystem must physically reject the write.
- **Filesystem is the source of truth.** `~/.glorbo/companies/` is user data and is never modified by upgrades. `~/.glorbo/glorbo.db` (SQLite) is **derived data**: `glorbo reindex` must be able to fully reconstruct it from the filesystem. Never store anything in SQLite that isn't rebuildable from markdown/JSONL on disk.
- **One-way inbox/outbox flow.** `agents/<name>/inbox/` is write-only for Elixir, read-only for the agent. `agents/<name>/outbox/` is write-only for the agent, read-only for Elixir. Agents never touch each other's directories directly — Elixir's Router mediates every transfer.
- **Audit log is append-only.** `audit/YYYY-MM.jsonl` entries are never modified or deleted. Ever.
- **Python never runs on the host.** All Python lives inside the `glorbo-runtime` OCI image, executed via `podman run` as per-agent Linux users. Adding Python dependencies to the host is off-spec.
- **Company isolation is absolute.** Each company runs in its own Podman container with only its own directory mounted. There is no cross-company access mechanism at any layer.
- **Crash isolation follows the OTP supervision tree.** Agent crash → only that agent restarts. Company crash → only that company's agents restart. Dashboard and other companies are unaffected. Preserve this when wiring new supervisors.

## Tech stack (planned)

- **Orchestration/dashboard:** Elixir/OTP + Phoenix LiveView + Phoenix Channels, Ecto with `ecto_sqlite3`, `file_system` (inotify) for filesystem watching, `mix release` with bundled ERTS for single-binary distribution.
- **Agent runtime:** Python 3.12+ inside Podman, with `ollama`, `huggingface_hub`, `anthropic`, `openai`, `google-genai`, `litellm`.
- **LLMs:** local-first (Ollama auto-downloaded by `glorbo init`) with cloud providers (Anthropic/OpenAI/Google) configured per-agent in `agent.md`.

## Planning archive

This project previously used GSD v1 planning. Those artifacts are frozen at `.planning.archive/` (see `.planning.archive/ARCHIVE.md`). They may contain useful historical context — design rationale for v0.0.1 / v0.0.2 phases, milestone audit findings, requirement traces — but they are **stale by default** and not part of the active workflow.

**Rules for Claude Code on the archive:**

1. Do **not** read `.planning.archive/` proactively. Default assumption: it's irrelevant to the current task.
2. Only dip into it if the current task genuinely needs historical context that isn't in `DESIGN.md`, `README.md`, `CHANGELOG.md`, or the source.
3. If you do use `.planning.archive/` content to shape a recommendation, decision, or plan, **explicitly tell the user** which file(s) you relied on and flag that the content may be outdated. Don't silently absorb archive material into current-state answers.
4. Do not run `/gsd-*` commands — GSD is disabled at the Claude Code level. If planning rigor is needed, use lightweight alternatives (superpowers brainstorming, manual PLAN.md, etc.).

## Repo layout notes

- `.agents/skills/` (symlinked from `.claude/skills/`) contains external skill plugins installed from GitHub (see `skills-lock.json`). These are **not Glorbo source code** — they are tooling for Claude Code itself. Don't edit or document them as part of Glorbo.
- `assets/index.html` is the marketing/landing page, unrelated to the Phoenix app that will eventually live here.
- `.bg-shell/` is gitignored Claude Code runtime state.
