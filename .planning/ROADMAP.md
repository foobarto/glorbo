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

- [x] **Phase 1: Compilable Skeleton + CI Release Pipeline** - Phoenix/OTP skeleton with SQLite WAL, `mix glorbo.doctor`, and CI producing signed x86_64 + aarch64 single-binary releases.
- [x] **Phase 2: Filesystem Foundation + Container Runtime + Local LLM** - `glorbo init` bootstraps Podman and Ollama, builds `glorbo-runtime` image, materialises `~/.glorbo/` hierarchy, audit log appends, and `reindex` rebuilds SQLite from disk.
- [x] **Phase 3: CLI Agent Runtime + bwrap Isolation + Routing + Budgets** - Per-company supervision trees with inotify-driven inbox/outbox, CLI agents (Claude Code, Gemini CLI, Codex) dispatched through `bwrap` sandboxes with filesystem + network namespace isolation, per-agent budgets, skills injection, and Director approval gates.
- [ ] **Phase 4: LiveView Dashboard + Real-Time Channels** - Phoenix LiveView on `:4000` with company overview, kanban, agent detail (live stdout), chat, approval queue, audit viewer, and system health, powered by Channels + PubSub wired to inotify.
- [ ] **Phase 5: CLI Completeness + Backup/Restore Portability** - Full CLI surface (`new`, `logs`, `console`, `migrate`, `backup`, `restore`, `doctor --fix`) with verified end-to-end portability: `backup` → `scp` → `restore` + `doctor --fix` reproduces a functional install on a fresh host.

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
**Plans**: 3 plans
- [x] 01-01-PLAN.md — Phoenix skeleton + domain-nested §4.1 module stubs + SQLite WAL + Wave 0 tests (FND-01, FND-02)
- [x] 01-02-PLAN.md — `Glorbo.Doctor` shared module + `Mix.Tasks.Glorbo.Doctor` with `--json` flag (FND-06)
- [x] 01-03-PLAN.md — Burrito single-binary release + argv dispatch + GitHub Actions CI matrix + Cosign keyless signing + VERIFY.md (FND-03, FND-04, FND-05)

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
**Plans**: 4 plans
- [x] 02-01-PLAN.md — Filesystem hierarchy + append-only AuditLog + Ecto schemas + MD5 reindex (FS-01..05)
- [x] 02-02-PLAN.md — Podman + Ollama binary bootstrap + Doctor Phase-2 check set + severity exit codes (RT-01, LLM-01)
- [x] 02-03-PLAN.md — glorbo-runtime OCI image (Containerfile + FastAPI worker + ghcr.io multi-arch CI) + Elixir Container modules (RT-02..06, LLM-02)
- [x] 02-04-PLAN.md — FileWatcher + glorbo init orchestrator + example acme company + airplane-mode proof (FS-06, LLM-05, CLI-02)

### Phase 3: CLI Agent Runtime + bwrap Isolation + Routing + Budgets
**Goal**: Markdown `agent.md` files become live, supervised CLI workers. Each agent runs as a short-lived `bwrap` sandbox that spawns the configured CLI tool (Claude Code `claude -p`, Gemini CLI `gemini`, or Codex `codex`) with the agent's workspace mounted writable, sibling/other-company paths denied, and network policy enforced via `--unshare-net`. Agents pick up tasks via inotify-driven inbox/outbox routing, respect per-agent permissions at the Elixir Router layer AND the bwrap namespace layer, honour USD budgets parsed from CLI session telemetry, and escalate approval-gated work to the Director via file mutation.
**Depends on**: Phase 2
**Requirements**: AGT-01, AGT-02, AGT-03, AGT-04, AGT-05, SEC-01, SEC-02, SEC-03, SEC-04, SEC-05, LLM-03, LLM-04
**Success Criteria** (what must be TRUE):
  1. Per-company OTP supervision tree (FileWatcher, Router, Scheduler, BudgetTracker, AuditLog, AgentSupervisor with per-agent GenServers) is running; killing an agent restarts only that agent, killing a company restarts only that company's agents, and other companies and the dashboard are unaffected.
  2. An agent wakes on each of the four triggers — new inbox file (inotify), cron-style heartbeat, `@agent` channel mention, Director request — and executes a task by spawning `bwrap <sandbox-args> <cli-tool> -p <prompt>` with stdout streamed to `agents/<name>/stdout.log`.
  3. Inbox/outbox one-way flow is enforced: an agent cannot write to another agent's inbox or to a channel file directly; the Router mediates every transfer, and writes routed to a channel the sender lacks `chat:write` for are rejected and audited.
  4. For an agent declaring `permissions: [projects:write:website-redesign]`, the `bwrap` sandbox mounts `projects/website-redesign/` read/write and `projects/other/` with `--ro-bind-try /dev/null` (denied) — verified by spawning the sandboxed CLI with a deliberate write attempt and observing `EACCES` at the kernel layer, not just an Elixir-side rejection.
  5. Per-agent network policy is enforced at `bwrap` launch time: `none` uses `--unshare-net` (no network namespace access); `api-only` uses a named network namespace with nftables allowlist; `open` shares the host network namespace. `network: none` agents cannot reach the public internet.
  6. Per-agent USD budget is tracked: Elixir parses CLI tool session telemetry after each invocation (Claude Code's JSONL session export; Gemini/Codex analogs), extracts token counts + cost, aggregates into the SQLite budget ledger, alerts fire at the configured threshold, and a hard stop refuses further task execution when the monthly cap is exceeded.
  7. A task with `requires_approval: director` frontmatter pauses before execution until the Director explicitly approves (dashboard-driven in Phase 4; file-mutation-driven here), and agent creation is rejected unless performed by the Director — agents cannot spawn agents.
  8. An agent using `provider: claude-code` (or `gemini-cli` / `codex`) executes tasks using each CLI tool's native authentication (tool-managed credentials, never copied into company directories or agent env). One provider + model per `agent.md` is enforced at parse time.
  9. Skills declared in an agent's `skills:` list are materialised into the agent workspace under `.glorbo-skills/` just before invocation, and referenced from the prompt in the form each CLI tool expects (e.g., Claude Code's skill-file loading; Gemini's system-prompt injection).
**Non-goals (deferred to a future milestone, see `.planning/deferred/container-runtime-v0.0.2/`)**:
  - Python-in-Podman agent runtime with litellm-based LLM dispatch
  - POSIX ACL enforcement (`setfacl`) for agent filesystem permissions — bwrap namespaces cover v1's needs
  - Per-agent Linux user provisioning with `/etc/subuid`-relative UID allocation
  - Offline inference via bundled Ollama — LLM-05 moves to the container runtime phase since CLI tools require their providers' cloud endpoints (an `ollama` CLI provider could be added as a follow-on, but is not in Phase 3)
**Plans**: 5 plans (Wave 0 foundations + Wave 1 parallel brain/body/gate + Wave 2 integration)
- [x] 03-01-PLAN.md — Wave 0 foundations: schemas, ACLMapper (dormant, reserved for container runtime), UidAllocator (dormant), worker skills/usage extensions, AUDIT_EVENTS.md. Executed before pivot; most artifacts reusable as-is.
- [x] 03-02-PLAN.md — Wave 1: Router + Scheduler + BudgetTracker + Budget.Ledger + llm_rates config + network_policy allowlist (AGT-02 cron/mention, AGT-03, AGT-05 Router block, SEC-01, SEC-05)
- [x] 03-03-PLAN.md — Wave 1: Agent.Parser + AgentSpec + Skills.Resolver + CLI.Adapter + 3 adapters (ClaudeCode/GeminiCli/Codex) + Dispatch + Agent.Server + AgentSupervisor + Registry (AGT-01 topology, AGT-02 triggers, AGT-04 skills, LLM-03, LLM-04)
- [x] 03-04-PLAN.md — Wave 1: TaskDefinition parser + Approvals.Gate GenServer with PubSub subscription + sentinel lifecycle + denial-to-history move (SEC-04)
- [x] 03-05-PLAN.md — Wave 2 (checkpoint): Sandbox.Bwrap + PermissionMapper + Network.Proxy (HTTPS CONNECT allowlist) + Company.Supervisor 2→6 + Watcher PubSub extension + Application Registry + Doctor bwrap check + 8 integration tests + human-verify checkpoint (AGT-01 e2e, AGT-05 e2e, SEC-02 kernel, SEC-03 kernel, full phase integration)

### Phase 4: LiveView Dashboard + Real-Time Channels
**Goal**: A Director opens `http://localhost:4000` and sees the filesystem come alive — every company, agent, task, chat message, approval request, audit event, and live stdout stream, updating in sub-second real time via inotify → PubSub → LiveView.
**Depends on**: Phase 3
**Requirements**: UI-01, UI-02, UI-03
**Plans**: 3 plans
- [ ] 04-01-PLAN.md — Wave 0 foundation: esbuild asset pipeline + CSS token scaffold + Watcher PubSub extension (stdout/wake/per-channel topics) + `Glorbo.TaskDefinition.write/2` atomic frontmatter rewrite + `GlorboWeb.StdoutStreamer` + `DynamicSupervisor` + `GlorboWeb.Actions` (post_message / set_approval / wake_agent) + `Glorbo.Config` (secret_key_base + dashboard_token) + test fixtures + `GlorboWeb.LiveCase` (UI-01, UI-02, UI-03)
- [ ] 04-02-PLAN.md — Wave 1 parallel: company-scope LiveViews (OverviewLive, CompanyLive, KanbanLive, AgentLive w/ stdout + wake, ApprovalQueueLive) + 7 components (Icon, CompanyCard, AgentCard, TaskCard, ApprovalCard, BudgetRing, StdoutTail) + kanban real-time test + approval end-to-end integration test (UI-01, UI-02, UI-03)
- [ ] 04-03-PLAN.md — Wave 1 parallel: content-scope LiveViews (ChannelLive, AuditLive, HealthLive) + global chrome (Sidebar, TabBar, HealthDot, app layout shell) + full `app.css` component fill (~500 LOC) + earmark+html_sanitize_ex markdown pipeline + `DashboardToken` plug + error templates (UI-01, UI-02, UI-03)
**Success Criteria** (what must be TRUE):
  1. `glorbo serve` starts Phoenix on `localhost:4000` and renders all seven views from DESIGN.md §9: company overview, kanban board, agent detail with live stdout tail, chat, approval queue, audit log viewer, and system health (container status, Elixir process tree, resource usage).
  2. When a file changes on disk under `~/.glorbo/companies/`, the dashboard updates in under one second without polling — verified by writing a new task markdown file and observing the kanban column repaint.
  3. Channel markdown files (`channels/*.md`) are append-only with Elixir as the sole writer; the dashboard chat UI renders them live, and a Director posting a message results in Elixir (not the browser) appending the validated entry.
  4. `@agent-name` mentions posted in a channel wake the named agent via the Router, and approval-gated tasks surfaced in the approval queue can be approved/rejected with one click, which updates the task file's frontmatter status.
**UI hint**: yes

### Phase 5: CLI Completeness + Backup/Restore Portability
**Goal**: Every CLI verb from DESIGN.md §10 works, and the portability story — `backup` on machine A, `scp` to machine B, `restore` + `doctor --fix`, everything functional — is end-to-end verified on a fresh host.
**Depends on**: Phase 4
**Requirements**: CLI-01, CLI-03
**Success Criteria** (what must be TRUE):
  1. All CLI verbs from the spec are implemented and documented: `init`, `up`, `down`, `status`, `serve`, `run`, `new company`, `new agent`, `new project`, `logs`, `doctor`, `doctor --fix`, `reindex`, `migrate`, `backup`, `restore`, `console`.
  2. `glorbo backup` produces a `tar.gz` containing `~/.glorbo/companies/`, `config.md`, and the audit log; `glorbo restore <archive>` extracts, runs `reindex`, and leaves the install in a usable state.
  3. End-to-end portability: on machine A run `glorbo down && glorbo backup`; `scp` the archive to machine B (fresh glorbo binary only); run `glorbo restore && glorbo doctor --fix && glorbo up`; a previously-running agent in a previously-existing company executes a task successfully on machine B.
  4. `glorbo console` opens an Elixir remote shell into the running release, `glorbo logs <company> [agent]` tails the correct log files, and `glorbo migrate` applies Ecto migrations in-place against an existing `glorbo.db`.
**Plans**: TBD (1-2 plans)

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Compilable Skeleton + CI Release Pipeline | 3/3 | Complete | 2026-04-15 |
| 2. Filesystem Foundation + Container Runtime + Local LLM | 4/4 | Complete | 2026-04-16 |
| 3. Agents, Routing, Kernel Permissions, Budgets | 5/5 | Complete | 2026-04-16 |
| 4. LiveView Dashboard + Real-Time Channels | 0/TBD | Not started | - |
| 5. CLI Completeness + Backup/Restore Portability | 0/TBD | Not started | - |

---
*Roadmap created: 2026-04-15 — coarse granularity, 5 phases, 38/38 v1 requirements mapped.*
*Phase 1 plans finalized: 2026-04-15 — 3 plans (01-01, 01-02, 01-03) in 3 waves; FND-01..06 fully covered.*
*Phase 1 complete: 2026-04-15 — compilable Elixir/Phoenix skeleton, `mix glorbo.doctor` CLI, Burrito single-binary release pipeline, GitHub Actions CI matrix, Cosign keyless signing. Tagged-release `cosign verify-blob` is the phase-gate manual step (pending `v0.0.1-rc1` push).*
