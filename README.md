<p align="center">
  <img src="assets/logo.png" alt="Glorbo" width="560">
</p>

<p align="center">
  <a href="https://github.com/foobarto/glorbo/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/foobarto/glorbo/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="https://github.com/foobarto/glorbo/releases/latest"><img alt="Release" src="https://img.shields.io/github/v/release/foobarto/glorbo?include_prereleases&sort=semver"></a>
  <a href="LICENSE"><img alt="License: MIT OR Apache-2.0" src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg"></a>
  <a href="https://elixir-lang.org"><img alt="Elixir" src="https://img.shields.io/badge/elixir-1.20.1-6E4A7E?logo=elixir&logoColor=white"></a>
  <a href="SECURITY.md"><img alt="Security Policy" src="https://img.shields.io/badge/security-policy-informational"></a>
  <a href="https://securityscorecards.dev/viewer/?uri=github.com/foobarto/glorbo"><img alt="OpenSSF Scorecard" src="https://api.securityscorecards.dev/projects/github.com/foobarto/glorbo/badge"></a>
  <a href="https://www.bestpractices.dev/projects/12943"><img alt="OpenSSF Best Practices" src="https://www.bestpractices.dev/projects/12943/badge"></a>
</p>

# Glorbo

> *Finally, a grumbo-compatible agent orchestrator. The fleeb juice is included.*

Glorbo is a self-hosted agent orchestration platform that models companies as
real organisations — org charts, goals, budgets, governance, chat — and runs
AI agents as employees inside kernel-level sandboxes.

**Like Obsidian, but for your agents.** Everything is markdown. Everything is a
file. No cloud, no SaaS, no Kubernetes — just a folder, some `bwrap` sandboxes,
and an Elixir process.

```
~/.glorbo/
├── glorbo                    # Single binary. That's the app.
├── glorbo.db                 # SQLite index. Rebuildable.
└── companies/acme/
    ├── company.md            # Mission, budget, settings
    ├── agents/ceo/AGENT.md   # Identity, permissions, model
    ├── channels/general.md   # Append-only chat logs
    ├── projects/<slug>/tasks/
    └── audit/2026-04.jsonl   # Append-only. Never modified.
```

Back up with `tar`. Version-control with `git`. Move with `scp`. Debug with
`cat`.

## Screenshots

<table>
  <tr>
    <td><img src="assets/screenshots/overview.png" alt="Overview" width="100%"></td>
    <td><img src="assets/screenshots/company.png" alt="Company" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies</code></sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;</code> — rollups, roster, org chart</sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/kanban.png" alt="Kanban" width="100%"></td>
    <td><img src="assets/screenshots/agent.png" alt="Agent" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/kanban</code></sub></td>
    <td align="center"><sub><code>/companies/&lt;co&gt;/agents/&lt;slug&gt;</code></sub></td>
  </tr>
  <tr>
    <td><img src="assets/screenshots/inbox.png" alt="Inbox" width="100%"></td>
    <td><img src="assets/screenshots/providers.png" alt="Providers" width="100%"></td>
  </tr>
  <tr>
    <td align="center"><sub><code>/companies/&lt;co&gt;/inbox</code> — unified approvals</sub></td>
    <td align="center"><sub><code>/providers</code> — CLI + native registry</sub></td>
  </tr>
</table>

Terminal phosphor aesthetic — monospace, OKLCH tokens, lowercase-slash panel
headers. No JS framework, no CSS build step.

## Features

- **Filesystem-first.** Agents, tasks, chat, permissions, goals, and audit
  logs are markdown + JSONL on disk. SQLite is a rebuildable index
  (`glorbo reindex`).
- **Kernel-sandboxed agents.** Every wake is a fresh `bwrap` process with
  user/IPC/PID/net/UTS namespaces unshared and `--cap-drop ALL`. Nothing
  escapes the bind-mount list.
- **Two provider kinds.** CLI adapters for `claude`, `gemini`, `codex`,
  `opencode`, `hermes`, `pi`, etc., plus native OpenAI-compatible endpoints
  (`openai`, `openrouter`, `minimax`, drop-in LM Studio / Ollama / llama.cpp /
  LocalAI / vLLM via `glorbo detect-providers` + `+ enable`). See GEP-32.
- **Budget governance.** Per-agent AND per-company monthly budgets in
  frontmatter; dispatch refuses at 100%, warns at 80%.
- **Permission model.** Declared in `AGENT.md`, enforced at both the Elixir
  router AND the kernel via bwrap mounts. No bind-mount → no access.
- **Real-time dashboard.** Phoenix LiveView at
  `http://127.0.0.1:4000`. Inotify repaints in under a second.
- **Approval + audit trail.** Tasks can require Director approval. Every
  decision writes a structured `YYYY-MM.jsonl` row.
- **Task chain observability.** Every `assigned_to:` flip appends to the
  task's `handoff_chain:` frontmatter; the `/companies/:co/tasks/:id/chain`
  view reconstructs the full multi-agent route with drift detection
  against the audit log (GEP-40).
- **Peer-review gate, auto-dispatched.** Tasks flagged
  `severity: major|critical` — or any task whose author opts in with
  `peer_review_required: true` — route through the `critiqueops`
  reviewer before Director approval can clear; the gate drops a
  wake sentinel into the reviewer's inbox so the review actually
  fires without manual intervention. Three-way verdict
  (approve/revise/block) is append-only per task; `revise` rounds
  the loop back to the original assignee with notes (GEP-41 +
  GEP-42).
- **Single Director write-channel.** Every filesystem mutation the
  Director-facing LiveViews can make flows through `Glorbo.Actions.*`
  modules with slug validation, atomic writes, threatmodel-appropriate
  symlink guards, and audit emission before the `File.*` call lands
  — enforced by a Credo ratchet that rejects raw writes under
  `lib/glorbo_web/live/` (GEP-36).
- **Optional git history.** `glorbo history init` opts the home
  tree into a derivative git repo with a tracked-scope
  `.gitignore` (durable state only; secrets, derived data, and
  per-agent transport dirs excluded). Every host-side write
  (Director or agent) lands as a kernel-committed commit with
  actor provenance; manual filesystem edits flow through the
  watcher fallback as `External` commits. CLI: `glorbo history
  {status, log, show, diff, restore}` (GEP-33).
- **Portable.** `glorbo backup | scp | glorbo restore` reproduces a working
  install on a fresh host.

## Quick Start

### Prerequisites (Linux)

- `bubblewrap` (`bwrap`), `passt` (for enforced `network: proxy`), `inotify-tools`.
- Ubuntu 24.04 / Debian 13: an unconfined AppArmor profile for `/usr/bin/bwrap`
  (template in `.github/workflows/ci.yml`).
- Either a provider CLI on `$PATH` or a native credentials file (see below).

`glorbo doctor` checks and, with `--fix`, repairs what it can.

### Install

**Homebrew (Linux x86_64 / aarch64):**

```bash
brew tap foobarto/tap
brew install glorbo
glorbo init
```

**Manual:**

```bash
curl -L https://github.com/foobarto/glorbo/releases/latest/download/glorbo-linux-$(uname -m) \
  -o ~/.local/bin/glorbo
chmod +x ~/.local/bin/glorbo
glorbo init
```

**macOS** (Intel + Apple Silicon):

```bash
brew tap foobarto/tap
brew install glorbo
glorbo init
```

Both Mach-O binaries are built by CI via Burrito's Zig-based cross-
compile from a Linux runner — no GHA macOS runners needed. On the
target Mac, `bwrap` has no equivalent, so agents run unsandboxed
with a one-time `agent.sandbox_unavailable` audit per company
boot; every other feature (dashboard, routing, scheduling, approval
gates, MCP server, audit log) matches Linux. FSEvents powers the
watcher, and the Burrito binary bundles its own BEAM runtime.

**Windows** — run the Linux binary inside
[WSL2](https://learn.microsoft.com/en-us/windows/wsl/install). No native
Windows port planned (bwrap / inotify / user namespaces).

### Add a native provider

```bash
mkdir -p ~/.config/glorbo/credentials && chmod 700 $_
cat > ~/.config/glorbo/credentials/openai.toml <<'EOF'
api_key = "sk-..."
EOF
```

> Provider config + credentials live under `~/.config/glorbo/` (GEP-61); a
> legacy `~/.local/etc/glorbo/credentials` tree is auto-migrated on first run.
> `GLORBO_CREDENTIALS_DIR` overrides the location.

Then point an agent at `provider: openai` (or `openrouter` / `minimax`) in
`AGENT.md`. The native tool catalog is `read_file` / `write_file` /
`edit_file` / `glob` / `grep` / `bash` / `web_fetch`. See GEP-32 for the
contract.

MiniMax ships with a static model catalog — `MiniMax-M3`, `MiniMax-M2.7`
(+`-highspeed`), and `MiniMax-M2.5` (+`-highspeed`); the `-highspeed`
variants are MiniMax's lower-latency serving tier with identical output.
Credentials go in `~/.config/glorbo/credentials/minimax.toml` (GEP-61;
`GLORBO_CREDENTIALS_DIR` overrides).

Or auto-detect a local server:

```bash
glorbo detect-providers     # probes ollama, llama.cpp, LocalAI, vLLM, LM Studio
```

### Hire an agent

Edit `~/.glorbo/companies/acme/agents/ceo/AGENT.md`:

```markdown
---
kind: agent/v1
slug: ceo
role: Chief Executive Officer
provider: claude-code     # or openai / openrouter / ...
model: claude-sonnet-4-5
network: proxy            # none | proxy | open
budget:
  monthly_usd: 100.00
heartbeat: "*/30 * * * *"
permissions:
  - projects:read:*
  - projects:write:*
  - tasks:create:*
  - agents:message:*
  - chat:write:*
---

You are the CEO of {{ company.name }}. Your mission: {{ company.mission }}.
```

### Start

```bash
glorbo up              # Detached daemon — dashboard at http://127.0.0.1:4000
glorbo status
glorbo logs acme ceo --follow
glorbo down
```

**Signing in (GEP-0053).** On first run the startup banner prints a
`http://127.0.0.1:4000/setup?token=…` URL — open it and choose a director
**passphrase**. After that the dashboard is reached at `/login` with that
passphrase; the one-time setup token is no longer needed in the browser.
MCP clients and CLIs keep using the `dashboard_token` (in
`~/.glorbo/config.md`) as an `Authorization: Bearer` API key — a token
leak no longer grants browser access once a passphrase is set. Forgot the
passphrase? Stop the daemon and run `glorbo reset-password` to return to
first-run setup.

To run as a user-level systemd service that survives shell sessions:

```bash
glorbo install         # writes ~/.config/systemd/user/glorbo.service + enable --now
sudo loginctl enable-linger "$USER"   # optional — survive logout
glorbo uninstall       # disable + remove the unit (keeps ~/.glorbo intact)
```

## CLI Reference

```
glorbo init [--force] [--no-example]    Bootstrap ~/.glorbo/ and verify deps
glorbo up | down | status | serve       Daemon lifecycle
glorbo reset-password                   Clear the dashboard passphrase → first-run setup (GEP-0053)
glorbo run <co>/<agent> <task>          One-shot agent dispatch (no dashboard)
glorbo install [--force] [--no-start]   Install user-systemd service (Linux)
glorbo uninstall                        Remove user-systemd service
glorbo new company|agent|project|skill  Scaffold
glorbo templates list|show              List/print agent + skill templates (GEP-10)
glorbo import paperclip <src> [--as]    Import a paperclip.ai agentcompanies tree
glorbo doctor [--json] [--fix]          Verify host prerequisites
glorbo detect-providers [--json]        Probe localhost for native providers
glorbo validate [PATH]                  Check files against FileSpec (GEP-25)
glorbo fmt [PATH] [--write]             Normalise frontmatter (GEP-25)
glorbo migrate                          Run Ecto migrations against glorbo.db
glorbo reindex                          Rebuild SQLite index from filesystem
glorbo fit [--use-case ...] [--host ..] Score local hardware → model fit (GEP-59)
glorbo memory index <co> --enable|--disable  Toggle a company's semantic-recall opt-in; the vector build runs on the next `reindex` (GEP-58)
glorbo backup | restore                 tar.gz roundtrip
glorbo logs <co> [agent] [--follow]     Tail audit or stdout
glorbo history <sub>                    Opt-in git history for ~/.glorbo/ (GEP-33)
glorbo shell                            [alpha] Interactive Director terminal (GEP-37)
glorbo console                          iex --remsh into the running daemon
glorbo version | --version | -V         Print the binary's version
glorbo help [<verb>]
```

The built-in `glorbo harness` subcommand is the internal native-provider
runtime invoked inside bwrap (GEP-32); Directors don't call it directly.

## How It Works

**Director + agents.** You are the Director. You own companies. Agents work
for you. The CEO agent is just the first employee.

**Inbox / outbox.** Agents write to their `outbox/`; Glorbo routes via the
Elixir router (permission-checked, atomic) into the recipient's `inbox/` or
a channel file. Agents never touch each other's directories directly.

**Execution.** An event (inbox item, heartbeat cron, channel mention) wakes
an agent. Glorbo composes a `bwrap` argv from the agent's permissions +
network policy, invokes the provider CLI or `glorbo harness` inside the
sandbox with the prompt on stdin, and reads the answer from
`$GLORBO_REPLY_PATH` when the process exits. Native providers additionally
emit `usage.json` for token accounting and per-tool audit events.

**Sandboxing baseline:**

```
--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid
--unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL
```

Plus workspace `rw`, outbox `rw`, inbox `ro`, per-permission mounts from
`AGENT.md`, and provider credentials bind-mounted `ro` with the right env
redirect (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
`GLORBO_NATIVE_CREDENTIALS_PATH`).

**Network policy:**

```
network: none    # --unshare-net (no egress possible)
network: proxy   # Linux: pasta-wrapped, only the Glorbo proxy port visible
network: open    # Inherits host netns
```

**Two-layer permissions.** The kernel layer is the bwrap mount list:
denied paths are simply not mounted. The Elixir router enforces the same
rules as belt-and-braces for cross-directory transfers.

## Tech Stack

| Component | Technology |
|-----------|------------|
| Orchestration | Elixir / OTP |
| Dashboard | Phoenix LiveView |
| Agent Runtime | `bwrap(1)` + provider CLI OR `glorbo harness` |
| LLMs | CLI (`claude`, `gemini`, `codex`, ...) or OpenAI-compatible endpoint |
| Filesystem | `inotify` + `file_system` (FSEvents on macOS) |
| Database | SQLite (via `ecto_sqlite3`) |
| Config / Data | Markdown + YAML frontmatter |
| Audit | JSONL files (append-only) |
| Binary | Burrito + bundled ERTS |

## Design Documents

- **[docs/DESIGN.md](docs/DESIGN.md)** — full living architecture.
- **[docs/geps/](docs/geps/)** — Glorbo Enhancement Proposals (numbered,
  append-only design records). Start with
  [GEP-1](docs/geps/0001-gep-purpose-and-guidelines.md),
  [GEP-2](docs/geps/0002-architecture-overview.md), and the
  [Zen of Glorbo](docs/geps/0011-zen-of-glorbo.md).
- **[docs/architecture.md](docs/architecture.md)** — module map + graph
  caveats (read before greping 200+ modules).
- **[CHANGELOG.md](CHANGELOG.md)** — full release history.

## Project Status

Pre-1.0. Latest release **v0.27.0** (2026-06-14). APIs, CLI flags, on-disk
layout, and SQLite schema may change between minor versions. See
[CHANGELOG.md](CHANGELOG.md) for the full release trail; see
[`docs/geps/`](docs/geps/) for which GEPs are Draft / Accepted /
Implemented.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports: [SECURITY.md](SECURITY.md).

Local dev loop:

```bash
git clone https://github.com/foobarto/glorbo && cd glorbo
mix setup           # deps + db + esbuild
mix phx.server      # dashboard on :4000
mix precommit       # format + compile-warn + credo + tests
```

Runtime is Elixir 1.20.1 / OTP 29.0.2 (pinned in `.tool-versions` —
`mise install` picks them up).

## License

Licensed under either of

- Apache License, Version 2.0
  ([LICENSE-APACHE](LICENSE-APACHE) or
  <http://www.apache.org/licenses/LICENSE-2.0>)
- MIT license
  ([LICENSE-MIT](LICENSE-MIT) or
  <http://opensource.org/licenses/MIT>)

at your option.

### Contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in the work by you, as defined in the Apache-2.0
license, shall be dual licensed as above, without any additional terms
or conditions.

---

<sub>*You take the whole Glorbo. You put it on another machine. It's still a Glorbo. What part of this is complicated?*</sub>

<img src="assets/glorbo_tv.png" alt="Glorbo and his pet robot watching Rick and Morty on TV — the show where Glorbo (the name) comes from" width="100%">
