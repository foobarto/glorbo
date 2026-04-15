# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Glorbo is **pre-implementation**. The repo currently contains only design artifacts (`DESIGN.md`, `README.md`) and planning infrastructure (`.planning/`). No Elixir or Python source exists yet. The first milestone will establish the Phoenix/SQLite skeleton and `mix glorbo.doctor` CLI. Until that lands, there are no build, lint, or test commands. Do not invent them.

`DESIGN.md` is the authoritative architectural spec; `README.md` is the user-facing pitch. When they disagree, `DESIGN.md` wins.

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

## Planning workflow (GSD v1)

This repo uses GSD v1 planning — artifacts live under `.planning/` (committed). Project-level context is in `.planning/PROJECT.md`. Before starting non-trivial implementation, consult `.planning/PROJECT.md` and any phase-specific docs under `.planning/`. Use `/gsd-*` slash commands for planning, execution, and review rather than improvising.

## Repo layout notes

- `.agents/skills/` (symlinked from `.claude/skills/`) contains external skill plugins installed from GitHub (see `skills-lock.json`). These are **not Glorbo source code** — they are tooling for Claude Code itself. Don't edit or document them as part of Glorbo.
- `assets/index.html` is the marketing/landing page, unrelated to the Phoenix app that will eventually live here.
- `.bg-shell/` is gitignored Claude Code runtime state.
