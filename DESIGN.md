# Glorbo — Design Document

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted, filesystem-first agent orchestration platform built on
Elixir/Phoenix. It models companies as real organisations — with org charts,
goals, budgets, governance, and communication — and runs AI agents as employees
inside Linux containers. Everything is markdown. Everything is a file.

---

## 1  Philosophy

> *You already know what it does. Your ploobis has never been cleaner.*

**It's just a directory.**  The entire system lives under `~/.glorbo/`. Deploy by
copying a binary.  Back up with `tar`.  Move between machines with `scp`.
Version-control your company with `git`.

**The kernel is the policy engine.**  Permissions are not enforced by application
code; they are enforced by Linux users, groups, and POSIX ACLs inside
containers.  An agent that lacks `projects:write:foo` literally cannot write to
that directory.  `ls -la` is your audit tool.

**Markdown is the source of truth.**  Agent definitions, goals, tasks,
permissions, chat — all human-readable markdown with YAML frontmatter.  SQLite
exists only as a derived, rebuildable index for fast dashboard queries.

**Stability over features.**  Elixir/OTP supervision trees mean a crashing agent
restarts automatically.  Container isolation means a misbehaving agent cannot
damage the host or other companies.  There is no message broker, no object
store, no cache layer.  The fewer moving parts, the fewer things break.

**Paperclip with taste.**  Glorbo adds what Paperclip deliberately omitted: the
ability to chat with agents in real time, a proper LiveView dashboard, and
rock-solid stability through OTP.  It replaces Node.js and embedded Postgres
with Elixir and the filesystem.

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
are defined in markdown and materialised as Linux users inside the Company
container.

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

> *The grumbo is made of Elixir. The fleeb is Python. You do NOT mix them on the host. That's how you get unschleemed ploobis.*

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
| Container management | System calls to `podman` CLI                      |
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
│   │   │   └── manages: lifecycle, state, container exec
│   │   └── Glorbo.Agent (engineer)
│   │
│   └── Glorbo.Company (sidehustle)
│       └── ...
```

If an Agent process crashes, only that Agent restarts.  If a Company crashes,
only that Company's agents restart.  The dashboard and other companies are
unaffected.

### 4.2  Python — The Hands

Python never runs on the host.  It lives exclusively inside Company containers.

The `glorbo-runtime` container image includes:

- Python 3.12+
- Pinned AI SDKs: `ollama`, `huggingface_hub`, `anthropic`, `openai`,
  `google-genai`, `litellm`, etc.
- A thin Glorbo worker entrypoint that:
  1. Reads a task JSON from a mounted path
  2. Loads the agent's identity/skills/context from mounted markdown
  3. Makes LLM API calls (local or cloud)
  4. Writes results (files, messages) to the agent's outbox/workspace
  5. Exits (or stays alive for streaming tasks)

The entrypoint is intentionally simple.  Complex orchestration logic lives in
Elixir.  Python's job is: receive instructions, call APIs, produce output.

### 4.3  LLM Providers

Glorbo is local-first.  Agents default to local inference, with cloud providers
available when you need more power or specific models.

**Local providers (no API key, no cost, offline-capable):**

| Provider       | Notes                                                    |
|----------------|----------------------------------------------------------|
| Ollama         | Default. Auto-downloaded by `glorbo init`. Supports       |
|                | Llama, Qwen, Mistral, Gemma, Phi, CodeLlama, and more.  |
| Hugging Face   | Direct model downloads via `huggingface_hub`. Run GGUF    |
|                | or transformer models locally. Vast model library.        |

**Cloud providers (API key required):**

| Provider       | Models                                                   |
|----------------|----------------------------------------------------------|
| Anthropic      | Claude Opus, Sonnet, Haiku                               |
| OpenAI         | GPT-4o, Codex, o-series                                  |
| Google         | Gemini Pro, Flash, Ultra                                 |

Provider and model are configured per agent in `agent.md`.  Different agents
in the same company can use different providers — a researcher on a local
Qwen model, an engineer on Claude, a copywriter on Gemini.  Mix and match
based on the task and your budget.

API keys for cloud providers are stored in `~/.glorbo/config.md` and injected
into containers as environment variables at runtime.  They never touch the
company directory and are never visible to agents in the filesystem.

### 4.4  Podman — The Building

Podman is the default container runtime (rootless, daemonless, compatible with
OCI images).

Each Company runs as a container:

```bash
podman run \
  --name glorbo-acme \
  --user glorbo-acme-ceo \              # Agent-specific Linux user
  --userns keep-id \                    # Map host UID for file ownership
  --volume ~/.glorbo/companies/acme:/company:Z \
  --network none \                      # Default: no network (configurable)
  --read-only \                         # Root filesystem is immutable
  --tmpfs /tmp \
  glorbo-runtime \
  /entrypoint --task /company/agents/ceo/inbox/current-task.json
```

**Container lifecycle options (per company or per agent):**

- **Ephemeral (default):** Container spins up per task execution, runs, exits.
  Clean, stateless, simple.  Best for most workloads.
- **Persistent:** Container stays running, Elixir sends tasks via mounted
  files or Unix socket.  Better for rapid back-and-forth or streaming.

**Network policy (configurable per agent):**

- `network: none` — Full air-gap.  Agent can only work with local files.
- `network: api-only` — Outbound HTTPS only, restricted to API endpoints.
- `network: open` — Unrestricted outbound.  Use with caution.

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
provider: ollama                   # Local-first: ollama, huggingface
model: qwen3:8b                    # Cloud: anthropic, openai, google
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

1. **Elixir** prepares a task context: the triggering event, the agent's
   identity, relevant project/goal context, and any skill prompts.
2. **Elixir** serialises this to a JSON task file and writes it to the agent's
   inbox (or a temp mount).
3. **Elixir** invokes `podman run` (or `podman exec` for persistent containers)
   as the agent's Linux user inside the Company container.
4. **Python** entrypoint reads the task, constructs the LLM prompt, calls the
   API, and writes outputs to the outbox/workspace.
5. **Python** writes stdout to the log file (streamed to the dashboard if the
   Director is watching).
6. **Python** exits.  Elixir detects the exit, reads the outbox, routes
   messages, updates the SQLite index.

### 5.4  Sleeping

After execution, the agent GenServer remains alive but idle.  It holds minimal
state: the agent's name, current status, and a reference to its file paths.  It
consumes negligible memory.  The container is stopped (ephemeral mode) or idle
(persistent mode).

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

Each agent's container stdout is written to `agents/<name>/stdout.log`.
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

**Layer 2: Filesystem (Linux ACLs inside container)**

At container startup, Elixir (or an init script) reconciles the declared
permissions to POSIX ACLs:

```bash
# Agent 'engineer' can read all projects but only write to website-redesign
setfacl -m u:glorbo-engineer:rx /company/projects/
setfacl -m u:glorbo-engineer:rwx /company/projects/website-redesign/
setfacl -m u:glorbo-engineer:--- /company/agents/ceo/

# Agent can always read/write its own directories
setfacl -m u:glorbo-engineer:rwx /company/agents/engineer/outbox/
setfacl -m u:glorbo-engineer:rwx /company/agents/engineer/workspace/
setfacl -m u:glorbo-engineer:r   /company/agents/engineer/inbox/
```

This means even if the Python code is compromised or the LLM tries to read
files it shouldn't, the kernel blocks it.  Defence in depth.

### 7.3  Company Isolation

Each Company runs in a separate container.  Company A's container has only
Company A's directory mounted.  There is no mechanism — at any layer — for an
agent in Company A to access Company B's data.

---

## 8  Budget & Governance

> *You gotta keep count of the fleeb juice or your dinglebop runs dry. Then nobody's chumbling anything.*

### 8.1  Budget Tracking

Each agent has a monthly budget declared in `agent.md`.  The Python worker
reports token usage and cost after each LLM call (written to a usage file in the
outbox).  Elixir aggregates this into the SQLite budget ledger.

When an agent hits the alert threshold, Elixir notifies the Director via the
dashboard and optionally pauses the agent.  When an agent exceeds the budget,
Elixir refuses to execute further tasks until the Director intervenes or a new
month begins.

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

- **No host Python:** The AI execution environment is fully containerised.
  A supply-chain attack on a pip package cannot affect the host.
- **Rootless containers:** Podman runs without root.  No daemon, no privilege
  escalation surface.
- **Network isolation:** Agents default to `network: none`.  They must be
  explicitly granted network access.
- **Read-only root filesystem:** Containers run with `--read-only`.  Agents can
  only write to their mounted workspace and outbox.
- **API keys:** Stored in `config.md` on the host, injected into containers as
  environment variables at runtime.  Never written to the company directory.
  Never visible to agents in the filesystem.
- **ACL enforcement:** Even if LLM-generated code attempts to access restricted
  paths, the kernel blocks it.
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
  