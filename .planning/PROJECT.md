# Glorbo

## What This Is

Glorbo is a self-hosted agent orchestration platform that models companies as real organisations — with org charts, goals, budgets, governance, and communication — and runs AI agents as employees inside Linux containers. Everything is a markdown file under `~/.glorbo/`; SQLite is a rebuildable index. Built for solo Linux operators ("Directors") who want local-first, private, single-binary agent infrastructure without cloud services, Python on the host, or a database cluster.

## Core Value

**It's just a directory.** Agents, tasks, chat, permissions, goals, and audit logs are markdown/JSONL on disk — deployable by copying a binary, backup-able with `tar`, debuggable with `cat`, version-controllable with `git`. If that invariant breaks, Glorbo is no longer Glorbo.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. -->

(None yet — ship to validate)

### Active

<!-- Current scope. Building toward these. -->

- [ ] Filesystem-first architecture: markdown + YAML frontmatter as source of truth for companies, agents, tasks, channels, goals, skills, permissions
- [ ] Single-binary Elixir/OTP release with bundled ERTS (`mix release`, `include_erts: true`)
- [ ] SQLite index (via `ecto_sqlite3`) with `glorbo reindex` rebuild contract — DB deletable without data loss
- [ ] Per-company OTP supervision trees: crashing agent restarts only that agent; crashing company restarts only that company
- [ ] Rootless Podman container runtime; auto-download static `podman` binary if absent; read-only root FS, `--userns keep-id`
- [ ] Ollama local LLM backend, auto-downloaded by `glorbo init`; works offline out of the box
- [ ] Cloud LLM providers (Anthropic, OpenAI, Google) via Python-in-container SDKs, API keys from `~/.glorbo/config.md` injected as env vars
- [ ] Hugging Face local models via `huggingface_hub`
- [ ] Inbox/outbox message routing with `file_system` (inotify) watchers, one-way flow enforced by ACLs
- [ ] Append-only channel markdown files, Elixir is the sole writer; `@agent` mention triggers wake
- [ ] Phoenix LiveView dashboard on `localhost:4000`: company overview, kanban board, agent detail with stdout streaming, chat, approval queue, audit log, system health
- [ ] Phoenix Channels + PubSub for real-time agent chat and stdout streaming
- [ ] Declarative permissions in `agent.md` frontmatter (`resource:action:scope`), enforced at app layer (Elixir Router) AND kernel layer (POSIX ACLs via `setfacl`)
- [ ] Per-agent monthly budget in USD with alert threshold and hard stop; usage reported by Python worker after each LLM call
- [ ] Director-approved approval gates for tasks with `requires_approval: director` frontmatter
- [ ] Append-only JSONL audit log (`audit/YYYY-MM.jsonl`), never modified/deleted, indexed into SQLite
- [ ] Per-agent network policy: `none` (default) / `api-only` / `open`
- [ ] Agent wake triggers: inbox inotify, cron-style heartbeat, channel mention, Director request
- [ ] Ephemeral container lifecycle (default); persistent lifecycle for streaming/rapid back-and-forth
- [ ] Skills system: markdown files injected into agent context at runtime
- [ ] Full company isolation: one container per company, no cross-company filesystem access possible
- [ ] CLI: `init`, `up`, `down`, `status`, `serve`, `run`, `new {company,agent,project}`, `logs`, `doctor`, `reindex`, `migrate`, `backup`, `restore`, `console`
- [ ] `glorbo doctor --fix` rebuilds container image after restore on a new machine
- [ ] Offline-capable end-to-end: fresh install → local model → run agents with no network
- [ ] Linux x86_64 and aarch64 release artifacts

### Out of Scope

<!-- Explicit boundaries. Includes reasoning to prevent re-adding. -->

- Multi-user / multi-Director — v1 is single-operator; trust model assumes one human owns `~/.glorbo/`
- Cloud deployment — local-first is the whole point; cloud changes threat model and architecture
- macOS / Windows support — depends on Linux user/ACL/userns primitives; WSL2 may work incidentally but is not a target
- GUI installer — audience is terminal-comfortable Linux users
- Code-plugin / extension system — extensibility via markdown skills and agent definitions, not loaded code
- LLM fine-tuning or training — Glorbo orchestrates; it does not train
- Git integration for companies/ — Director can `git init` themselves; Glorbo does not wrap git
- Message broker / object store / cache layer — filesystem + SQLite are the only stores; adding more contradicts Core Value
- Agent-created agents — agent creation is strictly a Director action in v1 (simpler trust model)
- Multi-model per agent — one provider+model per `agent.md`; use separate agents for cheap/expensive roles
- Template marketplace — deferred; explore after v1 ships
- Shared workspaces across agents — deferred; each workspace is single-agent in v1
- Agent-specified extra container packages — base image only in v1

## Context

- **Author:** Linux desktop user (Fedora-based host), comfortable with Podman, Elixir is the host-side language, Python stays inside containers by design.
- **Inspiration:** "Paperclip with taste" — adds real-time chat, LiveView dashboard, and OTP stability that Paperclip omitted. Replaces Node.js + embedded Postgres with Elixir + filesystem.
- **Existing specs:** `DESIGN.md` (32KB, 14 sections, comprehensive architecture) and `README.md` are authoritative. This PROJECT.md condenses them; the source docs lead on detail.
- **Prior-art constraints:** No comparable tool exists that combines (filesystem-first + OTP supervision + rootless containers + local LLMs + LiveView). Research should confirm this and surface adjacent patterns (Paperclip, Bumblebee, Livebook, Nerves) to borrow from.
- **Target user flow:** `curl` binary → `glorbo init` (~1 min, bootstraps Podman+Ollama if missing) → `glorbo new company` → edit markdown → `glorbo up` → dashboard at `localhost:4000`.
- **Portability expectation:** `glorbo backup` → `scp` → `glorbo restore` + `doctor --fix` → fully functional on the target machine.

## Constraints

- **Tech stack (fixed):** Elixir/OTP + Phoenix LiveView on host; Python 3.12+ only inside containers; SQLite via `ecto_sqlite3`; Podman rootless; Ollama for local LLMs. — These are the identity of the project, not choices to revisit per phase.
- **Host dependencies (minimal):** Linux kernel + `uidmap` package. Everything else (Podman, Ollama, Python, BEAM) is either bundled or auto-downloaded into `~/.glorbo/bin/`. — Install friction kills adoption for a solo-operator tool.
- **Security posture:** Defence in depth — app-layer permission checks AND kernel ACLs; API keys never touch the company directory; containers are rootless + read-only root FS + `network: none` by default. — A leaked key or prompt-injected agent must not breach the host.
- **Filesystem invariants:** `companies/` is user data (never auto-modified); `glorbo.db` is derived (deletable); `inbox/` is write-only for Elixir; `outbox/` is write-only for the agent. — Breaking these breaks debuggability and trust.
- **Offline capability:** Full functionality must work with no network after `init` has completed. — Local-first is a headline promise.
- **Performance:** Dashboard must render real-time (sub-second) for file changes via inotify→PubSub→LiveView; `glorbo reindex` must complete in seconds on a typical company. — Users will delete the DB casually; reindex must not be scary.
- **Binary size:** Single-file release including ERTS. Acceptable to be tens of MB; must not require Erlang on target host.
- **Platform:** Linux x86_64 and aarch64 only in v1.

## Key Decisions

<!-- Decisions that constrain future work. Add throughout project lifecycle. -->

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Full DESIGN.md scope for v1 (not MVP-subset, not walking skeleton) | User chose comprehensive v1; DESIGN.md already represents tight scope discipline (see §13 Non-Goals) | — Pending |
| Agent creation is Director-only in v1 | Simpler trust model; agent-initiated agent creation raises hard governance questions not worth solving now | — Pending |
| One provider+model per agent; no multi-model routing | Keeps `agent.md` simple; cheap/expensive-model tradeoffs handled by using separate agents | — Pending |
| Glorbo must function fully offline after `init` | Local-first is the headline promise; cloud providers are opt-in augmentation | — Pending |
| Elixir/OTP on host, Python only in containers | Supervision + concurrency come free from BEAM; Python's supply-chain risk is confined to container | — Pending |
| Podman over Docker | Rootless by default, daemonless, no root escalation surface | — Pending |
| Ollama as default LLM; Hugging Face for broader model library | Zero-config local inference; HF covers the long tail | — Pending |
| SQLite as rebuildable index, not source of truth | Markdown is canonical; DB corruption is recoverable by `reindex` | — Pending |
| POSIX ACLs for kernel-level permission enforcement | Application-layer trust is insufficient for LLM-generated code; kernel is the last line | — Pending |
| Phoenix LiveView, no JS framework | Real-time dashboard free; no build step; aligns with "fewer moving parts" | — Pending |
| Filesystem-first; no message broker / object store / cache | Adding infrastructure contradicts Core Value (`it's just a directory`) | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-15 after initialization*
