<p align="center">
  <img src="assets/logo.png" alt="Glorbo" width="560">
</p>

<p align="center">
  <a href="https://github.com/foobarto/glorbo/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/foobarto/glorbo/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="https://github.com/foobarto/glorbo/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/foobarto/glorbo?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="License: Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue.svg"></a>
  <a href="https://elixir-lang.org"><img alt="Elixir" src="https://img.shields.io/badge/elixir-1.18.4-6E4A7E?logo=elixir&logoColor=white"></a>
  <a href="https://erlang.org"><img alt="OTP" src="https://img.shields.io/badge/otp-28.0-A90533?logo=erlang&logoColor=white"></a>
  <a href="#"><img alt="Platform" src="https://img.shields.io/badge/platform-linux%20x86__64%20%7C%20aarch64-lightgrey"></a>
  <a href="SECURITY.md"><img alt="Security Policy" src="https://img.shields.io/badge/security-policy-informational"></a>
  <a href="CONTRIBUTING.md"><img alt="PRs Welcome" src="https://img.shields.io/badge/PRs-welcome-brightgreen"></a>
  <a href="https://github.com/foobarto/glorbo/commits/main"><img alt="Last commit" src="https://img.shields.io/github/last-commit/foobarto/glorbo"></a>
</p>

# Glorbo

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted agent orchestration platform that models companies as
real organisations — with org charts, goals, budgets, governance, and
communication — and runs AI agents as employees inside kernel-level sandboxes.

**Like Obsidian, but for your agents.** Everything is markdown. Everything is a
file. Everyone has a Glorbo in their home directory.

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

## Screenshots

<table>
  <tr>
    <td><img src="assets/screenshots/overview.png" alt="Overview: company cards + next-step hint" width="100%"></td>
    <td><img src="assets/screenshots/company.png" alt="Company page: stat cards, 14-day rollup strip, agent roster, org chart" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies</code> — overview grid with inline slug-availability probe</sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;</code> — 14-day rollups: runs / success rate / tasks by status / by priority</sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/kanban.png" alt="Kanban board with goal filter and drag-drop lanes" width="100%"></td>
    <td><img src="assets/screenshots/agent.png" alt="Agent detail: identity, stdout tail, sandbox argv, config edit form" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/kanban?goal=&lt;slug&gt;</code> — goal-scoped board</sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;/agents/&lt;slug&gt;</code> — runs tab w/ tool-call counts, inline config edit</sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/goals.png" alt="Goals page: per-goal roll-up with status breakdown" width="100%"></td>
    <td><img src="assets/screenshots/skills.png" alt="Skills marketplace: builtin / custom / shadowed" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/goals</code> — goal-scoped task rollups (v0.0.3)</sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;/skills</code> — builtin + custom skills with used-by counts (v0.0.3)</sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/inbox.png" alt="Unified director inbox with approve / deny / archive" width="100%"></td>
    <td><img src="assets/screenshots/audit.png" alt="Audit feed with two-letter actor avatars" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/inbox</code> — Mine / Recent / All / Archive (v0.0.3)</sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;/audit</code> — <em>&lt;actor&gt; &lt;verb&gt; &lt;object&gt;</em> sentence rendering + avatars</sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/approvals.png" alt="Approval queue with prompt diff and j/k/y/n keyboard" width="100%"></td>
    <td><img src="assets/screenshots/providers.png" alt="Provider registry: claude-code, codex, gemini-cli, hermes, opencode, pi" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/approvals</code> — prompt diff · <kbd>j</kbd>/<kbd>k</kbd>/<kbd>y</kbd>/<kbd>n</kbd></sub></td>
    <td align="center"><sub><code>/providers</code> — config-driven CLI registry (GEP-8)</sub></td>
  </tr>
</table>

Terminal phosphor aesthetic throughout — monospace, OKLCH tokens,
lowercase-slash panel headers. No JS framework, no build step for the
CSS.

## Features

**Filesystem-first architecture** — Agents, tasks, chat, permissions, goals,
and audit logs are all markdown and JSONL files on disk. SQLite exists only as
a rebuildable index for dashboard queries. Delete it anytime; `glorbo reindex`
brings it back in seconds.

**Kernel-sandboxed agents** — Every agent wake is a fresh `bwrap`
sandbox: `--unshare-user-try --unshare-ipc --unshare-pid --unshare-net
--die-with-parent --cap-drop ALL`. The workspace is `--bind`-mounted writable;
nothing else is visible. Network isolation is kernel-enforced, not
policy-enforced.

**CLI-tool agents** — Use the Claude Code, Gemini CLI, or Codex installs
already on your machine. Credentials are `--ro-bind`ed into the sandbox;
session state stays on the host. No new API keys to manage.

**Config-driven providers (v0.0.3, GEP-8)** — Each provider is a TOML
entry declaring how to invoke a CLI and how to parse its usage. Built-in
providers ship under `priv/providers/*.toml`; drop your own into
`~/.glorbo/providers.toml`. The `/providers` LiveView shows what's
routable. No Elixir code needed to register a new CLI.

**Local-first LLMs** — Agents use whichever CLI is installed on your
host (`claude`, `gemini`, `codex`, and OSS alternatives like `opencode`,
`hermes`, `pi`). Add a local model by installing its CLI; Glorbo detects
it via `glorbo doctor` or the `/providers` panel. No bundled runtime,
no SDK layer.

**Reply-file contract (v0.0.3, GEP-8)** — Every sandboxed invocation
ends with Glorbo reading the file at `$GLORBO_REPLY_PATH`. Agents
scaffolded by `glorbo new agent` are pre-populated with a system prompt
that instructs the CLI to write its final answer there. Failures
(missing / empty / too-large) surface as structured dispatch errors
in the audit log.

**Real-time dashboard** — Phoenix LiveView at `http://127.0.0.1:4000`
provides company overview, kanban board, agent monitoring with stdout
streaming, chat, approval queue, audit viewer, system health, and a
provider-registry panel at `/providers` (v0.0.3). Inotify events
repaint the UI in under a second with no polling. No JavaScript
framework. No build step.

**Director-centric surfaces (v0.0.3, GEP-20)** — Unified `/inbox`
with Mine/Recent/All/Archive tabs aggregating approvals + audit
activity; dedicated `/goals` page roll-up per company-declared
goal; `/skills` bundle view listing builtin + user-override
skills with used-by counts; inline AgentLive config edit form
that writes AGENT.md frontmatter in place; 14-day rollup strip
on every company dashboard (runs / success rate / tasks by
status / by priority); two-letter actor avatars on audit,
channel, and inbox rows; inline slug-availability probe on the
new-company modal; `⌘K` command palette with per-company
destinations + director actions; tool-call counts on Claude-Code
runs (`Bash×1, Read×2` on the Runs tab).

**Director safety + speed (v0.0.3-dev, loop session)** —
**Emergency stop** (topbar kill switch that halts every running
dispatch and refuses new ones until cleared);
**cost ledger** at `/costs` showing per-agent monthly spend for
the last 12 months; **Ctrl+K content search** covers task titles
across the focused company (cached by mtime); **brain dump**
surface (`g b`) captures throwaway thoughts into a daily log and
converts any entry to a task; **recurring tasks** (`schedule:`
frontmatter with cron or `hourly`/`daily`/`weekly`/`monthly`
aliases) fire scheduled dispatches via a per-company
`TaskScheduler`, auto-reset to `todo` on `done`, and render a
`↻` pill on the kanban; **chat rotation** archives channel logs into
`channels/archive/<channel>/<ts>.md` when size / line thresholds
trip, with an in-page archive browser; **per-task model /
provider override** and **named model aliases** on agents let
one task pin a specific LLM without editing the agent;
**natural-language heartbeat** compiles `"every morning at 9am"`
to cron at parse time; **per-task audit history panel** on every
task page shows a live-refreshing slice of the audit log scoped
to that task (dispatch / retry / scheduled-fire / update) with a
deep-link into the full audit view pre-filtered to the task id.

**Agent chat** — Talk to your agents. Agents talk to each other. Channels are
append-only markdown files underneath. Phoenix Channels handles real-time
delivery.

**Company isolation** — Each company's data lives in its own directory under
`~/.glorbo/companies/`. The bwrap sandbox bind-mounts only the active
company's directory; sibling companies are simply not in the mount list.

**Permission model** — Declared in markdown frontmatter, enforced at two
layers by design: the Elixir Router (application) and the Linux kernel
via `bwrap` mount namespaces. An agent without `projects:write:foo`
literally cannot write there.

**Budget governance** — Per-agent AND per-company monthly budgets
declared in markdown frontmatter (`budget_usd_cents_month:` on
`AGENT.md` or `company.md`). Dispatch refuses new work at 100%,
warns at 80%. No runaway API bills at 3 AM.

**Approval gates** — Tasks can require Director approval before execution.
The agent pauses, you review, one click to approve.

**OTP supervision** — If an agent crashes, only that agent restarts. If a
company crashes, only that company's agents restart. The dashboard and other
companies are unaffected. That's just what the BEAM does.

**Portable** — Deploy by copying a binary. Upgrade by replacing it. Move by
tarring the directory. The BEAM VM is bundled in the release via Burrito.
`glorbo backup` → `scp` → `glorbo restore` + `glorbo doctor --fix` reproduces
a functional install on a fresh host (verified end-to-end by
`test/integration/portability_test.exs`).

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

**Homebrew (Linux — x86_64 and aarch64):**

```bash
brew tap foobarto/tap
brew install glorbo
glorbo init
```

**Manual (direct binary):**

```bash
curl -L https://github.com/foobarto/glorbo/releases/latest/download/glorbo-linux-$(uname -m) \
  -o ~/.local/bin/glorbo
chmod +x ~/.local/bin/glorbo

glorbo init
```

**macOS** builds are on the roadmap — bwrap + inotify don't map 1:1
to macOS primitives, so early macOS support will degrade
gracefully (unsandboxed agent execution) with explicit caveats.
For now, Linux only.

**Windows** is supported via [WSL2](https://learn.microsoft.com/en-us/windows/wsl/install).
The Linux binaries above run unchanged inside a WSL2 distro
(Ubuntu, Fedora, etc.) — that's the supported way to run Glorbo
on a Windows host. There are no native Windows builds and none
are planned; the agent runtime depends on Linux kernel primitives
(bwrap sandboxing, inotify, user namespaces) that don't have
useful Windows equivalents.

`glorbo init` creates the directory hierarchy, verifies prerequisites via
`glorbo doctor`, and optionally scaffolds an example company.

### Local development

Build, run, and iterate on the code without touching the shipped binary.

**Prerequisites (dev-only, on top of the runtime ones above):**

- Elixir 1.18.4 / OTP 28.0.2 — pinned in `.tool-versions`; the recommended
  way to get them is [mise](https://mise.jdx.dev):
  ```bash
  mise install   # reads .tool-versions, installs both
  mise activate bash  # or zsh; add to your shell rc
  ```
- A C toolchain for native NIFs (`build-essential` / `base-devel` /
  equivalent).
- `inotify-tools` on the host — the LiveView watcher needs it for
  sub-second UI refresh.

No Node.js, no npm. Esbuild is shipped as a Hex package and runs
through `mix assets.build`.

**Clone + bootstrap:**

```bash
git clone https://github.com/foobarto/glorbo && cd glorbo
mix setup   # fetches deps, creates/migrates dev DB, installs esbuild
```

**Run the dev server:**

```bash
mix phx.server
# Dashboard at http://localhost:4000, live-reloaded on file change.
```

Dev-mode data lives in `~/.glorbo/`; the dashboard reads the same
filesystem as the installed binary. Scaffold a test company with
`mix run -e 'Glorbo.Init.run([])'` or — easier — invoke the CLI
subcommands directly from iex:

```bash
iex -S mix phx.server
# iex> Glorbo.CLI.dispatch(["new", "company", "acme"])
```

**Test + lint gates:**

```bash
mix test                 # full suite; creates/migrates test DB first
mix credo --strict       # zero-findings bar; CI fails on exit code 8
mix format --check-formatted
mix precommit            # compile --warnings-as-errors + format + test
```

Run `mix precommit` before pushing non-trivial changes — CI runs the
same gates and refuses red.

**Build a release:**

```bash
mix release              # Burrito-wrapped single binary → burrito_out/
```

The release binary embeds the BEAM runtime and is the same shape the
GitHub release ships.

**Project layout at a glance:**

| Path                        | What                                                    |
| --------------------------- | ------------------------------------------------------- |
| `lib/glorbo/`               | Kernel, CLI, agent runtime, filesystem, budget, doctor  |
| `lib/glorbo_web/`           | Phoenix endpoint, router, LiveViews, components         |
| `priv/providers/*.toml`     | Bundled CLI-provider manifests (GEP-8)                  |
| `assets/css/` + `assets/js/` | Dashboard styles + the small JS bundle (hooks + shortcuts) |
| `docs/geps/`                | Design decision records — start with GEP-1              |
| `test/`                     | ExUnit suite, integration tests tagged `:integration`   |
| `CLAUDE.md`                 | Codebase invariants + common commands (load-bearing)    |

**Agent-runtime dev loop:**

Agent dispatch needs `bwrap` and the provider CLI installed on the
host. From inside `iex -S mix phx.server`:

```elixir
# Poke the provider registry
Glorbo.CLI.Registry.list()

# Wake an agent (writes state/wake-request.md, the supervisor picks up)
GlorboWeb.Actions.wake_agent("acme", "ceo", "dev smoke test")
```

Stdout streams into the `/companies/acme/agents/ceo` LiveView. Every
invocation appends to `audit/YYYY-MM.jsonl` — check that file if you
don't see what you expect in the dashboard.

### Verify

```bash
glorbo doctor
```

Reports on the full dependency chain: kernel version, `uidmap`, disk space,
`~/.glorbo/` layout, ERTS, bwrap, user namespaces, installed CLI tools
(Claude Code, Gemini CLI, Codex, etc.), and tar-zstd.

### Hire an Agent

Edit `~/.glorbo/companies/acme/agents/ceo/agent.md`:

```markdown
---
name: CEO
role: Chief Executive Officer
provider: claude-code            # claude-code | gemini | codex
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
glorbo up              # Detached daemon — dashboard at http://127.0.0.1:4000
glorbo status          # Check daemon pid + uptime
glorbo logs acme ceo --follow
glorbo down            # Graceful SIGTERM → 10s grace → SIGKILL escalation
```

## CLI Reference

All verbs from `DESIGN.md` §10 are wired; the shipped surface as of v0.0.3:

```
glorbo init [--force] [--skip-pull] [--example|--no-example]
                                  Bootstrap ~/.glorbo/ and verify deps
glorbo up                         Start detached daemon (dashboard + supervision)
glorbo down                       Graceful shutdown via SIGTERM → SIGKILL
glorbo status                     Pidfile state + uptime
glorbo serve                      Foreground-blocking supervision (for systemd)
glorbo run <script>               One-shot script execution
glorbo new company <slug>         Scaffold a new company directory
glorbo new agent <co>/<slug>      Scaffold a new agent (--template supported)
glorbo new project <co>/<slug>    Scaffold a new project
glorbo new skill <co> <name>      Scaffold a new skill (--template supported)
glorbo templates list [kind]      List agent/skill templates (GEP-10)
glorbo templates show <kind> <name>
                                  Print a template's contents
glorbo import paperclip <src>     Import a paperclip.ai agentcompanies tree
glorbo logs <co> [agent] [--follow]
                                  Tail audit log or agent stdout (inotify-backed)
glorbo doctor [--json] [--fix]    Verify host prerequisites; 7 auto-fixers
glorbo reindex                    Rebuild SQLite index from filesystem
glorbo migrate                    Run pending Ecto migrations
glorbo backup [--output <path>]   tar.gz of ~/.glorbo/ with WAL checkpoint
glorbo restore <archive> [--force]
                                  Extract + migrate + reindex + doctor --fix
glorbo console                    iex --remsh into the running daemon
glorbo help                       Print usage
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

### Execution

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

### Sandboxing

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

The kernel layer is the bwrap argv: denied paths aren't bind-mounted.
The application layer (Elixir Router) validates cross-directory
transfers as belt-and-braces above the kernel.

## Tech Stack

| Component      | Technology                  | Why                                             |
|----------------|-----------------------------|-------------------------------------------------|
| Orchestration  | Elixir/OTP                  | Supervision trees, fault tolerance, concurrency |
| Dashboard      | Phoenix LiveView            | Real-time UI, no JS framework                   |
| Agent Chat     | Phoenix Channels            | WebSocket pub/sub, built-in                     |
| Agent Runtime  | `bwrap(1)` + CLI tools      | One binary per CLI install; no Python, no SDKs  |
| LLMs           | Whatever CLI you install    | `claude`, `gemini`, `codex`, `opencode`, etc.   |
| Filesystem     | `inotify` + file_system     | Event-driven watcher                            |
| Database       | SQLite (via `ecto_sqlite3`) | Single file, zero setup, disposable             |
| Config/Data    | Markdown + YAML frontmatter | Human-readable, git-friendly, greppable         |
| Audit          | JSONL files                 | Append-only, never modified                     |
| Binary         | Burrito + bundled ERTS      | Single binary, no Erlang dependency             |

## Design Documents

For the full living architecture, see [DESIGN.md](DESIGN.md). When
`DESIGN.md` and this README disagree, `DESIGN.md` wins.

For the *why* behind major design decisions, see the **Glorbo
Enhancement Proposals** under [`docs/geps/`](docs/geps/) — numbered,
append-only design records. [GEP-1](docs/geps/0001-gep-purpose-and-guidelines.md)
explains the process; [GEP-2](docs/geps/0002-architecture-overview.md)
is the architectural overview. The [Zen of Glorbo](docs/geps/0011-zen-of-glorbo.md)
captures the project's design philosophy in one page.

## Project Status

Pre-1.0. **v0.0.2** shipped 2026-04-16 and closed Milestone 01 (CLI-agent
runtime):

- Phase 01 — Compilable skeleton + CI + signed releases ✓
- Phase 02 — Filesystem foundation, doctor, `glorbo init` ✓
- Phase 03 — Agents, router, kernel permissions, budgets ✓
- Phase 04 — LiveView dashboard + Channels + PubSub ✓
- Phase 05 — CLI completeness + backup/restore + portability ✓

**v0.0.3** shipped 2026-04-19:

- **GEP-8 — provider registry + CLI auto-detect** ✓
- **GEP-10 — agent and skill templates** ✓ (`--template` on
  `glorbo new agent` + `glorbo new skill`, CEO/engineer/researcher
  templates built in, role-specific SOUL.md and HEARTBEAT.md
  auto-wired)
- **GEP-12 — no user-input atoms** ✓
- **GEP-13 — project-prefixed task IDs** ✓
- **GEP-14 — agent heartbeat semantics + HEARTBEAT.md** ✓
- **GEP-15 — ALLCAPS agent-facing markdown convention** ✓
- **GEP-16 — agent wake + dispatch pipeline** ✓
- **GEP-19 — director approval workflow protocol** ✓
- Reply-file contract (breaking — existing agents need an
  updated system prompt; `glorbo new agent` scaffolds this
  automatically).
- **`glorbo import paperclip <src>`** — import paperclip.ai
  `agentcompanies` trees; wraps each agent's `AGENTS.md` in
  Glorbo frontmatter, preserves HEARTBEAT/SOUL/TOOLS verbatim,
  prints a hint report naming every paperclip-ism the Director
  should hand-fix.
- **Dashboard UX overhaul** (M-series) ✓ — mockup-aligned shell
  (260px tri-section sidebar, topbar with `▚ GLORBO` + company
  picker, terminal-TUI phosphor tokens), company overview with
  stat cards + agent roster + org chart, agent-detail
  three-column layout with a right-panel collapse rail (auto
  on viewports < 1200px), Kanban drag-and-drop with `status:`
  frontmatter writeback, chat channel switcher + DM thread
  enumeration, approvals prompt-diff with `j/k/y/n` keyboard,
  audit unified free-text search, providers card grid with TOML
  snippet, global `g o/h/p` shortcuts, TWEAKS drawer, themed
  scrollbars, `+ new company/agent/task` entry points.
- **Approval workflow polish** — director/agent `assigned_to`
  swap on approval-request/grant/deny (preserved across the
  Gate daemon and UI-direct code paths), denial reason
  persisted into task frontmatter and audit, Escape closes all
  modals, Gate audit events now use canonical `target:` key.
- **Stdout streamer hardening** — CR / OSC / BEL stripping so
  terminal noise doesn't leak into the UI, autoscroll that
  unpins when the user scrolls up to read older output.
- **Accessibility sweep** — every `role="button"` surface gained
  `phx-keydown="Enter"` activation and a descriptive
  aria-label (task cards, agent table rows, approval rows,
  permission rows, file-tree actions as real `<button>`s).
- Dashboard hardening ✓ — auto-start company supervisors at app
  boot (fixes AuditLog-not-registered crash on every Director
  write-action).
- Tests: 895/895 green · `mix credo --strict` clean ·
  `mix gep.validate` clean

Pending for a later release: `api-only` netns + nftables egress
hardening; the wider GEP-9 (MCP/ACP protocol integration) and
GEP-17 (cross-OS sandbox + watcher) design work; optional
GEP-18 agentcompanies/v1 schema convergence.

Active design work lives in `docs/geps/`. Historical phase plans
are in `git log` for anyone who needs the archaeology.

## Contributing

Contributions welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before
submitting a pull request.

Security reports: see [SECURITY.md](SECURITY.md). Please don't file
sandbox-escape findings as public issues.

The project is Elixir through and through. Familiarity with OTP
supervision trees and Phoenix LiveView is helpful but not required — the
codebase is intentionally straightforward.

## License

[Apache License 2.0](LICENSE)

---

<sub>*You take the whole Glorbo. You put it on another machine. It's still a Glorbo. What part of this is complicated?*</sub>
