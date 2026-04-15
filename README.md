# Glorbo

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted agent orchestration platform that models companies as
real organisations — with org charts, goals, budgets, governance, and
communication — and runs AI agents as employees inside Linux containers.

Everything is markdown. Everything is a file. Everyone has a Glorbo in their
home directory.

---

## What Is This

You define a company. You hire agents. You give them jobs. They do the jobs.
They talk to each other through chat channels and task boards. You supervise
from a real-time dashboard. If something goes wrong, you check the markdown
files — because that's all there is.

No cloud. No SaaS. No Kubernetes. No database cluster. Just a folder, some
containers, and an Elixir process that keeps the office running.

```
~/.glorbo/
├── glorbo                    # Single binary. That's the app.
├── glorbo.db                 # SQLite index. Rebuildable. Disposable.
└── companies/
    └── acme/
        ├── company.md        # Mission, budget, settings
        ├── agents/
        │   ├── ceo/
        │   │   ├── agent.md  # Identity, permissions, model config
        │   │   ├── inbox/    # Tasks and messages land here
        │   │   ├── outbox/   # Agent writes here, Glorbo routes
        │   │   └── workspace/
        │   └── engineer/
        ├── channels/
        │   ├── general.md    # Append-only chat logs
        │   └── engineering.md
        ├── projects/
        │   └── website-redesign/
        │       ├── project.md
        │       └── tasks/
        └── audit/
            └── 2026-04.jsonl # Append-only. Never modified. Never deleted.
```

Back up with `tar`. Version-control with `git`. Move to another machine with
`scp`. Debug with `cat`.

## Features

**Filesystem-first architecture** — Agents, tasks, chat, permissions, goals,
and audit logs are all markdown and JSONL files on disk. SQLite exists only as a
rebuildable index for dashboard queries. Delete it anytime; `glorbo reindex`
brings it back in seconds.

**Containerised agent execution** — Python and all AI SDKs live inside OCI
containers managed by Podman. Zero Python on the host. Agents run as dedicated
Linux users inside containers with POSIX ACLs enforcing permissions at the
kernel level.

**Local-first LLMs** — Ollama is downloaded automatically and works out of the
box. Run Llama, Qwen, Mistral, Gemma, or any Hugging Face model locally —
private, offline, free. Cloud providers (Claude, Codex, Gemini) are available
when you need them, configured per agent. No API keys required to get started.

**Real-time dashboard** — Phoenix LiveView provides a live company overview,
kanban board, agent monitoring with stdout streaming, chat interface, approval
queue, and budget tracking. No JavaScript framework. No build step. It's just
LiveView.

**Agent chat** — Talk to your agents. Agents talk to each other. Channels are
append-only markdown files underneath. Phoenix Channels handles the real-time
delivery.

**Company isolation** — Each company runs in its own container. Company A
literally cannot see Company B's files. Multiple companies, one machine, full
separation.

**Permission model** — Declared in markdown frontmatter, enforced by both the
application layer (Elixir routes messages) and the kernel layer (Linux ACLs
block filesystem access). Defence in depth.

**Budget governance** — Per-agent monthly budgets with alerts and hard stops.
No runaway API bills at 3 AM.

**Approval gates** — Tasks can require Director approval before execution. The
agent pauses, you review, one click to approve.

**OTP supervision** — If an agent crashes, only that agent restarts. If a
company crashes, only that company restarts. The dashboard and other companies
are unaffected. That's just what the BEAM does.

**Portable** — Deploy by copying a binary. Upgrade by replacing it. Move by
tarring the directory. The BEAM VM is bundled in the release.

## Quick Start

### Prerequisites

- Linux (x86_64 or aarch64)
- `uidmap` package (for rootless containers — already installed on most distros)

That's it. No Python. No Erlang. No Node.js. Glorbo downloads Podman and
Ollama automatically if they aren't already installed. Local LLM inference
works out of the box.

### Install

```bash
curl -L https://github.com/foobarto/glorbo/releases/latest/download/glorbo-linux-$(uname -m) \
  -o ~/.local/bin/glorbo
chmod +x ~/.local/bin/glorbo

glorbo init
```

`glorbo init` creates the directory structure, downloads Podman if needed,
builds the container image, and optionally scaffolds an example company. Takes
about a minute.

### Verify

```bash
glorbo doctor
```

### Create a Company

```bash
glorbo new company acme
```

Edit `~/.glorbo/companies/acme/company.md` with your mission and settings.

### Hire an Agent

```bash
glorbo new agent acme ceo
```

Edit `~/.glorbo/companies/acme/agents/ceo/agent.md`:

```markdown
---
name: CEO
role: Chief Executive Officer
provider: ollama                  # Local: ollama, huggingface
model: qwen3:8b                   # Cloud: anthropic, openai, google
budget:
  monthly_usd: 100.00
heartbeat: "*/30 * * * *"
network: api-only
permissions:
  - projects:read:*
  - projects:write:*
  - tasks:create:*
  - agents:message:*
  - chat:write:*
---

You are the CEO of {{ company.name }}.
Your mission: {{ company.mission }}
```

### Start

```bash
glorbo up acme
```

### Open the Dashboard

```
http://localhost:4000
```

## CLI Reference

```
glorbo init                       Set up ~/.glorbo/ and build container image
glorbo up [company]               Start company containers, begin orchestration
glorbo down [company]             Stop company containers
glorbo status                     Show companies, agents, active tasks
glorbo serve                      Start dashboard + orchestration (foreground)
glorbo run                        Start orchestration only (headless)

glorbo new company <name>         Scaffold a new company
glorbo new agent <company> <name> Scaffold a new agent
glorbo new project <co> <name>    Scaffold a new project

glorbo logs <company> [agent]     Tail logs
glorbo doctor                     Check system dependencies
glorbo reindex                    Rebuild SQLite index from filesystem
glorbo migrate                    Run schema migrations after upgrade

glorbo backup                     Archive ~/.glorbo/ to a tarball
glorbo restore <archive>          Extract archive and reindex
glorbo console                    Elixir remote console (debugging)
```

## How It Works

### The Director

You are the **Director**. You own the company. You hire agents, set the mission,
approve budgets, and intervene when needed. The CEO works for you, not the other
way around.

### Communication

Agents communicate through two mechanisms:

**Inbox/Outbox** — An agent writes a markdown file to its `outbox/`. Glorbo
picks it up, checks permissions, and delivers it to the recipient's `inbox/` or
appends it to a channel. The agent never touches another agent's files directly.

**Channels** — Append-only markdown files. Every message is a timestamped
section. Glorbo is the only writer (atomic, permission-checked). The dashboard
renders them as real-time chat.

### Execution

1. An event triggers an agent (new inbox item, heartbeat, channel mention)
2. Glorbo prepares a task context with the agent's identity, skills, and
   relevant project data
3. Glorbo runs the Python worker inside the company container as the agent's
   Linux user
4. Python calls the LLM, writes results to the agent's outbox/workspace
5. Glorbo detects the output, routes messages, updates the index
6. The container exits (or stays idle if in persistent mode)

### Sandboxing

Each company runs in a Podman container. Inside the container, each agent is a
Linux user with POSIX ACLs controlling exactly which directories it can read and
write. The container runs rootless, with a read-only root filesystem, and
defaults to no network access.

```
network: none        # Full air-gap (default)
network: api-only    # Outbound HTTPS to API endpoints only
network: open        # Unrestricted outbound
```

### Permissions

Declared in `agent.md`, enforced by the kernel:

```yaml
permissions:
  - projects:read:*
  - projects:write:website-redesign
  - tasks:create:website-redesign
  - agents:message:cto
  - chat:write:engineering
  - tools:execute:code-runner
  - budget:read:self
```

No application-level trust. If an agent doesn't have `projects:write:foo`, the
Linux filesystem literally won't let it write there.

## Upgrade

```bash
curl -L <new-release-url> -o ~/.local/bin/glorbo
glorbo migrate
```

Your company data is never touched. The binary is stateless.

## Move to Another Machine

```bash
# Source
glorbo down
glorbo backup

# Target
glorbo restore glorbo-backup-20260415.tar.gz
glorbo init --repair    # Rebuilds container image
glorbo up
```

## Tech Stack

| Component      | Technology                  | Why                                        |
|----------------|-----------------------------|--------------------------------------------|
| Orchestration  | Elixir/OTP                  | Supervision trees, fault tolerance, concurrency |
| Dashboard      | Phoenix LiveView            | Real-time UI, no JS framework              |
| Agent Chat     | Phoenix Channels            | WebSocket pub/sub, built-in                 |
| Agent Runtime  | Python (in container)       | AI SDK ecosystem                            |
| Local LLM      | Ollama (auto-downloaded)    | Private, offline, zero API cost             |
| Model Hub      | Hugging Face                | Vast model library, local inference         |
| Cloud LLM      | Claude, Codex, Gemini       | When you need more power (API key required) |
| Containers     | Podman (auto-downloaded)    | No daemon, no root, OCI-compatible          |
| Database       | SQLite (via ecto_sqlite3)   | Single file, zero setup, disposable         |
| Config/Data    | Markdown + YAML frontmatter | Human-readable, git-friendly, greppable     |
| Audit          | JSONL files                 | Append-only, never modified                 |
| Binary         | mix release + bundled ERTS  | Single binary, no Erlang dependency         |

## Design Document

For the full architecture, see [DESIGN.md](DESIGN.md).

## Project Status

Glorbo is under active development. The core orchestration, filesystem
watching, container management, and LiveView dashboard are functional. The
permission model and budget governance are implemented. Agent chat and the
approval queue are in progress.

See the [issues](https://github.com/foobarto/glorbo/issues) for current work
and known limitations.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
before submitting a pull request.

The project is written in Elixir (orchestration, dashboard) and Python (agent
workers). Familiarity with OTP supervision trees and Phoenix LiveView is
helpful but not required — the codebase is intentionally straightforward.

## License

[MIT](LICENSE)

---

<sub>*You take the whole Glorbo. You put it on another machine. It's still a Glorbo. What part of this is complicated?*</sub>
