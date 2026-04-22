
## Overview
Glorbo is a self-hosted agent orchestration platform that runs external LLM CLI tools inside kernel-level `bwrap` sandboxes. All company data (agents, tasks, chat, approvals, audit logs) is stored as markdown/JSONL under `~/.glorbo/companies/<company>/`, with SQLite (`glorbo.db`) used only as a rebuildable index for the dashboard. Operators interact through a Phoenix LiveView dashboard (default `127.0.0.1:4000`) and a local MCP JSON-RPC endpoint (`/mcp`). The runtime launches agents via `Glorbo.Agent.Dispatch` and routes all agent-authored writes through `Glorbo.Company.Router`, enforcing permissions in both the application layer and the kernel layer (`Glorbo.Security.ACLMapper` + `Glorbo.Sandbox.PermissionMapper`).

Security goals in this codebase are: (1) contain untrusted agent/LLM output, (2) enforce per-agent and per-company isolation, (3) protect host secrets and provider credentials, (4) preserve append-only audit logs for forensics, and (5) prevent runaway cost or unsafe actions via budgets and approval gates.

## Threat model, Trust boundaries and assumptions
### Trust boundaries
- **Host ↔ sandbox boundary:** untrusted agent processes run inside `bwrap` (`lib/glorbo/sandbox/bwrap.ex`). The kernel namespace boundary is the primary security control.
- **Router boundary:** all agent writes must flow through `Glorbo.Company.Router` (`lib/glorbo/company/router.ex`) which validates sender identity and permissions.
- **Company boundary:** each company has its own directory tree; bwrap only mounts the active company’s directory to keep siblings invisible.
- **HTTP boundary:** dashboard and MCP requests are external inputs that can mutate the filesystem via `GlorboWeb.Actions` and MCP tools.
- **File-format boundary:** YAML frontmatter, markdown bodies, and JSONL logs are untrusted inputs parsed by the system.

### Attacker-controlled inputs
- Agent output files in `agents/<slug>/outbox/`, `workspace/`, and reply files; filenames and markdown bodies are fully attacker-controlled.
- Network egress from agents when `network: open` or `api-only` is configured.
- HTTP requests to the dashboard or MCP endpoint (if accessible on the host).
- Files and logs written by provider CLIs (usage JSONL, stdout, etc.).
- Any file placed under `~/.glorbo` by external processes running as the same OS user.

### Operator-controlled inputs
- `~/.glorbo/config.md` (secret_key_base, dashboard token, host/port), environment overrides, and file permissions.
- Agent/company frontmatter (permissions, budgets, network policy, approvals).
- Provider registry TOML (`auth_binds`, invocation args), network allowlists (`config/network_policy.exs`).

### Developer-controlled inputs
- Mix tasks, tests, CI scripts, release packaging, docs. These are not runtime attack surfaces but affect supply-chain integrity.

### Assumptions
- Default deployment is **local-only** (loopback binding). LAN exposure is opt-in and should set a dashboard token.
- `bwrap` and user namespaces are available on Linux; if unavailable (macOS), agents run unsandboxed with a warning (`lib/glorbo/sandbox/unsandboxed.ex`).
- The local OS user running Glorbo is trusted; if an attacker already has that user’s shell, they can bypass filesystem controls (out of scope).
- External LLM CLIs may be buggy or adversarial; the sandbox is expected to contain them.

## Attack surface, mitigations and attacker stories
### Agent runtime & sandbox
**Surface:** `Glorbo.Agent.Dispatch` + `Glorbo.Sandbox.Bwrap` spawn external CLIs inside a sandbox with per-permission mounts. Agent permissions are parsed in `Glorbo.Agent.Parser` and mapped to mounts by `Glorbo.Sandbox.PermissionMapper`.

**Mitigations:**
- `bwrap` baseline flags drop capabilities and isolate namespaces (`--unshare-user-try`, `--unshare-pid`, `--unshare-net`, `--cap-drop ALL`) and mount only a minimal `/etc` (`lib/glorbo/sandbox/bwrap.ex`).
- Per-permission mounts enforce **sibling invisibility**; only permitted project/channel paths are mounted (`lib/glorbo/sandbox/permission_mapper.ex`).
- Application-layer permission checks via `Glorbo.Security.ACLMapper` + `Company.Router` provide defense in depth.
- `Agent.Parser` uses allowlists, slug regexes, and avoids atom creation on user input; it rejects `agents:create` permissions (`lib/glorbo/agent/parser.ex`).
- `network: none` unshares the netns; `api-only` uses an allowlist proxy (`lib/glorbo/network/proxy.ex`) but is advisory if the CLI ignores proxy env vars.
- Execution timeouts kill runaway CLI processes; reply file contracts and audit events capture failures.

**Attacker stories:**
- A malicious agent attempts to read or write outside its allowed project using path traversal in permission scopes or symlinks in its workspace.
- A compromised CLI ignores proxy env vars to exfiltrate data even in `api-only` mode.
- On macOS, the unsandboxed fallback could allow full host access if a malicious agent runs.

### Router & filesystem routing
**Surface:** `Glorbo.Company.Router` handles outbox messages, tasks, and path requests; it is the central gate between agent-controlled files and host writes.

**Mitigations:**
- Sender identity is derived from the outbox path (anti-spoof), and control characters in `msg_id`/`to` are rejected to prevent YAML/frontmatter injection.
- `ACLMapper.check_action` enforces permission checks before routing; `agents:create` is explicitly blocked.
- Channel writes are append-only with `[:append, :sync]` to avoid interleaving races; rejections are audited and archived.
- Director actions use `GlorboWeb.Actions` with slug/path validation and symlink checks (`File.lstat!`) before writing.

**Attacker stories:**
- An agent tries to impersonate another sender by crafting an outbox file path; the router’s `verify_sender_slug` should reject it.
- An agent tries to send a message with embedded newlines to smuggle frontmatter or overwrite other files.
- A symlink swap attempt aims to redirect channel/task writes to arbitrary host paths.

### Path access requests
**Surface:** Agents can request temporary access to host paths via `path-request-<task_id>.md` handled by `Glorbo.PathRequestGate`.

**Mitigations:**
- Only absolute paths are accepted; `..` and `/proc|/sys|/dev` are rejected; request size and count are capped.
- Director approval is required and grants are stored in `PathGrantStore` and revoked after dispatch.

**Attacker stories:**
- An agent requests sensitive files or attempts to smuggle a forbidden path via symlink or path tricks.
- A race or validation bug could grant more access than approved.

### Web dashboard & LiveView
**Surface:** Phoenix LiveView routes, search API, and session cookies (`lib/glorbo_web/router.ex`).

**Mitigations:**
- CSRF protection and secure browser headers are enabled in the `:browser` pipeline.
- Optional bearer token gate (`lib/glorbo_web/plugs/dashboard_token.ex`) protects LAN exposure; constant-time compare avoids timing leakage.
- Slug validation (`GlorboWeb.Slug`) and write paths in `GlorboWeb.Actions` prevent path traversal.
- Default binding is loopback (`config/runtime.exs`), limiting remote access by default.

**Attacker stories:**
- If the operator binds to `0.0.0.0` without a token, any LAN user could approve tasks, create agents, or read audit logs.
- Token leakage via URLs, browser history, or referrers could grant access to the dashboard.

### MCP server
**Surface:** The `/mcp` endpoint provides JSON-RPC tools that can mutate state (approve tasks, create agents, etc.).

**Mitigations:**
- `GlorboWeb.MCP.Plug` enforces origin allowlists to reduce DNS rebinding risk and validates protocol headers.
- `GlorboWeb.MCP.Args` validates slugs before any path construction.
- Tool implementations delegate to `GlorboWeb.Actions` or the Router for consistent validation.
- Default loopback binding is the outer boundary; MCP is intentionally not behind the dashboard token.

**Attacker stories:**
- A local malicious process (or remote attacker if bound to LAN) could call MCP tools to approve/deny tasks or create privileged agents.
- Origin checks could be bypassed if a client spoofs headers or if the operator exposes the endpoint beyond localhost.

### Markdown rendering & XSS
**Surface:** Agent-authored markdown in channels, task comments, and proposals displayed in the dashboard.

**Mitigations:**
- `GlorboWeb.Markdown` renders via Earmark and sanitizes with `HtmlSanitizeEx`; mention/linkification uses escaped tokens (`lib/glorbo_web/markdown.ex`).

**Attacker stories:**
- A malicious agent attempts to inject `<script>` or `javascript:` URLs to capture the dashboard token or modify UI behavior.

### Audit log integrity
**Surface:** Audit logs are the authoritative record of actions (`audit/YYYY-MM.jsonl`).

**Mitigations:**
- `Glorbo.Company.AuditLog` only appends JSON-encoded records with `fsync`; there is no update/delete API.
- SQLite is derived; failure to mirror doesn’t erase the JSONL entry.

**Attacker stories:**
- An attacker tries to inject newline-delimited JSON to forge or hide audit events, or manipulate the company slug to redirect log writes.

### Secrets, config, and provider bindings
**Surface:** `config.md` holds secret_key_base, dashboard token, and Erlang cookie; provider TOML can mount host auth directories into sandboxes.

**Mitigations:**
- `Glorbo.Config` writes secrets with mode `0600` via atomic rename and never logs secret values (`lib/glorbo/config.ex`).
- `Filesystem.Hierarchy` locks down `runtime/sockets` and `run` directories to `0700`.
- Provider registry loader validates `auth_binds` shapes; bwrap binds are read-only by default (`lib/glorbo/cli/registry/loader.ex`).

**Attacker stories:**
- A second local user reads `config.md` if permissions are weakened.
- Misconfigured `auth_binds` mount sensitive host paths into the sandbox, effectively bypassing isolation.

### Build/CI vs runtime
Mix tasks and release scripts (`lib/mix/tasks/*`, `rel/`) are developer-controlled and generally out of runtime scope. The main security concern here is supply-chain integrity of release binaries and external CLI tools.

## Criticality calibration (critical, high, medium, low)
### Critical
Vulnerabilities that break core isolation or enable unauthorized remote control.
- Examples: sandbox escape from `bwrap`, cross-company data access, bypass of Router permission checks to write arbitrary host paths, or unauthenticated remote access to dashboard/MCP with mutation capabilities.
- Tampering with or deleting audit logs to conceal actions also qualifies.

### High
Severe permission or secret exposure requiring some local access or misconfiguration.
- Examples: path traversal in permission scopes granting access to unintended projects, bypass of `network: none` or path-request approval, leakage of `config.md` or provider credentials, or XSS that steals a dashboard token when the UI is LAN-exposed.

### Medium
Impactful but constrained to local-only deployment assumptions or requiring user interaction.
- Examples: CSRF or XSS against a loopback-only dashboard, DoS via large files or inotify flooding (bounded by caps and watcher limits), or corruption of the SQLite index (non-authoritative).
- These rise to High/Critical if the operator exposes the service to LAN or runs on shared hosts.

### Low
Defense-in-depth gaps or minor disclosures without a clear exploitation path.
- Examples: overly verbose error messages, minor markdown rendering quirks, or non-sensitive metadata leakage (versions, uptime). These matter mostly for hardening, not direct compromise.

---

## Open findings

Codex scan (2026-04-22 / 2026-04-23 sweep, 126 findings). **85 open** ·
41 dropped: waves 1–3 on 2026-04-22 closed 26; wave 4 on 2026-04-23
closed 6 highs (dispatcher reply lstat, router slug validation,
approval-gate director mark, dispatch task_id validation); wave 5
closed 3 mediums (Kanban list_projects lstat+slug, AgentLive io
preview lstat, TaskDefinition.write regular-file guard) and
discovered 6 more mediums were already fixed by earlier waves
(false-positive Codex flags; verified against HEAD).

Breakdown: 0 critical, 0 high, 22 medium, 39 low, 24 informational.

Format per row: **title** — short gist. *Paths:* touched files.
See `git log -- docs/testing/threatmodel.md` for the raw Codex import (with per-finding URLs) and the wave-1/2/3 closure log.

### Medium (constrained exploit — local access or misconfig) — 22

- **Unbounded MCP sessions/subscriptions allow resource exhaustion DoS** — The commit introduces per-session GenServers and resource subscriptions for MCP. `initialize` now calls `Session.start_session/1` to spawn a new process for every request, but there is no cap, TTL, or cleanup unless the client sends DELETE. Additionally,…
  *Paths:* `lib/glorbo_web/mcp/plug.ex, lib/glorbo_web/mcp/session.ex`
- **MCP create_agent allows YAML injection in AGENT.md** — The new MCP tool `glorbo.create_agent` accepts free-form `role`, `provider`, `model`, `reports_to`, and `template` strings from RPC clients and passes them directly into the agent scaffold. The scaffold writes these values into YAML frontmatter with no…
  *Paths:* `lib/glorbo_web/mcp/tools/create_agent.ex, lib/glorbo/cli/scaffold/agent.ex`
- **Proposal YAML key injection can forge approval fields** — The new proposal outbox handler preserves all agent-supplied frontmatter keys and then re-serializes them to YAML with raw key interpolation. Because keys are not quoted or validated, a malicious agent can craft a YAML key containing newline/colon sequences…
  *Paths:* `lib/glorbo/company/router.ex`
- **Release formula task trusts remote SHA256SUMS input** — The newly added Mix task fetches SHA256SUMS over HTTPS via :httpc using default options and parses each line into a map without enforcing that the "sha" tokens are valid hex digests. Those untrusted values are then embedded verbatim in the Ruby formula…
  *Paths:* `lib/mix/tasks/glorbo.release_formula.ex`
- **Company cap sums global agent slugs, enabling cross-company DoS** — The new CompanyCap module computes company usage by listing agent directory names and summing Budget rows where agent_slug is in that list. The budgets table is keyed only by agent_slug and year_month, with no company field. If two companies share an agent…
  *Paths:* `lib/glorbo/budget/company_cap.ex, lib/glorbo/budget.ex`
- **Unbounded ETS cache of task titles can exhaust memory** — Glorbo.Search now lazily creates a named, public ETS table and caches every task title by path+mtime. Titles are taken directly from frontmatter and inserted into ETS with no size checks or eviction. Because agent-authored tasks only require a non-empty…
  *Paths:* `lib/glorbo/search.ex, lib/glorbo/company/router.ex`
- **Archive listing reads entire archive files on every update** — The new archive browser refreshes the archive list on every file event and, for each archive file, performs a full File.read to compute size and message counts. An agent with chat:write permission can spam messages to rotate channels, producing many large…
  *Paths:* `lib/glorbo_web/live/channel_live.ex`
- **Stuck sentinel resolution trusts paths from untrusted files** — The loop-detector feature adds a "stuck" sentinel flow that loads any `agents/*/state/stuck-on-*.md` file and surfaces it in the Inbox UI. Agents have write access to their own `state` directory, so a malicious agent can craft a fake stuck sentinel with a…
  *Paths:* `lib/glorbo_web/live/inbox_live.ex, lib/glorbo/security/acl_mapper.ex`
- **Auto-mounting CLI binary dirs leaks host paths into sandbox** — `cli_binary_binds/1` now auto-detects the provider’s resolved binary path and ro-binds both the symlink’s parent directory and the symlink target’s parent into the sandbox at the same absolute paths. Because `resolved_path` comes from PATH or a user-defined…
  *Paths:* `lib/glorbo/agent/dispatch.ex`
- **Kanban open_task allows arbitrary project file reads** — The new KanbanLive open_task handler trusts the client-supplied "path" and calls File.read/1 after resolve_task_path/2, which only enforces a "projects/" prefix and absence of "..". It does not require a tasks/ path, a .md extension, or a regular file, and…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex`
- **Erlang cookie exposed via console command-line arguments** — `Glorbo.CLI.Console.launch/2` builds an argv list that embeds the Erlang distribution cookie and spawns `iex` with those arguments. On many systems, command-line arguments are visible to other local users via `ps`/`/proc`, so a different OS user can read the…
  *Paths:* `lib/glorbo/cli/console.ex`
- **Restore tar guard ignores symlink targets, enabling path escape** — `Glorbo.Restore.run/2` introduces a traversal guard that rejects absolute paths or `..` segments by inspecting entry names returned from `:erl_tar.table/2`. This does not validate symlink or hardlink targets, and `:erl_tar.extract/2` is then invoked directly…
  *Paths:* `lib/glorbo/restore.ex`
- **Backup archive permissions set after creation allow local read race** — Glorbo.Backup creates the archive via :erl_tar.create, which uses the process umask (often 0644) when creating the file. The code only applies chmod 0600 after successful creation. This leaves a race window where a local user with access to the output…
  *Paths:* `lib/glorbo/backup.ex`
- **Agent scaffold writes unsupported budget key, cap ignored** — The new `glorbo new agent` scaffold writes `budget:\n monthly_usd: 10.00` into `agent.md`. The runtime parser and budget tracker only look for `budget_usd_cents_month`, so the cap is parsed as `nil` and enforcement is skipped. This means freshly scaffolded…
  *Paths:* `lib/glorbo/cli/scaffold/agent.ex, lib/glorbo/agent/parser.ex`
- **Unbounded stdout buffering enables dashboard DoS** — The new AgentLive starts a StdoutStreamer and inserts each stdout line into a LiveView stream. StdoutStreamer concatenates new bytes onto an in-memory buffer and only trims it when a newline arrives; there is no cap on the buffer or per-line size. A sandboxed…
  *Paths:* `lib/glorbo_web/live/agent_live.ex, lib/glorbo_web/stdout_streamer.ex`
- **Approvals.Gate activation allows self‑approval of tasks** — The commit wires Glorbo.Approvals.Gate into the per‑company supervision tree, making the approval flow live. Gate subscribes to project task file events and resolves approvals whenever it sees a task status set to "approved" or "denied". Because there is no…
  *Paths:* `lib/glorbo/company/supervisor.ex, lib/glorbo/approvals/gate.ex, lib/glorbo/security/acl_mapper.ex`
- **Proxy connection tasks leak mailbox messages causing DoS** — The commit switches per-connection handling from Task.Supervisor.start_child/2 to Task.Supervisor.async_nolink/2 inside the accept loop. async_nolink delivers {ref, result} and :DOWN messages to its caller (the acceptor task), but the acceptor never receives…
  *Paths:* `lib/glorbo/network/proxy.ex`
- **Permission scopes allow path traversal in bwrap mounts** — The new PermissionMapper maps permission tuples directly into bwrap --bind/--ro-bind arguments using Path.join with the raw scope value. ACLMapper.parse_permission only validates that the string has three parts and that the resource is whitelisted; it does…
  *Paths:* `lib/glorbo/sandbox/permission_mapper.ex, lib/glorbo/security/acl_mapper.ex`
- **Skills resolver follows symlinks when copying skill files** — Glorbo.Skills.Resolver builds the source path under "~/.glorbo/skills" and uses File.cp!/2 (via fs_fun) to copy the file into the per-task run directory. File.cp!/2 dereferences symlinks, but the resolver never checks whether the source is a regular file…
  *Paths:* `lib/glorbo/skills/resolver.ex`
- **Watcher reindex reads unvalidated paths via symlinks** — Filesystem.Watcher now calls mark_dirty/2 for any file event that is not under inbox/outbox/audit/channels. mark_dirty/2 and process_path/2 simply invoke process_file/1, which unconditionally reads the provided path. There is no check that the path is within…
  *Paths:* `lib/glorbo/filesystem/watcher.ex, lib/glorbo/filesystem/reindex.ex`
- **Config file created without restrictive permissions** — The new filesystem hierarchy initializer writes config.md and logs/glorbo.log using File.write! and creates directories with File.mkdir_p! but never sets restrictive permissions on those paths. Only runtime/sockets is chmod’d to 0700. On typical umask 022…
  *Paths:* `lib/glorbo/filesystem/hierarchy.ex`
- **CI workflow uses unpinned GitHub Action tags** — The added workflow uses multiple `uses: ...@vX` references to third‑party actions without pinning them to commit SHAs. GitHub Action tags are mutable; if any upstream action is compromised or retagged, the workflow will execute attacker‑controlled code. This…
  *Paths:* `github/workflows/ci.yml`

### Low (defense-in-depth / bounded DoS / integrity gaps) — 39

- **MCP initialize crashes on list params, enabling local DoS** — `handle_initialize/1` now calls `Map.get(params || %{}, "protocolVersion")` to negotiate versions. However, the request parser in `MCP.Plug.extract_request/1` still treats JSON-RPC `params` arrays as valid, so `params` can be a list. `Map.get/2` on a list…
  *Paths:* `lib/glorbo_web/mcp/server.ex, lib/glorbo_web/mcp/plug.ex`
- **MCP post_message mentions spoof director in agent inboxes** — The commit adds MCP write tooling that calls Actions.post_message/4 with a caller-controlled actor (mcp:<client>). Actions.post_message now records that actor in the channel log and audit entry, but its mention fanout still routes through…
  *Paths:* `lib/glorbo_web/mcp/tools/post_message.ex, lib/glorbo_web/actions.ex`
- **MCP endpoint exposed without dashboard token or auth gate** — The commit adds a new MCP JSON-RPC endpoint at /mcp and explicitly forwards it outside the :dashboard pipeline that enforces the optional bearer token. The only guard is an Origin host check, but the plug also allows requests with no Origin header (for CLI…
  *Paths:* `lib/glorbo_web/router.ex, lib/glorbo_web/mcp/plug.ex`
- **ProposalsSink trusts proposal metadata for audit actions/actors** — ProposalsSink reads any direct-child `proposals/*.md` file and derives the audit `action` and `actor` from the unvalidated frontmatter fields (`status`, `approved_by`, `proposed_by`). Since proposal files are agent-controlled when an agent has…
  *Paths:* `lib/glorbo/company/proposals_sink.ex`
- **InboxLive path approval crashes on malformed paths payload** — `approve_path` decodes the `paths` value directly from the LiveView event and immediately pattern-matches each element while converting `mode` with `String.to_existing_atom/1`. If a client tampers with the event payload (e.g., non-list JSON, entries missing…
  *Paths:* `lib/glorbo_web/live/inbox_live.ex`
- **Validator follows symlinks, enabling local DoS on validate** — Glorbo.FileSpec.Validator expands the target path using Path.wildcard and File.regular?, which follow symlinks. It then reads every matched file with File.read/1. An attacker who can write to the workspace (e.g., a malicious agent) can plant a symlink to a…
  *Paths:* `lib/glorbo/file_spec/validator.ex`
- **Unbounded sidebar memory scans enable low-effort UI DoS** — The sidebar now calls count_memory_files/2 for every agent row. That function performs File.ls on the agent's memory directory and walks all entries to match a regex. There is no cap or caching, and memory files are attacker-controlled via the agent outbox. A…
  *Paths:* `lib/glorbo_web/components/sidebar.ex`
- **Unbounded memory file reads allow local DoS via huge files** — Glorbo.Agent.Memory.compose/3 introduces unbounded File.read calls for both the MEMORY.md index and each memory body file. The code enforces a 20KB output budget only after the entire file contents are loaded into memory, meaning a large file placed under…
  *Paths:* `lib/glorbo/agent/memory.ex`
- **PATH search for epmd enables local command hijack** — The commit adds ensure_epmd/0 to spawn the EPMD daemon before Node.start/2. When the expected ERTS epmd binary is not present, it falls back to executing "epmd" via System.cmd/3. This relies on the current PATH and permits command hijacking if an attacker can…
  *Paths:* `lib/glorbo/cli/lifecycle/distribution.ex`
- **TaskLive audit aggregation can exhaust memory on large logs** — The new TaskLive usage strip computes totals by calling load_usage_totals, which reads the entire monthly audit JSONL file with File.read and splits it into a list of lines before reduction. Audit logs are append-only and can grow without bound from untrusted…
  *Paths:* `lib/glorbo_web/live/task_live.ex`
- **UTF-8 offset mismatch can truncate rotated chat logs** — The new rotation logic collects header positions with `Regex.scan(..., return: :index)`, which returns byte offsets, and then feeds those offsets into `String.split_at/2`, which operates on grapheme indices. When messages contain multibyte UTF-8 characters…
  *Paths:* `lib/glorbo/chat/rotation.ex`
- **Recurring schedule parsing can crash on non-string YAML values** — The commit adds a schedule field and recurring-task loop-back logic. Both the parser and the recurring check call to_string on the raw YAML value. If an attacker (agent or any process writing task files) sets schedule to a non-scalar YAML value such as a map…
  *Paths:* `lib/glorbo/task_definition.ex`
- **strip_ansi crashes on non‑UTF‑8 reply/STDOUT output** — The commit adds strip_ansi/1 and applies it to both stdout fallback replies and on-disk reply reads. strip_ansi relies on String.replace/3, which requires valid UTF‑8 binaries. Agent/CLI output is attacker-controlled and may contain arbitrary bytes; invalid…
  *Paths:* `lib/glorbo/cli/dispatcher.ex`
- **TaskLive deletes tasks without recording audit events** — TaskLive now supports delete_task, but the handler directly renames the task file into history/deleted without emitting an audit event. This diverges from KanbanLive’s delete path, which explicitly appends a task.delete audit entry. As a result, anyone with…
  *Paths:* `lib/glorbo_web/live/task_live.ex, lib/glorbo_web/live/kanban_live.ex`
- **Task goal frontmatter can crash parsing on non-scalar values** — TaskDefinition.parse_frontmatter now reads the optional goal key and passes it to as_string. as_string blindly calls to_string for non-binary values, which raises Protocol.UndefinedError for YAML maps or lists. A task file containing goal: {foo: bar} or goal:…
  *Paths:* `lib/glorbo/task_definition.ex`
- **Inbox audit feed rereads full log on each update** — InboxLive’s recent-activity panel uses File.read/1 to load the full current-month audit log and then filters the last 50 lines. This happens during initial mount and again on every :file_event and :audit_append notification. Because audit entries are…
  *Paths:* `lib/glorbo_web/live/inbox_live.ex`
- **Protocol-relative return_to enables open redirect from Kanban** — KanbanLive now stores return_to directly from query params and uses it to push_navigate on cancel. The guard only checks String.starts_with?(path, "/"), which permits protocol-relative URLs such as "//evil.com". An attacker can craft a link like…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex`
- **RunLog crashes on malformed duration_ms in audit JSONL** — The new Glorbo.Agent.RunLog reader converts detail["duration_ms"] with String.to_integer/1. If an audit JSONL entry contains a non-numeric duration_ms (e.g., tampered or malformed log line), String.to_integer raises an ArgumentError, which bubbles out of…
  *Paths:* `lib/glorbo/agent/run_log.ex`
- **Release boot check disabled, allowing dev debug flags in prod** — The commit sets `validate_compile_env: false` in the release configuration. Phoenix uses compile‑time settings for endpoint flags like `debug_errors` and `code_reloader`. If release artifacts are compiled under dev/test (which sets these to true) and then run…
  *Paths:* `mix.exs, config/dev.exs`
- **Stop button can kill an agent in the wrong company** — Agent servers are registered with a `{kind, company_slug, agent_slug}` key, but the new LiveView stop handler calls `find_agent_server/1` with only the agent slug. That helper uses `Registry.match` with `{:agent_server, :_, slug}`, returning the first…
  *Paths:* `lib/glorbo_web/live/agent_live.ex, lib/glorbo/agent/registry.ex`
- **Denial reason input can corrupt task frontmatter parsing** — The commit adds a denial-reason textarea and passes its raw contents to GlorboWeb.Actions.set_approval/4. When a denial reason is present, set_approval rebuilds task frontmatter via TaskDefinition.write_frontmatter/2. That serializer only escapes double…
  *Paths:* `lib/glorbo_web/live/approval_queue_live.ex, lib/glorbo_web/actions.ex, lib/glorbo/task_definition.ex`
- **Channel creation bypasses symlink checks and can write outside scope** — The new `create_channel` LiveView handler constructs a path and uses `File.mkdir_p` + `File.write` after only checking slug validity and `File.exists?`. This bypasses the `ensure_regular_file`/`lstat` symlink protections used in `GlorboWeb.Actions`. A…
  *Paths:* `lib/glorbo_web/live/channel_live.ex`
- **company.md editor allows symlink-based file overwrite** — The commit adds a dashboard modal that rewrites company.md by writing to `company.md.tmp` and renaming it. The implementation does not verify that either `company.md` or the temporary path is a regular file, nor does it use an exclusive/unique temp file. If…
  *Paths:* `lib/glorbo_web/live/company_live.ex`
- **Stdout parsing allows spoofed dispatch/exit markers** — StdoutStreamer now classifies any line matching the dispatch/exit regexes as metadata and StdoutTail renders those lines as special cards, omitting the raw body. Because agent stdout is attacker-controlled, an agent can emit lines like "=== exit 0 ===" or…
  *Paths:* `lib/glorbo_web/stdout_streamer.ex, lib/glorbo_web/components/stdout_tail.ex`
- **CLI failure logging can crash on non‑UTF‑8 stdout** — The new maybe_log_run_output/4 helper logs a snippet of CLI stdout when exit status is non‑zero or a reply file is missing. It converts the raw stdout to a string and calls String.slice/3. However, stdout is captured as raw binary from the bwrap port (with…
  *Paths:* `lib/glorbo/cli/dispatcher.ex, lib/glorbo/sandbox/bwrap.ex`
- **Agent history loads full audit log causing potential DoS** — The history feature loads the current-month audit log with File.read and splits/reverses the entire file just to find the last 200 matching rows. Audit logs are append-only and can grow very large (especially if a malicious agent or external caller generates…
  *Paths:* `lib/glorbo_web/live/agent_live.ex`
- **Scheduler reads HEARTBEAT.md without filtering non-regular files** — The new HEARTBEAT.md lookup reads the file with File.read after a size check using File.stat, but does not verify that the path is a regular file or reject symlinks/special files. An untrusted agent can replace HEARTBEAT.md with a FIFO, device file, or…
  *Paths:* `lib/glorbo/company/scheduler.ex`
- **Providers page now exposes raw TOML config contents** — The commit adds a collapsible TOML snippet for each provider. The LiveView calls read_toml/1, which does a File.read on the provider’s source_file and renders the raw text into the page. User-defined providers.toml supports env overrides and other potentially…
  *Paths:* `lib/glorbo_web/live/providers_live.ex`
- **Kanban drag-drop trusts client paths for filesystem writes** — The new "kanban:move" LiveView event accepts a `task_path` from the browser and only validates that it starts with "projects/" and does not contain "..". It then calls `Glorbo.TaskDefinition.write/2` directly. This bypasses the stricter task-path validation…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex`
- **Restore rejection leaves modified files on symlink escape** — When restore detects escaping symlinks it now calls clean_up_extract/2 instead of wiping the base. clean_up_extract only removes top-level entries that did not exist before extraction. If the base already contains entries like config.md or companies/, a…
  *Paths:* `lib/glorbo/restore.ex`
- **CLI run bypasses director approval requirements** — `glorbo run` parses the task file and immediately calls `Glorbo.Agent.Dispatch.execute/3`. It never checks `TaskDefinition.requires_approval?/1` or consults the approval gate/state, so a task with `requires_approval: director` in frontmatter will still run.…
  *Paths:* `lib/glorbo/cli/lifecycle/run.ex, lib/glorbo/task_definition.ex`
- **StdoutStreamer buffers unlimited line data, enabling DoS** — GlorboWeb.StdoutStreamer concatenates the previous buffer with each read chunk and retains the trailing partial line in memory until a newline appears. If an agent writes a very long line without newlines to stdout.log, `state.buf` grows by 64 KiB every poll…
  *Paths:* `lib/glorbo_web/stdout_streamer.ex`
- **Unbounded agent.md scan on startup enables local DoS** — The commit adds a boot-time scan that walks every agents/<slug>/agent.md to decide whether to start the Network.Proxy. This is done during Company.Supervisor.init/1 and calls Agent.Parser.parse_file/1 for each file. Agent.Parser.parse_file/1 uses File.read/1…
  *Paths:* `lib/glorbo/company/supervisor.ex, lib/glorbo/agent/parser.ex`
- **Insecure prompt tempfile in /tmp may leak or clobber data** — The commit replaces direct stdin piping with a prompt tempfile created in the system temp directory. The tempfile is created with File.write/2 and a predictable name derived from System.unique_integer/1. File.write/2 does not request exclusive creation or set…
  *Paths:* `lib/glorbo/sandbox/bwrap.ex`
- **Unvalidated token counts in CLI adapters can crash parsing** — The new CLI adapters parse usage telemetry from JSONL/stdout files that are attacker-controlled (agent workspace or CLI output). In ClaudeCode, Codex, and GeminiCli, token fields are added without type checks. If a malicious or buggy CLI emits strings/arrays…
  *Paths:* `lib/glorbo/cli/claude_code.ex, lib/glorbo/cli/codex.ex, lib/glorbo/cli/gemini_cli.ex`
- **Budget alerts use unsanitized agent slugs in file paths** — BudgetTracker’s alert writer builds the output path with `Path.join([... "#{agent_slug}-budget.md"])` and then calls `mkdir_p!` and `write!` without validating the slug. If an attacker can influence `agent_slug` (e.g., via agent creation or on-disk…
  *Paths:* `lib/glorbo/company/budget_tracker.ex`
- **Batch reindex deletes can exceed SQLite parameter limit** — The updated cleanup_vanished/1 batches deletes with `where ... in ^vanished`. SQLite (the default backend) caps the number of bind variables (typically 999). If a large number of markdown files were previously indexed and later removed (e.g., an untrusted…
  *Paths:* `lib/glorbo/filesystem/reindex.ex`
- **AuditLog append uses unsanitized company in file path** — The new AuditLog implementation derives the audit log file path directly from `entry[:company]`/`entry["company"]`. `entry_company/1` converts the value to a string without any slug/path validation, and `jsonl_path/3` passes it straight into `Path.join/1`. If…
  *Paths:* `lib/glorbo/company/audit_log.ex`
- **Symlink escape in reindex allows out-of-scope file reads** — Glorbo.Filesystem.Reindex.safe_markdown_files/1 claims to enforce a symlink escape defense by checking that each candidate path stays under the companies directory. However, it uses Path.expand on the symlink path, which is purely lexical and does not resolve…
  *Paths:* `lib/glorbo/filesystem/reindex.ex`

### Informational (correctness / UX — not a direct security gap) — 24

- **TaskComments parse swaps capture order, misreads entries** — `@message_re` defines named captures in the order `ts`, `author`, `body`. `parse/1` destructures the `Regex.scan(..., capture: :all_names)` results as `[author, body, ts]`, which does not match the capture order returned by Elixir. This causes comment entries…
  *Paths:* `lib/glorbo/task_comments.ex`
- **Overview goals parsing crashes on non-string goal slug** — The commit adds goals aggregation for company cards by parsing `company.md` and iterating over each goal entry. The code calls `to_string/1` on `goal.slug` without verifying it is a scalar string/atom/integer. YAML frontmatter is attacker-controlled per the…
  *Paths:* `lib/glorbo_web/live/overview_live.ex`
- **Proxy classifier lacks validation and can crash on bad return** — In classify_unlisted/5, the proxy only pattern-matches the expected classifier verdict tuples. safe_classify/3 only rescues raises and exits, but it does not validate or coerce unexpected return values. A classifier that returns nil or any non-matching tuple…
  *Paths:* `lib/glorbo/network/proxy.ex`
- **SmartClassifier allows private IPs when explicitly allowlisted** — In Glorbo.Network.SmartClassifier.classify/2, the rule order checks denylist → allowlist → private_ip → ad_tld. This means any host that matches the allowlist is immediately allowed, even if it is a literal private IP like 127.0.0.1 or 10.0.0.1. The module’s…
  *Paths:* `lib/glorbo/network/smart_classifier.ex`
- **Task assignment kind change breaks agent reply routing** — The commit changes task assignment notifications to use a new kind/subkind schema (`kind: inbox-message/v1`, `subkind: task_assignment`). Agent.Server’s `reply_target/1` still checks for `kind == "task_assignment"` and otherwise skips messages from the…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex, lib/glorbo/agent/server.ex`
- **NL schedule parser ignores 'every weekday at <time>'** — Glorbo.ScheduleNL’s documentation lists “every weekday at 9am” as supported. However, dispatch/1 only handles the exact rest == "weekday" or "weekend" tokens and does not parse an optional “at <time>” suffix for those bucketed terms. As a result, schedules…
  *Paths:* `lib/glorbo/schedule_nl.ex`
- **Invalid schedule stash drops timer_ref, leaving stale timers** — The commit changes invalid-cron handling to store a minimal entry (schedule/rel_path/invalid?) in state.tasks. If a task previously had a valid schedule and an armed timer, this replacement drops the existing timer_ref. When the schedule is later fixed before…
  *Paths:* `lib/glorbo/company/task_scheduler.ex`
- **Task budget audit ignores task-level provider override** — The dispatch pipeline resolves the provider using task-level overrides, but the new per-task budget check derives cost via Ledger.compute_cost_cents/4 using spec.provider. When a task overrides provider (or the agent spec leaves provider unset), this path…
  *Paths:* `lib/glorbo/agent/dispatch.ex`
- **Costs ledger merges agent spend across companies** — The new /costs page builds rows per {company, slug} from the filesystem, but it queries and groups ledger data solely by agent_slug. If two companies use the same agent slug, the costs matrix will combine their spend and display the same totals under both…
  *Paths:* `lib/glorbo_web/live/costs_live.ex, lib/glorbo/budget/ledger.ex`
- **NL heartbeat parsing crashes on inputs like "every 9am** — Glorbo.Schedule.NL.compile/1 uses Regex.run/2 with optional minute and am/pm captures. When minutes are omitted (e.g., "every 9am", "daily at 9am", "every monday at 9am"), Regex.run returns a nil minute capture. split_rest/1 passes that nil through, and…
  *Paths:* `lib/glorbo/schedule/nl.ex, lib/glorbo/agent/parser.ex`
- **Model alias parsing crashes on non-string YAML values** — The added model alias support converts each alias key/value with `to_string/1` without guarding against values that lack the String.Chars protocol (e.g., nested maps or lists of strings in YAML). When such a malformed `models:` block is parsed, `to_string/1`…
  *Paths:* `lib/glorbo/agent/parser.ex`
- **AgentLive config form writes unsupported network value** — `config_save` now writes the network field from the form directly into AGENT.md. The form only offers `none` and `outgoing`, yet `Glorbo.Agent.Parser` only recognizes `none`, `api-only`, and `open`. If a director saves the form, the file is updated with an…
  *Paths:* `lib/glorbo_web/live/agent_live.ex, lib/glorbo/agent/parser.ex`
- **Hot-reload ignores legacy agent.md causing stale specs** — Agent.Server now triggers a reload for both AGENT.md and agent.md edits, but maybe_reload_spec hardcodes the canonical AGENT.md path. On installations that still only have agent.md, the reload attempt reads a non-existent file and keeps the old spec. This…
  *Paths:* `lib/glorbo/agent/server.ex`
- **Workspace ignore rule skips reindex for agent slug "workspace** — The commit adds a classify/1 rule that ignores any path under "agents/" containing the substring "/workspace/". This is intended to skip the agent workspace directory, but it also matches all paths for an agent whose slug is exactly "workspace" (e.g.,…
  *Paths:* `lib/glorbo/filesystem/watcher.ex`
- **Approval reassignment writes task files without symlink checks** — The commit adds reassign_task/3 calls during approval request and grant. reassign_task builds an absolute path from task_path and calls TaskDefinition.write without validating that the target is a regular file or rejecting symlinks. An agent with tasks:update…
  *Paths:* `lib/glorbo/approvals/gate.ex, lib/glorbo/task_definition.ex`
- **Dashboard now accepts underscore slugs but routing rejects them** — This commit updates the client-side slug pattern for new agents to allow underscores and require a leading letter. However, the LiveView routing guard still uses GlorboWeb.Slug.valid?/1, which only allows [a-z0-9-]+. As a result, agents created with…
  *Paths:* `lib/glorbo_web/live/company_live.ex, lib/glorbo_web/slug.ex, lib/glorbo_web/live/agent_live.ex`
- **Company dashboard crashes when CLI registry is unavailable** — CompanyLive now calls provider_options() at mount time to populate the new-agent provider dropdown. provider_options/0 calls CLIRegistry.list/0 and rescues only exceptions. CLIRegistry.list/0 uses Agent.get/2; when the registry process is not running (e.g.,…
  *Paths:* `lib/glorbo_web/live/company_live.ex, lib/glorbo/cli/registry.ex`
- **Heartbeat inbox scans now skip drain/reply due to trigger tagging** — The commit threads the wake trigger into inbox scans and stores it in the task map. For heartbeat wakes, this now produces tasks with trigger=:heartbeat instead of :inbox. Downstream logic only routes replies and drains inbox files for :inbox or :mention…
  *Paths:* `lib/glorbo/agent/server.ex`
- **AuditLive realtime append leaves pagination offset stale** — AuditLive now handles {:audit_append, record} by appending to the in-memory tail and incrementing total_lines, but it never updates offset or beginning. When the tail is capped to 500 entries, the oldest entry is dropped and the offset should be incremented;…
  *Paths:* `lib/glorbo_web/live/audit_live.ex`
- **Kanban editor YAML writer fails to escape backslashes** — The save_task handler now takes raw user input (title/assigned_to/priority/etc.) and writes it via TaskDefinition.write_frontmatter. That writer constructs YAML lines with yaml_scalar, but yaml_scalar only escapes double quotes and leaves backslashes…
  *Paths:* `lib/glorbo_web/live/kanban_live.ex, lib/glorbo/task_definition.ex`
- **Unbounded parallel version probes allow local DoS** — The new detection module runs version probes in parallel using Task.async_stream with max_concurrency set to the full provider list length. The provider list is loaded directly from ~/.glorbo/providers.toml without any cap, so a locally writable providers…
  *Paths:* `lib/glorbo/cli/registry/detection.ex, lib/glorbo/cli/registry/loader.ex`
- **GEP validator crashes on non-numeric frontmatter values** — Gep.Validator normalizes numeric frontmatter fields (gep, requires, supersedes, superseded-by, extended-by, see-also) by calling String.to_integer/1 on any binary value. If a GEP file contains a non-numeric string (e.g., "GEP-0001" or "foo") in one of these…
  *Paths:* `lib/gep/validator.ex`
- **Inotify follow can skip log bytes during concurrent writes** — Glorbo.CLI.Logs.handle_modification/3 reads from the previous size to EOF, then sets the next offset using a second File.stat!/1. If the log grows between the read and that stat, last_size jumps past unread bytes. Subsequent events see new_size <= last_size…
  *Paths:* `lib/glorbo/cli/logs.ex`
- **TaskDefinition prefix check allows traversal outside company** — `relative_task_path/3` trusts `String.starts_with?/2` on the raw `file_path` to decide if a task lives under the target company. Because the path is not normalized or resolved, an attacker who can influence the task path (or place a symlink in the tasks…
  *Paths:* `lib/glorbo/task_definition.ex`

