# Glorbo — Design Document

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted, filesystem-first agent orchestration platform built on
Elixir/Phoenix. It models companies as real organisations — with org charts,
goals, budgets, governance, and communication — and runs AI agents as employees
inside kernel-sandboxed (`bwrap`) processes. Everything is markdown. Everything
is a file.

> **Reading notes.** This document is the living architectural reference.
> For the *why* behind major decisions, see the corresponding
> **Glorbo Enhancement Proposals** in `docs/geps/`:
>
> - **GEP-2** — architectural overview (the big picture).
> - **GEP-3** — filesystem as source of truth.
> - **GEP-4** — CLI-tool agents (no Python, no custom LLM client).
> - **GEP-5** — bwrap sandboxing (**Podman tier was planned and
>   dropped — see GEP-5 D6**; historical Podman/Python content below
>   is kept for context only).
> - **GEP-6** — Phoenix LiveView + Channels dashboard.
> - **GEP-7** — SQLite as derived data.
> - **GEP-8** — provider registry + CLI auto-detect (in-flight).
> - **GEP-9** — protocol-level integration (MCP, ACP) for future
>   bidirectional needs.
>
> **Important:** sections below that describe a Python agent runtime
> inside Podman (the original pre-pivot plan) are preserved as
> historical context, but they are **not active roadmap**. The
> authoritative runtime story is: agents are CLI-tool subprocesses
> under `bwrap`. No Python. No container runtime. See GEP-4 and
> GEP-5.

---

## 1  Philosophy

> *You already know what it does. Your ploobis has never been cleaner.*

**It's just a directory.**  The entire system lives under `~/.glorbo/`. Deploy by
copying a binary.  Back up with `tar`.  Move between machines with `scp`.
Version-control your company with `git`.

**The kernel is the policy engine.**  Permissions are not enforced by application
code; they are enforced by the kernel. In v0.0.1 that's bwrap mount namespaces
(denied paths aren't mounted; allowed paths are `--ro-bind` or `--bind`); in
v0.0.2 that's Linux users, groups, and POSIX ACLs inside containers.  Either
way, an agent that lacks `projects:write:foo` literally cannot write to that
directory.  `ls -la` is your audit tool.

**Markdown is the source of truth.**  Agent definitions, goals, tasks,
permissions, chat — all human-readable markdown with YAML frontmatter.  SQLite
exists only as a derived, rebuildable index for fast dashboard queries.

**Stability over features.**  Elixir/OTP supervision trees mean a crashing agent
restarts automatically.  Sandbox isolation (bwrap in v0.0.1, Podman containers
in v0.0.2) means a misbehaving agent cannot damage the host or other
companies.  There is no message broker, no object store, no cache layer.  The
fewer moving parts, the fewer things break.

**Paperclip with taste.**  Glorbo adds what Paperclip deliberately omitted: the
ability to chat with agents in real time, a proper LiveView dashboard, and
rock-solid stability through OTP.  It replaces Node.js and embedded Postgres
with Elixir and the filesystem.

> **Milestone scope — agents are CLI-first, permanently.** Agents are
> sandboxed CLI tools (Claude Code, Gemini CLI, Codex, and OSS
> alternatives) wrapped in `bwrap` (bubblewrap) mount- and
> network-namespace isolation. The Python-in-Podman agent runtime with
> `litellm` dispatch and POSIX ACL enforcement — originally the whole
> §4.2 / §4.4 / §7.2 story — was **deferred** in v0.0.2 and then
> **dropped entirely** in 2026-04-17 (see GEP-5 D6). Sections below
> that still describe the container path are preserved as historical
> context; they are not active roadmap. "Python never runs on the
> host" is now load-bearing everywhere: Glorbo needs no Python at all.

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

A Company is an isolated unit of work with its own mission, agents, projects,
and budget.  Each Company runs inside its own container.  Multiple Companies can
run simultaneously on the same host, fully isolated from each other.

### 2.3  Agent

An Agent is a defined role within a Company.  It has an identity (name, role,
backstory), permissions, a budget, and a provider/model configuration.  Agents
are defined in markdown.  In v0.0.1 an agent materialises at wake-time as a
short-lived `bwrap` sandbox wrapping a CLI tool invocation (Claude Code,
Gemini CLI, or Codex).  In v0.0.2 agents will additionally be materialisable
as per-agent Linux users inside a Podman-managed Company container.

Agents do not run continuously.  They wake on events: a new task in their inbox,
a scheduled heartbeat, a message in a channel they watch, or a direct request
from the Director.

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
├── config.md                       # Global settings, provider API keys, defaults
├── glorbo.db                       # SQLite index (rebuildable, disposable)
├── bin/
│   ├── podman                      # Static podman binary (if not system-installed)
│   └── ollama                      # Static ollama binary (if not system-installed)
├── models/                         # Ollama model storage
├── containers/
│   ├── glorbo-runtime/             # Base OCI image definition
│   │   ├── Containerfile
│   │   └── requirements.txt        # Pinned Python dependencies
│   └── cache/                      # Pulled/built image layers
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
│       │   │   ├── workspace/      # Mounted into container; agent works here
│       │   │   ├── stdout.log      # Container stdout stream (tailed by UI)
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
│       └── audit/
│           └── 2026-04.jsonl       # Append-only audit events
│
└── logs/
    ├── glorbo.log                  # Elixir application log
    └── containers/
        └── acme.log                # Container runtime log
```

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

> *The grumbo is made of Elixir. The hizzards are CLI tools, hermetically schleemed inside bwrap. The fleeb is Python — still off the host, sleeping in its Podman pod until v0.0.2. Don't mix them on the host. That's how you get unschleemed ploobis.*

### 4.1  Elixir/Phoenix — The Brain

The core process.  Runs on the host (not in a container).

| Concern             | Solution                                         |
|----------------------|--------------------------------------------------|
| Orchestration        | OTP GenServers, one per agent lifecycle           |
| Scheduling           | GenServer timers + `:timer` for heartbeats        |
| File watching        | `file_system` hex package (inotify)               |
| Dashboard            | Phoenix LiveView                                  |
| Agent chat / streaming | Phoenix Channels + PubSub                       |
| Database             | Ecto + `ecto_sqlite3`                             |
| Agent sandbox        | `bwrap` argv build + `Port.open` (v0.0.1); `podman` CLI in v0.0.2 |
| Release packaging    | `mix release` with `include_erts: true`           |

**Supervision tree (sketch):**

```
Glorbo.Application
├── Glorbo.Repo                          # SQLite / Ecto
├── Glorbo.ContainerManager              # Manages podman lifecycle
├── GlorboWeb.Endpoint                   # Phoenix (dashboard, API)
│
├── Glorbo.CompanySupervisor             # DynamicSupervisor
│   ├── Glorbo.Company (acme)            # Per-company supervisor
│   │   ├── Glorbo.Company.FileWatcher   # inotify on company dir
│   │   ├── Glorbo.Company.Router        # Routes outbox → inbox/channels
│   │   ├── Glorbo.Company.Scheduler     # Heartbeats, cron-like triggers
│   │   ├── Glorbo.Company.BudgetTracker # Token/cost accounting
│   │   ├── Glorbo.Company.AuditLog      # Appends to audit JSONL
│   │   │
│   │   ├── Glorbo.Agent (ceo)           # Per-agent GenServer
│   │   │   └── manages: lifecycle, state, bwrap+CLI exec (v0.0.2: container exec)
│   │   └── Glorbo.Agent (engineer)
│   │
│   └── Glorbo.Company (sidehustle)
│       └── ...
```

If an Agent process crashes, only that Agent restarts.  If a Company crashes,
only that Company's agents restart.  The dashboard and other companies are
unaffected.

### 4.2  CLI Agents — The Hands (v0.0.1)

Python never runs on the host — and in v0.0.1 it doesn't run anywhere at all.
Glorbo spawns existing terminal AI tools (Claude Code, Gemini CLI, Codex) as
short-lived sandboxed processes and lets each tool handle its own model access,
auth, and tool-use loop.

For each agent wake, Elixir:

1. Materialises skills and the task prompt into the agent's workspace
   (`.glorbo-skills/`, `.glorbo-run/<task-id>/task-prompt.md`).
2. Resolves the agent's `provider:` (`claude-code | gemini-cli | codex`) to an
   adapter that knows the binary, argv, and telemetry layout.
3. Builds a `bwrap` argv from the agent's `permissions:` and `network:`
   declarations (see §4.4).
4. Spawns `bwrap <sandbox-args> <cli-tool> -p` with the task prompt on stdin,
   the workspace as `cwd`, and stdout tailed to `agents/<name>/stdout.log`.
5. On exit, parses the CLI tool's session telemetry for token/cost usage, moves
   outbox files through the Router, and cleans up per-invocation scratch.

The CLI tool is trusted; Glorbo doesn't ship its own LLM client. Each tool
manages its own credentials (Claude Code's login, `gcloud`/`GEMINI_API_KEY`,
`OPENAI_API_KEY`), and Glorbo never touches those secrets — the company
directory sees no API keys in v0.0.1. Complex orchestration logic still lives
in Elixir; the CLI tool's job is: receive a prompt on stdin, do the work inside
its sandbox view of the workspace, exit.

> **v0.0.2 — Python inside Podman.** The original design shipped Python 3.12+
> inside a `glorbo-runtime` container image with pinned AI SDKs (`ollama`,
> `huggingface_hub`, `anthropic`, `openai`, `google-genai`, `litellm`) and a
> thin FastAPI worker entrypoint reading task JSON from mounted paths, making
> LLM calls, writing to outbox, and exiting. The image has already been built
> (Phase 2) and is published to `ghcr.io/foobarto/glorbo-runtime`, but it is
> **dormant** in v0.0.1 — no code path spawns it. It returns in v0.0.2 as the
> isolation story for agents that need to execute arbitrary LLM-generated code
> or run providers Glorbo prefers to dispatch directly via litellm.

### 4.3  LLM Providers

Provider and model are configured per agent in `agent.md`. Exactly one
provider + one model per agent — no multi-model routing per agent. Different
agents in the same company can use different providers: a researcher on
Claude Code, an engineer on Codex, a copywriter on Gemini.

**v0.0.1 — CLI-tool providers (each CLI handles its own auth):**

| `provider:`     | Binary     | Auth                                         |
|-----------------|-----------|----------------------------------------------|
| `claude-code`   | `claude`  | Claude Code's own login (`~/.claude/`)       |
| `gemini-cli`    | `gemini`  | `GEMINI_API_KEY` or `gcloud` ADC             |
| `codex`         | `codex`   | Codex CLI's own auth (`~/.codex/`)           |

Glorbo never handles API keys directly in v0.0.1. Each CLI tool's credentials
stay in the user's home directory and are bind-mounted read-only into the
sandbox if the agent's provider requires them — and only for that provider.
The company directory holds no secrets. `~/.glorbo/config.md` exists but does
not inject keys into agent processes in this milestone.

> **v0.0.2 — Direct-SDK providers via litellm inside the container runtime.**
> When the container runtime returns, the following providers dispatch through
> `litellm` inside `glorbo-runtime`, with keys sourced from `~/.glorbo/config.md`
> and injected as container env vars at invocation time (never written to the
> company directory, never visible to agents in the filesystem):
>
> | Provider     | Models                                                   |
> |--------------|----------------------------------------------------------|
> | `anthropic`  | Claude Opus, Sonnet, Haiku                               |
> | `openai`     | GPT-4o, Codex, o-series                                  |
> | `google`     | Gemini Pro, Flash, Ultra                                 |
> | `ollama`     | Llama, Qwen, Mistral, Gemma, Phi, CodeLlama (local)      |
> | `huggingface`| GGUF / transformer models via `huggingface_hub` (local)  |
>
> Local-first stays the long-term goal; `LLM-05` (full offline flow after
> `init`) lives with the container runtime phase because CLI tools need their
> providers' cloud endpoints. A future `provider: ollama-cli` adapter could
> restore offline CLI-mode by spawning `ollama run` inside the same bwrap
> sandbox.

### 4.4  bwrap + Podman — The Kernel Guards

Kernel-enforced isolation is a **two-tier** story. In v0.0.1 the active tier is
bwrap; Podman is staged-but-dormant and becomes active in v0.0.2.

#### 4.4.1  bwrap — the v0.0.1 sandbox

[`bwrap`](https://github.com/containers/bubblewrap) (bubblewrap) is the
kernel-layer isolator for v0.0.1. Every CLI-tool invocation runs inside a
fresh bwrap process tree that dies with its parent. The sandbox is built from
the agent's `permissions:` and `network:` declarations — no standing container,
no long-lived namespace, no privileged daemon.

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
- `network: api-only` — shared netns + `HTTP_PROXY`/`HTTPS_PROXY` pointed at a
  Glorbo-managed HTTPS CONNECT allowlist proxy. Advisory for v0.0.1 (a
  determined agent could ignore the env vars); a netns + nftables hardening
  iteration is planned.
- `network: open` — host netns inherited (no `--unshare-net`). Explicit opt-in.

Sibling agents and other companies are **not mounted** — company isolation is
therefore absolute by construction: there is no path inside the sandbox that
could reach another company's data.

#### 4.4.2  Podman — v0.0.2 building

> **v0.0.2** — Podman is the rootless, daemonless container runtime that
> hosts the Python agent runtime when it returns. Each Company will run as a
> Podman container, with agents materialised as distinct Linux users inside,
> permissions enforced via POSIX ACLs on the mounted company directory, and
> network policy via per-container netns + nftables.
>
> ```bash
> podman run \
>   --name glorbo-acme \
>   --user glorbo-acme-ceo \              # Agent-specific Linux user
>   --userns keep-id \                    # Map host UID for file ownership
>   --volume ~/.glorbo/companies/acme:/company:Z \
>   --network none \                      # Default: no network (configurable)
>   --read-only \                         # Root filesystem is immutable
>   --tmpfs /tmp \
>   glorbo-runtime \
>   /entrypoint --task /company/agents/ceo/inbox/current-task.json
> ```
>
> **Container lifecycle options (per company or per agent):**
>
> - **Ephemeral (default):** Container spins up per task execution, runs, exits.
>   Clean, stateless, simple. Best for most workloads.
> - **Persistent:** Container stays running, Elixir sends tasks via mounted
>   files or Unix socket. Better for rapid back-and-forth or streaming.
>
> The static Podman binary is bootstrapped by `glorbo init` into
> `~/.glorbo/bin/podman` (Phase 2 work), and `glorbo-runtime` is already built
> and cached locally — both sit dormant until v0.0.2 re-activates them.

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
provider: claude-code              # v0.0.1: claude-code | gemini-cli | codex
model: claude-sonnet-4-5           # v0.0.2 adds: anthropic, openai, google, ollama, huggingface
budget:
  monthly_usd: 50.00
  alert_at_pct: 80
heartbeat: "*/30 * * * *"          # Check inbox every 30 minutes
network: api-only
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
  - tools:execute:code-runner
  - budget:read:self
---

## System Prompt

You are a Software Engineer at {{ company.name }}.  Your mission is aligned
with the company goal: {{ company.mission }}.

You report to {{ reports_to.name }} ({{ reports_to.role }}).

When you receive a task, you should:
1. Acknowledge it by updating the task status to `in-progress`
2. Do the work in your workspace
3. Write deliverables to the project artifacts folder
4. Update the task status to `review` and notify your manager
5. If blocked, escalate via chat or create a sub-task

{{ skills }}
```

### 5.2  Waking

Agents wake in response to:

| Trigger            | Mechanism                                          |
|--------------------|----------------------------------------------------|
| New inbox item     | inotify on `agents/<name>/inbox/` → GenServer call |
| Heartbeat schedule | Elixir `:timer` based on cron expression           |
| Director request      | Dashboard action → GenServer call                  |
| Channel mention    | Elixir Router detects `@agent-name` in message     |

### 5.3  Execution

**v0.0.1 — bwrap + CLI tool pipeline:**

1. **Elixir** prepares a task context: triggering event, agent identity,
   project/goal references, skill list.
2. **Elixir** materialises the context onto disk inside the agent's workspace:
   `.glorbo-run/<task-id>/task-prompt.md` (the prompt) and `.glorbo-skills/*.md`
   (the named skills, copied from `~/.glorbo/companies/<co>/skills/`).
3. **Elixir** resolves `agent.md`'s `provider:` to a CLI adapter
   (`Glorbo.CLI.Adapter.ClaudeCode | GeminiCli | Codex`) and builds a `bwrap`
   argv from `permissions:` + `network:` (see §4.4, §7.2).
4. **Elixir** spawns `bwrap <sandbox-args> <cli-tool> -p` via `Port.open`,
   with the task prompt piped on stdin and the agent's workspace as `cwd`.
5. **The CLI tool** runs inside the sandbox, reads `.glorbo-skills/` on demand,
   does its tool-use loop, and writes results into `/workspace` and `/outbox`.
   stdout is tailed to `agents/<name>/stdout.log`.
6. **The CLI tool** exits. Elixir parses session telemetry (Claude Code session
   JSONL under `CLAUDE_PROJECT_DIR`, Gemini/Codex analogs) for token + cost,
   records it in the budget ledger, removes `.glorbo-run/` + `.glorbo-skills/`,
   reads the outbox, routes messages, and updates the SQLite index.

> **v0.0.2 — Python worker in Podman.** Steps 3–6 are replaced by: Elixir
> serialises the task to JSON, invokes `podman run` (ephemeral) or `podman
> exec` (persistent) as the agent's Linux user inside the Company container,
> the Python entrypoint reads the task and calls the LLM via `litellm`, writes
> outputs to outbox/workspace, and exits. Budget tracking switches from CLI
> telemetry parsing to Python-reported `cost_usd`.

### 5.4  Sleeping

After execution, the agent GenServer remains alive but idle.  It holds minimal
state: the agent's name, current status, and a reference to its file paths.  It
consumes negligible memory.  In v0.0.1 the `bwrap` process tree has already
exited — there is literally nothing left running between wakes. In v0.0.2 the
container is stopped (ephemeral mode) or idle (persistent mode).

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

Each agent's sandboxed CLI stdout (v0.0.1: `bwrap <…> claude -p`; v0.0.2:
container stdout) is written to `agents/<name>/stdout.log`.
Elixir's `FileWatcher` tails this file and pushes lines to the LiveView
dashboard via PubSub.  The Director can watch any agent's live output.

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

**Layer 2 (v0.0.1): Kernel (bwrap mount + network namespaces)**

At each agent wake, `Glorbo.Sandbox.PermissionMapper` converts the agent's
`permissions:` list into a `bwrap` argv. What the agent cannot see, it cannot
touch — and what bwrap mounts read-only, the kernel will refuse to write:

```
permissions:
  - projects:read:*                          → --ro-bind <co>/projects /projects
  - projects:write:website-redesign          → --bind    <co>/projects/website-redesign /projects/website-redesign
  - chat:read:*                              → --ro-bind <co>/channels /channels
  # (no agents:read:ceo)                     → <co>/agents/ceo NOT mounted — invisible
```

`network:` declarations map to `--unshare-net` (none), a shared netns +
HTTPS CONNECT allowlist proxy env (api-only), or inherited host netns (open).
A write attempt into `/projects/other-project` from inside the sandboxed CLI
fails with `EACCES` at the kernel — not at the Elixir layer.

> **Layer 2 (v0.0.2): Filesystem (Linux ACLs inside container).** When the
> Podman runtime returns, permissions also reconcile to POSIX ACLs on the
> company directory, enforced against the agent's Linux user:
>
> ```bash
> # Agent 'engineer' can read all projects but only write to website-redesign
> setfacl -m u:glorbo-engineer:rx /company/projects/
> setfacl -m u:glorbo-engineer:rwx /company/projects/website-redesign/
> setfacl -m u:glorbo-engineer:--- /company/agents/ceo/
>
> # Agent can always read/write its own directories
> setfacl -m u:glorbo-engineer:rwx /company/agents/engineer/outbox/
> setfacl -m u:glorbo-engineer:rwx /company/agents/engineer/workspace/
> setfacl -m u:glorbo-engineer:r   /company/agents/engineer/inbox/
> ```
>
> `Glorbo.Security.ACLMapper` and `Glorbo.Runtime.UidAllocator` already ship
> in the tree (dormant in v0.0.1) so the container path can plug in without
> new foundations.

Either way, defence in depth: the Router says no, and if the Router is
wrong, the kernel says no.

### 7.3  Company Isolation

In v0.0.1, agents in Company A are spawned inside a `bwrap` sandbox whose
mount set contains only subpaths of Company A's directory; Company B's
directory is never mounted and therefore not reachable from any path inside
the sandbox. In v0.0.2, each Company additionally runs in a separate Podman
container with only its own directory volume-mounted. There is no mechanism —
at any layer, in any milestone — for an agent in Company A to access
Company B's data.

---

## 8  Budget & Governance

> *You gotta keep count of the fleeb juice or your dinglebop runs dry. Then nobody's chumbling anything.*

### 8.1  Budget Tracking

Each agent has a monthly budget declared in `agent.md`. In v0.0.1, Elixir
parses each CLI tool's session telemetry after every invocation and aggregates
the result into the SQLite budget ledger:

| Provider       | Telemetry source                                             | Fields parsed                          |
|----------------|--------------------------------------------------------------|----------------------------------------|
| `claude-code`  | `CLAUDE_PROJECT_DIR/<session>.jsonl` — `message.usage` lines | `input_tokens`, `output_tokens`, cache |
| `codex`        | Codex rollout JSONL — `token_count` records                  | prompt / completion tokens             |
| `gemini-cli`   | `gemini` stdout final JSON — `stats.models.*.tokens`         | prompt / completion tokens             |

Cost in USD is computed by Elixir via a per-model rate table
(`config/llm_rates.exs`) — CLI tools don't always report dollar cost, so
Glorbo owns the mapping. The ledger shape is one row per `{company, agent,
year_month}` with atomic increment on invocation.

Pre-dispatch, `BudgetTracker.check_budget/1` returns `:ok | {:alert, used,
cap} | {:stop, used, cap}`. `:alert` fires a dashboard notification and writes
`alerts/<agent>-budget.md`. `:stop` aborts the wake, writes a rejection to the
agent's inbox, and emits a `budget.hard_stop` audit event until the Director
intervenes or a new month begins.

> **v0.0.2** — The Python worker reports `cost_usd` directly via `litellm`'s
> per-call cost callback, written to a usage file in the outbox on each LLM
> call. The ledger shape and alert/hard-stop mechanics are unchanged; only
> the usage source differs.

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
- **Chat:** Real-time channel view.  Director can read all channels, post to any
  channel, DM any agent.
- **Approval queue:** Pending approval requests with one-click approve/reject.
- **Audit log:** Searchable, filterable event history.
- **System health:** Container status, resource usage, Elixir process tree.

### Real-time Updates

LiveView subscribes to PubSub topics per company.  File changes detected by
inotify trigger PubSub broadcasts.  The dashboard updates without polling.

---

## 10  CLI

> *Pre-schleemed. Zero hizzard leakage. One command.*

```
glorbo init                     # First-time setup: build container image,
                                # create ~/.glorbo/, scaffold example company

glorbo up [company]             # Start company container(s), begin watching
glorbo down [company]           # Stop company container(s)
glorbo status                   # Show all companies, agents, active tasks

glorbo new company <name>       # Scaffold a new company directory
glorbo new agent <company> <n>  # Scaffold a new agent in a company
glorbo new project <co> <name>  # Scaffold a new project

glorbo reindex                  # Rebuild SQLite from filesystem
glorbo migrate                  # Run Ecto migrations after upgrade
glorbo doctor                   # Check dependencies (podman, etc.)
glorbo doctor --fix             # Repair flagged problems (re-pull image,
                                # re-download binaries, re-verify ACLs)

glorbo logs <company> [agent]   # Tail logs
glorbo console                  # Elixir remote console (debugging)
glorbo serve                    # Start dashboard + orchestration (foreground)
glorbo run                      # Start orchestration only (headless)

glorbo backup                   # Shortcut: tar czf glorbo-backup-<date>.tar.gz
glorbo restore <archive>        # Extract + reindex
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
2. Checks for system `podman`.  If not found, downloads the `podman-static`
   binary into `~/.glorbo/bin/` — no root, no package manager.
3. Checks for system `ollama`.  If not found, downloads the static binary into
   `~/.glorbo/bin/` — providing a local LLM backend out of the box.
4. Checks for `newuidmap`/`newgidmap` (required for rootless containers;
   provided by the `uidmap` or `shadow` package on most distros).
5. Builds the `glorbo-runtime` container image from the bundled
   `Containerfile` and `requirements.txt`.
6. Optionally pulls a default local model (e.g. `llama3.2` or `qwen3`).
7. Optionally scaffolds an example company with a CEO agent.
8. Runs `glorbo doctor` to verify everything.

### System Dependencies

| Dependency       | Required | Provided by           | Purpose                          |
|------------------|----------|-----------------------|----------------------------------|
| Linux kernel     | Yes      | —                     | It's Linux-first                 |
| podman           | Auto     | Downloaded by init    | Container runtime (rootless)     |
| ollama           | Auto     | Downloaded by init    | Local LLM inference              |
| uidmap           | Yes      | `uidmap` or `shadow`  | newuidmap/newgidmap for rootless  |
| None else        |          |                       | BEAM VM is bundled in the binary |

If the system already has podman or ollama installed, Glorbo uses them.
Otherwise, it downloads the statically linked binaries and manages them locally
in `~/.glorbo/bin/`.  No root required.  No package manager required.

Agents can use local models via Ollama or Hugging Face (free, private,
offline-capable) or cloud providers like Anthropic (Claude), OpenAI (Codex),
and Google (Gemini) via API keys — configured per agent in `agent.md`.  Both
can be used simultaneously, even within the same company.  Local providers are
the default; cloud providers are an opt-in upgrade, not a prerequisite.

Python is **not** a host dependency.  It lives inside the container image.

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

- **No host Python (v0.0.1: no Python at all):** v0.0.1 doesn't install or
  invoke Python anywhere; agent execution is a sandboxed CLI tool. v0.0.2
  returns Python to the inside of Podman containers, where a pip-package
  supply-chain compromise still cannot reach the host.
- **Unprivileged sandboxes:** bwrap runs with `--unshare-user-try --cap-drop
  ALL` and no setuid helpers. Podman (v0.0.2) runs rootless — no daemon, no
  privilege escalation surface.
- **Network isolation:** Agents default to `network: none` — v0.0.1 enforces
  this via `--unshare-net` (kernel netns), v0.0.2 via container `--network
  none`. They must be explicitly granted network access.
- **Read-only mounts:** bwrap binds everything but the agent's own workspace
  and outbox as `--ro-bind`. v0.0.2 containers additionally run with
  `--read-only` root filesystem.
- **API keys:** In v0.0.1, each CLI tool owns its own credentials in the
  user's home directory — Glorbo never handles keys, never copies them into
  the company directory, never injects them as env vars. In v0.0.2, direct-
  SDK providers source keys from `~/.glorbo/config.md`, injected into
  containers as env vars at runtime, never written to the company directory,
  never visible to agents in the filesystem.
- **Kernel-layer enforcement:** Even if an LLM attempts to access restricted
  paths, the kernel blocks it — via bwrap mount namespaces in v0.0.1, via
  POSIX ACLs inside the container in v0.0.2.
- **Budget limits:** Hard stops on spending prevent runaway API costs.
- **Audit trail:** Append-only, never modified.  Every action is recorded.

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
  