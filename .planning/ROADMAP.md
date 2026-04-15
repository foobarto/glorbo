# Roadmap: Glorbo

## Overview

Glorbo's journey from empty repo to shippable v1 traces the dependency arrows
of the architecture itself: a compilable Elixir/Phoenix skeleton that can
bootstrap a single-binary release → a runtime foundation (filesystem layout,
Podman, Ollama, append-only audit) that makes "it's just a directory" real →
the agent execution core (supervision, routing, kernel-enforced permissions,
budgets) that turns markdown into running work → a LiveView dashboard that
makes the filesystem observable in real time → CLI completeness plus
backup/restore/portability that lets a Director move Glorbo between machines
with `scp`. Each phase is an independently demoable slice; earlier phases
never depend on functionality delivered by later ones.

**Granularity:** coarse (5 phases, 1-3 plans each)
**Source of truth:** `DESIGN.md` §1-14
**Core invariant shaping order:** kernel is the policy engine; filesystem is
canonical; SQLite is derived; Python never on host; company isolation
absolute; OTP supervision preserves crash isolation; audit is append-only.

## Phases

- [ ] **Phase 1: Compilable Skeleton + CI Release Pipeline** - Phoenix/OTP skeleton with SQLite WAL, `mix glorbo.doctor`, and CI producing signed x86_64 + aarch64 single-binary releases.
- [ ] **Phase 2: Filesystem Foundation + Container Runtime + Local LLM** - `glorbo init` bootstraps Podman and Ollama, builds `glorbo-runtime` image, materialises `~/.glorbo/` hierarchy, audit log appends, and `reindex` rebuilds SQLite from disk.
- [ ] **Phase 3: Agents, Routing, Kernel Permissions, Budgets** - Per-company supervision trees with inotify-driven inbox/outbox, kernel-enforced ACLs matching `agent.md`, per-agent budgets and network policy, skills injection, and Director approval gates — all running offline end-to-end.
- [ ] **Phase 4: LiveView Dashboard + Real-Time Channels** - Phoenix LiveView on `:4000` with company overview, kanban, agent detail (live stdout), chat, approval queue, audit viewer, and system health, powered by Channels + PubSub wired to inotify.
- [ ] **Phase 5: CLI Completeness + Backup/Restore Portability** - Full CLI surface (`new`, `logs`, `console`, `migrate`, `backup`, `restore`, `init --repair`) with verified end-to-end portability: `backup` → `scp` → `restore` + `init --repair` reproduces a functional install on a fresh host.

## Phase Details

### Phase 1: Compilable Skeleton + CI Release Pipeline
**Goal**: A fresh checkout compiles to a signed, self-contained Linux binary on both x86_64 and aarch64, and that binary runs `glorbo doctor` to verify the host can eventually host Glorbo.
**Depends on**: Nothing (first phase)
**Requirements**: FND-01, FND-02, FND-03, FND-04, FND-05, FND-06
**Success Criteria** (what must be TRUE):
  1. `mix compile` succeeds on a fresh checkout with the domain-nested module layout from DESIGN.md §4.1 and the OTP supervision tree skeleton (Application → Repo, ContainerManager stub, Endpoint, CompanySupervisor) in place.
  2. `mix test` passes against Ecto + `ecto_sqlite3` with WAL mode configured for dev/test/runtime.
  3. `mix release` produces a single-file binary with `include_erts: true` that runs on a host with no Erlang installed.
  4. CI builds, tests, signs, and uploads x86_64 **and** aarch64 artifacts on every push to `main`.
  5. Running `./glorbo doctor` on a bare host reports pass/fail for kernel version, `uidmap` presence, disk space, and `~/.glorbo/` write permissions.
**Plans**: TBD (2-3 plans)

### Phase 2: Filesystem Foundation + Container Runtime + Local LLM
**Goal**: `glorbo init` converts a fresh host into a working Glorbo installation — Podman and Ollama bootstrapped, `glorbo-runtime` image built, `~/.glorbo/` hierarchy created, audit log appending, reindex contract operational, offline-capable.
**Depends on**: Phase 1
**Requirements**: FS-01, FS-02, FS-03, FS-04, FS-05, FS-06, RT-01, RT-02, RT-03, RT-04, RT-05, RT-06, LLM-01, LLM-02, LLM-05, CLI-02
**Success Criteria** (what must be TRUE):
  1. `glorbo init` on a fresh Fedora-like host completes in ~1 minute: creates the `~/.glorbo/` hierarchy matching DESIGN.md §3, auto-downloads static `podman` and `ollama` into `~/.glorbo/bin/` when missing, builds the `glorbo-runtime` OCI image from the bundled `Containerfile` and `requirements.txt`, and pulls a default local model.
  2. Deleting `~/.glorbo/glorbo.db` and running `glorbo reindex` fully reconstructs the index from the `companies/` tree and `audit/YYYY-MM.jsonl` files with no user data loss.
  3. Every orchestration event (init, image build, container start) appends to `audit/YYYY-MM.jsonl` as append-only JSONL and is mirrored into SQLite; entries are never modified or deleted.
  4. `file_system` (inotify) watchers report filesystem changes under a test company with sub-second latency.
  5. A company container launches with its own directory mounted (and no other company's directory visible), `--userns keep-id`, `--read-only` root FS, `network: none`, Python available only inside the container, and can be run ephemerally (default) or persistently.
  6. A trivial Ollama inference call executes inside the container on a host with no network connectivity (airplane mode) after `init` has completed.
**Plans**: TBD (2-3 plans)

### Phase 3: Agents, Routing, Kernel Permissions, Budgets
**Goal**: Markdown `agent.md` files become live, supervised, kernel-isolated workers that pick up tasks, collaborate via inbox/outbox and channels, respect per-agent permissions at both app and kernel layers, honour network policy and USD budgets, and escalate approval-gated work to the Director.
**Depends on**: Phase 2
**Requirements**: AGT-01, AGT-02, AGT-03, AGT-04, AGT-05, SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, LLM-03, LLM-04
**Success Criteria** (what must be TRUE):
  1. Per-company OTP supervision tree (FileWatcher, Router, Scheduler, BudgetTracker, AuditLog, per-agent GenServers) is running; killing an agent restarts only that agent, killing a company restarts only that company's agents, and other companies and the dashboard are unaffected.
  2. An agent wakes on each of the four triggers — new inbox file (inotify), cron-style heartbeat, `@agent` channel mention, Director request — and executes a task via `podman run` in its Linux user, with stdout streamed to `agents/<name>/stdout.log`.
  3. Inbox/outbox one-way flow is enforced: an agent cannot write to another agent's inbox or to a channel file directly; the Router mediates every transfer, and writes routed to a channel the sender lacks `chat:write` for are rejected and audited.
  4. For an agent declaring `permissions: [projects:write:website-redesign]`, POSIX ACLs inside the container physically reject `open(O_WRONLY)` on `projects/other/` — verified by running a deliberate write attempt from the Python worker and observing `EACCES` at the kernel layer, not just an Elixir-side rejection.
  5. Per-agent network policy (`none` default / `api-only` / `open`) is enforced at container-launch time; `network: none` agents cannot reach the public internet even when the LLM requests it.
  6. Per-agent USD budget is tracked: the Python worker reports `tokens_used` and `cost_usd` after each LLM call, Elixir aggregates into the SQLite budget ledger, alerts fire at the configured threshold, and a hard stop refuses further task execution when the monthly cap is exceeded.
  7. A task with `requires_approval: director` frontmatter pauses before execution until the Director explicitly approves (dashboard-driven in Phase 4; file-mutation-driven here), and agent creation is rejected unless performed by the Director — agents cannot spawn agents.
  8. An agent using `provider: anthropic` (or `openai` / `google`) with its API key in `~/.glorbo/config.md` executes a task using cloud inference; the key is injected as a container env var and is never written to the company directory. One provider + model per `agent.md` is enforced.
  9. Skills declared in an agent's `skills:` list are injected into the LLM prompt at runtime from `skills/<name>.md`.
**Plans**: TBD (2-3 plans)

### Phase 4: LiveView Dashboard + Real-Time Channels
**Goal**: A Director opens `http://localhost:4000` and sees the filesystem come alive — every company, agent, task, chat message, approval request, audit event, and live stdout stream, updating in sub-second real time via inotify → PubSub → LiveView.
**Depends on**: Phase 3
**Requirements**: UI-01, UI-02, UI-03
**Plans**: TBD (1-2 plans)
**Success Criteria** (what must be TRUE):
  1. `glorbo serve` starts Phoenix on `localhost:4000` and renders all seven views from DESIGN.md §9: company overview, kanban board, agent detail with live stdout tail, chat, approval queue, audit log viewer, and system health (container status, Elixir process tree, resource usage).
  2. When a file changes on disk under `~/.glorbo/companies/`, the dashboard updates in under one second without polling — verified by writing a new task markdown file and observing the kanban column repaint.
  3. Channel markdown files (`channels/*.md`) are append-only with Elixir as the sole writer; the dashboard chat UI renders them live, and a Director posting a message results in Elixir (not the browser) appending the validated entry.
  4. `@agent-name` mentions posted in a channel wake the named agent via the Router, and approval-gated tasks surfaced in the approval queue can be approved/rejected with one click, which updates the task file's frontmatter status.
**UI hint**: yes

### Phase 5: CLI Completeness + Backup/Restore Portability
**Goal**: Every CLI verb from DESIGN.md §10 works, and the portability story — `backup` on machine A, `scp` to machine B, `restore` + `init --repair`, everything functional — is end-to-end verified on a fresh host.
**Depends on**: Phase 4
**Requirements**: CLI-01, CLI-03
**Success Criteria** (what must be TRUE):
  1. All CLI verbs from the spec are implemented and documented: `init`, `init --repair`, `up`, `down`, `status`, `serve`, `run`, `new company`, `new agent`, `new project`, `logs`, `doctor`, `reindex`, `migrate`, `backup`, `restore`, `console`.
  2. `glorbo backup` produces a `tar.gz` containing `~/.glorbo/companies/`, `config.md`, and the audit log; `glorbo restore <archive>` extracts, runs `reindex`, and leaves the install in a usable state.
  3. End-to-end portability: on machine A run `glorbo down && glorbo backup`; `scp` the archive to machine B (fresh glorbo binary only); run `glorbo restore && glorbo init --repair && glorbo up`; a previously-running agent in a previously-existing company executes a task successfully on machine B.
  4. `glorbo console` opens an Elixir remote shell into the running release, `glorbo logs <company> [agent]` tails the correct log files, and `glorbo migrate` applies Ecto migrations in-place against an existing `glorbo.db`.
**Plans**: TBD (1-2 plans)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Compilable Skeleton + CI Release Pipeline | 0/TBD | Not started | - |
| 2. Filesystem Foundation + Container Runtime + Local LLM | 0/TBD | Not started | - |
| 3. Agents, Routing, Kernel Permissions, Budgets | 0/TBD | Not started | - |
| 4. LiveView Dashboard + Real-Time Channels | 0/TBD | Not started | - |
| 5. CLI Completeness + Backup/Restore Portability | 0/TBD | Not started | - |

---
*Roadmap created: 2026-04-15 — coarse granularity, 5 phases, 38/38 v1 requirements mapped.*
