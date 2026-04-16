# Phase 3: Agents, Routing, Kernel Permissions, Budgets - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-16
**Phase:** 03-agents-routing-kernel-permissions-budgets
**Mode:** `--auto` (autonomous) — all gray areas auto-resolved to recommended defaults
**Areas discussed:** Linux user provisioning, POSIX ACL reconciliation, Network policy, Router architecture, Agent wake + execution, Budget tracking, Approval gates, Skills injection, Cloud LLM provider wiring, Agent-creation restriction, Supervision tree

---

## Linux user provisioning

| Option | Description | Selected |
|--------|-------------|----------|
| Static preset UIDs | Hard-coded UID map per agent in `config.md` | |
| Per-company 100-UID block, dynamic | Each company reserves 100-UID block; agents assigned sequentially — **recommended** (deterministic + zero-config) | ✓ |
| Fully dynamic at runtime | Allocate on container start, no persistence | |
| Host-side `useradd` | Real Linux users on the host | |

**Auto-selected:** Per-company 100-UID block, in-container `/etc/passwd` overlay, tombstoned on agent removal.
**Reason:** Deterministic UIDs for debuggability; no host mutation; matches `--userns keep-id`.

---

## POSIX ACL reconciliation timing

| Option | Description | Selected |
|--------|-------------|----------|
| On every permission file change | Watcher-driven reconciliation | |
| On container start only | Idempotent reconciliation at boot — **recommended** | ✓ |
| Continuous audit loop | Periodic re-verify of ACLs on running containers | |

**Auto-selected:** Container-start reconciliation + `setfacl -b` before re-apply.
**Reason:** Permissions change rarely; container-start is sufficient and cheap.

---

## Network policy (`api-only` tier)

| Option | Description | Selected |
|--------|-------------|----------|
| `--network host` with iptables | Share host network + filter | |
| `slirp4netns` + netavark allow-list | Rootless namespace + per-container egress filter — **recommended** | ✓ |
| VPN/WireGuard per company | Tunnel all egress through a company VPN | |

**Auto-selected:** slirp4netns + netavark firewall allow-list (provider endpoints), with in-container iptables fallback.
**Reason:** Defence in depth; matches rootless trust model.

---

## Router shape

| Option | Description | Selected |
|--------|-------------|----------|
| Single global Router | One Router for all companies | |
| Per-company Router GenServer | One Router per company, supervised by Company tree — **recommended** | ✓ |
| Embedded in per-agent GenServer | No central router; each agent routes its own messages | |

**Auto-selected:** Per-company `Glorbo.Company.Router` GenServer.
**Reason:** Crash-isolation invariant; single auditable choke point per company.

---

## Routing permission denial behaviour

| Option | Description | Selected |
|--------|-------------|----------|
| Silent drop | Delete file, no notice | |
| Rejection message to sender inbox + audit | Sender sees why it was rejected, audit records it — **recommended** | ✓ |
| Kill the agent | Aggressive: permission violation = agent death | |

**Auto-selected:** Rejection notice in sender inbox + `permission.denied` audit event.
**Reason:** Debuggable + auditable; matches filesystem-first principle.

---

## Agent GenServer topology

| Option | Description | Selected |
|--------|-------------|----------|
| One GenServer per agent under DynamicSupervisor | Clean crash isolation; matches DESIGN.md §4.1 — **recommended** | ✓ |
| Single Scheduler dispatching to Tasks | No per-agent GenServer; dispatch via Task.Supervisor only | |
| Agent-pool pattern | Worker pool with dispatch queue | |

**Auto-selected:** One `Glorbo.Company.Agent` GenServer per agent; execution runs in supervised Task.
**Reason:** AGT-01 crash isolation; matches DESIGN.md §4.1.

---

## Cron heartbeat implementation

| Option | Description | Selected |
|--------|-------------|----------|
| Oban | Postgres-backed job queue (requires PG) | |
| Quantum | Elixir cron scheduler library | |
| `crontab` pure-Elixir parser + `Process.send_after` | Minimal dep, no job store — **recommended** | ✓ |
| DIY `:timer.send_interval` | No library at all | |

**Auto-selected:** `crontab` library + `Process.send_after`.
**Reason:** No Postgres; no Quantum job-store overhead; simple cron suffices for Glorbo's heartbeat frequency.

---

## Budget hard-stop enforcement point

| Option | Description | Selected |
|--------|-------------|----------|
| Kill container mid-call | Cancel the in-flight LLM call if budget exceeded during execution | |
| Pre-dispatch check | Refuse to dispatch new tasks if budget exceeded — **recommended** | ✓ |
| Post-hoc warning only | Let calls through; alert Director to refund | |

**Auto-selected:** Pre-dispatch check via `BudgetTracker.check_budget/1`.
**Reason:** Worst case is one call slightly over cap; matches litellm's "cost known after the call" shape.

---

## Approval gate mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Phoenix Channel message from dashboard | Approval is a live dashboard event | |
| SQLite row update | Approval is a DB change | |
| Task file `status: approved` edit | Approval is a file write; dashboard renders file state — **recommended** | ✓ |
| Dedicated approvals table | Separate storage for approval state | |

**Auto-selected:** Task frontmatter `status: approved` edit.
**Reason:** Filesystem-first; dashboard (Phase 4) is a render of file state; single source of truth.

---

## Skills injection mechanism

| Option | Description | Selected |
|--------|-------------|----------|
| Bind-mount skills dir into container | Worker reads skill files at runtime | |
| Elixir injects resolved skill content into task JSON — **recommended** | Worker receives ready-to-use text | ✓ |
| Python worker fetches from a skills API | Runtime HTTP call | |

**Auto-selected:** Inject resolved skills markdown into `/run` POST body (`skills_resolved:` field).
**Reason:** Simplest worker code; no new mount; preserves `network: none` mode.

---

## API key source and injection

| Option | Description | Selected |
|--------|-------------|----------|
| Env var at container start | Visible in `podman inspect` | |
| Per-agent secret file (bind-mount) | Extra mount, extra complexity | |
| Injected in `/run` POST body from `config.md` — **recommended** | Request-scope only; never in `podman inspect` | ✓ |
| External secret vault (HashiCorp/SOPS) | Runtime vault lookup | |

**Auto-selected:** Per-request body field (carries forward Phase 2 D-37).
**Reason:** Already the contract; D-38 just wires it to `config.md` lookup.

---

## Claude's Discretion

- ACL mapping table structure (Map vs behaviour module)
- Router file-routing queue internal shape
- BudgetTracker in-memory vs SQLite-direct on every check
- Scheduler's cron parsing library (strongly recommend `crontab`; alternatives acceptable)
- Whether per-agent Task.Supervisor is child of Company or agent GenServer
- Audit event key naming conventions for Phase 3 events
- `budgets` table: cents vs fractional USD (strongly recommend cents)
- Skill schema validation timing (dispatch vs commit)
- Inbox cleanup / message-lifecycle policy (TTL, archive, etc.)

## Deferred Ideas

- Agent-spawn-agent — permanently out of v1
- Mid-run budget top-ups
- Time-based permission windows
- Per-message quotas separate from USD
- Skill marketplace / cross-company skill sharing
- Router-level rate limiting
- Host-side ACLs on `~/.glorbo/` (needs multi-user trust model)
- `agents:create` permission + template bots
- Websocket stdout streaming (Phase 2 committed to file-tail)
- Per-company HTTP proxy config
