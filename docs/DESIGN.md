# Glorbo — Design Document

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted, filesystem-first agent orchestration platform built on
Elixir/Phoenix. It models companies as real organisations — with org charts,
goals, budgets, governance, and communication — and runs AI agents as employees
inside kernel-sandboxed (`bwrap`) processes. Everything is markdown. Everything
is a file.

> **Reading notes.** This document is the living architectural reference
> — it describes the *intended* state of Glorbo, not necessarily the
> state of the code at any given moment. When the two diverge, this is
> where you read what we're aiming at. For the *why* behind major
> decisions, see the corresponding **Glorbo Enhancement Proposals** in
> `docs/geps/`:
>
> - **GEP-2** — architectural overview (the big picture).
> - **GEP-3** — filesystem as source of truth.
> - **GEP-4** — CLI-tool agents (no Python, no custom LLM client).
> - **GEP-5** — bwrap sandboxing (the Podman tier once planned for
>   v0.0.2 was **dropped entirely** in GEP-5 D6 — bwrap is the only
>   isolation layer, permanently).
> - **GEP-6** — Phoenix LiveView + Channels dashboard.
> - **GEP-7** — SQLite as derived data.
> - **GEP-8** — provider registry + CLI auto-detect.
> - **GEP-9** — protocol-level integration (MCP, ACP) for future
>   bidirectional needs.
> - **GEP-10** — agent/skill templates.
> - **GEP-11** — the Zen of Glorbo.
> - **GEP-12** — no user-input atoms (Registry over named processes).
> - **GEP-13** — project-prefixed task IDs.
> - **GEP-14** — agent heartbeat semantics and `HEARTBEAT.md`.
> - **GEP-15** — ALLCAPS convention for agent-facing markdown
>   (`AGENT.md`, `SOUL.md`, `HEARTBEAT.md`).
> - **GEP-16** — agent wake + dispatch pipeline.
> - **GEP-17** — cross-OS sandbox + filesystem-watcher landscape.
> - **GEP-18** — `agentcompanies/v1` interop (placeholder).
> - **GEP-19** — director approval workflow protocol (sentinel
>   contract, `assigned_to` swap, Gate vs UI code paths).
>
> **Runtime story:** agents are CLI-tool subprocesses under `bwrap`.
> No Python on the host. No container runtime. No Ollama binary
> bundled. See GEP-4 and GEP-5.

---

## 1  Philosophy

> *You already know what it does. Your ploobis has never been cleaner.*

**It's just a directory.**  The entire system lives under `~/.glorbo/`. Deploy by
copying a binary.  Back up with `tar`.  Move between machines with `scp`.
Version-control your company with `git`.

**The kernel is the policy engine.** Permissions are not enforced by
application code; they are enforced by the kernel via bwrap mount
namespaces — denied paths aren't mounted, allowed paths are `--ro-bind`
or `--bind`. An agent that lacks `projects:write:foo` literally cannot
write to that directory. `ls -la` is your audit tool.

**Markdown is the source of truth.**  Agent definitions, goals, tasks,
permissions, chat — all human-readable markdown with YAML frontmatter.  SQLite
exists only as a derived, rebuildable index for fast dashboard queries.

**Stability over features.** Elixir/OTP supervision trees mean a crashing
agent restarts automatically. Sandbox isolation (bwrap) means a
misbehaving agent cannot damage the host or other companies. There is
no message broker, no object store, no cache layer. The fewer moving
parts, the fewer things break.

**Paperclip with taste.**  Glorbo adds what Paperclip deliberately omitted: the
ability to chat with agents in real time, a proper LiveView dashboard, and
rock-solid stability through OTP.  It replaces Node.js and embedded Postgres
with Elixir and the filesystem.

> **Runtime scope — agents are CLI-first, permanently.** Agents are
> sandboxed CLI tools (Claude Code, Gemini CLI, Codex, and OSS
> alternatives — see GEP-8's provider registry) wrapped in `bwrap`
> (bubblewrap) mount- and network-namespace isolation. "No Python
> anywhere" is load-bearing: Glorbo needs no Python on the host, and
> there is no container runtime under which Python (or anything else)
> is launched. The pre-pivot Python-in-Podman agent runtime with
> `litellm` dispatch and POSIX ACL enforcement was dropped entirely in
> 2026-04-17 (GEP-5 D6).

---

## 2  Concepts

> *The dinglebop is what holds the whole chumble together. Everyone knows that.*

### 2.1  The Director

The human operator is called the **Director**.  The Director is the governing
authority — they hire agents, set company missions, approve budgets, and
intervene when needed.  A CEO agent works *for* the Director, not the other way
round.  The Director is not an employee.  They are the owner.

In the dashboard, the Director sees everything, approves escalations, and can
chat with any agent directly.  In the filesystem, the Director is the host user
who owns `~/.glorbo/` and runs the Glorbo binary.

### 2.2  Company

A Company is an isolated unit of work with its own mission, agents,
projects, and budget. Each Company has its own OTP supervision tree
(file-watcher, router, scheduler, budget tracker, approval gate); each
agent wake inside a Company is a fresh `bwrap` sandbox bind-mounting
only that Company's directory. Multiple Companies can run
simultaneously on the same host, fully isolated from each other.

### 2.3  Agent

An Agent is a defined role within a Company. It has an identity (name,
role, backstory), permissions, a budget, and a provider/model
configuration. Agents are defined in markdown. An agent materialises at
wake-time as a short-lived `bwrap` sandbox wrapping a CLI tool
invocation — Claude Code, Gemini CLI, Codex, or any provider declared
in the registry (GEP-8). There is no long-lived agent process between
wakes.

Agents do not run continuously. They wake on events: a new task in
their inbox, a scheduled heartbeat, a message in a channel they watch,
or a direct request from the Director.

### 2.4  Project

A Project is a collection of related work under a Company.  It contains tasks,
artifacts, and its own goal hierarchy.  Projects are directories with a
`project.md` definition.

### 2.5  Task

A Task is a unit of work assigned to an Agent.  Tasks are markdown files with
status, priority, assignee, and a thread of updates.  Tasks are the primary
coordination mechanism — the kanban board of the Company.

### 2.6  Channel

A Channel is a communication space — a single append-only markdown file where
Agents and the Director exchange messages.  Channels can be public (all company
agents) or scoped (engineering, ceo-engineer-dm).

### 2.7  Skill

A Skill is a reusable capability that can be injected into an Agent at runtime.
Skills are markdown files describing the capability, any tool requirements, and
prompt instructions.

---

## 3  Directory Structure

> *A schlami organises the blamfs into nested hizzard compartments. This is standard.*

```
~/.glorbo/
├── glorbo                          # Elixir release binary (self-contained BEAM)
├── config.md                       # Global settings (host, port, dashboard token)
├── providers.toml                  # (optional) user-declared CLI providers (GEP-8)
├── glorbo.db                       # SQLite index (rebuildable, disposable)
│
├── state/
│   ├── .erl_cookie                 # Release cookie (mode 0600) for `glorbo console`
│   └── glorbo.pid                  # Daemon pidfile (mode 0600)
│
├── audit/
│   └── _system/
│       └── 2026-04.jsonl           # System-level audit events (init, backup, …)
│
├── companies/
│   └── acme/
│       ├── company.md              # Mission, budget, global settings
│       │
│       ├── agents/
│       │   ├── ceo/
│       │   │   ├── agent.md        # Identity, role, permissions, model config
│       │   │   ├── inbox/          # Incoming tasks and messages (Elixir writes)
│       │   │   ├── outbox/         # Agent writes here; Elixir routes
│       │   │   ├── workspace/      # Bind-mounted into sandbox; agent works here
│       │   │   ├── stdout.log      # Sandboxed CLI stdout (tailed by UI)
│       │   │   └── history/        # Consolidated old inbox/outbox
│       │   │
│       │   └── engineer/
│       │       ├── agent.md
│       │       ├── inbox/
│       │       ├── outbox/
│       │       ├── workspace/
│       │       ├── stdout.log
│       │       └── history/
│       │
│       ├── channels/
│       │   ├── general.md          # Append-only chat log
│       │   ├── engineering.md
│       │   └── director-ceo-dm.md  # Director ↔ CEO direct messages
│       │
│       ├── projects/
│       │   └── website-redesign/
│       │       ├── project.md      # Goal, description, status
│       │       ├── tasks/
│       │       │   ├── 001-design-landing.md
│       │       │   └── 002-implement-nav.md
│       │       └── artifacts/      # Deliverables, outputs
│       │
│       ├── goals/
│       │   └── q3-2026.md          # High-level objective, broken into projects
│       │
│       ├── skills/
│       │   ├── web-search.md
│       │   └── code-review.md
│       │
│       ├── alerts/
│       │   └── engineer-budget.md  # Budget-threshold alert files
│       │
│       └── audit/
│           └── 2026-04.jsonl       # Append-only audit events
│
└── logs/
    └── glorbo.log                  # Elixir application log
```

The pre-pivot tree had additional `bin/`, `models/`, `containers/`
directories (static Podman + Ollama + the `glorbo-runtime` Python
image). Those were dropped with the container tier in GEP-5 D6 — agents
run directly as `bwrap`-sandboxed CLI subprocesses and Glorbo doesn't
bundle a model host.

### Key Invariants

- `companies/` is **user data**.  Glorbo never deletes or modifies files here
  without explicit Director action.  Upgrades never touch this tree.
- `glorbo.db` is **derived data**.  It can be deleted and rebuilt at any time
  with `glorbo reindex`.
- The `glorbo` binary is **stateless**.  Replace it to upgrade.  Run
  `glorbo migrate` to apply any schema changes to the SQLite index.
- Agent `inbox/` directories are **write-only for Elixir**, read-only for the
  agent.  Agent `outbox/` directories are **write-only for the agent**, read-only
  for Elixir.  This enforces one-way flow.

---

## 4  Technology Stack

> *The grumbo is made of Elixir. The hizzards are CLI tools, hermetically schleemed inside bwrap. No fleeb on the host, no fleeb in a pod — no fleeb anywhere. That's how you keep the ploobis clean.*

### 4.1  Elixir/Phoenix — The Brain

The core process.  Runs on the host (not in a container).

| Concern              | Solution                                                   |
|----------------------|------------------------------------------------------------|
| Orchestration        | OTP GenServers, one per agent lifecycle                    |
| Scheduling           | Per-company `Scheduler` (agent heartbeats) + `TaskScheduler` (`schedule:` on task frontmatter fires dispatches via assignee inbox) — both built on `crontab` |
| File watching        | `file_system` hex package (inotify)                        |
| Dashboard            | Phoenix LiveView                                           |
| Agent chat / streaming | Phoenix Channels + PubSub                                |
| Database             | Ecto + `ecto_sqlite3` (WAL mode)                           |
| Provider registry    | `Glorbo.CLI.Registry` Agent (GEP-8)                        |
| Agent sandbox        | `bwrap` argv build + `Port.open` per invocation            |
| Release packaging    | `mix release` + Burrito (single binary, bundled ERTS)      |

**Supervision tree (sketch):**

```
Glorbo.Application
├── Glorbo.Repo                          # SQLite / Ecto (WAL mode)
├── Phoenix.PubSub (Glorbo.PubSub)
├── Finch (Glorbo.Finch)
├── GlorboWeb.Telemetry
├── Glorbo.Agent.Registry                # :via registry for per-agent pids
├── Glorbo.CLI.Registry                  # Provider snapshot (GEP-8)
├── Glorbo.CompanySupervisor             # DynamicSupervisor
│   └── Glorbo.Company.Supervisor (acme) # Per-company supervisor
│       ├── Glorbo.Company.FileWatcher   # inotify on company dir
│       ├── Glorbo.Company.Router        # Routes outbox → inbox/channels
│       ├── Glorbo.Company.Scheduler     # Per-agent heartbeats (AGENT.md `heartbeat:` cron)
│       ├── Glorbo.Company.TaskScheduler # Per-task `schedule:` dispatch firing
│       ├── Glorbo.Company.BudgetTracker # Token/cost accounting
│       ├── Glorbo.Approvals.Gate        # Approval-queue gate
│       ├── Glorbo.Network.Proxy         # Hostname-allowlist HTTPS proxy
│       │                                # (only if any agent has network: proxy)
│       ├── Task.Supervisor              # Per-agent dispatch tasks
│       └── Glorbo.Agent.Server (ceo)    # One per agent; idle between wakes;
│                                        # wakes → bwrap+CLI invocation via
│                                        # Glorbo.CLI.Dispatcher
├── GlorboWeb.StdoutStreamer.Supervisor  # LV stdout tail streamers
└── GlorboWeb.Endpoint                   # Phoenix
```

If an Agent process crashes, only that Agent restarts.  If a Company crashes,
only that Company's agents restart.  The dashboard and other companies are
unaffected.

### 4.2  Provider Runtimes — The Hands

Python never runs on the host. Glorbo spawns either existing terminal
AI tools (Claude Code, Gemini CLI, Codex, and any other CLI provider
registered via GEP-8) or its own `glorbo harness` native-provider
subcommand as short-lived sandboxed processes. External CLIs keep their
own model access, auth, and tool-use loop; the native harness speaks an
OpenAI-compatible HTTP API from inside the same bwrap tree.

For each agent wake, Elixir:

1. Materialises skills and the task prompt into the agent's workspace
   (`.glorbo-skills/`, `.glorbo-run/<task-id>/task-prompt.md`).
2. Resolves the agent's `provider:` through `Glorbo.CLI.Registry` to a
   `Provider` struct: either a CLI binary + argv template, or a native
   endpoint + auth contract, plus env overrides, reply-path template,
   and an optional usage-parser binding.
3. Builds a `bwrap` argv from the agent's `permissions:` and `network:`
   declarations (see §4.4).
4. Calls `Glorbo.CLI.Dispatcher.invoke/3`, which expands the provider's
   argv/env templates, sets `$GLORBO_REPLY_PATH` to a unique per-
   invocation file path, spawns `bwrap <sandbox-args> <provider-runtime> …` via
   `Port.open`, pipes the task prompt on stdin, tails stdout to
   `agents/<name>/stdout.log`.
5. On exit, reads the reply file at `$GLORBO_REPLY_PATH` (see §4.2.1),
   runs the bound usage-parser for token/cost telemetry, moves outbox
   files through the Router, and cleans up per-invocation scratch.

The provider runtime is trusted, but Glorbo still does not run an
in-process SDK client. CLI providers manage their own credentials
(Claude Code's login, `gcloud`/`GEMINI_API_KEY`, `OPENAI_API_KEY`);
native providers read `~/.local/etc/glorbo/credentials/<provider>.toml`
via a per-dispatch bind at `/creds/provider.toml`. In all cases the
company directory sees no API keys. Complex orchestration logic lives in
Elixir; the runtime's job is: receive a prompt on stdin, do the work
inside its sandbox view of the workspace, write its final answer to
`$GLORBO_REPLY_PATH`, exit.

#### 4.2.1  Reply-file contract (GEP-8 D1)

Every invocation ends with Glorbo reading a unique per-invocation file
at the path exported in `$GLORBO_REPLY_PATH`. The contract is
deliberately strict:

- **Missing file** → `:reply_file_missing` (the agent produced nothing).
- **Empty file** → `:reply_file_empty` (the agent wrote 0 bytes).
- **File > `reply_max_bytes`** (default 1 MiB) → `:reply_file_too_large`.
- **Well-formed, non-empty, under the cap** → success; contents surface
  as the agent's answer in the dashboard and audit log.

The scaffolder injects this contract into every new `agent.md` system
prompt so new agents aren't born broken. Agents upgrading from
pre-GEP-8 must edit their system prompts to add the instruction.

### 4.3  LLM Providers

Provider and model are configured per agent in `agent.md`. Exactly one
provider + one model per agent — no multi-model routing per agent.
Different agents in the same company can use different providers: a
researcher on Claude Code, an engineer on Codex, a copywriter on Gemini.

Providers are config-driven, not code-driven (GEP-8 D6). Each provider
is a TOML entry declaring:

- Its binary name (PATH) or absolute path
- An argv template and prompt delivery mode
- An env-var override block (e.g. `CLAUDE_CONFIG_DIR`, `CODEX_HOME`)
- The reply contract (dir + filename template + size cap)
- An optional usage-parser binding (for budget tracking)
- Optional named path transforms (e.g. Claude's `/`→`-` workspace
  encoding)
- A version probe flag + regex (opt-in for user-declared entries)

Built-in providers ship under `priv/providers/*.toml`. User-declared
providers drop in at `~/.glorbo/providers.toml`. `Glorbo.CLI.Registry`
loads both at boot, PATH-detects CLI binaries, classifies native
providers, and caches the snapshot. The `/providers` LiveView surfaces
the current state; `glorbo doctor --probe` triggers CLI version probes.

**Shipped providers:**

| `provider:`    | Kind     | Runtime            | Auth source                                        | Usage tracked? |
|----------------|----------|--------------------|----------------------------------------------------|----------------|
| `claude-code`  | CLI      | `claude`           | Claude Code's own login (`~/.claude/`)             | Yes (JSONL)    |
| `codex`        | CLI      | `codex`            | Codex CLI's own auth (`~/.codex/`)                 | Yes (JSONL)    |
| `gemini-cli`   | CLI      | `gemini`           | `GEMINI_API_KEY` or `gcloud` ADC                   | Yes (stdout)   |
| `hermes`       | CLI      | `hermes`           | Whatever hermes is configured against              | No             |
| `opencode`     | CLI      | `opencode`         | Whatever opencode is configured against            | No             |
| `pi`           | CLI      | `pi`               | Local (typically offline)                          | No             |
| `openai`       | Native   | `glorbo harness`   | `~/.local/etc/glorbo/credentials/openai.toml`      | Yes (JSON)     |
| `openrouter`   | Native   | `glorbo harness`   | `~/.local/etc/glorbo/credentials/openrouter.toml`  | Yes (JSON)     |

Untracked providers require the agent to opt in via
`allow_untracked_budget: true` in its `agent.md` — dispatch refuses
otherwise (GEP-8 D15). Local-first offline operation is supported out
of the box through `pi` and whatever other local-only CLIs the Director
installs; adding a new local provider is a TOML file, not an Elixir
module.

Glorbo never stores provider secrets in `~/.glorbo/`. CLI-tool
credentials stay in the user's home directory and are bind-mounted
read-only into the sandbox if the agent's provider requires them.
Native-provider credentials live in
`~/.local/etc/glorbo/credentials/<provider>.toml` and are also
bind-mounted read-only. The company directory holds no secrets.
`~/.glorbo/config.md` stores dashboard settings (bind address,
dashboard token) — not provider credentials.

### 4.4  bwrap — The Kernel Guard

[`bwrap`](https://github.com/containers/bubblewrap) (bubblewrap) is the
kernel-layer isolator. Every CLI-tool invocation runs inside a fresh
bwrap process tree that dies with its parent. The sandbox is built
from the agent's `permissions:` and `network:` declarations — no
standing container, no long-lived namespace, no privileged daemon.

> **Historical note — Podman tier dropped.** An earlier plan had Podman
> containers as a second isolation tier for a Python agent runtime.
> That tier was dropped entirely in GEP-5 D6 (2026-04-17) along with
> the Python runtime itself. bwrap is the only isolation layer, and
> it's permanent.

**Base sandbox flags (every invocation):**

```
--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid
--unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL
--proc /proc --dev /dev --tmpfs /tmp
```

**Filesystem mounts (derived per agent):**

```
--ro-bind /usr /usr   --ro-bind /bin /bin   --ro-bind /lib /lib
--ro-bind /lib64 /lib64   --ro-bind /etc /etc        # tool availability
--bind  <co>/agents/<me>/workspace /workspace         # read/write: self
--bind  <co>/agents/<me>/outbox    /outbox            # write-only: self
--ro-bind <co>/agents/<me>/inbox   /inbox             # read-only: self
# per-permission binds (see §7.2):
--ro-bind <co>/projects              /projects                 # projects:read:*
--bind    <co>/projects/<name>       /projects/<name>          # projects:write:<name>
--ro-bind <co>/channels              /channels                 # chat:read:*
# everything else in <co>/ is NOT mounted — invisible by construction
```

**Network policy (enforced at bwrap launch):**

- `network: none` (default) — `--unshare-net`: no network namespace access,
  kernel-enforced.
- `network: proxy` — shared netns + `HTTP_PROXY`/`HTTPS_PROXY`
  pointed at a Glorbo-managed HTTPS CONNECT allowlist proxy. Currently
  advisory (a determined agent could ignore the env vars); a dedicated
  netns + `nftables` hardening iteration is planned to make the
  allowlist kernel-enforced.
- `network: open` — host netns inherited (no `--unshare-net`). Explicit opt-in.

Sibling agents and other companies are **not mounted** — company
isolation is therefore absolute by construction: there is no path
inside the sandbox that could reach another company's data.

**Planned hardening (GEP-31, Draft):** `network: proxy` currently
inherits the host netns plus a `HTTPS_PROXY` env var pointing at
the per-company hostname-allowlist proxy. This is advisory — a
determined agent could ignore the env vars. GEP-31 will move
`proxy` agents into a per-dispatch netns with `pasta` forwarding
only the proxy port, making the allowlist kernel-enforced like
`none` already is.

Until that ships, a missing `network:` field in AGENT.md defaults
to `:none` (kernel-enforced) rather than `:proxy` (advisory) —
see threatmodel wave-3 M16. Templates that legitimately need
egress (CLI providers, editor agents) declare `network: proxy`
explicitly.

### 4.5  SQLite — The Index

SQLite stores only derived, queryable data:

- Task index (status, assignee, project, due date, timestamps)
- Budget ledger (agent, tokens used, cost, timestamp)
- Agent status (last heartbeat, current state, active task)
- Audit event index (for dashboard search/filter)
- Channel message index (for search)

**Rebuild contract:** `glorbo reindex` walks the `companies/` tree, parses all
markdown frontmatter and JSONL audit logs, and fully reconstructs the database.
The database file can be deleted at any time without data loss.

---

## 5  Agent Lifecycle

> *First the dinglebop schleems. Then it chumbles. Then it sleeps. If the grumbo crashes, another schlami picks it right back up. That's OTP, baby.*

### 5.1  Definition

An agent is defined by its `agent.md` file:

```markdown
---
name: Engineer
role: Software Engineer
reports_to: cto
provider: claude-code              # any name registered in the provider registry
model: claude-sonnet-4-5           # provider-specific
budget:
  monthly_usd: 50.00
  alert_at_pct: 80
heartbeat: "*/30 * * * *"          # Check inbox every 30 minutes
network: proxy
# Set to true only when routing through a provider whose
# usage_parser = "none" (hermes, opencode, pi). Default false — dispatch
# refuses an untracked provider without this opt-in (GEP-8 D15).
allow_untracked_budget: false
skills:
  - code-review
  - web-search
permissions:
  - projects:read:*
  - projects:write:website-redesign
  - tasks:create:website-redesign
  - tasks:update:website-redesign
  - agents:list
  - agents:message:cto
  - chat:write:engineering
  - chat:read:*
  - proposals:write:*          # Can create hiring/budget/project proposals
  - tools:execute:code-runner
  - budget:read:self
---

## System Prompt

You are a Software Engineer at {{ company.name }}. Your mission is
aligned with the company goal: {{ company.mission }}.

You report to {{ reports_to.name }} ({{ reports_to.role }}).

When you receive a task:
1. Acknowledge it by updating the task status to `in-progress`.
2. Do the work in your workspace.
3. Write deliverables to the project artifacts folder.
4. Update the task status to `review` and notify your manager.
5. If blocked, escalate via chat or create a sub-task.

## Reply contract (required)

When you finish, write your final answer to `$GLORBO_REPLY_PATH`:

```sh
echo "Done — here's the summary..." > "$GLORBO_REPLY_PATH"
```

Glorbo reads this file on your exit. Missing or empty = invocation
failure. (GEP-8 §4.2.1.)

{{ skills }}
```

### 5.2  Waking

Agents wake in response to:

| Trigger            | Mechanism                                          |
|--------------------|----------------------------------------------------|
| New inbox item     | inotify on `agents/<name>/inbox/` → GenServer call |
| Heartbeat schedule | Elixir `:timer` based on cron expression           |
| Director request   | Dashboard action → GenServer call                  |
| Channel mention    | Elixir Router detects `@agent-name` in message     |

**Heartbeat with empty inbox.** When a heartbeat fires and the inbox
scanner finds no actionable file, the agent still dispatches. The
task body is empty and the system prompt carries the agent's
`HEARTBEAT.md` checklist — this lets heartbeat-only agents (like a
CEO on a `*/5 * * * *` cron) run their tick-by-tick grooming loop even
when no one has assigned them work.

### 5.3  Execution

The bwrap + CLI pipeline (GEP-4, GEP-8):

1. **Elixir** prepares a task context: triggering event, agent identity,
   project/goal references, skill list.
2. **Elixir** composes the system prompt from three contract files:
   `AGENT.md` (role + permissions), `SOUL.md` (voice / character),
   and `HEARTBEAT.md` (tick-by-tick checklist). The prompt is
   materialised onto disk inside the agent's workspace as
   `.glorbo-run/<task-id>/task-prompt.md`, alongside
   `.glorbo-skills/*.md` (the named skills, copied from
   `~/.glorbo/companies/<co>/skills/`).
3. **`Glorbo.Agent.Dispatch`** resolves `agent.md`'s `provider:` through
   `Glorbo.CLI.Registry.get/1` to a `Provider` struct (see §4.3). If
   the provider's `usage_parser = "none"` and the agent lacks
   `allow_untracked_budget: true`, dispatch refuses here (GEP-8 D15).
4. **`Glorbo.CLI.Dispatcher.invoke/3`** expands the provider's argv and
   env templates with `{model}`, `{workspace}`, `{timestamp}`,
   `{invocation_id}`, and named path transforms. It prepares
   `$GLORBO_REPLY_PATH` as a unique per-invocation file path under
   `agents/<name>/.glorbo/outbox/`.
5. **Elixir** builds a `bwrap` argv from `permissions:` + `network:`
   (see §4.4, §7.2) and spawns `bwrap <sandbox-args> <cli-tool> …` via
   `Port.open`, with the task prompt piped on stdin, the agent's
   workspace as `cwd`, and stdout tailed to `agents/<name>/stdout.log`.
6. **The CLI tool** runs inside the sandbox, reads `.glorbo-skills/` on
   demand, does its tool-use loop, writes results into the workspace,
   and writes its final reply to `$GLORBO_REPLY_PATH`.
7. **The CLI tool** exits. The Dispatcher reads `$GLORBO_REPLY_PATH`
   (enforcing size cap and non-emptiness; see §4.2.1), invokes the
   provider's bound usage-parser, records the result in the budget
   ledger, removes `.glorbo-run/` + `.glorbo-skills/`, reads the
   outbox, routes messages, emits `agent.complete` to the audit log,
   and updates the SQLite index.

### 5.4  Sleeping

After execution, the agent GenServer remains alive but idle. It holds
minimal state: the agent's name, current status, and a reference to its
file paths. It consumes negligible memory. The `bwrap` process tree has
already exited — there is literally nothing left running between wakes.

---

## 6  Communication

> *The blamfs rub against the chumble. That's how messages get delivered. Don't overthink it.*

### 6.1  Inbox / Outbox

The primary communication channel.  Every message between agents or between the
Director and an agent follows the same pattern:

1. Sender writes a markdown file to their own `outbox/`.
2. Elixir's `FileWatcher` detects the new file.
3. Elixir's `Router` reads the file, checks sender permissions.
4. If permitted, Elixir copies the file to the recipient's `inbox/` (or appends
   to a channel file).
5. If the recipient agent has an inotify trigger, it wakes.
6. Original file in `outbox/` is moved to `history/`.

**Message format:**

```markdown
---
id: msg-20260415-102300-a1b2c3
from: ceo
to: engineer                        # or channel:engineering
timestamp: 2026-04-15T10:23:00Z
type: task-assignment                # message | task-assignment | escalation
references: projects/website-redesign/tasks/001-design-landing.md
---

Please start on the landing page wireframe.  Priority is high — the Director
wants to review by Friday.
```

### 6.2  Channels

Channels are append-only markdown files.  Elixir is the only writer (it appends
validated, permission-checked messages).  Agents read channels that their
permissions allow.

```markdown
# engineering

## 2026-04-15T10:23:00Z | CEO
@Engineer the landing page needs to be done by Friday.
Priority: high

## 2026-04-15T10:23:45Z | Engineer
Acknowledged. I'll start with the wireframe today.

## 2026-04-15T10:24:01Z | System
Task created: `projects/website-redesign/tasks/003-wireframe.md`
Assigned to: Engineer
```

Phoenix LiveView tails these files for real-time display.  The dashboard
renders them as chat UIs.  But they're always just files underneath.

### 6.3  Stdout Streaming

Each agent's sandboxed CLI stdout (`bwrap <…> claude …`, `bwrap <…>
gemini …`, etc.) is written to `agents/<name>/stdout.log`. Elixir's
`FileWatcher` tails this file and pushes lines to the LiveView
dashboard via PubSub. The Director can watch any agent's live output.

This is **read-only observation** — the Director cannot write to the agent's
stdin.  Interaction happens through the inbox/chat mechanism, not through
terminal control.

---

## 7  Permissions & Isolation

> *You wouldn't let an unschleemed hizzard near your ploobis. Same principle.*

### 7.1  Declarative Permissions

Permissions are declared in `agent.md` frontmatter using a resource:action:scope
syntax:

```
resource:action:scope
```

**Resources:** `projects`, `tasks`, `agents`, `chat`, `channels`, `tools`,
`budget`, `goals`, `skills`, `company`

**Actions:** `read`, `write`, `create`, `update`, `delete`, `list`, `execute`,
`message`

**Scopes:** `*` (all within company), a specific name, or `self`

**Examples:**

```yaml
permissions:
  - projects:read:*                    # Can read all projects
  - projects:write:website-redesign    # Can write only to this project
  - tasks:create:website-redesign      # Can create tasks in this project
  - agents:message:cto                 # Can message the CTO
  - agents:message:engineer            # Can message the Engineer
  - chat:write:engineering             # Can write to #engineering
  - chat:read:*                        # Can read all channels
  - tools:execute:code-runner          # Can use the code-runner tool
  - tools:execute:web-search           # Can use web search
  - budget:read:self                   # Can see own budget usage
  - company:read                       # Can read company mission/goals
```

### 7.2  Enforcement — Two Layers

**Layer 1: Application (Elixir Router)**

When Elixir routes a message or task, it checks the sender's permissions against
the action.  If an agent writes to its outbox addressed to a channel it lacks
`chat:write` for, Elixir rejects the message and logs the attempt.

**Layer 2: Kernel (bwrap mount + network namespaces)**

At each agent wake, `Glorbo.Sandbox.PermissionMapper` converts the
agent's `permissions:` list into a `bwrap` argv. What the agent cannot
see, it cannot touch — and what bwrap mounts read-only, the kernel will
refuse to write:

```
permissions:
  - projects:read:*                          → --ro-bind <co>/projects /projects
  - projects:write:website-redesign          → --bind    <co>/projects/website-redesign /projects/website-redesign
  - chat:read:*                              → --ro-bind <co>/channels /channels
  - proposals:write:*                        → --bind    <co>/proposals /proposals
  # (no agents:read:ceo)                     → <co>/agents/ceo NOT mounted — invisible
```

`network:` declarations map to `--unshare-net` (none), a shared netns +
HTTPS CONNECT allowlist proxy env (proxy), or inherited host netns
(open). A write attempt into `/projects/other-project` from inside the
sandboxed CLI fails with `EACCES` at the kernel — not at the Elixir
layer.

Defence in depth: the Router says no, and if the Router is wrong, the
kernel says no.

### 7.3  Company Isolation

Agents in Company A are spawned inside a `bwrap` sandbox whose mount
set contains only subpaths of Company A's directory; Company B's
directory is never mounted and therefore not reachable from any path
inside the sandbox. There is no mechanism — at any layer — for an
agent in Company A to access Company B's data.

---

## 8  Budget & Governance

> *You gotta keep count of the fleeb juice or your dinglebop runs dry. Then nobody's chumbling anything.*

### 8.1  Budget Tracking

Each agent has a monthly budget declared in `agent.md`. Each provider
entry in the registry binds to a named usage-parser (GEP-8 D6) whose
output shape is `%{prompt_tokens, completion_tokens, model}`. After
every invocation, Elixir runs the bound parser and aggregates the
result into the SQLite budget ledger:

| Provider       | Parser           | Telemetry source                                     |
|----------------|------------------|------------------------------------------------------|
| `claude-code`  | `claude_jsonl`   | `$CLAUDE_CONFIG_DIR/projects/<encoded>/*.jsonl`      |
| `codex`        | `codex_jsonl`    | `$CODEX_HOME/sessions/**/rollout-*.jsonl`            |
| `gemini-cli`   | `gemini_stdout`  | gemini's `--output-format json` stdout blob          |
| `openai` / `openrouter` | `native_v1` | `$GLORBO_USAGE_PATH` JSON emitted by `glorbo harness` |
| `hermes`/`opencode`/`pi` | `none` | (no parser — untracked; agent must opt in)        |

Cost in USD is computed by Elixir via a per-model rate table
(`config/llm_rates.exs`) — CLI tools don't always report dollar cost,
so Glorbo owns the mapping. The ledger shape is one row per
`{company, agent, year_month}` with atomic increment on invocation.

Pre-dispatch, `BudgetTracker.check_budget/1` returns `:ok | {:alert,
used, cap} | {:stop, used, cap}`. `:alert` fires a dashboard
notification and writes `alerts/<agent>-budget.md`. `:stop` aborts the
wake, writes a rejection to the agent's inbox, and emits a
`budget.hard_stop` audit event until the Director intervenes or a new
month begins. The `alerts_fired` MapSet is rehydrated from the alerts
directory on BudgetTracker restart, so a crashing tracker doesn't
re-fire alerts it's already emitted.

Agents routing through an untracked provider
(`usage_parser = "none"`) must opt in via `allow_untracked_budget:
true` in their `agent.md` (GEP-8 D15). The tracker records zeros for
these invocations; making the opt-in visible in `agent.md` means the
Director can grep for it.

### 8.2  Approval Gates

Tasks can require Director approval before execution.  This is declared in the task
frontmatter:

```markdown
---
title: Deploy to production
assignee: engineer
status: pending-approval
requires_approval: director
---
```

When an agent picks up a task with `requires_approval`, it pauses and notifies
the Director.  The Director approves via the dashboard (which updates the task file's
status to `approved`).  The agent wakes and proceeds.

### 8.3  Audit Log

Every significant action is appended to `audit/YYYY-MM.jsonl`:

```json
{"ts":"2026-04-15T10:23:00Z","actor":"ceo","action":"task.create","target":"projects/website-redesign/tasks/003","detail":"Wireframe landing page"}
{"ts":"2026-04-15T10:24:01Z","actor":"system","action":"message.route","from":"ceo","to":"engineer","msg_id":"msg-20260415-102300-a1b2c3"}
{"ts":"2026-04-15T10:30:00Z","actor":"engineer","action":"budget.usage","tokens":1523,"cost_usd":0.04}
```

Append-only.  Never modified.  Never deleted.  Indexed into SQLite for dashboard
queries.

---

## 9  Dashboard (Phoenix LiveView)

> *It's like looking at all your blamfs at once. Real-time. Full chumble visibility.*

The dashboard is served by Phoenix on a local port (default: `localhost:4000`).
It is optional — Glorbo runs headless without it.  The dashboard is for the
Director only.

### Key Views

- **Company overview:** Agent statuses, active tasks, budget burn, recent
  activity.
- **Kanban board:** Tasks across projects, drag-and-drop status updates,
  filterable by agent/project/priority.
- **Agent detail:** Agent config, current task, budget usage, live stdout
  stream, inbox/outbox history.
- **Chat:** Real-time channel view. Director can read all channels, post
  to any channel, DM any agent.
- **Approval queue:** Pending approval requests with one-click approve/reject.
- **Audit log:** Searchable, filterable event history.
- **System health:** Host prerequisite checks, resource usage, Elixir
  process tree.
- **Providers:** Provider registry status (GEP-8). Every declared
  provider with routable / untracked / not-installed badge, resolved
  PATH, version (after probe), parser binding, and `source`
  (`builtin` vs `user`). Refresh + version-probe buttons.

### Real-time Updates

LiveView subscribes to PubSub topics per company.  File changes detected by
inotify trigger PubSub broadcasts.  The dashboard updates without polling.

---

## 10  CLI

> *Pre-schleemed. Zero hizzard leakage. One command.*

```
glorbo init [--force]           # First-time setup: create ~/.glorbo/,
     [--no-example]              # verify deps via `glorbo doctor`,
                                # optionally scaffold example company (acme).

glorbo up                       # Start detached daemon (dashboard +
                                # supervision tree). Idempotent via pidfile.
glorbo down                     # Graceful SIGTERM → 10s grace → SIGKILL.
glorbo status                   # Pidfile state + uptime.
glorbo serve                    # Foreground supervision (for systemd).
glorbo run <script>             # One-shot script execution.

glorbo new company <slug>       # Scaffold a new company directory.
glorbo new agent <co>/<slug>    # Scaffold a new agent.md with defaults +
                                # reply-contract system prompt (GEP-8).
glorbo new project <co>/<slug>  # Scaffold a new project.

glorbo reindex                  # Rebuild SQLite from filesystem.
glorbo migrate                  # Run pending Ecto migrations.
glorbo doctor [--json] [--fix]  # Host prerequisite checks + auto-fixers.
glorbo doctor --probe           # Version-probe the provider registry.

glorbo logs <co> [agent]        # Tail audit log or agent stdout
  [--follow]                    # (inotify-backed live tail).
glorbo console                  # Elixir remote console against the
                                # running daemon.

glorbo backup [--output <path>] # tar.gz of ~/.glorbo/ with WAL checkpoint.
glorbo restore <archive>        # Extract + migrate + reindex + doctor --fix.
  [--force]                     #

glorbo help [<verb>]            # Usage text.
```

---

## 11  Deployment & Portability

> *You take the whole Glorbo. You put it on another machine. It's still a Glorbo. What part of this is complicated?*

### Installation

```bash
# Download the binary for your architecture
curl -L https://github.com/foobarto/glorbo/releases/latest/download/glorbo-linux-x86_64 \
  -o ~/.local/bin/glorbo
chmod +x ~/.local/bin/glorbo

# First-time setup
glorbo init
```

`glorbo init` performs:

1. Creates `~/.glorbo/` directory structure.
2. Runs the pre-doctor pass (`linux_kernel`, `uidmap`, `disk_space`,
   `glorbo_dir`, `erts_version`, `audit_dir`, `sockets_dir`, `tar_zstd`,
   `bwrap`, `user_namespaces`). Blocker failures abort init.
3. Writes `~/.glorbo/config.md` with a generated secret and default
   host/port (`127.0.0.1:4000`).
4. Bootstraps `state/.erl_cookie` (mode 0600) for `glorbo console` remsh.
5. (Unless `--no-example`) Scaffolds the `acme` example company with a
   CEO agent including the reply-contract system prompt.
6. Rebuilds the SQLite index from disk (`glorbo reindex`).
7. Runs a post-doctor pass to confirm everything is green.

### System Dependencies

| Dependency       | Required | Provided by                     | Purpose                          |
|------------------|----------|---------------------------------|----------------------------------|
| Linux kernel ≥ 5.13 | Yes   | your distro                     | user namespaces, bwrap           |
| `bubblewrap`     | Yes      | distro package (`apt`/`dnf`/…)  | kernel-level agent sandboxing    |
| `uidmap`         | Yes      | `uidmap` or `shadow` package    | `newuidmap`/`newgidmap` helpers  |
| `inotify-tools`  | Yes      | distro package                  | filesystem watcher               |
| One or more provider runtimes | Yes | install a CLI or configure native credentials | `claude`, `gemini`, `codex`, or `credentials/<provider>.toml` |
| BEAM VM          | Bundled  | Burrito release                 | no Erlang install needed         |

Agents can use local models via CLIs that wrap them (e.g. `pi`,
`opencode` against a local backend) or cloud providers like Anthropic
(Claude), OpenAI, and Google (Gemini). GEP-32 phase 1 also ships
native OpenAI-compatible providers (`openai`, `openrouter`) with no
external CLI install. All of these are configured per agent in
`agent.md` and resolve through the provider registry. Local providers
are the default-friendly choice; cloud providers are opt-in.

Python is **not** a host dependency. There is no container runtime.
Glorbo bundles neither Podman nor Ollama — those were part of a
pre-pivot plan dropped in GEP-5 D6.

### Upgrade

```bash
# Replace binary
curl -L <new-release-url> -o ~/.local/bin/glorbo

# Apply any schema changes
glorbo migrate
```

Company data is never touched.  The SQLite index is migrated in-place.  If
migration fails, the old binary still works with the old index.

### Move to Another Machine

```bash
# Source machine
glorbo down
glorbo backup    # creates ~/.glorbo/backups/glorbo-backup-20260415.tar.gz

# Target machine (install glorbo binary first)
glorbo restore glorbo-backup-20260415.tar.gz
glorbo doctor --fix    # Rebuilds container image on new machine
glorbo up
```

---

## 12  Security Considerations

> *The chumble is fully sealed. No fleeb juice gets out. No unschleemed dinglebops get in. That's the whole point of the grumbo.*

- **No Python anywhere:** Glorbo doesn't install or invoke Python on
  the host or in any sandbox. Agent execution is a sandboxed CLI tool
  invocation — nothing more. (GEP-5 D6.)
- **Unprivileged sandboxes:** bwrap runs with `--unshare-user-try
  --cap-drop ALL` and no setuid helpers.
- **Network isolation:** Agents default to `network: none` —
  `--unshare-net` is a kernel netns shutdown; egress is physically
  blocked. `proxy` and `open` must be explicitly opted into.
- **Read-only mounts:** bwrap binds everything but the agent's own
  workspace and outbox as `--ro-bind`. Sibling agents and other
  companies are not mounted at all.
- **API keys:** Each CLI tool owns its own credentials in the user's
  home directory (`~/.claude/`, `~/.codex/`, `~/.config/gcloud/`, …).
  Glorbo never handles keys, never copies them into the company
  directory, never injects them as env vars. `~/.glorbo/config.md`
  stores dashboard settings (bind address, dashboard token) only.
- **Kernel-layer enforcement:** Even if an LLM attempts to access
  restricted paths, the kernel blocks it via bwrap mount namespaces.
- **Reply-file size cap:** Invocations are bounded at 1 MiB by default
  (`reply_max_bytes` per provider) so a runaway agent can't fill disk.
- **Budget limits:** Hard stops on spending prevent runaway API costs.
- **Audit trail:** Append-only, never modified. Every action is
  recorded.

---

## 13  Non-Goals (v1)

> *Look, we're not trying to build a whole Plumbus here. It's a Glorbo. Stay focused.*

- **Multi-user / multi-Director:** v1 is single-operator.  One person, one
  `~/.glorbo/`.
- **Cloud deployment:** This is a local-first tool.  Cloud can come later.
- **GUI installer:** The audience is Linux users comfortable with a terminal.
- **Windows / macOS:** Linux-first.  WSL2 may work but is not a target.
- **Plugin / extension system:** Skills and agent definitions provide
  extensibility through configuration, not code plugins.
- **LLM fine-tuning or training:** Glorbo orchestrates; it does not train.
- **Git integration:** Users can `git init` their companies directory
  themselves.  Glorbo does not manage git.

---

## 14  Open Questions

> *Nobody knows what happens if you double-schleem the grumbo. We'll figure it out.*

- **Heartbeat granularity:** Is cron syntax sufficient, or do we need event-
  driven triggers beyond inotify (e.g., "wake when budget resets")?
- **Agent-created agents:** Can a CEO agent create new agents (with Director
  approval), or is agent creation always a Director/human action?
- **Multi-model per agent:** Should an agent be able to use different models for
  different tasks (cheap model for classification, expensive for generation)?
- **Shared workspaces:** Can two agents collaborate on the same workspace
  directory, or is each workspace strictly single-agent?
- **Container image customisation:** Should agents be able to specify additional
  pip packages or tools beyond the base image?
- **Offline mode:** Should Glorbo function (with cached skills/context) when
  the machine has no internet?
- **Template marketplace:** Should there be a way to share company templates
  (agent configurations, skill definitions, goal structures)?
  
