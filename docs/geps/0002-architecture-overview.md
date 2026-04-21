---
gep: 2
title: Glorbo Architecture Overview
author: Glorbo Maintainers <security@example.invalid>
status: Accepted
type: Informational
created: 2026-04-17
extended-by: [3, 4, 5, 6, 7, 8, 12, 21, 22, 23]
see-also: []
history:
  - date: 2026-04-17
    status: Draft
    note: Initial retrofit capturing v0.0.1/v0.0.2 architectural decisions from DESIGN.md.
  - date: 2026-04-17
    status: Accepted
    note: Approved as the architectural baseline for all subsequent subsystem GEPs.
---

# GEP-2: Glorbo Architecture Overview

## Purpose

This GEP captures the big-picture architectural decisions that shape
Glorbo — the ones every subsequent GEP will reference rather than
re-derive. It does **not** replace `DESIGN.md`; `DESIGN.md` is the
living "what is" reference, and this GEP is the "why is" companion. If
`DESIGN.md` evolves over time, this GEP stays fixed as a record of the
2026-04-17 shape of Glorbo's architecture. Material architectural
changes land as new GEPs that supersede or extend this one.

Subsequent GEPs dive into specific subsystems:

- **GEP-3** — filesystem as source of truth (the derived-data contract).
- **GEP-4** — CLI-tool agents over a custom LLM client.
- **GEP-5** — sandboxing (bwrap; no container runtime).
- **GEP-6** — Phoenix LiveView + Channels for the dashboard.
- **GEP-7** — SQLite as derived data.
- **GEP-8** — provider registry + CLI auto-detect.

Readers who want the full detail on any of the below should follow the
relevant GEP.

## What Glorbo is

Glorbo is a **self-hosted, filesystem-first, single-host agent
orchestration platform** that models real-world companies (org charts,
goals, budgets, governance) and runs AI agents as sandboxed
"employees." Everything user-facing is markdown on disk; the whole
installation is one binary plus a directory tree under `~/.glorbo/`.

It deliberately avoids:

- Cloud backends.
- Distributed systems (no Kubernetes, no message brokers, no object
  stores).
- Custom databases (SQLite only, and only as a derived index).
- A custom LLM client (CLI tools handle that).

It deliberately embraces:

- Elixir/OTP for orchestration and crash isolation.
- Linux kernel primitives (mount namespaces, network namespaces) for
  enforcement, not application code.
- Phoenix LiveView for the dashboard — no separate frontend tree.
- Markdown + JSONL for all user-authored and audit-bearing data.

## Architectural pillars

Five load-bearing ideas. Each is expanded on in a dedicated GEP (or a
relevant section of this one) but they are listed together here so the
shape is visible at a glance.

### 1. The kernel is the policy engine

Permissions declared in `agent.md` frontmatter (`resource:action:scope`)
are enforced at **two layers**:

- **Application** — the Elixir Router rejects cross-directory transfers
  that would violate the declaration.
- **Kernel** — the Linux kernel physically rejects them via `bwrap`
  mount namespaces (denied paths aren't mounted).

If an agent lacks `projects:write:foo`, the filesystem itself refuses
the write — the application check is redundant belt-and-braces. This
means a compromised or misbehaving agent cannot exfiltrate or mutate
data outside its declared permissions even if application-level checks
are bypassed.

Detailed treatment: **GEP-5** (sandboxing).

### 2. The filesystem is the source of truth

User data — companies, agents, goals, tasks, chats, audit logs — lives
as markdown and JSONL files under `~/.glorbo/companies/<slug>/`. SQLite
(`~/.glorbo/glorbo.db`) is **derived data**: `glorbo reindex` must be
able to rebuild every SQLite row from the filesystem alone. Anything
SQLite holds that isn't reconstructible from disk is an invariant
violation.

Consequences:

- Upgrades never touch `companies/`. `glorbo migrate` only rewrites the
  DB schema.
- Backup = `tar` or `git`. Restore = `tar` / `git clone` + `glorbo
  reindex`.
- Moving to a new host = `scp` the directory, `glorbo reindex`, run.
- The human is the last line of defense: they can open any file, any
  time, and understand system state without running the app.

Detailed treatment: **GEP-3** (filesystem as source of truth) and
**GEP-7** (SQLite as derived data).

### 3. Agents are wrapped CLIs, not SDK clients

Glorbo does not ship its own LLM client. Each agent is bound to a CLI
tool (`claude-code`, `gemini-cli`, `codex`, and eventually
`hermes`, `opencode`, `pi`, etc.) and Glorbo invokes that CLI as a
sandboxed subprocess. The CLI handles auth, model access, tool-use
loop, and telemetry in its own format. Glorbo handles lifecycle,
routing, permissions, budget tracking, and dashboard.

Auth lives on the host side (`~/.claude/`, `~/.gemini/`, `~/.codex/`);
Glorbo bind-mounts the auth dir read-only into the sandbox and
redirects session writes to the agent's workspace. This gives
per-agent session isolation while sharing one login per provider.

Detailed treatment: **GEP-4** (CLI-tool agents) and **GEP-8** (provider
registry).

### 4. One-way inbox/outbox flow

Messages between agents are mediated by the Elixir Router, never
written directly:

- `agents/<name>/inbox/` — write-only for Elixir, read-only for the
  agent.
- `agents/<name>/outbox/` — write-only for the agent, read-only for
  Elixir.

The Router reads an agent's outbox, validates the intended recipient
against the sender's permissions, and atomically moves the file into
the recipient's inbox. Agents have no direct filesystem path to each
other's directories — the sandbox wouldn't mount them anyway.

This invariant is enforced both in mount namespaces (agents literally
cannot see each other's inboxes) and in application logic (the Router
refuses transfers that violate permissions).

### 5. OTP supervision defines crash isolation

The supervision tree defines what "crash" means:

- Agent crash → only that agent restarts. Company unaffected.
- Company crash → only that company's agents restart. Dashboard and
  other companies unaffected.
- Dashboard crash → restarted by the top-level supervisor; companies
  and agents continue.

No process owns state that can't be rebuilt from disk. File watchers,
routers, and budget trackers are all restartable — on restart they
reread their authoritative on-disk state and resume.

## Topology

Single-host by design. One Elixir node per host, one OS process tree.
No clustering, no replicas. Multiple companies live inside the same
`glorbo` process, but each is isolated at several layers:

1. **Directory isolation** — each company is its own subtree under
   `companies/<slug>/`. No shared dirs.
2. **Sandbox isolation** — each agent is a short-lived `bwrap`
   process with only its own workspace and declared permission targets
   mounted. Sibling agents and other companies are simply not in the
   mount list.
3. **Supervision isolation** — each company is a separate
   `Glorbo.Company` supervisor subtree under `Glorbo.CompanySupervisor`.
4. **Budget isolation** — each company has its own `BudgetTracker`
   GenServer and its own rows in the shared SQLite ledger.

There is no cross-company access mechanism at any layer. A company
can't read another company's files, route messages to another
company's agents, or consume another company's budget. The single
point of shared state is SQLite, and that's purely the Director's
view — Directors see across all companies; agents never do.

## Runtime story

Glorbo runs one way, on every version that has shipped:

- Agents are `bwrap`-sandboxed subprocesses of published CLI tools
  (`claude`, `gemini`, `codex`, …). The only host dependencies are
  Elixir/OTP and `bwrap`.
- No Python on the host, no Python anywhere. No SDK-based LLM
  dispatch. No container runtime.

The two-layer enforcement model (kernel + application) holds via
bwrap mount namespaces.

**Historical note:** the pre-pivot architecture planned a
`glorbo-runtime` Podman image hosting a Python worker with `litellm`
and pinned AI SDKs. That plan was carried forward into DESIGN.md.
With GEP-4's CLI-wrapping pivot, the Python worker was no longer
needed, and the Podman tier was dropped entirely — see GEP-5 D6.
Git history around 2026-04-17 holds the detailed restoration plan
that was considered and then discarded.

## Major components (one-line tour)

| Component                          | Role                                                     |
|------------------------------------|----------------------------------------------------------|
| `Glorbo.Application`                | Top-level OTP application; starts the supervision tree.  |
| `Glorbo.Repo`                      | Ecto / SQLite. Derived index only.                       |
| `GlorboWeb.Endpoint`                | Phoenix endpoint for the dashboard + Channels.           |
| ~~`Glorbo.ContainerManager`~~       | Removed — Podman tier dropped (see GEP-5 D6).            |
| `Glorbo.CompanySupervisor`          | `DynamicSupervisor` over per-company trees.              |
| `Glorbo.Company.*` (per-company)    | FileWatcher, Router, Scheduler, BudgetTracker, AuditLog. |
| `Glorbo.Agent` (per-agent)          | GenServer owning agent lifecycle and bwrap exec.         |
| `Glorbo.CLI.Adapter.*`              | Per-CLI-tool adapter (subject to GEP-8 refactor).        |
| `Glorbo.Sandbox.Bwrap`              | `bwrap` argv builder.                                    |
| `Glorbo.Skills.Resolver`            | Materialises skills into agent workspaces.               |
| `Glorbo.Audit`, `Glorbo.Budget`     | Append-only audit log, budget ledger.                    |

Detail on any of these lives in its own module docs or a subsystem
GEP.

## Non-obvious choices (referenced from later GEPs)

Each is expanded in its own GEP. Listed here as one-line claims.

- **No distributed state.** Single-host by design. Scale is horizontal
  per user, not per installation.
- **No custom database.** SQLite is boring, stable, portable, and more
  than adequate. No Postgres cluster.
- **No custom LLM client.** Reuse upstream work via CLI tools. See
  GEP-4.
- **No Python on the host, ever.** And no Python anywhere else either
  — the pre-pivot plan for a Python agent runtime inside Podman was
  dropped (see GEP-5 D6). Adding Python deps to the Elixir side is a
  design bug.
- **No REST or gRPC API.** Dashboard is LiveView; external integration
  is "read the filesystem." See GEP-6.
- **No in-memory state that can't be rebuilt from disk.** See GEP-3,
  GEP-7.

## Decision log

### D1. Single-host over distributed

- **Decided:** Glorbo runs as a single Elixir node per host. No
  clustering.
- **Alternatives:** OTP distribution across hosts; HA replication;
  multi-tenant SaaS.
- **Why:** the product is "someone's Glorbo in their home directory,"
  not "a shared platform." Distribution adds enormous complexity
  (consensus, split-brain, network partitions) for use cases that
  aren't the target market. If a user needs more horsepower, they
  install Glorbo on a beefier machine; they don't cluster.

### D2. OTP supervision for crash isolation, not error handling

- **Decided:** lean on OTP's "let it crash + supervisor restarts"
  model. Don't rescue from errors; crash, log, supervise.
- **Alternatives:** defensive try/catch everywhere; exceptions as
  control flow; explicit circuit breakers per component.
- **Why:** OTP's strength is precisely bounded crash blast radius. An
  agent that gets into a bad state should die and be restarted, not
  hobble along in a corrupted state. The supervision tree (described
  above) is the control flow for recovery — writing it by hand in
  application code duplicates what OTP already does correctly.

### D3. Filesystem as source of truth, SQLite as derived

- **Decided:** markdown/JSONL on disk is authoritative; SQLite
  rebuildable from it.
- **Alternatives:** DB-first (everything in SQLite, files as projections
  for humans); Postgres; event sourcing to an append-only log.
- **Why:** Glorbo's philosophy is "a directory you can back up with
  tar." A DB-first design would mean users can't sensibly read or edit
  their own data without going through Glorbo. Making files
  authoritative keeps the system auditable and transportable. Detail in
  GEP-3.

### D4. Kernel-level permission enforcement, not application-level

- **Decided:** permissions declared in `agent.md` are enforced by mount
  namespaces / POSIX ACLs as well as by application checks.
- **Alternatives:** application-only checks; trust agents to stay in
  their lane; abstain entirely.
- **Why:** agents run LLM output. Application-level checks are
  bypassable by any sufficiently motivated (or confused) agent if the
  underlying filesystem allows the write. Putting the enforcement
  below the application layer closes the class of bugs where app code
  has a hole. Detail in GEP-5.

### D5. Wrap existing CLI tools instead of writing a custom LLM client

- **Decided:** v0.0.1 agents are `claude-code` / `gemini-cli` / `codex`
  subprocesses. Glorbo never calls Anthropic/OpenAI/Google APIs
  directly.
- **Alternatives:** use `litellm` or a custom SDK wrapper; hand-roll
  per-provider HTTP clients.
- **Why:** auth, rate limiting, retry logic, tool-use loops, token
  streaming, model selection, session history — every LLM provider's
  CLI already solves these. Reinventing them is wasted work, and the
  wheel spins faster than our reinvention could keep up. Cost: we're
  bound to each CLI's invocation shape and telemetry format, which is
  what GEP-8 addresses. Detail in GEP-4.

### D6. Phoenix LiveView for the dashboard, not a separate SPA

- **Decided:** the dashboard is server-rendered LiveView with Phoenix
  Channels for real-time updates.
- **Alternatives:** React/Vue/Svelte SPA over a REST/GraphQL API;
  htmx; server-rendered with htmx-style partial updates.
- **Why:** a separate SPA means a separate build, a separate dep tree,
  a separate auth story, and two moving parts instead of one. LiveView
  delivers real-time UI with one server process and ~zero JS build
  ceremony (esbuild via Hex, no npm). It fits the single-binary
  distribution story. Detail in GEP-6.

### D7. Inbox/outbox one-way flow, Router-mediated

- **Decided:** agents never write to each other's directories.
  All transfers go through the Elixir Router.
- **Alternatives:** shared scratch dirs; publish/subscribe bus;
  message broker.
- **Why:** one-way flow makes the permission model checkable — the
  Router is the single point of enforcement. A shared scratch dir
  would require per-file permission checks everywhere. A broker adds
  a moving part with no benefit at Glorbo's scale.

### D8. bwrap-only sandboxing; Podman dropped

- **Decided:** Glorbo sandboxes agents with bwrap and does not ship a
  container runtime. The originally planned Podman tier is off the
  roadmap.
- **Alternatives:** ship Podman in v0.0.3 as originally planned; keep
  it as an optional "multi-tenant deployment" mode; wait-and-see.
- **Why:** Podman's principal justification was hosting a Python
  agent runtime (`litellm` SDK dispatch). GEP-4's CLI-wrapping pivot
  eliminated the Python runtime; what remains of Podman's value (per-
  agent Linux users, bundled image, persistent per-company runtime)
  is nice-to-have but doesn't justify the maintenance cost against
  Glorbo's single-user Director threat model. Future bidirectional /
  long-running agent workflows are expected to be answered at the
  protocol layer (MCP, ACP — see GEP-9), not via a container tier.
  Full rationale in GEP-5 D6 and GEP-5 §"Why Podman was considered
  and dropped."

## Related

- `DESIGN.md` — the living "what is" architectural reference.
- `CHANGELOG.md` — what actually shipped in each release.
- Git history (pre-2026-04-17) — original `.planning/` GSD artifacts:
  PROJECT.md, ROADMAP.md, per-phase plans, and the
  `deferred/container-runtime-v0.0.2/` restoration plan (all deleted
  when the archive was retired; `git log --all --diff-filter=D --
  .planning/` finds the file list).
