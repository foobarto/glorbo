# Requirements: Glorbo

**Defined:** 2026-04-15
**Core Value:** It's just a directory. Agents, tasks, chat, permissions, goals, and audit logs are markdown/JSONL on disk — deployable by copying a binary, backup-able with `tar`, debuggable with `cat`, version-controllable with `git`.

Source of truth: `DESIGN.md` (authoritative architecture, 14 sections). This file surfaces checkable requirements; `DESIGN.md` holds the full rationale.

## v1 Requirements

### Foundation (FND)

- [x] **FND-01**: Phoenix project generated with `mix phx.new`, SQLite via `ecto_sqlite3`, modules reshaped to domain-nested layout matching `DESIGN.md`
- [x] **FND-02**: SQLite configured in WAL mode for dev, test, and runtime
- [x] **FND-03**: Single-binary release built via `mix release` with `include_erts: true` — no Erlang required on target
- [x] **FND-04**: Linux x86_64 **and** aarch64 release artifacts produced
- [x] **FND-05**: CI pipeline compiles, tests, and uploads signed binary artifacts per push to `main`
- [x] **FND-06**: `mix glorbo.doctor` CLI verifies host prerequisites (kernel, `uidmap`, disk, write perms on `~/.glorbo/`)

### Filesystem Layout & Index (FS)

- [ ] **FS-01**: `~/.glorbo/` directory hierarchy created by `glorbo init` matches `DESIGN.md` §4 (companies, audit, bin, config)
- [ ] **FS-02**: Markdown + YAML frontmatter is canonical storage for companies, agents, tasks, channels, goals, skills, permissions
- [ ] **FS-03**: `~/.glorbo/glorbo.db` (SQLite) is a rebuildable index — `glorbo reindex` fully reconstructs it from disk
- [ ] **FS-04**: Deleting `glorbo.db` never loses user data; next boot or `reindex` restores it
- [ ] **FS-05**: Append-only JSONL audit log at `audit/YYYY-MM.jsonl` — entries are never modified or deleted, and are mirrored into SQLite on each write
- [ ] **FS-06**: `file_system` (inotify) watchers detect filesystem changes with sub-second latency

### Runtime & Containers (RT)

- [ ] **RT-01**: Rootless Podman auto-detected; static `podman` binary auto-downloaded into `~/.glorbo/bin/` when missing
- [ ] **RT-02**: `glorbo-runtime` OCI image built and cached locally; `glorbo doctor --fix` rebuilds it after restore on a new machine
- [ ] **RT-03**: Each company runs in its own Podman container, mounting only that company's directory — no cross-company filesystem access possible
- [ ] **RT-04**: Containers use `--userns keep-id`, read-only root FS, `network: none` by default
- [ ] **RT-05**: Ephemeral container lifecycle is the default; persistent lifecycle opt-in for streaming/rapid back-and-forth agents
- [ ] **RT-06**: Python never executes on the host — all Python is inside `glorbo-runtime`

### LLM Backends (LLM)

- [ ] **LLM-01**: Ollama auto-downloaded by `glorbo init`; local inference works offline out of the box
- [ ] **LLM-02**: Hugging Face local models supported via `huggingface_hub`
- [ ] **LLM-03**: Cloud providers — Anthropic, OpenAI, Google — usable via per-agent config in `agent.md`; API keys read from `~/.glorbo/config.md` and injected as env vars, never written to company directories
- [ ] **LLM-04**: One provider + model per agent; no multi-model routing per agent
- [ ] **LLM-05**: Full end-to-end flow works offline after `init` completes (local model only)

### Agents & Supervision (AGT)

- [ ] **AGT-01**: Per-company OTP supervision tree — crashing agent restarts only that agent; crashing company restarts only that company; dashboard and other companies unaffected
- [ ] **AGT-02**: Agent wake triggers: inbox inotify, cron-style heartbeat, channel `@agent` mention, Director request
- [ ] **AGT-03**: Inbox/outbox one-way message flow — `inbox/` is write-only for Elixir + read-only for the agent; `outbox/` is write-only for the agent + read-only for Elixir; Elixir's Router mediates every transfer
- [ ] **AGT-04**: Skills system — markdown files injected into agent context at runtime
- [ ] **AGT-05**: Agent creation is Director-only in v1 (agents cannot spawn agents)

### Permissions & Security (SEC)

- [ ] **SEC-01**: Declarative permissions in `agent.md` frontmatter (`resource:action:scope`) enforced at the Elixir Router (application layer)
- [ ] **SEC-02**: Same permissions enforced at the kernel layer via POSIX ACLs (`setfacl`) inside the company container — application-only checks are a design bug
- [ ] **SEC-03**: Per-agent network policy: `none` (default) / `api-only` / `open`
- [ ] **SEC-04**: Director-approved approval gates for tasks with `requires_approval: director` frontmatter
- [ ] **SEC-05**: Per-agent monthly budget in USD with alert threshold and hard stop; usage reported by Python worker after each LLM call and indexed into SQLite

### Dashboard & Real-Time (UI)

- [ ] **UI-01**: Phoenix LiveView dashboard on `localhost:4000` — company overview, kanban board, agent detail with stdout streaming, chat, approval queue, audit log, system health
- [ ] **UI-02**: Phoenix Channels + PubSub deliver sub-second real-time updates for agent chat and stdout streaming
- [ ] **UI-03**: Append-only channel markdown files; Elixir is the sole writer; `@agent` mention wakes the agent

### CLI Surface (CLI)

- [ ] **CLI-01**: Commands implemented: `init`, `up`, `down`, `status`, `serve`, `run`, `new {company,agent,project}`, `logs`, `doctor`, `reindex`, `migrate`, `backup`, `restore`, `console`
- [ ] **CLI-02**: `glorbo init` bootstraps missing Podman and Ollama in ~1 minute on a fresh Fedora-like host
- [ ] **CLI-03**: `glorbo backup` + `scp` + `glorbo restore` + `glorbo doctor --fix` reproduces a functional install on the target machine

## v2 Requirements

Deferred from v1 — tracked but not in current roadmap.

### Extensibility

- **EXT-01**: Template marketplace for companies/agents/skills
- **EXT-02**: Shared workspaces across agents within a company

## Out of Scope

| Feature | Reason |
|---------|--------|
| Multi-user / multi-Director | v1 trust model assumes one human owns `~/.glorbo/`; changing that reshapes ACL story |
| Cloud deployment | Local-first is the whole point; cloud changes threat model and architecture |
| macOS / Windows native support | Depends on Linux user/ACL/userns primitives; WSL2 may work incidentally but is not a target |
| GUI installer | Audience is terminal-comfortable Linux users |
| Code-plugin / extension system | Extensibility via markdown skills + agent definitions, not loaded code |
| LLM fine-tuning or training | Glorbo orchestrates; it does not train |
| Git wrapping for companies/ | Director can `git init` themselves; Glorbo does not wrap git |
| Message broker / object store / cache | Filesystem + SQLite are the only stores; adding contradicts Core Value |
| Agent-created agents | Agent creation is strictly Director in v1 (simpler trust model) |
| Multi-model per agent | One provider+model per `agent.md`; use separate agents for cheap/expensive roles |

## Traceability

*Populated by roadmap creation — each requirement maps to exactly one phase. Unmapped = roadmap gap.*

| Requirement | Phase | Status |
|-------------|-------|--------|
| FND-01 | Phase 1 | Complete |
| FND-02 | Phase 1 | Complete |
| FND-03 | Phase 1 | Complete |
| FND-04 | Phase 1 | Complete |
| FND-05 | Phase 1 | Complete |
| FND-06 | Phase 1 | Complete |
| FS-01 | Phase 2 | Pending |
| FS-02 | Phase 2 | Pending |
| FS-03 | Phase 2 | Pending |
| FS-04 | Phase 2 | Pending |
| FS-05 | Phase 2 | Pending |
| FS-06 | Phase 2 | Pending |
| RT-01 | Phase 2 | Pending |
| RT-02 | Phase 2 | Pending |
| RT-03 | Phase 2 | Pending |
| RT-04 | Phase 2 | Pending |
| RT-05 | Phase 2 | Pending |
| RT-06 | Phase 2 | Pending |
| LLM-01 | Phase 2 | Pending |
| LLM-02 | Phase 2 | Pending |
| LLM-03 | Phase 3 | Pending |
| LLM-04 | Phase 3 | Pending |
| LLM-05 | Phase 2 | Pending |
| AGT-01 | Phase 3 | Pending |
| AGT-02 | Phase 3 | Pending |
| AGT-03 | Phase 3 | Pending |
| AGT-04 | Phase 3 | Pending |
| AGT-05 | Phase 3 | Pending |
| SEC-01 | Phase 3 | Pending |
| SEC-02 | Phase 3 | Pending |
| SEC-03 | Phase 3 | Pending |
| SEC-04 | Phase 3 | Pending |
| SEC-05 | Phase 3 | Pending |
| UI-01 | Phase 4 | Pending |
| UI-02 | Phase 4 | Pending |
| UI-03 | Phase 4 | Pending |
| CLI-01 | Phase 5 | Pending |
| CLI-02 | Phase 2 | Pending |
| CLI-03 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 38 total
- Mapped to phases: 38
- Unmapped: 0

**By phase:**
- Phase 1 (Skeleton + CI): 6 requirements — FND-01..06
- Phase 2 (FS + Runtime + Local LLM): 15 requirements — FS-01..06, RT-01..06, LLM-01, LLM-02, LLM-05, CLI-02
- Phase 3 (Agents + Routing + Perms + Budgets): 12 requirements — AGT-01..05, SEC-01..05, LLM-03, LLM-04
- Phase 4 (Dashboard + Real-Time): 3 requirements — UI-01..03
- Phase 5 (CLI + Portability): 2 requirements — CLI-01, CLI-03

---
*Requirements defined: 2026-04-15*
*Last updated: 2026-04-15 — Phase 1 complete: FND-01..06 all marked Complete (6/38 v1 requirements shipped).*
