<p align="center">
  <img src="assets/logo.png" alt="Glorbo" width="520">
</p>

# Glorbo

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted agent orchestration platform that models companies as
real organisations — with org charts, goals, budgets, governance, and
communication — and runs AI agents as employees inside kernel-level sandboxes.

Everything is markdown. Everything is a file. Everyone has a Glorbo in their
home directory.

---

## What Is This

You define a company. You hire agents. You give them jobs. They do the jobs.
They talk to each other through chat channels and task boards. You supervise
from a real-time dashboard. If something goes wrong, you check the markdown
files — because that's all there is.

No cloud. No SaaS. No Kubernetes. No database cluster. Just a folder, some
sandboxes, and an Elixir process that keeps the office running.

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

## Milestone Scope

**v0.0.1 — CLI-agent runtime (current).** Agents are wrapped invocations of
CLI tools you already have installed: **Claude Code**, **Gemini CLI**, and
**Codex**. Every wake spawns a fresh `bwrap(1)` sandbox with only the agent's
workspace mounted, no network (unless explicitly granted), and all
capabilities dropped. Zero Python on the host; Glorbo itself is a single
Elixir binary.

**v0.0.2 — Podman + Python runtime (deferred).** Moves agents into per-agent
Linux users inside a Podman-managed Company container, with `litellm`
dispatching to any provider (local Ollama, Anthropic, OpenAI, Google) and
POSIX ACLs as the second enforcement layer. The container design is
preserved in `DESIGN.md` and dormant in the codebase; restoration guide at
`.planning/deferred/container-runtime-v0.0.2/`.

## Features

**Filesystem-first architecture** — Agents, tasks, chat, permissions, goals,
and audit logs are all markdown and JSONL files on disk. SQLite exists only as
a rebuildable index for dashboard queries. Delete it anytime; `glorbo reindex`
brings it back in seconds.

**Kernel-sandboxed agents (v0.0.1)** — Every agent wake is a fresh `bwrap`
sandbox: `--unshare-user-try --unshare-ipc --unshare-pid --unshare-net
--die-with-parent --cap-drop ALL`. The workspace is `--bind`-mounted writable;
nothing else is visible. Network isolation is kernel-enforced, not
policy-enforced.

**CLI-tool agents** — Use the Claude Code, Gemini CLI, or Codex installs
already on your machine. Credentials are `--ro-bind`ed into the sandbox;
session state stays on the host. No new API keys to manage.

**Local-first LLMs (v0.0.2)** — In the v0.0.2 container runtime, Ollama is
auto-downloaded by `glorbo init`. Cloud providers (Anthropic, OpenAI, Google)
configurable per agent via `litellm`.

**Real-time dashboard (Phase 4)** — Phoenix LiveView provides company overview,
kanban board, agent monitoring with stdout streaming, chat, approval queue, and
budget tracking. No JavaScript framework. No build step.

**Agent chat** — Talk to your agents. Agents talk to each other. Channels are
append-only markdown files underneath. Phoenix Channels handles real-time
delivery.

**Company isolation** — Each company's data lives in its own directory under
`~/.glorbo/companies/`. In v0.0.1 the bwrap sandbox bind-mounts only the
active company; in v0.0.2 each company runs in its own Podman container with
no cross-mount.

**Permission model** — Declared in markdown frontmatter, enforced at two
layers by design: the Elixir Router (application) and the kernel (bwrap
mounts in v0.0.1, POSIX ACLs in v0.0.2). An agent without
`projects:write:foo` literally cannot write there.

**Budget governance** — Per-agent monthly budgets with alerts and hard stops.
No runaway API bills at 3 AM.

**Approval gates** — Tasks can require Director approval before execution.
The agent pauses, you review, one click to approve.

**OTP supervision** — If an agent crashes, only that agent restarts. If a
company crashes, only that company's agents restart. The dashboard and other
companies are unaffected. That's just what the BEAM does.

**Portable** — Deploy by copying a binary. Upgrade by replacing it. Move by
tarring the directory. The BEAM VM is bundled in the release via Burrito.

## Quick Start

### Prerequisites

- Linux (x86_64 or aarch64)
- `bubblewrap` (`bwrap`) — available in every major distro's package manager
- `inotify-tools`
- On Ubuntu 24.04 / Debian 13, an unconfined AppArmor profile for
  `/usr/bin/bwrap` (the kernel blocks unprivileged user-namespace network
  operations otherwise; see `.github/workflows/ci.yml` for the canonical
  profile).
- At least one of: Claude Code CLI, Gemini CLI, or Codex CLI installed and
  authenticated.

No Python. No Erlang. No Node.js. `glorbo init` verifies the rest and
bootstraps `~/.glorbo/`.

### Install

```bash
curl -L https://github.com/foobarto/glorbo/releases/latest/download/glorbo-linux-$(uname -m) \
  -o ~/.local/bin/glorbo
chmod +x ~/.local/bin/glorbo

glorbo init
```

`glorbo init` creates the directory hierarchy, verifies prerequisites via
`glorbo doctor`, and optionally scaffolds an example company.

### Verify

```bash
glorbo doctor
```

Reports on the full dependency chain: kernel version, `uidmap`, disk space,
`~/.glorbo/` layout, ERTS, bwrap, user namespaces, and (in v0.0.2) Podman,
Ollama, the runtime container image, and tar-zstd.

### Hire an Agent

Edit `~/.glorbo/companies/acme/agents/ceo/agent.md`:

```markdown
---
name: CEO
role: Chief Executive Officer
provider: claude-code            # v0.0.1: claude-code | gemini | codex
model: claude-opus-4-6           # Provider-specific
budget:
  monthly_usd: 100.00
heartbeat: "*/30 * * * *"
network: api-only                # none | api-only | open
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
glorbo up acme    # Phase 4+ — dashboard not yet shipping a `up` verb
```

See **CLI Reference** below for what's actually wired in v0.0.1 today.

## CLI Reference

Commands wired in v0.0.1:

```
glorbo init [--force] [--skip-pull] [--example|--no-example]
                                  Bootstrap ~/.glorbo/ and verify deps
glorbo doctor [--json] [--fix]    Verify host prerequisites
glorbo help                       Print usage
```

Planned in subsequent phases (shape stable in `DESIGN.md` §10):

```
glorbo up [company]               Start orchestration for a company
glorbo down [company]             Stop orchestration
glorbo status                     Show companies, agents, active tasks
glorbo serve                      Dashboard + orchestration (foreground)
glorbo logs <company> [agent]     Tail an agent's stdout.log
glorbo reindex                    Rebuild SQLite index from filesystem
glorbo backup                     Tar up ~/.glorbo/
glorbo restore <archive>          Extract and reindex
glorbo console                    Elixir remote console
```

## How It Works

### The Director

You are the **Director**. You own the company. You hire agents, set the
mission, approve budgets, and intervene when needed. The CEO agent works for
you, not the other way around.

### Communication

**Inbox/Outbox** — An agent writes a markdown file to its `outbox/`. Glorbo
picks it up via `inotify`, checks permissions, and delivers it to the
recipient's `inbox/` or appends it to a channel. Agents never touch each
other's files directly — the Elixir Router mediates every transfer.

**Channels** — Append-only markdown files. Every message is a timestamped
section. Glorbo is the only writer (atomic, permission-checked). The
dashboard renders them as real-time chat.

### Execution (v0.0.1)

1. An event triggers an agent (new inbox item, heartbeat, channel mention).
2. Glorbo composes a bwrap argv for the agent's declared permissions,
   network policy, and CLI provider.
3. `Port.open/2` invokes `bwrap` with the prompt fed on stdin from a
   tempfile; the CLI tool (`claude -p`, `gemini -p`, `codex exec -`) runs
   inside the sandbox.
4. The CLI writes results to the agent's workspace/outbox.
5. Glorbo detects the output via inotify, routes messages, updates the
   index, appends to the audit log, and records token usage against the
   agent's budget.
6. The sandbox exits.

### Sandboxing (v0.0.1)

Every agent wake is a short-lived `bwrap` process:

- Baseline: `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid
  --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL`.
- Root filesystem: `--ro-bind /usr /usr`, merged-/usr symlinks, minimal
  `/etc` (resolv.conf, hosts, passwd, group, ssl certs) on top of a
  `--tmpfs /etc`.
- Agent-owned: workspace bind-mounted `rw`, outbox `rw`, inbox `ro`.
- Per-permission mounts spliced in from the `agent.md` frontmatter.
- CLI provider credentials (`~/.claude`, `~/.config/gemini`,
  `~/.codex`) bind-mounted `ro`, redirected via per-provider env
  (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`).

Network policy:

```
network: none        # --unshare-net (kernel-enforced egress block)
network: api-only    # Inherits host netns; HTTP(S)_PROXY points at an
                     #   allowlisted hostname proxy (advisory)
network: open        # Inherits host netns; no proxy
```

### Permissions

Declared in `agent.md`, enforced at two layers:

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

In v0.0.1 the kernel layer is the bwrap argv: denied paths aren't
bind-mounted. In v0.0.2 a second POSIX-ACL layer will enforce inside the
Company container.

## Tech Stack

| Component      | Technology                  | Why                                             |
|----------------|-----------------------------|-------------------------------------------------|
| Orchestration  | Elixir/OTP                  | Supervision trees, fault tolerance, concurrency |
| Dashboard      | Phoenix LiveView (Phase 4)  | Real-time UI, no JS framework                   |
| Agent Chat     | Phoenix Channels            | WebSocket pub/sub, built-in                     |
| Agent Runtime  | `bwrap(1)` + CLI tools      | **v0.0.1** — no Python needed                   |
| Agent Runtime  | Python in Podman (deferred) | **v0.0.2** — `litellm`, POSIX ACLs              |
| Local LLM      | Ollama (deferred)           | **v0.0.2** — private, offline, zero API cost    |
| Cloud LLM      | Claude, Codex, Gemini       | Via their official CLIs in v0.0.1               |
| Filesystem     | `inotify` + file_system     | Event-driven watcher                            |
| Database       | SQLite (via `ecto_sqlite3`) | Single file, zero setup, disposable             |
| Config/Data    | Markdown + YAML frontmatter | Human-readable, git-friendly, greppable         |
| Audit          | JSONL files                 | Append-only, never modified                     |
| Binary         | Burrito + bundled ERTS      | Single binary, no Erlang dependency             |

## Design Document

For the full architecture, see [DESIGN.md](DESIGN.md). When `DESIGN.md` and
this README disagree, `DESIGN.md` wins.

## Project Status

Pre-1.0 (currently **v0.0.1**). Milestone 01 (CLI-agent runtime) is in
active development:

- Phase 01 — Compilable skeleton + CI + signed releases ✓
- Phase 02 — Filesystem foundation, doctor, `glorbo init` ✓
- Phase 03 — Agents, router, kernel permissions, budgets ✓
- Phase 04 — LiveView dashboard (in progress)
- Phase 05 — Approvals, scheduler, backup/restore (planned)

See the [issues](https://github.com/foobarto/glorbo/issues) and
`.planning/phases/` for current work and known limitations. Planning
artifacts (`PLAN.md`, `RESEARCH.md`, `VERIFICATION.md`) are committed on
`main` — feel free to read ahead.

## Contributing

Contributions welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before
submitting a pull request.

Security reports: see [SECURITY.md](SECURITY.md). Please don't file
sandbox-escape findings as public issues.

The project is Elixir through and through in v0.0.1. Familiarity with OTP
supervision trees and Phoenix LiveView is helpful but not required — the
codebase is intentionally straightforward.

## License

[Apache License 2.0](LICENSE)

---

<sub>*You take the whole Glorbo. You put it on another machine. It's still a Glorbo. What part of this is complicated?*</sub>
