# Phase 3: CLI Agent Runtime + bwrap Isolation + Routing + Budgets - Research

**Researched:** 2026-04-16
**Domain:** Linux unprivileged sandboxing (bwrap) + CLI-agent dispatch + session-telemetry budget parsing + OTP per-agent supervision
**Confidence:** HIGH

## Summary

Bubblewrap is the correct kernel-layer isolation primitive for CLI-first agents. On the target host (Fedora Bazzite 43, kernel 6.17.7, bwrap 0.11.0), user namespaces are unconditionally available (`user.max_user_namespaces = 254351`) and no AppArmor restrictions apply. The pivot away from Podman + POSIX ACL reduces implementation surface by roughly 60% while keeping the "kernel is the policy engine" invariant intact — bwrap's mount namespace enforces filesystem isolation at the VFS layer, which `ls` inside the sandbox cannot even see past.

Each of the three supported CLI tools has a verifiable token-usage path. Claude Code writes `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl` with per-assistant-turn `usage` objects (verified on this machine against live session files — field names locked). Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` with NDJSON `event_msg` records containing `payload.type == "token_count"` and cumulative `total_token_usage` (verified on this machine). Gemini CLI 0.6.1+ with `--output-format json` returns `stats.models.<model>.tokens.{prompt,candidates,cached,thoughts,tool,total}` in a single JSON object to stdout — Glorbo captures stdout as the authoritative usage source for Gemini (no session-file tail needed). This gives budget parity across the three providers without any wrapper scripts.

The `api-only` network policy is the weakest spot. HTTPS proxies cannot filter HTTPS by hostname without TLS interception, and TLS interception would break the CLI tools' certificate pinning and auth flows. The pragmatic v0.0.1 ship is exactly what CONTEXT.md's D-17 proposes: set `HTTPS_PROXY` env var to a localhost proxy that accepts HTTP `CONNECT` and validates the `Host:port` of the CONNECT line against a static allowlist, then tunnels the raw TLS bytes through. This is advisory-strength (an agent ignoring `HTTPS_PROXY` bypasses it) but is the only option short of a hardened netns + nftables path, which CONTEXT.md explicitly defers. Recommend a small custom Elixir CONNECT proxy under `Glorbo.Network.Proxy` rather than tinyproxy: tinyproxy's `FilterDefaultDeny` only works for plain HTTP, not HTTPS CONNECT tunnels, so it provides no real protection against the CLI tools (which exclusively use HTTPS).

**Primary recommendation:** Ship the 6-child supervision tree with `Glorbo.Sandbox.Bwrap.build_argv/2` as a pure function (unit-tested argv composition, integration-tested `:bwrap` tag) and per-provider adapters that parse their respective session telemetry. For v0.0.1 `api-only`, ship an Elixir-native HTTPS CONNECT proxy with allowlist enforcement; document it as advisory; mark netns+nftables as a hardening iteration. Use `MuonTrap.Daemon` (already in deps) with `--die-with-parent --unshare-pid` to guarantee bwrap cleanup.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**CLI agent dispatch (D-01 … D-07):**
- D-01: Agent invocation shape `bwrap <sandbox-args> <cli-tool> -p <prompt>`. One process tree per invocation, clean exit reclaims all resources. No persistent process pool.
- D-02: Supported providers in v0.0.1 — `claude-code`, `gemini-cli`, `codex`. Strict allowlist. Unknown provider → parse-time error.
- D-03: Prompt delivery — write `task-prompt.md` to `.glorbo-run/<task-id>/`; CLI invoked with prompt via stdin AND workspace as cwd.
- D-04: Skills materialisation — Elixir copies skills listed in `agent.md` from `~/.glorbo/skills/<n>.md` to agent workspace `.glorbo-skills/<n>.md` just before invocation. Also writes `.glorbo-skills/INDEX.md`. Prompt includes "Available skills in `.glorbo-skills/`".
- D-05: Cleanup — post-invocation, Elixir removes `.glorbo-run/<task-id>/` and `.glorbo-skills/`. Agent's own files (`outbox/`, `workspace/`, `state/`) persist.
- D-06: Timeout — global default 300s, per-agent override via `agent.md` `timeout_seconds:`. On timeout SIGTERM → 5s → SIGKILL. Logs `timeout` audit event.
- D-07: stdout/stderr streamed to `agents/<name>/stdout.log` via `Port` → `File.open!([:append, :sync])`.

**bwrap sandbox architecture (D-08 … D-13):**
- D-08: Base flags — `--die-with-parent --unshare-user-try --unshare-ipc --unshare-pid --unshare-uts --unshare-cgroup-try --new-session --cap-drop ALL`.
- D-09: Filesystem bind strategy — ro-bind `/usr /bin /lib /lib64 /etc`; bind agent workspace rw; ro-bind agent inbox; per-permission mounts (D-11); everything else NOT mounted; `--tmpfs /tmp`; `--proc /proc`; `--dev /dev`.
- D-10: Default-deny for other companies — absolute, enforced by "not mounted = not visible".
- D-11: Permission → bwrap mapping (exact table in CONTEXT.md).
- D-12: Sibling-agent invisibility — `agents:list` exposes only siblings' `agent.md` via staging tmpfs.
- D-13: Testing hook — `Glorbo.Sandbox.Bwrap.build_argv/2` returns a plain argv list; integration tests tagged `:bwrap`.

**Network policy (D-14 … D-18):**
- D-14: Policy values `none | api-only | open`.
- D-15: Enforcement via bwrap — `none` = `--unshare-net`; `api-only` = shared netns + HTTP_PROXY env (simpler D-17 route); `open` = inherit host netns.
- D-16: `api-only` static base list in `config/network_policy.exs`; per-company override via `company.md` `network_allow:`.
- D-17: `api-only` initial implementation — HTTP_PROXY/HTTPS_PROXY env + Glorbo-managed proxy with hostname allowlist. Motivated bypass possible in v0.0.1; netns+nftables deferred.
- D-18: `api-only` integration test — mock server at allowed + disallowed hosts.

**Router + Watcher wiring (D-19 … D-22):** Single per-company `Glorbo.Company.Router` GenServer. Rejection → `history/<id>.rejected.md` + rejection-notice in sender inbox + audit. Channel append-only `[:append, :sync]`. `@<name>` mentions scanned, synthetic mention message to `agents/<name>/inbox/mentions/<ts>-<channel>.md`. No agent has `agents:create` in v0.0.1.

**Scheduler (D-23, D-24):** `crontab` Hex (already in deps), `Crontab.Scheduler.get_next_run_date/1`, `Process.send_after`. Recompute wall-clock on every firing.

**Per-agent GenServer (D-25 … D-28):** `Glorbo.Agent.Server` under `Glorbo.Company.AgentSupervisor` (DynamicSupervisor). State = `{company_slug, agent_slug, pending_wakes, current_task, budget_state}`. Wake-queue dedup. Dispatch pipeline: budget check → skills → prompt → CLI resolve → bwrap argv → Port.open → stdout tail → wait → usage parse → budget record → skills cleanup → workspace cleanup. Per-agent `Task.Supervisor`.

**Budget tracking (D-29 … D-33):** Usage source per CLI telemetry (Claude JSONL; Gemini stdout JSON; Codex rollout JSONL). Cost via `config/llm_rates.exs` per-model rate table. Ledger = existing `Glorbo.Budget` schema (Plan 03-01). Hard-stop = pre-dispatch check. Alert marker = `alerts/<agent>-budget.md`.

**Approval gates (D-34 … D-37):** Sentinel `agents/<name>/state/awaiting-approval-<task_id>.md` + `approval.requested` audit. Director edits task `status: approved` → Watcher → Gate → wake with `director-approval`. `Glorbo.Approvals.Gate` GenServer per-company. Denial = `approval.denied` + sentinel removed + task → `history/`.

**Skills injection (D-38 … D-40):** `Glorbo.Skills.Resolver.materialize/3`. Missing skill → `skill.missing` audit + dropped. Order = `agent.md` list order.

**Provider adapters (D-41 … D-43):** `Glorbo.CLI.Adapter` behaviour with `binary/0, args/3, usage_path/2, parse_usage/1`. Three adapters: `ClaudeCode, GeminiCli, Codex`. Validation — `provider:` in allowlist + CLI binary on `PATH` (else `provider.unavailable` + no-wake).

**Supervision tree (D-44, D-45):** 6-child Company supervisor: AuditLog + Filesystem.Watcher + Router + Scheduler + BudgetTracker + AgentSupervisor. `Approvals.Gate` lives under Router (not as seventh sibling). Crash recovery: Router ← Watcher re-emission; BudgetTracker ← SQLite ledger; Scheduler ← filesystem `agent.md`.

### Claude's Discretion

- Exact `bwrap` argv ordering and grouping (security-relevant — researcher proposes locked canonical order).
- Whether skill materialisation happens at wake-time or at container-start.
- TinyProxy vs HTTP-filtering proxy vs custom `Glorbo.Proxy` for `api-only`.
- Cron parsing library edge cases — `crontab` selected.
- Per-agent `Task.Supervisor` placement (child of agent GenServer vs sibling under AgentSupervisor).
- Workspace cleanup granularity — per-task-id vs per-invocation vs per-day.
- Adapter module naming.
- Whether `agent.md`'s `model:` field is required for each provider.
- Audit event naming for Phase 3 events.

### Deferred Ideas (OUT OF SCOPE)

- Python-in-container agent runtime + litellm dispatch → `.planning/deferred/container-runtime-v0.0.2/`
- POSIX ACL enforcement (`ACLMapper` dormant)
- Per-agent Linux user provisioning (`UidAllocator` dormant)
- LLM-05 offline Ollama inference
- Anthropic/OpenAI/Google direct-SDK providers
- `api-only` via netavark / in-namespace nftables
- Agent-created agents
- Router-level rate limiting
- Websocket/SSE stdout streaming
- Time-based permission windows
- Per-message quotas

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| AGT-01 | Per-company OTP supervision tree — crash isolation | 6-child supervisor tree (D-44); per-agent `DynamicSupervisor`; `Task.Supervisor` isolates Port work (D-28). Verified pattern against Phase 2 `Glorbo.Company.Supervisor`. |
| AGT-02 | Agent wake triggers: inbox inotify, cron heartbeat, channel mention, Director request | `Glorbo.Filesystem.Watcher` already routes inbox events (Phase 2); `crontab` + `Process.send_after` for heartbeats; Router scans `@<name>` mentions; `Agent.Server.wake/2` takes `trigger :: :inbox | :heartbeat | :mention | :director-request`. |
| AGT-03 | Inbox/outbox one-way flow via Router | Router is single choke point; no public `write_inbox/*` function (stub comment confirms); channel writes enforced by Router-only path with `[:append, :sync]`. |
| AGT-04 | Skills system — markdown injected into agent context at runtime | `Glorbo.Skills.Resolver.materialize/3` copies skills to `.glorbo-skills/` before invocation + cleanup after (D-04, D-05). Worker `skills_resolved` field (Plan 03-01) dormant until container runtime phase. |
| AGT-05 | Agent creation is Director-only | Router rejects any routed message whose payload would write `agents/<new>/agent.md`; no agent has `agents:create` permission in v0.0.1 (D-22). |
| SEC-01 | Declarative permissions enforced at Elixir Router | `Glorbo.Security.ACLMapper.check_action/2` (Plan 03-01, already shipped). Router calls this pre-route. Already unit-tested (20 cases). |
| SEC-02 | Same permissions enforced at kernel layer via bwrap | `Glorbo.Sandbox.PermissionMapper` translates permissions → bwrap `--ro-bind`/`--bind` flags per D-11 table. Parent dir NOT mounted when only child permitted = sibling projects invisible via VFS. |
| SEC-03 | Per-agent network policy — none/api-only/open | `--unshare-net` for `none` (kernel-enforced); `HTTPS_PROXY=localhost:<port>` + `Glorbo.Network.Proxy` for `api-only` (advisory in v0.0.1); inherit netns for `open`. |
| SEC-04 | Director-approved approval gates for `requires_approval: director` | `Glorbo.Approvals.Gate` GenServer + `TasksApprovalState` schema (Plan 03-01, already shipped). Sentinel file + Watcher-driven status-change detection. |
| SEC-05 | Per-agent monthly USD budget with alert + hard-stop, parsed from CLI session telemetry | Three-adapter usage parsing; existing `Glorbo.Budget` schema (Plan 03-01); `BudgetTracker.check_budget/1` pre-dispatch gate; alert marker file; `budget.hard_stop` audit event. |
| LLM-03 | Cloud providers via `agent.md` — v0.0.1 providers `claude-code | gemini-cli | codex`, each CLI manages own auth | Provider adapter behaviour + three adapters; `provider:` parse-validated at agent load; CLI binary presence verified at agent wake (else `provider.unavailable`). |
| LLM-04 | One provider + model per agent | Validation in `agent.md` parser: exactly one `provider:` + one `model:` field, no list syntax. Model forwarded as `--model` (claude-code), `-m` (gemini / codex). |

</phase_requirements>

## Project Constraints (from CLAUDE.md)

Load-bearing invariants that research findings must respect:

1. **Kernel is the policy engine.** For Phase 3, bwrap is the kernel layer. An agent that lacks `projects:write:foo` literally cannot write to `/projects/foo/` because that path is not bind-mounted into its sandbox. Application-only checks are a design bug.
2. **Filesystem is source of truth.** SQLite budget/approval tables are derived from CLI session telemetry + task file frontmatter; `glorbo reindex` must be able to reconstruct them from disk.
3. **One-way inbox/outbox.** Router mediates every transfer; no direct agent-to-agent writes.
4. **Audit log is append-only.** All Phase-3 events go through `Glorbo.Company.AuditLog.append/2` exclusively (AUDIT_EVENTS.md registry).
5. **Python never runs on the host.** Phase 3's v0.0.1 runtime has zero Python — containers + litellm are deferred.
6. **Company isolation is absolute.** bwrap enforces this at the VFS layer; other companies' paths are not in any mount of the sandbox.
7. **OTP crash isolation.** 6-child supervision tree strategy `:one_for_one`; per-agent DynamicSupervisor so one agent crash doesn't cascade.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `bubblewrap` (host) | ≥ 0.8.0; target has 0.11.0 | Unprivileged sandbox launcher (mount, pid, net, ipc, uts, cgroup namespaces) | The Flatpak project's isolation primitive. Start-up ~8ms vs ~279ms for podman (jvns). `[VERIFIED: command -v bwrap, bwrap --version]` |
| `crontab` Hex | 1.2.x (already in `mix.exs`, Plan 03-01 added) | Cron expression parse + next-run computation for `Glorbo.Company.Scheduler` | Pure Elixir, no GenServer; composes with `Process.send_after`. `[VERIFIED: mix.exs line 54]` |
| `file_system` Hex | 1.0.x (already in `mix.exs`) | inotify watching for inbox/outbox events | Phase 2's `Glorbo.Filesystem.Watcher` already routes by path prefix (`agents/*/inbox/*`, `agents/*/outbox/*`, `channels/*`). `[VERIFIED: lib/glorbo/filesystem/watcher.ex]` |
| `muontrap` Hex | 1.6.x (already in `mix.exs`) | Port-supervising wrapper — SIGTERM then SIGKILL cascade; cgroups on Linux prevent escaped children | `MuonTrap.Daemon` treats OS process as GenServer; default `delay_to_sigkill: 500ms`. `[VERIFIED: mix.exs line 64; hexdocs muontrap 1.7]` |
| `jason` Hex | 1.4.x | Parse JSONL session files (Claude, Codex) + Gemini stdout JSON | Already in deps. `[VERIFIED: mix.exs]` |
| `yaml_front_matter` Hex | 1.0.x | Parse `agent.md` frontmatter — `provider:`, `model:`, `permissions:`, `heartbeat:`, `budget:`, `network:`, `skills:` | Phase 1's safe-loader wrapper `Glorbo.Filesystem.Frontmatter` (already handles size-cap + yamerl). `[VERIFIED: lib/glorbo/filesystem/frontmatter.ex]` |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `Port` (stdlib) | — | Spawn bwrap, stream stdout, observe exit_status | Always. Wrap inside `MuonTrap.Daemon` to guarantee cleanup on crash. |
| `Task.Supervisor` (stdlib) | — | Per-agent supervised async invocation | One per `Agent.Server` so long-running Port work doesn't block wake-message handling (D-28). |
| `DynamicSupervisor` (stdlib) | — | `Glorbo.Company.AgentSupervisor` | Spawns `Agent.Server` children at company-up from `agent.md` files. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Custom Elixir CONNECT proxy (`Glorbo.Network.Proxy`) | `tinyproxy` + `FilterDefaultDeny` | tinyproxy does NOT filter HTTPS CONNECT tunnels — `FilterDefaultDeny` only applies to plain HTTP. Since all three CLI tools use HTTPS exclusively, tinyproxy would be a no-op. `[CITED: tinyproxy.github.io]` |
| Custom Elixir CONNECT proxy | `mitmproxy` with allowlist script | Requires TLS interception → breaks CLI tool cert-pinning + auth. Not suitable. |
| Custom Elixir CONNECT proxy | `squid` with `http_access allow` ACL | Works for HTTPS CONNECT via CONNECT-method ACL on destination hostname, but 20MB+ dependency, RHEL/Fedora ships 6.x (outdated), complex config. OTP-native is simpler + auditable. |
| `crontab` Hex | `quantum-elixir` | Quantum is a full scheduler with its own GenServer. Glorbo already owns wake logic in `Agent.Server` — pure-function cron parsing is the smaller surface. |
| `MuonTrap.Daemon` | Plain `Port.open/2` + `--die-with-parent` | bwrap issue #529: `--die-with-parent` does NOT kill spawned processes unless `--unshare-pid` is also set. Using both + MuonTrap gives triple-belt-and-braces cleanup. `[CITED: github.com/containers/bubblewrap/issues/529]` |

**Installation:** All Elixir deps already pinned. Host deps:

```bash
# Required on Fedora/Bazzite (already installed on dev host):
sudo dnf install bubblewrap   # verify: bwrap --version >= 0.8

# bwrap requires kernel userns; verify:
sysctl user.max_user_namespaces   # must be > 0 (dev host: 254351)
```

**Version verification (2026-04-16, on dev host):**
- `bwrap --version` → `bubblewrap 0.11.0` `[VERIFIED: local]`
- `claude --version` → `2.1.110 (Claude Code)` `[VERIFIED: local]`
- `gemini` (0.6.1+ expected for `--output-format json`) `[VERIFIED: local binary present]`
- `codex` (with `exec --json` and rollout JSONL) `[VERIFIED: local binary present + ~/.codex/sessions with token_count events]`
- Kernel 6.17.7 on Fedora 43 — user namespaces unrestricted `[VERIFIED: /proc/sys/user/max_user_namespaces]`

## Architecture Patterns

### Recommended Project Structure

```
lib/glorbo/
├── agent/
│   ├── server.ex              # Per-agent GenServer (D-25..D-28) — currently stub
│   └── dispatch.ex            # NEW: the wake-to-cleanup pipeline (D-27)
├── cli/                       # NEW subtree — provider adapters (D-41..D-43)
│   ├── adapter.ex             # Behaviour
│   ├── claude_code.ex
│   ├── gemini_cli.ex
│   └── codex.ex
├── sandbox/                   # NEW subtree — bwrap invocation (D-08..D-13)
│   ├── bwrap.ex               # build_argv/2, start/2
│   └── permission_mapper.ex   # D-11 table
├── network/                   # NEW subtree — api-only proxy (D-17)
│   └── proxy.ex               # Elixir CONNECT proxy w/ allowlist
├── skills/
│   └── resolver.ex            # NEW: materialize/3, cleanup/2 (D-38..D-40)
├── approvals/
│   └── gate.ex                # NEW: GenServer sentinel-watcher (D-34..D-37)
├── budget/
│   └── ledger.ex              # NEW: upsert + aggregate + alert (D-31, D-32)
├── company/
│   ├── agent_supervisor.ex    # NEW: DynamicSupervisor for per-agent GenServers
│   ├── supervisor.ex          # EXTEND: 2-child → 6-child
│   ├── router.ex              # FILL: currently stub
│   ├── scheduler.ex           # FILL: currently stub
│   └── budget_tracker.ex      # FILL: currently stub
├── security/
│   └── acl_mapper.ex          # Plan 03-01 shipped (Router uses check_action/2)
├── budget.ex                  # Plan 03-01 schema
└── tasks_approval_state.ex    # Plan 03-01 schema

config/
├── llm_rates.exs              # NEW: per-{provider, model} USD/Mtok rate table (D-30)
└── network_policy.exs         # NEW: api-only base allowlist (D-16)
```

### Pattern 1: bwrap argv builder as pure function

**What:** `Glorbo.Sandbox.Bwrap.build_argv/2` takes agent state and permissions, returns a list of strings.
**When to use:** Every agent dispatch. Unit tests assert argv shape without running bwrap.
**Example (verified argv composition for Fedora where /bin, /lib, /lib64 are symlinks to /usr/*):**

```elixir
# Source: bwrap 0.11.0 --help + sambaiz.net Claude Code sandbox analysis + live host probing
def build_argv(agent_state, permissions) do
  [
    # Namespaces (D-08) — ORDER MATTERS: namespace flags before mount flags
    "--die-with-parent",
    "--unshare-user-try",
    "--unshare-ipc",
    "--unshare-pid",
    "--unshare-uts",
    "--unshare-cgroup-try",
    "--new-session",
    "--cap-drop", "ALL",

    # Network — only for `none`; `api-only` relies on HTTP_PROXY env; `open` omits flag
    network_flag(agent_state.network_policy),

    # Root FS (D-09) — Fedora symlinks /bin -> /usr/bin etc., so use --symlink
    "--ro-bind", "/usr", "/usr",
    "--symlink", "usr/bin", "/bin",
    "--symlink", "usr/lib", "/lib",
    "--symlink", "usr/lib64", "/lib64",
    "--symlink", "usr/sbin", "/sbin",
    "--ro-bind", "/etc", "/etc",
    "--proc", "/proc",
    "--dev", "/dev",
    "--tmpfs", "/tmp",

    # Agent-owned dirs (always mounted)
    "--bind", agent_state.workspace_path, "/workspace",
    "--bind", agent_state.outbox_path, "/outbox",
    "--ro-bind", agent_state.inbox_path, "/inbox",

    # Per-permission mounts (D-11 via PermissionMapper)
    Glorbo.Sandbox.PermissionMapper.to_argv(permissions, agent_state.company_path),

    # cwd + env
    "--chdir", "/workspace",
    "--setenv", "HOME", "/workspace",
    maybe_proxy_env(agent_state.network_policy)  # HTTPS_PROXY for api-only
  ]
  |> List.flatten()
end
```

**Why symlinks for /bin /lib /lib64:** On Fedora-family distros (including Bazzite), these are symlinks to `/usr/*`. Using `--ro-bind /bin /bin` would fail because the source is a symlink, not a directory. `[VERIFIED: ls -ld /bin /lib /lib64 on dev host shows all three are symlinks to usr/*]` On Debian/Ubuntu systems where `/bin` is a real directory (pre-usrmerge) or a symlink (post-usrmerge), the `--symlink` approach works in both cases because the target is resolved at sandbox launch.

### Pattern 2: Port + MuonTrap.Daemon for CLI execution

**What:** Wrap bwrap invocation in `MuonTrap.Daemon` so crash cleanup is guaranteed.
**When to use:** Always. Never use raw `Port.open/2` for external commands.
**Example:**

```elixir
# Source: hexdocs.pm/muontrap + github containers/bubblewrap#529
{:ok, daemon_pid} =
  MuonTrap.Daemon.start_link(
    "bwrap",
    argv,
    stdout: log_file,
    stderr: log_file,
    name: {:via, Registry, {Glorbo.AgentRegistry, {company, agent, task_id}}},
    exit_status_to_reason: fn status -> {:shutdown, {:exit_status, status}} end,
    cd: agent_state.workspace_path,
    env: [{"HOME", "/workspace"} | proxy_env]
  )
```

**Why three layers of cleanup:**
1. `--die-with-parent` — bwrap dies when Elixir's Port dies
2. `--unshare-pid` — bwrap becomes pid1 in new namespace, so when bwrap dies the whole tree dies (issue #529 confirms `--die-with-parent` alone is insufficient without this)
3. `MuonTrap.Daemon` — SIGTERM then SIGKILL after 500ms; cgroups trap any escapees on Linux

### Pattern 3: Per-provider adapter behaviour

**What:** `Glorbo.CLI.Adapter` behaviour with uniform interface across providers.
**When to use:** Adding a new CLI provider (ollama-cli, etc. in future).
**Example:**

```elixir
defmodule Glorbo.CLI.Adapter do
  @callback binary() :: String.t()
  @callback args(task_prompt_path :: String.t(), model :: String.t(), opts :: keyword()) :: [String.t()]
  @callback usage_path(agent_slug :: String.t(), workspace :: String.t()) :: String.t() | :stdout
  @callback parse_usage(payload :: binary() | {:jsonl_file, String.t()}) ::
              {:ok, %{prompt_tokens: integer(), completion_tokens: integer(), model: String.t()}}
              | {:error, term()}
end

# ClaudeCode: usage_path returns path to session JSONL (tail after exit)
# GeminiCli:  usage_path returns :stdout (parse captured stdout as JSON)
# Codex:      usage_path returns path to ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
```

### Pattern 4: Watcher-driven approval gate

**What:** `Glorbo.Approvals.Gate` subscribes to existing `Glorbo.Filesystem.Watcher` events via PubSub-style callbacks (Watcher is per-company singleton; Gate registers a path-prefix handler).
**When to use:** Tasks with `requires_approval: director` frontmatter.
**Example flow:**
1. Agent picks up task → detects `requires_approval: director` → writes sentinel `agents/<name>/state/awaiting-approval-<task_id>.md` + `approval.requested` audit → returns to idle.
2. Director edits task file: `status: pending-approval` → `status: approved`.
3. Watcher detects modification of `projects/**/*.md`.
4. Gate reads modified file's frontmatter, if status flipped to `approved`/`denied` and there's a matching sentinel, acts.
5. On approval: emits `approval.granted` audit, removes sentinel, calls `Agent.Server.wake(agent, :director_approval)`.
6. On denial: emits `approval.denied`, removes sentinel, moves task to `history/`.

**Rationale:** Uses existing Watcher infrastructure (no second inotify watcher); Gate has zero long-lived state beyond company slug (crash-resumes from filesystem).

### Anti-Patterns to Avoid

- **`--ro-bind /` ("bind everything read-only then overlay writable"):** Exposes `/home/<director>/` which contains SSH keys, `.claude/` auth, browser data. D-09 is explicit — only mount what's needed. **Never** do `--ro-bind / /`.
- **`--unshare-user` without `-try`:** Fails hard on older kernels / AppArmor-restricted Ubuntu. `--unshare-user-try` gracefully continues (accepts the namespace-fallback security tradeoff, which is visible in audit). Fedora / Bazzite don't hit this path but cross-distro releases will.
- **Building argv by string concatenation:** Shell-injection risk for paths with spaces. Always return a list of strings; `Port.open/2` with `{:spawn_executable, bwrap_path}` and `args:` option avoids shell entirely.
- **Direct writes to another agent's inbox from Router code:** Router MUST go through `Glorbo.Filesystem.InboxWriter` (to be added) with audit + permission check, never `File.write!/2`. Even inside Glorbo, enforce the one-way invariant via module API.
- **Trusting `HTTPS_PROXY` env as a security boundary:** It is advisory only. Document clearly in release notes. Do NOT sell `api-only` as a hardened boundary until netns+nftables ships.
- **Parsing YAML with eager evaluation:** Already solved via `Glorbo.Filesystem.Frontmatter` + yamerl safe-loader (Phase 2). Never introduce a non-safe YAML loader.
- **Using `String.to_atom/1` on user input:** ACLMapper (Plan 03-01) correctly uses whitelists; extend same discipline to `provider:` field parsing (D-43 — allowlist match, not atom conversion).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Process tree kill | Custom SIGTERM→SIGKILL loop | `MuonTrap.Daemon` | Already in deps; handles cgroups, zombie reaping, delay-to-sigkill. Hand-rolled version misses cgroup escape path. |
| Cron parser | Regex over `* * * * *` | `crontab` Hex | Handles `*/30`, ranges, DST jumps. Correctness edge cases are subtle. |
| Mount namespace isolation | `mount()` syscall wrappers | `bwrap` binary | Unprivileged user-namespace bind-mount is nontrivial; bwrap is the blessed tool (Flatpak uses it at scale). |
| HTTPS CONNECT proxy | Raw `:gen_tcp` parsing CONNECT lines | Still write the proxy OTP-native under `Glorbo.Network.Proxy`, but use `Plug.Conn` + `Bandit`? | **Exception:** No Hex package fits ("default-deny HTTPS CONNECT allowlist"). iron-proxy exists but is Rust; mitmproxy needs cert interception. Write small (~150 LOC) OTP CONNECT proxy using `:gen_tcp`, accept CONNECT, validate host against allowlist, open upstream socket, bidirectionally splice. **Document as advisory in v0.0.1.** |
| YAML frontmatter parsing | Hand-rolled YAML | `YamlFrontMatter` + `YamlElixir` (yamerl) | Already wrapped safely in `Glorbo.Filesystem.Frontmatter`. |
| Ecto monthly upsert with increment | `SELECT ... UPDATE` pattern | `on_conflict: {:replace, [:prompt_tokens, :completion_tokens, :cost_usd_cents]}` with incremented values computed before insert, OR use `Repo.insert/2` with `conflict_target: [:agent_slug, :year_month]` + atomic SQL `excluded.prompt_tokens + ...` | Plan 03-01 schema already has the composite unique index; see pitfall 4. |
| Claude Code JSONL parsing | Custom JSON reader | `Jason.decode!/1` line-by-line over `File.stream!/1` | Files can be large (hours of session). Stream-parse, filter `type == "assistant"`, extract `.message.usage`. |
| Network egress filtering at kernel level | Custom netfilter hooks | `--unshare-net` (none), `HTTPS_PROXY` env (api-only advisory), shared netns (open) | Rootless netns+nftables is feasible but CONTEXT.md defers it. Don't attempt in Phase 3. |

**Key insight:** The v0.0.1 philosophy is "use what the host already provides"; bwrap is on PATH on every modern Linux distro via the `bubblewrap` package; CLI tools handle their own auth; session telemetry is already being written by the tools — Glorbo just reads it.

## Runtime State Inventory

This phase is primarily additive (new supervisors + adapters + proxy), not a rename. But two categories still need an explicit inventory:

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | `budgets` and `tasks_approval_state` tables (Plan 03-01 migrations applied) — already empty; no data migration needed. | None — schemas are exercised fresh. |
| Live service config | None — Phase 3 does not touch external services (no Podman containers in v0.0.1, no Ollama, no external proxies). | None. |
| OS-registered state | None — no systemd units, no cron entries, no launchd. Scheduler is in-BEAM only. | None. |
| Secrets/env vars | CLI tools each own their own auth: `~/.claude/` (Claude Code OAuth), `~/.codex/auth.json` (Codex), `~/.gemini/oauth_creds.json` + `~/.gemini/google_accounts.json` (Gemini). Glorbo MUST NOT read these. `~/.glorbo/config.md` key-injection is deferred per LLM-03 re-scoping. | bwrap sandbox for agents must bind each CLI's config dir **read-only** (so auth works) OR invoke the CLI outside-sandbox (research Q below). **Decision needed in planning.** |
| Build artifacts | `containers/glorbo-runtime/worker/*` (Plan 03-01) — DORMANT, not invoked in v0.0.1. Worker extensions are ready for container runtime phase. | None — confirmed dormant; no tests will exercise them in Phase 3. |

**Critical Secrets caveat — new research finding:** The CLI tool needs its auth files to reach the provider. For `claude`, that is `~/.claude/` (OAuth tokens) + `~/.claude/projects/` (session history). If bwrap unconditionally hides `/home/$USER/`, the CLI tool can't authenticate. Options:

1. **Per-agent OAuth:** Director logs into claude/gemini/codex separately for each agent identity (too painful for v0.0.1).
2. **Shared auth, isolated sessions:** Bind `~/.claude/` read-only into the sandbox, but set `CLAUDE_CONFIG_DIR=/workspace/.glorbo-claude/` so session JSONL writes go to the workspace (not leak into the Director's real `~/.claude/projects/`). `[VERIFIED: code.claude.com/docs/en/env-vars confirms CLAUDE_CONFIG_DIR controls session dir]`
3. **Full shared state:** Just bind `~/.claude/` read-write. Agent sessions mix with Director sessions. Simple but muddies the session history.

**Recommendation:** Option 2 (shared auth, per-agent session dir). Plan must include this env-var setup in `Glorbo.CLI.Adapter.ClaudeCode.args/3`. Equivalent approach for Gemini (`~/.gemini/oauth_creds.json` read-only + working dir forces per-agent state) and Codex (`~/.codex/auth.json` read-only + `CODEX_HOME=/workspace/.glorbo-codex/` equivalent if supported). **Codex `CODEX_HOME` is documented** `[CITED: ccusage.com/guide/codex/]`; it defaults to `~/.codex` and can be overridden.

## Common Pitfalls

### Pitfall 1: `--die-with-parent` alone is insufficient
**What goes wrong:** Kill the BEAM or the Port, but child CLI processes spawned by bwrap keep running and hold file handles.
**Why it happens:** `--die-with-parent` sends SIGKILL to the bwrap process only, not to its children. When bwrap dies, its children become reparented to pid 1 and continue. `[CITED: github.com/containers/bubblewrap/issues/529]`
**How to avoid:** Combine `--die-with-parent` + `--unshare-pid`. When bwrap has its own pid namespace and becomes pid1 inside, its death kills everything in the namespace (kernel-enforced). Additionally wrap in `MuonTrap.Daemon` for cgroup-backed cleanup.
**Warning signs:** Stale `claude` or `gemini` processes in `ps aux` after Elixir restart; rising RSS on company-up/down cycles.

### Pitfall 2: Budget upsert race under concurrent agents
**What goes wrong:** Two agents finish invocations at the same millisecond. Each reads `budgets.prompt_tokens = 100`, adds own delta, writes back — one delta is lost.
**Why it happens:** Read-modify-write pattern without atomic increment. `[ASSUMED]` — SQLite's transaction model makes this less likely than on Postgres, but WAL mode + concurrent writers can still exhibit it.
**How to avoid:** Ecto `on_conflict` with `{:replace_all_except, [:id]}` does NOT do atomic arithmetic; you must use a fragment. Correct pattern:

```elixir
# Source: hexdocs.pm/ecto/Ecto.Repo.html#c:insert/2 on_conflict fragment
from(b in Budget, update: [inc: [
  prompt_tokens: ^delta_prompt,
  completion_tokens: ^delta_completion,
  cost_usd_cents: ^delta_cost
]])
|> Repo.insert(
  conflict_target: [:agent_slug, :year_month],
  on_conflict: {:replace_all_except, [:id, :inserted_at]}
)
```

Actually the safest pattern is a single SQL `INSERT ... ON CONFLICT ... DO UPDATE SET prompt_tokens = budgets.prompt_tokens + excluded.prompt_tokens`. Use an explicit Ecto fragment: `on_conflict: [inc: [prompt_tokens: delta_prompt, ...]]` — Ecto supports keyword `[inc: ...]` directly.
**Warning signs:** Budget ledger entries lower than audit-event sum in fast tests.

### Pitfall 3: Cron `Process.send_after` drifts under VM pauses
**What goes wrong:** Computed next_run is 30 minutes from now. VM GC pauses 500ms. Send-after fires at T+30min+500ms, then next computation is "+30min from T+30min+500ms" — drift compounds.
**Why it happens:** `Process.send_after` delay is relative to now, not absolute.
**How to avoid:** Always recompute next-run from wall-clock on firing: `Crontab.Scheduler.get_next_run_date(expr, DateTime.utc_now())`. `[VERIFIED: CONTEXT.md D-24 already prescribes this.]`
**Warning signs:** Heartbeats drift seconds per day in long-running tests.

### Pitfall 4: Pending-map DoS via file churn
**What goes wrong:** Agent writes 10k small files to outbox in rapid succession → Watcher's 100ms debounce map grows unbounded.
**Why it happens:** Coalescing map keyed by path.
**How to avoid:** Phase 2's Watcher already caps at `@max_pending 10_000` with drop-with-warning. Router must NOT replicate the same sin; use same cap if buffering outbox events. `[VERIFIED: lib/glorbo/filesystem/watcher.ex line 35]`

### Pitfall 5: Claude Code session JSONL race — tool exits before final usage write
**What goes wrong:** `claude` process exits, Elixir reads JSONL, last turn's `usage` entry not yet flushed.
**Why it happens:** The assistant turn's JSONL is written asynchronously. On very fast `-p` invocations the final assistant message may not include a usage object by the time the process exits.
**How to avoid:** After process exit, retry `File.stat/1` with 100ms intervals up to 2s waiting for the `.jsonl` mtime to settle; then read. If still no usage for the final turn, emit `budget.usage_missing` audit event and record 0 tokens (conservative). `[ASSUMED]` — need empirical check once adapter is wired.
**Warning signs:** Sporadic 0-token budget rows that should have been non-zero.

### Pitfall 6: Gemini CLI JSON output requires full capture, not streaming
**What goes wrong:** Plan tries to tail Gemini output with `stream-json` format + parse the `result` event. On agent timeout, the `result` event never arrives — no token data at all.
**Why it happens:** `stream-json` emits partial events; terminal `result` carries stats. `--output-format json` emits one blob only at the end.
**How to avoid:** For Gemini, use `--output-format json` (single blob) and capture full stdout; parse on exit. Accept that timeout = no token data (same as Claude Code pitfall 5).
**Warning signs:** Budget ledger shows 0 for successful Gemini runs → check you're not parsing `stream-json` partial events.

### Pitfall 7: HTTPS_PROXY bypass — the CLI tool honors it, but a subprocess might not
**What goes wrong:** `api-only` agent invokes `claude -p "run git push"`. Claude calls the Bash tool which runs `git push`. `git` doesn't read `HTTPS_PROXY` for SSH, so the push succeeds despite allowlist denying github.com.
**Why it happens:** `HTTPS_PROXY` is an application-level convention. Not kernel-enforced.
**How to avoid:** Document as known limitation in v0.0.1. Agents with tool-execute permissions + `network: api-only` are not fully contained — recommend `network: none` when running tool-heavy agents. Netns+nftables is the real fix (deferred).
**Warning signs:** Audit log shows outbound connections succeeding from agents that should be proxy-gated.

### Pitfall 8: Port stdin close semantics
**What goes wrong:** Agent prompt is 5MB (a long task with many skills). `Port` stdin writes buffer up, child CLI blocks waiting for EOF.
**Why it happens:** Need to explicitly close stdin after writing the prompt (D-03 uses stdin delivery).
**How to avoid:** Use `Port.command(port, data)` + `Port.close(port)` in the send-prompt phase. Actually, better: use `MuonTrap.Daemon.send_stdin/2` if available, or write the prompt to a file and pass `--prompt-file`. Since CONTEXT.md D-03 specifies stdin AND file (both), the file path is the safer signal path; use stdin only for small prompts. **Revisit in plan.**
**Warning signs:** Hanging agents with 100% CPU on the CLI child; prompt never finishes.

### Pitfall 9: bwrap `--unshare-user-try` fallback is a security delta, not a failure
**What goes wrong:** On kernels without unprivileged user namespaces (old Debian Jessie, some RHEL 7), `--unshare-user-try` silently continues without the user namespace. Sandbox is less isolated than intended but still appears to work.
**Why it happens:** `-try` suffix is permissive by design.
**How to avoid:** Doctor must check `user.max_user_namespaces > 0` and fail release-builds on hosts that don't meet the bar. Log `namespace.fallback` audit event if user namespace was not obtained at runtime (parse bwrap stderr or use `--info-fd`). `[VERIFIED: bwrap --help line 'Create new user namespace if possible else continue by skipping it']`
**Warning signs:** Bazzite dev host (unrestricted) will never hit this; test on a pristine Ubuntu 22.04 with `kernel.apparmor_restrict_unprivileged_userns=1` before release.

### Pitfall 10: Codex CLI `token_count` events are cumulative — delta math required
**What goes wrong:** Glorbo sums all `token_count` events in a rollout → budget shows 10x the real usage.
**Why it happens:** Each event carries running totals for the session. Adding them stacks counts. `[VERIFIED: live rollout inspection on dev host shows cumulative totals]`
**How to avoid:** Take last `token_count` event's `total_token_usage` minus the first event's totals (which may be the baseline at session start with 0s), OR for single-invocation `codex exec --json`, just read the final event's `total_token_usage`.
**Warning signs:** Budget for a 10-token task shows up as 100 tokens.

## Code Examples

Verified patterns from live probing + official sources.

### Claude Code: session JSONL usage entry shape

```jsonl
# Source: verified on dev host /home/user/.claude/projects/-home-foobarto-Dokumenty-glorbo/<uuid>.jsonl
{"parentUuid":"...","isSidechain":false,"message":{"model":"claude-opus-4-6","id":"msg_01...","type":"message","role":"assistant","content":[...],"stop_reason":"tool_use","usage":{"input_tokens":2,"cache_creation_input_tokens":46335,"cache_read_input_tokens":0,"output_tokens":73,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":"standard","cache_creation":{"ephemeral_1h_input_tokens":46335,"ephemeral_5m_input_tokens":0}}}}
```

**Extraction code:**

```elixir
# Source: research inference from live JSONL inspection
defmodule Glorbo.CLI.Adapter.ClaudeCode do
  @behaviour Glorbo.CLI.Adapter

  def binary, do: System.find_executable("claude") || raise("claude not on PATH")

  def args(prompt_path, model, _opts) do
    # Reads prompt from file at prompt_path; --print for non-interactive
    [
      "--print",
      "--model", model,
      "--output-format", "text",
      "--no-session-persistence"  # or set CLAUDE_CONFIG_DIR via env to scope persistence
    ]
  end

  def usage_path(_agent_slug, workspace) do
    # With CLAUDE_CONFIG_DIR=<workspace>/.glorbo-claude, JSONL lands here:
    encoded = workspace |> String.replace("/", "-")
    Path.join([workspace, ".glorbo-claude", "projects", encoded])
    # Latest *.jsonl file in this dir = this session
  end

  def parse_usage({:jsonl_file, path}) do
    path
    |> File.stream!()
    |> Stream.map(&Jason.decode!/1)
    |> Stream.filter(&(&1["type"] == "assistant"))
    |> Enum.reduce(%{prompt: 0, completion: 0, model: nil}, fn entry, acc ->
      usage = get_in(entry, ["message", "usage"]) || %{}
      %{
        prompt:
          acc.prompt +
            (usage["input_tokens"] || 0) +
            (usage["cache_creation_input_tokens"] || 0) +
            (usage["cache_read_input_tokens"] || 0),
        completion: acc.completion + (usage["output_tokens"] || 0),
        model: get_in(entry, ["message", "model"]) || acc.model
      }
    end)
    |> then(&{:ok, &1})
  end
end
```

### Codex: rollout JSONL `token_count` event shape

```jsonl
# Source: verified on dev host /home/user/.codex/sessions/2026/04/14/rollout-*.jsonl
{"timestamp":"2026-04-13T22:46:49.670Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":12007,"cached_input_tokens":6528,"output_tokens":274,"reasoning_output_tokens":44,"total_tokens":12281},"last_token_usage":{"input_tokens":12007,"cached_input_tokens":6528,"output_tokens":274,"reasoning_output_tokens":44,"total_tokens":12281},"model_context_window":258400},"rate_limits":{...}}}
```

**Extraction code:**

```elixir
# Source: research inference from live JSONL inspection
defmodule Glorbo.CLI.Adapter.Codex do
  @behaviour Glorbo.CLI.Adapter

  def binary, do: System.find_executable("codex") || raise("codex not on PATH")

  # Use `codex exec --json` for non-interactive + structured output
  def args(prompt_path, model, _opts) do
    [
      "exec",
      "--json",
      "--model", model,
      "--skip-git-repo-check",
      "-"  # reads prompt from stdin; alt: pass file via <(cat prompt)
    ]
  end

  def usage_path(_agent_slug, workspace) do
    # With CODEX_HOME=<workspace>/.glorbo-codex, rollouts land here:
    Path.join([workspace, ".glorbo-codex", "sessions"])
    # Find latest rollout-*.jsonl recursively under YYYY/MM/DD/
  end

  def parse_usage({:jsonl_file, path}) do
    # The LAST token_count event contains the final cumulative totals.
    last_event =
      path
      |> File.stream!()
      |> Stream.map(&Jason.decode!/1)
      |> Stream.filter(fn e ->
        e["type"] == "event_msg" and get_in(e, ["payload", "type"]) == "token_count"
      end)
      |> Enum.reduce(nil, fn e, _ -> e end)  # keep last

    case last_event do
      nil ->
        {:error, :no_token_count}

      event ->
        u = get_in(event, ["payload", "info", "total_token_usage"]) || %{}
        {:ok,
         %{
           prompt: (u["input_tokens"] || 0) + (u["cached_input_tokens"] || 0),
           completion: (u["output_tokens"] || 0) + (u["reasoning_output_tokens"] || 0),
           # Codex doesn't surface model name per event; parse turn_context event, or
           # fall back to agent.md model (which is what user configured):
           model: nil
         }}
    end
  end
end
```

### Gemini CLI: stdout JSON shape

```json
{
  "response": "The capital of France is Paris.",
  "stats": {
    "models": {
      "gemini-2.5-pro": {
        "api": { "requests": 1, "errors": 0, "latency_ms": 824 },
        "tokens": {
          "prompt": 24939,
          "candidates": 20,
          "cached": 21263,
          "thoughts": 154,
          "tool": 0,
          "total": 25113
        }
      }
    },
    "tools": {},
    "files": {}
  }
}
```

`[CITED: google-gemini.github.io/gemini-cli/docs/cli/headless.html]`

**Extraction code:**

```elixir
# Source: gemini-cli headless docs
defmodule Glorbo.CLI.Adapter.GeminiCli do
  @behaviour Glorbo.CLI.Adapter

  def binary, do: System.find_executable("gemini") || raise("gemini not on PATH")

  def args(_prompt_path, model, _opts) do
    # Non-interactive: stdin contains prompt; --output-format json captures stats
    [
      "-p",  # read prompt; if combined with stdin, stdin is appended
      "",    # empty inline prompt; full prompt via stdin
      "-m", model,
      "--output-format", "json",
      "--approval-mode", "yolo"  # auto-approve since we're sandboxed
    ]
  end

  def usage_path(_agent_slug, _workspace), do: :stdout

  def parse_usage({:stdout, blob}) do
    case Jason.decode(blob) do
      {:ok, %{"stats" => %{"models" => models}}} when is_map(models) and map_size(models) > 0 ->
        # Sum across all models used (single-model usually, but be safe)
        Enum.reduce(models, {:ok, %{prompt: 0, completion: 0, model: nil}}, fn
          {name, %{"tokens" => t}}, {:ok, acc} ->
            {:ok,
             %{
               prompt: acc.prompt + (t["prompt"] || 0) + (t["cached"] || 0),
               completion: acc.completion + (t["candidates"] || 0) + (t["thoughts"] || 0) + (t["tool"] || 0),
               model: acc.model || name
             }}

          _, acc ->
            acc
        end)

      _ ->
        {:error, :no_stats}
    end
  end
end
```

### Gate watcher hook pattern (matching Phase 2 Watcher architecture)

```elixir
# Source: lib/glorbo/filesystem/watcher.ex line 122 dispatch_by_prefix
# Approach: extend Watcher with a PubSub broadcast OR register a callback;
# since Phase 2's Watcher dispatches inline, the cleanest extension is to
# broadcast via Phoenix.PubSub and have Gate subscribe:
defmodule Glorbo.Approvals.Gate do
  use GenServer

  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{company}:projects")
    {:ok, %{company: company}}
  end

  def handle_info({:file_event, rel_path, :modified}, state) do
    with {:ok, meta, _body} <- read_frontmatter(state.company, rel_path),
         status when status in ["approved", "denied"] <- meta["status"],
         {:ok, sentinel} <- find_sentinel(state.company, rel_path) do
      act_on_status(status, sentinel, state.company)
    end
    {:noreply, state}
  end
end
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Podman + setfacl ACLs for per-agent filesystem policy | bwrap + mount namespace (no POSIX ACL) | This pivot | Lower implementation cost; `ls` can't even see denied paths. `ACLMapper` sits dormant for container runtime phase. |
| Python worker reporting `cost_usd` via litellm.completion_cost | CLI tool session telemetry parsing (JSONL / stdout JSON) | This pivot | Glorbo owns cost math via `config/llm_rates.exs`. Gemini 0.6.1 JSON output makes this clean. |
| podman `--network none` for isolation | bwrap `--unshare-net` | This pivot | Same kernel primitive, no container runtime required. |
| Tinyproxy or netavark for api-only | Custom Elixir CONNECT proxy with hostname allowlist | This research (CONTEXT.md D-17) | Tinyproxy can't filter HTTPS (only plain HTTP); custom proxy is ~150 LOC, OTP-native, auditable. |
| Claude Code `~/.claude/projects/...` files kept in sessions subdir per older docs | `~/.claude/projects/<encoded-path>/<session>.jsonl` (no `sessions/` subdir) with per-turn `usage` | Verified 2026-04-16 on live install | Path encoding: `/home/user/myapp` → `-home-user-myapp`. |

**Deprecated/outdated:**
- Old Phase 3 CONTEXT.md (now at `.planning/deferred/container-runtime-v0.0.2/`): Podman + subuid UidAllocator + setfacl + litellm dispatch — archived, not deleted; infrastructure retained dormant.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | SQLite WAL + concurrent Ecto writes can exhibit lost-update race on budget upsert | Pitfall 2 | If false, budget math is already safe without `[inc: ]` pattern. Low risk — the fix is additive. |
| A2 | Claude Code JSONL has race between process exit and final usage flush (needs 100ms retry) | Pitfall 5 | If false, retry logic is defensive dead code. Test with a short `claude -p` run to confirm. |
| A3 | Codex doesn't surface model name per event (falls back to `agent.md` model) | Code Examples: Codex adapter | If false, could extract per-turn model accurately; currently we trust user config. Low impact — user configured the model. |
| A4 | `HTTPS_PROXY` env var bypass is acceptable threat model for v0.0.1 | Pitfall 7, D-17 | User-locked via D-17 ("motivated bypass is possible in v0.0.1"). Re-confirm in plan. |
| A5 | `--unshare-pid` guarantees child cleanup on bwrap SIGKILL | Pitfall 1, Pattern 2 | If false, zombies persist. Test: launch `bwrap --unshare-pid bash -c 'sleep 300 &'`, kill bwrap, confirm `sleep` is reaped. |
| A6 | Tinyproxy's `FilterDefaultDeny` truly doesn't filter HTTPS CONNECT by hostname | Standard Stack / Don't Hand-Roll | Confirmed by upstream tinyproxy.github.io; low risk. |
| A7 | Gemini CLI writes session to `~/.gemini/...` but NO JSONL token log — stdout JSON is authoritative | Code Examples: Gemini | Could not find a JSONL on dev host in `~/.gemini/`; stdout JSON path is the documented mechanism. If a JSONL exists in some Gemini mode, parse as optional fallback. |
| A8 | `CLAUDE_CONFIG_DIR` properly reroutes session JSONL writes (not just UI config) | Runtime State Inventory, Pitfall-free integration | Documented behavior per code.claude.com/docs; if false, sessions mix with Director's. Test in integration. |
| A9 | Writing ~150 LOC Elixir CONNECT proxy is feasible with `:gen_tcp` + `Task.Supervisor` | Don't Hand-Roll exception | Standard OTP pattern; low risk but verify with spike. |
| A10 | Fedora-family `/bin`, `/lib`, `/lib64` symlinks mean `--symlink` is universally correct | Pattern 1 | Verified on dev host; verified in multiple distros via usrmerge. Debian 12 post-usrmerge same. Pre-usrmerge distros are EOL. |

## Open Questions

1. **CLI auth dir mounting strategy in bwrap**
   - What we know: each CLI tool needs its config/auth dir accessible (`~/.claude/`, `~/.gemini/`, `~/.codex/`). bwrap mount namespace hides host `$HOME` by default.
   - What's unclear: should Glorbo (a) bind each CLI's config dir read-only + reroute sessions via `CLAUDE_CONFIG_DIR`/`CODEX_HOME`/Gemini equivalent, or (b) do the whole invocation outside bwrap (relying only on network + env for restriction)?
   - Recommendation: (a) is the secure option; plan must enumerate auth paths per provider + `env:` overrides to redirect session writes.

2. **Handling `agents:list` staging dir creation race**
   - What we know: D-12 says expose sibling `agent.md` files via a staging tmpfs.
   - What's unclear: is the staging dir created per-invocation (fresh every time) or per-agent (long-lived)? If per-invocation, cleanup granularity aligns with D-05; if per-agent, need reindex on `agent.md` changes.
   - Recommendation: per-invocation, as a subdir of `.glorbo-run/<task-id>/.agents-view/`. Keeps it uniform with skill/prompt cleanup.

3. **Gemini CLI model field parity**
   - What we know: stdout JSON has `stats.models.<model>.tokens`. The `<model>` key is the model name, but Gemini's `--model` flag uses aliases (`gemini-2.5-pro`, etc.) which may or may not match the reported key.
   - What's unclear: does Gemini always key `stats.models` by the full model ID or by the alias?
   - Recommendation: parse defensively — if `stats.models` has exactly one key, use it; else sum across keys. Adapter test with live Gemini invocation during plan execution.

4. **Codex `CODEX_HOME` session path under sandbox**
   - What we know: `CODEX_HOME=~/.codex` by default; rollouts land in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`.
   - What's unclear: does setting `CODEX_HOME` within bwrap correctly redirect writes, or does codex cache the path at startup?
   - Recommendation: integration test (`:codex` tag) — start codex with `CODEX_HOME=/workspace/.glorbo-codex`, assert rollout file appears there.

5. **Scheduler wake arrival during already-executing task**
   - What we know: D-26 says dedup wakes; if cron fires during execution, queue one more; coalesce further.
   - What's unclear: what does "coalesce" mean concretely — a counter, a set-with-trigger, or just "set pending=true"?
   - Recommendation: `pending_wakes :: boolean() | {trigger :: atom(), count :: non_neg_integer()}`. On finish, if pending, re-wake with the most recent trigger. Details in plan.

6. **Proxy port allocation**
   - What we know: `HTTPS_PROXY=localhost:<port>` inside sandbox; port must be reachable.
   - What's unclear: one proxy per company (simpler) vs one proxy per agent-invocation (cleaner audit). With `--unshare-net` absent in `api-only` (per D-17), the sandbox can reach host's `localhost`.
   - Recommendation: one proxy per company (under `Glorbo.Company.Supervisor` as a seventh child if network policy in use, or dynamically started if any agent has `api-only`). Listen on ephemeral port, pass via env to each sandbox.

7. **Phoenix.PubSub broadcast from Watcher — does Phase 2 already do this?**
   - What we know: Phase 2's Watcher dispatches inline (`dispatch_by_prefix/4`).
   - What's unclear: Plan 03-02 onward depends on Router + Gate subscribing to Watcher events. Is the Watcher extended to broadcast, or do Router/Gate poll filesystem?
   - Recommendation: extend Watcher to broadcast via Phoenix.PubSub topic per company; Router subscribes to `company:<slug>:outbox`, Gate subscribes to `company:<slug>:projects`. Small Watcher change; justified by subscriber proliferation.

## Environment Availability

| Dependency | Required By | Available (dev host) | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `bwrap` binary | SEC-02, SEC-03, AGT-02 dispatch | YES | 0.11.0 | Block at Doctor level; no runtime fallback. |
| Kernel user namespaces | bwrap `--unshare-user-try` | YES | `max_user_namespaces=254351` | `--unshare-user-try` falls back gracefully; log `namespace.fallback` audit. |
| `claude` CLI | Provider `claude-code` agents | YES | 2.1.110 | Per-agent: if missing, emit `provider.unavailable` + no-wake (D-43). |
| `gemini` CLI | Provider `gemini-cli` agents | YES | (inspected) | Per-agent: `provider.unavailable` + no-wake. |
| `codex` CLI | Provider `codex` agents | YES | (inspected) | Per-agent: `provider.unavailable` + no-wake. |
| Elixir `crontab` Hex | Scheduler | YES (Plan 03-01 added) | 1.2.x | No fallback needed. |
| Elixir `muontrap` Hex | Port cleanup | YES | 1.6.x | No fallback needed. |
| `file_system` Hex inotify | AGT-02 inbox trigger + approval gate | YES (Phase 2) | 1.0.x | Phase 2 already operational. |
| SQLite WAL | Budget + TasksApprovalState persistence | YES (Phase 1) | — | No fallback needed. |
| Phoenix.PubSub | Watcher → Router/Gate events | YES (Phase 1) | — | No fallback needed. |
| `ip netns` rootless | Future netns+nftables api-only path | DEFERRED | — | Out of scope; v0.0.1 uses HTTPS_PROXY path. |

**Missing dependencies with no fallback:**
- None on dev host. Release targets: Doctor must gate on `bwrap >= 0.8` and `user.max_user_namespaces > 0`.

**Missing dependencies with fallback:**
- Per-provider CLI absence: agent-level no-wake + `provider.unavailable` audit. Not a deploy-blocker (other agents can still operate).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | `ExUnit` (Elixir 1.18) + Python `pytest` (containers/ runtime — DORMANT in v0.0.1) |
| Config file | `test/test_helper.exs` (exists, from Phase 1+2) |
| Quick run command | `mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex` |
| Full suite command | `mix test` (runs everything including `:bwrap` tag if bwrap available) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AGT-01 | 6-child supervisor tree + crash isolation | unit | `mix test test/glorbo/company/supervisor_test.exs -x` | ❌ Wave 0 — extend existing `supervisor_test.exs` |
| AGT-01 | Per-agent GenServer crash restarts only that agent | integration | `mix test test/integration/agent_crash_isolation_test.exs` | ❌ Wave 0 |
| AGT-02 | Inbox inotify wake | integration | `mix test test/integration/agent_wake_inbox_test.exs --include integration` | ❌ Wave 0 |
| AGT-02 | Heartbeat cron wake | unit | `mix test test/glorbo/company/scheduler_test.exs` | ❌ Wave 0 |
| AGT-02 | Channel mention wake | unit | `mix test test/glorbo/company/router_test.exs` | ❌ Wave 0 |
| AGT-03 | One-way flow — agent can't write another's inbox | integration | `mix test test/integration/inbox_isolation_test.exs --include integration` | ❌ Wave 0 |
| AGT-04 | Skills materialised in `.glorbo-skills/` | unit | `mix test test/glorbo/skills/resolver_test.exs` | ❌ Wave 0 |
| AGT-05 | Router rejects `agents:create` routing | unit | `mix test test/glorbo/company/router_test.exs` | ❌ Wave 0 (new case in existing file) |
| SEC-01 | Router rejects messages lacking permission | unit | `mix test test/glorbo/company/router_test.exs` | ❌ Wave 0 |
| SEC-02 | bwrap mount namespace blocks disallowed write | integration | `mix test test/integration/sandbox_filesystem_test.exs --include bwrap` | ❌ Wave 0 (needs `:bwrap` tag) |
| SEC-02 | `Glorbo.Sandbox.Bwrap.build_argv/2` argv composition | unit | `mix test test/glorbo/sandbox/bwrap_test.exs` | ❌ Wave 0 |
| SEC-02 | `PermissionMapper` permission → bwrap flags | unit | `mix test test/glorbo/sandbox/permission_mapper_test.exs` | ❌ Wave 0 |
| SEC-03 | `--unshare-net` blocks network (policy `none`) | integration | `mix test test/integration/sandbox_network_none_test.exs --include bwrap` | ❌ Wave 0 |
| SEC-03 | `api-only` proxy allows allowlisted, denies others | integration | `mix test test/integration/sandbox_network_api_only_test.exs --include bwrap` | ❌ Wave 0 |
| SEC-04 | Sentinel + status-flip approval | integration | `mix test test/integration/approval_gate_test.exs --include integration` | ❌ Wave 0 |
| SEC-05 | Budget upsert idempotency | unit | `mix test test/glorbo/budget/ledger_test.exs` | ❌ Wave 0 |
| SEC-05 | Hard-stop aborts dispatch | integration | `mix test test/integration/budget_hard_stop_test.exs` | ❌ Wave 0 |
| LLM-03 | Provider adapter shape (Claude/Gemini/Codex) | unit | `mix test test/glorbo/cli/ -x` | ❌ Wave 0 |
| LLM-03 | End-to-end Claude Code invocation (if `claude` on PATH) | integration | `mix test test/integration/claude_code_invocation_test.exs --include claude_code` | ❌ Wave 0 |
| LLM-04 | Single provider+model enforced at agent parse | unit | `mix test test/glorbo/agent/parser_test.exs` | ❌ Wave 0 (may extend Phase 2 `agent.md` parse tests) |

### Sampling Rate
- **Per task commit:** `mix test --exclude integration --exclude bwrap --exclude claude_code --exclude gemini_cli --exclude codex` (unit only, ~ seconds)
- **Per wave merge:** `mix test --exclude claude_code --exclude gemini_cli --exclude codex` (integration + bwrap; skip CLI-dependent)
- **Phase gate:** Full `mix test` on host with all three CLI tools authenticated + `bwrap` installed

### Wave 0 Gaps
- [ ] `test/glorbo/company/supervisor_test.exs` — extend for 6-child tree; covers AGT-01
- [ ] `test/glorbo/company/router_test.exs` — new; covers AGT-02, AGT-03, AGT-05, SEC-01
- [ ] `test/glorbo/company/scheduler_test.exs` — new; covers AGT-02 heartbeat
- [ ] `test/glorbo/company/budget_tracker_test.exs` — new; covers SEC-05 pre-dispatch gate
- [ ] `test/glorbo/agent/server_test.exs` — new; covers AGT-01 per-agent crash
- [ ] `test/glorbo/sandbox/bwrap_test.exs` — new; argv composition
- [ ] `test/glorbo/sandbox/permission_mapper_test.exs` — new; D-11 mapping table
- [ ] `test/glorbo/cli/claude_code_test.exs` — new; adapter + JSONL parse with fixture
- [ ] `test/glorbo/cli/gemini_cli_test.exs` — new; adapter + stdout JSON parse
- [ ] `test/glorbo/cli/codex_test.exs` — new; adapter + rollout JSONL parse
- [ ] `test/glorbo/skills/resolver_test.exs` — new; materialise + cleanup
- [ ] `test/glorbo/approvals/gate_test.exs` — new; sentinel lifecycle
- [ ] `test/glorbo/budget/ledger_test.exs` — new; atomic upsert
- [ ] `test/glorbo/network/proxy_test.exs` — new; CONNECT allowlist
- [ ] `test/integration/agent_crash_isolation_test.exs` — new; tagged `:integration`
- [ ] `test/integration/agent_wake_inbox_test.exs` — new; tagged `:integration`
- [ ] `test/integration/inbox_isolation_test.exs` — new; tagged `:integration`
- [ ] `test/integration/sandbox_filesystem_test.exs` — new; tagged `:bwrap`
- [ ] `test/integration/sandbox_network_none_test.exs` — new; tagged `:bwrap`
- [ ] `test/integration/sandbox_network_api_only_test.exs` — new; tagged `:bwrap`
- [ ] `test/integration/approval_gate_test.exs` — new; tagged `:integration`
- [ ] `test/integration/budget_hard_stop_test.exs` — new; tagged `:integration`
- [ ] `test/integration/claude_code_invocation_test.exs` — new; tagged `:claude_code`
- [ ] Fixtures: `test/fixtures/claude_session_*.jsonl`, `test/fixtures/codex_rollout_*.jsonl`, `test/fixtures/gemini_stdout_*.json` — capture minimal real outputs

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | YES | Defence-in-depth: Router app-layer check + bwrap kernel-layer enforcement (CLAUDE.md invariant). |
| V2 Authentication | partial | Delegated to each CLI tool (claude/gemini/codex manage own OAuth); Glorbo never handles provider API keys directly in v0.0.1 (LLM-03 re-scope). |
| V3 Session Management | NO | No user sessions in Glorbo v0.0.1 (dashboard is Phase 4; single-operator model). |
| V4 Access Control | YES | Per-permission bwrap mount mapping (SEC-01 + SEC-02); kernel enforces via VFS (no mount = no path exists). |
| V5 Input Validation | YES | `agent.md` frontmatter: yamerl safe-loader + size cap (10 MB); `provider:` whitelist match (not atom conversion); permission tuples pattern-matched against whitelist (`Glorbo.Security.ACLMapper.parse_permission/1`). |
| V6 Cryptography | NO | Glorbo does no crypto in v0.0.1; TLS offloaded to CLI tools + host OS trust store. |
| V7 Error Handling / Logging | YES | Append-only audit log (CLAUDE.md invariant); structured AUDIT_EVENTS.md registry; no secrets in audit payloads. |
| V10 Malicious Code | YES | Agent output (LLM-generated) cannot escape sandbox; bwrap mount namespace is the containment. Tool execution (`tools:execute:*`) still runs inside sandbox, so LLM-generated shell commands are confined. |
| V11 Business Logic | YES | Budget hard-stop prevents runaway cost; approval gates prevent unreviewed destructive actions (`requires_approval: director`). |
| V12 Files and Resources | YES | `.glorbo-run/<task-id>/` cleanup (D-05); skill injection is read-only from sandbox perspective; prompt file written before spawn, deleted after. |
| V14 Configuration | YES | Network policy per-agent (`none` default — V14 secure-by-default); Doctor enforces `bwrap >= 0.8`. |

### Known Threat Patterns for bwrap+CLI-agent stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| LLM-generated shell command reads `/etc/passwd` inside sandbox | Information Disclosure | `/etc` is ro-bind'd (intentional for `getent`, DNS) but contains no real secrets on Linux; `~/.ssh/`, `~/.claude/` etc. are NOT mounted. |
| LLM-generated shell command writes outside permitted project | Tampering | Project dir not mounted = VFS has no such path; kernel returns ENOENT at open(). |
| Sibling agent eavesdrops via shared tmpfs | Information Disclosure | Each invocation gets a fresh `--tmpfs /tmp`; no persistent shared state. |
| Agent with `api-only` escapes via `curl --noproxy` | Information Disclosure + Spoofing | **Known v0.0.1 gap** — `HTTPS_PROXY` is advisory. Mitigation: use `network: none` for tool-heavy agents; document in release notes. |
| Cron-fork DoS (agent writes 10k tasks) | Denial of Service | Watcher `@max_pending 10_000` cap (Phase 2); Router should replicate for outbox. |
| YAML billion-laughs / bomb in agent.md | Denial of Service | yamerl safe-loader + 10 MB content cap (Phase 2 `Glorbo.Filesystem.Frontmatter`). |
| Budget race between concurrent agents | Tampering / Repudiation | Atomic `inc: [...]` in Ecto `on_conflict` (Pitfall 2); composite unique index on `(agent_slug, year_month)` (Plan 03-01). |
| Approval bypass by editing audit JSONL | Tampering | CLAUDE.md invariant — audit is append-only, enforced at `AuditLog.append/2` (sole writer, Phase 2 D-24). Filesystem ACLs on `audit/` prevent direct agent writes (agent never has write permission to `audit/`). |
| Router re-entrancy: agent writes to its own inbox by mistake | Confused deputy | Router rejects any outbox message whose `to:` resolves to the sender; append `message.reject` audit. |
| Malformed `token_count` JSONL causing parser panic | Denial of Service | `Jason.decode/1` with `{:error, _}` branch; log `usage.parse_error` audit; record 0 tokens for that invocation (conservative). |
| Zombie CLI processes after company shutdown | Resource exhaustion | `--die-with-parent` + `--unshare-pid` + `MuonTrap.Daemon` (Pitfall 1). |

**Security level alignment:** Per `.planning/config.json`: `security_enforcement: true`, `security_asvs_level: 2`, `security_block_on: high`. Phase 3 threat surface is within ASVS L2 scope (non-enterprise, single-operator, defence-in-depth between application + kernel layers).

## Sources

### Primary (HIGH confidence)
- **Live host probing (2026-04-16)**: bwrap 0.11.0, kernel 6.17.7, claude 2.1.110, gemini + codex present; `/home/user/.claude/projects/-home-foobarto-Dokumenty-glorbo/*.jsonl` inspection; `/home/user/.codex/sessions/2026/04/14/rollout-*.jsonl` inspection.
- **`bwrap --help` on 0.11.0**: authoritative flag reference.
- **`claude --help`, `gemini --help`, `codex --help`**: authoritative CLI flag reference.
- **[Claude Code Environment Variables](https://code.claude.com/docs/en/env-vars)**: `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_SKIP_PROMPT_HISTORY`.
- **[Claude Code Enterprise Network Configuration](https://code.claude.com/docs/en/network-config)**: api.anthropic.com, claude.ai, platform.claude.com — authoritative allowlist set.
- **[crontab Hex docs v1.2.0](https://hexdocs.pm/crontab/Crontab.Scheduler.html)**: `get_next_run_date/2` signature + behaviour.
- **[MuonTrap Hex docs 1.7](https://hexdocs.pm/muontrap/MuonTrap.html)**: `:delay_to_sigkill`, cgroups, supervision.
- **[Gemini CLI Headless Mode Docs](https://google-gemini.github.io/gemini-cli/docs/cli/headless.html)**: `stats.models.<model>.tokens` schema + JSON example.
- **[bubblewrap GitHub README](https://github.com/containers/bubblewrap)**: flag semantics + CVE history.
- **[Crontab Hex v1.2](https://hexdocs.pm/crontab/)**: confirmed in `mix.exs` line 54.
- **Codebase**: `lib/glorbo/filesystem/watcher.ex` (Phase 2 dispatch_by_prefix), `lib/glorbo/security/acl_mapper.ex` (Plan 03-01), `lib/glorbo/runtime/uid_allocator.ex` (Plan 03-01, dormant), `lib/glorbo/budget.ex` + `lib/glorbo/tasks_approval_state.ex` (Plan 03-01 schemas), `lib/glorbo/company/supervisor.ex` (current 2-child shape).

### Secondary (MEDIUM confidence)
- **[bubblewrap issue #529](https://github.com/containers/bubblewrap/issues/529)**: `--die-with-parent` requires `--unshare-pid` for child cleanup — community-confirmed.
- **[Inside Claude Code: Session File Format (databunny / Medium, Feb 2026)](https://databunny.medium.com/inside-claude-code-the-session-file-format-and-how-to-inspect-it-b9998e66d56b)**: JSONL schema — confirmed by live inspection.
- **[ccusage guide — Codex CLI](https://ccusage.com/guide/codex/)**: rollout path + `token_count` event shape + cumulative semantics — confirmed by live inspection.
- **[jvns.ca — Notes on bubblewrap](https://jvns.ca/blog/2022/06/28/some-notes-on-bubblewrap/)**: /proc /dev requirements, UID mapping gotchas, startup performance.
- **[sambaiz.net — Claude Code sandbox runtime](https://www.sambaiz.net/en/article/547/)**: socat + HTTP_PROXY pattern — confirms our D-17 approach is real-world proven.
- **[ArchWiki Bubblewrap](https://wiki.archlinux.org/title/Bubblewrap)**: `--symlink usr/lib64 /lib64` pattern for distros with merged /usr.
- **[tinyproxy.conf man page](https://manpages.debian.org/testing/tinyproxy/tinyproxy.conf.5.en.html)**: FilterDefaultDeny scope (HTTP only, not HTTPS CONNECT).
- **[mitmproxy Ignore Domains](https://docs.mitmproxy.org/stable/howto/ignore-domains/)**: SNI-based filter pattern (only applicable with TLS interception, not our model).

### Tertiary (LOW confidence)
- **[ccusage main guide](https://ccusage.com/guide/)**: `~/.config/claude/projects/` as v1.0.30+ location (LEGACY `~/.claude/projects/`) — live inspection confirmed legacy path still active on claude 2.1.110 + dev host.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — every library verified against `mix.exs` or against live CLI binary help output.
- bwrap argv composition: HIGH — verified against `bwrap --help` on 0.11.0 + live host filesystem layout.
- CLI telemetry schemas: HIGH for Claude Code (live inspection of JSONL on dev host) + Codex (live inspection of rollout JSONL with `token_count` events); HIGH for Gemini (documented stdout JSON schema + confirmed no JSONL session log needed).
- Architecture patterns: HIGH — aligns with Phase 1/2 established patterns (pure-function builders, dep-injectable IO, GenServer + DynamicSupervisor).
- Pitfalls: MEDIUM — 10 pitfalls identified, 7 with cited sources, 3 labeled `[ASSUMED]` pending empirical check during plan execution.
- Network policy `api-only`: MEDIUM for design (D-17 is explicit user decision); HIGH for gap-honest communication (bypass risk documented); LOW for long-term hardening (netns+nftables deferred).
- Security threat mapping: HIGH — ASVS L2 categories crossed against CLAUDE.md invariants.

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (30 days — bwrap stable, CLI tools may ship new versions; re-check Gemini JSON schema + Codex `token_count` shape before release).

---

*Phase: 03-agents-routing-kernel-permissions-budgets*
*Research date: 2026-04-16 (CLI-agent pivot researched fresh — supersedes container-runtime research archived at `.planning/deferred/container-runtime-v0.0.2/03-RESEARCH.md`)*
