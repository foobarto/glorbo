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

Task comment writes follow symlinks to arbitrary host files
Link: https://chatgpt.com/codex/cloud/security/findings/e39ec2efaed481918544ac5ff4d524c7?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: high (attack path: high)
Status: resolved (commit 0720d62, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: cc99146
Author: security@example.invalid
Created: 22.04.2026, 20:56:12
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
This commit introduced a new comment storage path without the symlink protections that existed for task-file comments, enabling arbitrary file writes via symlinked .comments.md files.
The commit moved task comments into sibling "<task>.comments.md" files and now uses Glorbo.TaskComments.append/4 from both the director comment path and agent replies. Unlike the previous task-file append, there is no regular-file or no-follow check on the comments file. TaskComments.ensure_file/2 only calls File.exists?/1 and then File.write/3, which will follow a pre-created symlink. An attacker (e.g., an agent with tasks:update or projects:write access to the tasks directory) can create <task-id>.comments.md as a symlink to an arbitrary host file (such as ~/.glorbo/config.md) and then trigger a comment write, causing the host process to append to the target and breaking sandbox isolation.

# Validation
## Rubric
- [x] Locate where comment thread paths are derived and verify whether a regular-file/symlink check is applied before writes.
- [x] Inspect `TaskComments.append/4` and `ensure_file/2` for lstat/no-follow protections vs. `File.exists?/1` + `File.write/3` behavior.
- [x] Confirm all call sites (director + agent reply) use `TaskComments.append/4` without additional validation.
- [ ] Execute a runtime PoC demonstrating symlinked `<task-id>.comments.md` writes (blocked by missing Elixir/Erlang in container).
- [x] Compare with existing symlink protections (`ensure_regular_file/1`) to show regression scope.
## Report
Rubric-driven validation attempted dynamic reproduction first. Tried to run Elixir tooling to execute a PoC, but runtime is missing: `mix --version` and `elixir -e 'IO.puts(:ok)'` both failed with `bash: command not found` and mise attempting (and failing) to download Elixir/Erlang due to blocked network (see command outputs). As a result, no runtime PoC could be executed. Code inspection shows the comments file is derived and written without symlink protection: `post_task_comment/4` computes `comments_path = Glorbo.TaskComments.path_for(abs_task)` and calls `Glorbo.TaskComments.append/4` with no regular-file check (lib/glorbo_web/actions.ex:142-156). `Glorbo.TaskComments.append/4` calls `ensure_file/2` then `File.write(path, entry, [:append, :sync])` (lib/glorbo/task_comments.ex:80-89); `ensure_file/2` only checks `File.exists?/1` and then `File.write/2` on first write (lib/glorbo/task_comments.ex:111-127). `File.exists?/1` will return true for a pre-created symlink, and `File.write/3` follows symlinks, enabling arbitrary file append via a symlinked `<task-id>.comments.md`. The existing symlink defense (`ensure_regular_file/1` using `File.lstat`) is only applied to the task file itself, not the comments sibling (lib/glorbo_web/actions.ex:146-147, 622-629). The agent reply path also uses `TaskComments.append/4` with no validation (lib/glorbo/agent/server.ex:588-601). This confirms the arbitrary file write via symlinked comments file introduced by the commit.

# Evidence
/workspace/glorbo/lib/glorbo_web/actions.ex (L142 to 158)
  Note: Director comments now derive a sibling comments_path and call TaskComments.append without validating the comments file as a regular file.
```
    with :ok <- validate_slug(company),
         :ok <- validate_task_path_strict(task_path),
         :ok <- validate_body(body),
         :ok <- validate_comment_nonblank(body),
         abs_task = Path.join([base, "companies", company, task_path]),
         :ok <- ensure_regular_file(abs_task) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      task_id = task_path |> Path.basename() |> Path.rootname()
      # GEP-30 D8: comments live in a sibling `.comments.md` file,
      # not inline in the task body. The task file stays diff-clean;
      # the thread is rendered from the sibling by Kanban + TaskLive.
      comments_path = Glorbo.TaskComments.path_for(abs_task)

      case Glorbo.TaskComments.append(comments_path, "director", body,
             ts: ts,
             task_id: task_id
           ) do
```

/workspace/glorbo/lib/glorbo/task_comments.ex (L111 to 126)
  Note: ensure_file only checks File.exists?/1 and then File.write/2, so a pre-existing symlink is followed and written to.
```
  defp ensure_file(path, task_id) do
    if File.exists?(path) do
      :ok
    else
      ts = DateTime.utc_now() |> DateTime.to_iso8601()

      header = """
      ---
      kind: task-comments/v1
      task_id: #{task_id}
      created_at: #{ts}
      ---
      """

      with :ok <- File.mkdir_p(Path.dirname(path)) do
        File.write(path, header)
```

/workspace/glorbo/lib/glorbo/task_comments.ex (L80 to 89)
  Note: TaskComments.append writes directly to the provided path after ensure_file, with no lstat/no-follow protection.
```
  @spec append(Path.t(), binary(), binary(), keyword()) :: :ok | {:error, term()}
  def append(path, author, body, opts \\ [])
      when is_binary(path) and is_binary(author) and is_binary(body) do
    ts = Keyword.get_lazy(opts, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
    task_id = Keyword.get_lazy(opts, :task_id, fn -> derive_task_id(path) end)

    with :ok <- ensure_file(path, task_id) do
      entry = "\n## #{ts} | #{author}\n#{String.trim_trailing(body)}\n"
      File.write(path, entry, [:append, :sync])
    end
```

Proposed patch:
diff --git a/lib/glorbo/task_comments.ex b/lib/glorbo/task_comments.ex
index ead96c48ef3737d7389c55def215884ddd3ba8fe..11d6c360184c05b06c60db2f15e9d5e5cfa0c2b0 100644
--- a/lib/glorbo/task_comments.ex
+++ b/lib/glorbo/task_comments.ex
@@ -61,76 +61,90 @@ defmodule Glorbo.TaskComments do
   Entries are returned in on-disk (chronological) order.
   """
   @spec read(Path.t()) :: {:ok, [entry]} | {:error, term()}
   def read(path) when is_binary(path) do
     case File.read(path) do
       {:ok, content} -> {:ok, parse(content)}
       {:error, :enoent} -> {:ok, []}
       {:error, _} = err -> err
     end
   end
 
   @doc """
   Append one entry to the thread file, bootstrapping frontmatter
   + a blank-line separator if the file doesn't exist yet.
 
   The write uses `[:append, :sync]` so crashes don't leave a
   partial entry on disk. Returns `:ok` on success or
   `{:error, reason}` on IO failure.
   """
   @spec append(Path.t(), binary(), binary(), keyword()) :: :ok | {:error, term()}
   def append(path, author, body, opts \\ [])
       when is_binary(path) and is_binary(author) and is_binary(body) do
     ts = Keyword.get_lazy(opts, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
     task_id = Keyword.get_lazy(opts, :task_id, fn -> derive_task_id(path) end)
 
-    with :ok <- ensure_file(path, task_id) do
+    with :ok <- ensure_file(path, task_id),
+         :ok <- ensure_regular_file(path) do
       entry = "\n## #{ts} | #{author}\n#{String.trim_trailing(body)}\n"
       File.write(path, entry, [:append, :sync])
     end
   end
 
   # ---------------------------------------------------------------------------
   # Internals
   # ---------------------------------------------------------------------------
 
   defp parse(content) do
     @message_re
     |> Regex.scan(content, capture: :all_names)
     |> Enum.map(fn [author, body, ts] ->
       %{
         author: String.trim(author),
         timestamp: String.trim(ts),
         body: String.trim_trailing(body)
       }
     end)
   end
 
   # Bootstrap the file with a minimal frontmatter block on first write.
   # If the file already exists we leave it alone — the caller only
   # appends a new entry.
   defp ensure_file(path, task_id) do
-    if File.exists?(path) do
-      :ok
-    else
-      ts = DateTime.utc_now() |> DateTime.to_iso8601()
-
-      header = """
-      ---
-      kind: task-comments/v1
-      task_id: #{task_id}
-      created_at: #{ts}
-      ---
-      """
-
-      with :ok <- File.mkdir_p(Path.dirname(path)) do
-        File.write(path, header)
+    with :ok <- ensure_regular_file(path) do
+      if File.exists?(path) do
+        :ok
+      else
+        ts = DateTime.utc_now() |> DateTime.to_iso8601()
+
+        header = """
+        ---
+        kind: task-comments/v1
+        task_id: #{task_id}
+        created_at: #{ts}
+        ---
+        """
+
+        with :ok <- File.mkdir_p(Path.dirname(path)) do
+          File.write(path, header)
+        end
       end
     end
   end
 
+  # Defense against symlink-swap (T-04-01): existing file must be regular.
+  # Missing path is allowed (first write creates the file).
+  defp ensure_regular_file(path) do
+    case File.lstat(path) do
+      {:ok, %File.Stat{type: :regular}} -> :ok
+      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
+      {:error, :enoent} -> :ok
+      {:error, reason} -> {:error, reason}
+    end
+  end
+
   defp derive_task_id(path) do
     path
     |> Path.basename()
     |> String.replace_suffix(".comments.md", "")
   end
 end


diff --git a/test/glorbo/task_comments_test.exs b/test/glorbo/task_comments_test.exs
index a389a3bd87370a45c17df0abedb2e69c6ef3b2d4..a2194b33b2450c546c5d708a5f2ab6f3579849c3 100644
--- a/test/glorbo/task_comments_test.exs
+++ b/test/glorbo/task_comments_test.exs
@@ -68,27 +68,39 @@ defmodule Glorbo.TaskCommentsTest do
       assert content =~ "kind: task-comments/v1"
       assert content =~ "task_id: blog-2"
       assert content =~ "## 2026-04-22T10:00:00Z | director"
       assert content =~ "hello"
     end
 
     test "second append preserves the first", %{tmp: tmp} do
       path = Path.join(tmp, "blog-2.comments.md")
 
       :ok = TaskComments.append(path, "director", "first", ts: "2026-04-22T10:00:00Z")
       :ok = TaskComments.append(path, "ceo", "second", ts: "2026-04-22T10:01:00Z")
 
       assert {:ok, [a, b]} = TaskComments.read(path)
       assert a.body == "first"
       assert a.author == "director"
       assert b.body == "second"
       assert b.author == "ceo"
     end
 
     test "creates the parent directory when it doesn't exist", %{tmp: tmp} do
       path = Path.join([tmp, "deep", "nested", "blog-2.comments.md"])
 
       assert :ok = TaskComments.append(path, "director", "hi", ts: "2026-04-22T10:00:00Z")
       assert File.exists?(path)
     end
+
+    test "rejects a symlink comments path", %{tmp: tmp} do
+      target = Path.join(tmp, "outside.md")
+      path = Path.join(tmp, "blog-2.comments.md")
+      File.write!(target, "do not touch")
+      File.ln_s!(target, path)
+
+      assert {:error, :not_a_regular_file} =
+               TaskComments.append(path, "director", "hi", ts: "2026-04-22T10:00:00Z")
+
+      assert File.read!(target) == "do not touch"
+    end
   end
 end

# Attack-path analysis
Final: high | Decider: model_decided | Matrix severity: medium | Policy adjusted: medium
## Rationale
Static evidence shows the comments file is written without symlink/regular-file checks (TaskComments.append + ensure_file) and both director and agent comment paths use it. This enables arbitrary host file append from an in-scope untrusted agent, which is a meaningful sandbox-boundary break, but the attack is local/internal and append-only, so it is kept at high rather than critical.
## Likelihood
medium - Exploit requires an agent or internal actor who can write into the tasks directory and trigger comment writes; this is plausible for agents with tasks:update/projects:write, but not universally available and no runtime PoC was executed.
## Impact
high - A sandboxed agent can cause the host process to append to arbitrary host files via symlinked .comments.md, breaking the intended sandbox boundary and allowing integrity/availability damage to host config or audit files.
## Assumptions
- Agents with tasks:update or projects:write can create files/symlinks within the company tasks directory that is bind-mounted into their sandbox.
- An attacker can trigger a task comment append via agent reply handling or director comments.
- The host process has filesystem permissions to write targeted host files (e.g., ~/.glorbo/config.md).
- No additional runtime hardening (e.g., nofollow open flags) is applied outside the shown code paths.
- Ability to create or replace <task-id>.comments.md in a company tasks directory
- Ability to trigger a comment append (agent reply or director comment)
## Path
n1 -> n2 -> n3 -> n4
## Path evidence
- `lib/glorbo/task_comments.ex:80-89` - append writes to the provided path with File.write after ensure_file, which will follow symlinks.
- `lib/glorbo/task_comments.ex:111-127` - ensure_file only checks File.exists? and then File.write, with no lstat/no-follow validation.
- `lib/glorbo_web/actions.ex:142-156` - director comments compute comments_path and call TaskComments.append; only the task file is checked with ensure_regular_file.
- `lib/glorbo/agent/server.ex:588-601` - agent task comment replies also call TaskComments.append on the sibling comments file without validation.
- `config/runtime.exs:58-85` - default endpoint binds to 127.0.0.1:4000 (loopback), reducing remote exposure but not local/sandboxed agent risk.
## Narrative
Task comment writes now go to a sibling .comments.md file without a regular-file/symlink check. TaskComments.append calls ensure_file (File.exists? + File.write) and then File.write(:append), which follows symlinks; both the director path (post_task_comment) and agent reply path call append on comments_path without validation, enabling an agent who can write in the tasks directory to redirect comment writes to arbitrary host files.
## Controls
- Slug/path validation for task paths
- ensure_regular_file applied to the task file (not the comments file)
- bwrap sandbox and permission mapper for agent processes
- default loopback binding for the web endpoint
## Blindspots
- No runtime PoC executed due to missing Elixir runtime in the container.
- Permission mapping for tasks directory writes was not validated in this analysis.
- OS-specific no-follow behavior or mount options were not verified.
---
MCP create_agent allows YAML injection in AGENT.md
Link: https://chatgpt.com/codex/cloud/security/findings/ee02758e44308191937d702875e07e71?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: high
Status: resolved (commit 7948a55, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 0bc6453
Author: security@example.invalid
Created: 22.04.2026, 21:01:10
Assignee: Unassigned
Signals: Security, Validated

# Summary
Introduced: The newly exposed MCP create_agent path forwards untrusted strings into YAML frontmatter without sanitization, enabling frontmatter injection and privilege escalation for the scaffolded agent.
The new MCP tool `glorbo.create_agent` accepts free-form `role`, `provider`, `model`, `reports_to`, and `template` strings from RPC clients and passes them directly into the agent scaffold. The scaffold writes these values into YAML frontmatter with no escaping (provider/model unquoted; role quoted but not escaped). A crafted value containing newlines or `---` can inject additional frontmatter keys (e.g., `permissions:` or `network: open`), allowing an MCP caller to create a high-privilege or unsandboxed agent despite the tool’s intended minimal defaults. This expands the attack surface for any MCP client (or any LAN client if the endpoint is exposed) and undermines per-agent isolation controls.

# Validation
## Rubric
- [x] Identify untrusted MCP args forwarded to scaffold without validation (create_agent.ex:59-68).
- [x] Confirm scaffold writes these values into YAML frontmatter without escaping (agent.ex:116-128).
- [x] Verify parser/ACL accepts injected network/permissions keys (parser.ex:53,110-116; acl_mapper.ex:17-37).
- [ ] Execute PoC to observe injected frontmatter on disk (blocked: mix/elixir missing).
## Report
Attempted dynamic PoC: `mix run -e "IO.puts(:ok)"` failed because Elixir/Mix is not installed in the container (command not found), and both `valgrind --version` and `gdb --version` are unavailable, so crash/valgrind/debugger validation couldn't be performed. Code review shows MCP create_agent forwards untrusted args directly into scaffold opts with no sanitization (lib/glorbo_web/mcp/tools/create_agent.ex:59-68). The default scaffold writes AGENT.md frontmatter with role interpolated in quotes without escaping and provider/model unquoted (lib/glorbo/cli/scaffold/agent.ex:116-128), so newline/quote injection can add extra YAML keys like `network` or `permissions`. The agent parser accepts `network: open` and consumes `permissions` from frontmatter (lib/glorbo/agent/parser.ex:53,110-116), and ACLMapper whitelists resources like `projects` (lib/glorbo/security/acl_mapper.ex:17-37), meaning injected permissions such as `projects:write:*` would be honored. A runnable PoC script has been placed under /workspace/validation_artifacts to demonstrate the injection once Elixir is available.

# Evidence
/workspace/glorbo/lib/glorbo_web/mcp/tools/create_agent.ex (L59 to 68)
  Note: Untrusted MCP arguments (role/provider/model/reports_to/template) are forwarded into scaffold options with no validation or escaping.
```
  defp do_call(company, slug, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    opts =
      [base: base]
      |> maybe_put(:role, args["role"])
      |> maybe_put(:provider, args["provider"])
      |> maybe_put(:model, args["model"])
      |> maybe_put(:reports_to, args["reports_to"])
      |> maybe_put(:template, args["template"])
```

/workspace/glorbo/lib/glorbo/cli/scaffold/agent.ex (L116 to 128)
  Note: Scaffold writes role/provider/model directly into YAML frontmatter without escaping, enabling newline/`---` injection to add or override security-critical fields like permissions/network.
```
    role = opts[:role] || "Agent"
    provider = opts[:provider] || "claude-code"
    model = opts[:model] || "claude-sonnet-4-5"

    File.write!(Path.join(ag_path, "AGENT.md"), """
    ---
    kind: agent/v1
    slug: #{agent}
    name: #{String.upcase(agent)}
    role: "#{role}"
    provider: #{provider}
    model: #{model}
    network: api-only
```

---
Predictable heartbeat task_id enables symlink-based host writes
Link: https://chatgpt.com/codex/cloud/security/findings/eeababf45a70819196ad6d8820fa836b?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: high
Status: resolved (commit 0720d62, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: b18dfab
Author: security@example.invalid
Created: 22.04.2026, 21:03:46
Assignee: Unassigned
Signals: Security

# Summary
Introduced: the heartbeat_task now uses a predictable task_id, which combined with existing run-dir construction and unchecked writes enables a symlink-based arbitrary file write outside the sandbox.
The new heartbeat path synthesizes a task with the constant ID "heartbeat" when the inbox is empty. Dispatch builds the run directory from task_id and writes the prompt file with mkdir_p/write without checking for symlinks. Because the agent controls its workspace, it can create `.glorbo-run/heartbeat` as a symlink to any host path writable by the Glorbo user. When the heartbeat fires, the host process follows that symlink and overwrites the target with attacker-influenced prompt content (which can be shaped via agent memory/outbox), breaking the sandbox boundary and allowing arbitrary host file modification.

# Evidence
/workspace/glorbo/lib/glorbo/agent/dispatch.ex (L362 to 365)
  Note: write_prompt mkdir_p/writes into the run directory without symlink protection, so a precreated symlink is followed.
```
  defp write_prompt(run_dir, prompt, opts) do
    fs = fs_fun(opts)
    fs.mkdir_p!.(run_dir)
    fs.write!.(prompt_path(run_dir), prompt)
```

/workspace/glorbo/lib/glorbo/agent/dispatch.ex (L630 to 642)
  Note: Run directory path is derived directly from task.task_id under the agent's workspace, making the heartbeat path predictable.
```
  defp prepare_run_dir_path(spec, task, opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())

    Path.join([
      base,
      "companies",
      spec.company,
      "agents",
      spec.slug,
      "workspace",
      ".glorbo-run",
      task.task_id
    ])
```

/workspace/glorbo/lib/glorbo/agent/server.ex (L825 to 849)
  Note: Heartbeat dispatch synthesizes a task with the fixed task_id "heartbeat" when the inbox is empty.
```
  defp resolve_task(state, trigger, nil) do
    case call_inbox_scan(state, trigger) do
      nil when trigger == :heartbeat ->
        heartbeat_task(state)

      task ->
        task
    end
  end

  # GEP-14: when inbox is empty on a heartbeat wake, synthesise a minimal
  # task so the agent still dispatches.  HEARTBEAT.md lives in the system
  # prompt (read_system_prompt), not the task body.
  defp heartbeat_task(state) do
    %{spec: spec, base: base} = state
    company_root = Path.join([base, "companies", spec.company])
    hb_path = Path.join([company_root, "agents", spec.slug, "HEARTBEAT.md"])

    if File.exists?(hb_path) do
      %{
        task_id: "heartbeat",
        task_path: nil,
        prompt: compose_prompt(spec, base, nil, :heartbeat),
        trigger: :heartbeat
      }
```

---
Path requests permit cross-company write mounts
Link: https://chatgpt.com/codex/cloud/security/findings/c4044dca19b4819198e51111c6113c14?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: high
Status: resolved (commit 0720d62, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: dd0932e
Author: security@example.invalid
Created: 22.04.2026, 21:01:15
Assignee: Unassigned
Signals: Security, Validated

# Summary
PathRequestGate’s grant validation permits :write for any absolute path and does not enforce cross-company read-only. The stored mode is passed unchanged into bwrap, which uses --bind for :write, enabling read-write mounts of other companies’ files.
The new PathRequestGate validates only that requested paths are absolute and not under /proc,/sys,/dev. It does not check whether a granted path lives under ~/.glorbo/companies/<other> or downgrade write access for cross-company paths. The grant stores the requested mode unchanged, and bwrap turns :write into a --bind mount. As a result, a malicious agent can request a path in another company's tree and, if the director approves (even assuming cross-company requests are forced read-only per the design), obtain write access to other companies' data. This violates the core isolation boundary.

# Validation
## Rubric
- [x] Check GEP-27 spec mandates cross-company paths are read-only (docs/geps/0027-agent-sandbox-path-requests.md:151-161).
- [x] Verify PathRequestGate validation allows :write and only validates absolute/forbidden paths (lib/glorbo/path_request_gate.ex:254-280).
- [x] Verify PathRequestGate stores granted mode unchanged in PathGrantStore (lib/glorbo/path_request_gate.ex:359-371).
- [x] Verify bwrap uses :write to emit --bind (read-write) for approved paths (lib/glorbo/sandbox/bwrap.ex:317-331).
- [x] Confirm no cross-company downgrade logic elsewhere in reviewed modules (search and file review).
## Report
Attempted dynamic validation first: `mix --version` failed because Elixir/Erlang are not installed and the container cannot fetch them (output included “bash: command not found: mix” plus a failed download via mise). `valgrind --version` and `gdb --version` were also unavailable (“command not found”). As a result, used code review. GEP-27 explicitly requires cross-company paths to be mounted read-only regardless of requested mode (docs/geps/0027-agent-sandbox-path-requests.md:151-161). PathRequestGate’s grant validation only checks for absolute paths, traversal, and forbidden prefixes and allows modes in [:read, :write] with no cross-company downgrade (lib/glorbo/path_request_gate.ex:254-280). The grant writer stores the director-supplied mode unchanged in PathGrantStore (lib/glorbo/path_request_gate.ex:359-371). Bwrap maps mode :write to `--bind` (read-write), not `--ro-bind` (lib/glorbo/sandbox/bwrap.ex:317-331). Therefore, approving a path under another company’s tree with `:write` yields a read-write bind mount, violating the documented cross-company read-only constraint. A PoC script describing the flow is included in the artifacts for execution once Elixir is available.

# Evidence
/workspace/glorbo/lib/glorbo/path_request_gate.ex (L254 to 280)
  Note: Grant validation only checks absolute paths and allows :write; no cross-company read-only enforcement is applied here.
```
  defp valid_host_path?(path) when is_binary(path) do
    Regex.match?(@absolute_path_re, path) and
      not String.contains?(path, "..") and
      not any_forbidden_path?([%{"path" => path}])
  end

  defp valid_host_path?(_), do: false

  defp any_forbidden_path?(paths) do
    Enum.any?(paths, fn %{"path" => p} ->
      Enum.any?(@forbidden_paths, fn fp -> String.starts_with?(p, fp) end)
    end)
  end

  defp validate_granted_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &valid_granted_path?/1) do
      :ok
    else
      {:error, :invalid_granted_path}
    end
  end

  defp validate_granted_paths(_), do: {:error, :empty_granted_paths}

  defp valid_granted_path?(%{path: p, mode: m}) when is_binary(p) and m in [:read, :write] do
    valid_host_path?(p)
  end
```

/workspace/glorbo/lib/glorbo/path_request_gate.ex (L359 to 368)
  Note: Granted paths preserve the director-supplied mode without any downgrade for cross-company paths.
```
  defp write_grant(agent_slug, task_id, granted_paths, state) do
    now = DateTime.utc_now()

    paths_for_store =
      Enum.map(granted_paths, fn %{path: host_path, mode: mode} ->
        %{
          host_path: host_path,
          sandbox_path: sandbox_path_for(host_path),
          mode: mode
        }
```

/workspace/glorbo/lib/glorbo/sandbox/bwrap.ex (L317 to 331)
  Note: bwrap converts mode :write into a --bind mount, enabling write access for any granted path.
```
  @doc """
  Generate bwrap mount flags for approved external paths (GEP-27).

  Each approved path is mounted under `/external/<basename>`:
    - read mode → `--ro-bind`
    - write mode → `--bind`

  Returns a flat list of strings for splicing into `build_argv/1`.
  """
  @spec approved_path_flags([map()]) :: [String.t()]
  def approved_path_flags(paths) when is_list(paths) do
    Enum.flat_map(paths, fn %{host_path: host, sandbox_path: sandbox, mode: mode} ->
      flag = if mode == :write, do: "--bind", else: "--ro-bind"
      [flag, host, sandbox]
    end)
```
---
Unbounded MCP sessions/subscriptions allow resource exhaustion DoS
Link: https://chatgpt.com/codex/cloud/security/findings/87f1330330708191a2b06b9815880efe?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: medium
Status: resolved (commit e477fa7, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 910f2ed
Author: security@example.invalid
Created: 22.04.2026, 20:58:55
Assignee: Unassigned
Signals: Security, Validated

# Summary
Bug introduced: unlimited session creation and topic subscriptions with no existence checks or limits allows a client to consume unbounded resources and DoS the service.
The commit introduces per-session GenServers and resource subscriptions for MCP. `initialize` now calls `Session.start_session/1` to spawn a new process for every request, but there is no cap, TTL, or cleanup unless the client sends DELETE. Additionally, `resources/subscribe` forwards arbitrary slug‑shaped URIs to `Session.subscribe/2`, which maps them directly to PubSub topics using only slug validation and immediately subscribes. Because there is no check that the company/channel exists (or any per-session limit), a malicious client that can reach `/mcp` can create an unbounded number of sessions and topics, exhausting memory and causing a denial of service. This is new behavior introduced by the session/subscription feature.

# Validation
## Rubric
- [x] Verify `initialize` always creates a new session without rate/TTL controls
- [x] Confirm SessionSupervisor has no `max_children` cap and cleanup is only explicit
- [x] Confirm `resources/subscribe` accepts slug-only URIs and subscribes to PubSub with no existence check
- [x] Check per-session subscription storage lacks size limits
- [ ] Execute runtime reproduction (blocked: Elixir/OTP tools not installed)
## Report
Dynamic reproduction attempts were blocked: `elixir -v` and `mix test` both failed with `command not found` because the container lacks the Elixir/OTP toolchain (mise attempted network fetches and failed). Without a runnable BEAM, crash/valgrind/debugger methods were not feasible. Code review shows unbounded session creation and subscriptions: `ensure_session/2` always calls `Session.start_session/1` for `initialize` with no limit or TTL (lib/glorbo_web/mcp/plug.ex:199-212). `Session.start_session/1` unconditionally starts a new child under a DynamicSupervisor (lib/glorbo_web/mcp/session.ex:63-82), and the supervisor is configured without `max_children` (default :infinity) in the application tree (lib/glorbo/application.ex:100-107). `resources/subscribe` simply calls `Session.subscribe/2` (lib/glorbo_web/mcp/server.ex:240-256), which maps URIs to PubSub topics via `uri_to_topic/1` and `company_topic/chat_topic` using only slug validation (lib/glorbo_web/mcp/session.ex:424-462) backed by `Resources.valid_segment?/1` (lib/glorbo_web/mcp/resources.ex:43-49) with no existence checks. `add_subscription/3` immediately subscribes to PubSub and stores each URI in a MapSet without any per-session cap (lib/glorbo_web/mcp/session.ex:323-344). Together these confirm the DoS vector: repeated `initialize` calls create unlimited session processes and `resources/subscribe` can accumulate unlimited topic subscriptions unless clients explicitly DELETE the session.

# Evidence
/workspace/glorbo/lib/glorbo_web/mcp/plug.ex (L118 to 211)
  Note: Every `initialize` request creates a new Session via `Session.start_session/1` with no cap or TTL, enabling unbounded session creation.
```
  defp handle_post(conn) do
    with {:ok, envelope, conn} <- read_envelope(conn),
         {:ok, method, params, id} <- extract_request(envelope),
         :ok <- validate_protocol_version(conn, method),
         {:ok, session_id, conn} <- ensure_session(conn, method) do
      context = build_context(conn, session_id)

      if is_nil(id) do
        # Notification per JSON-RPC 2.0: request with no `id` field
        # (or an explicit `null` id). Server MUST NOT return a
        # response body. Dispatch for side effects, then 202.
        _ = Server.dispatch(method, params, context)
        send_resp(conn, 202, "")
      else
        dispatch_request(conn, method, params, id, context, session_id)
      end
    else
      {:error, :invalid_json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(rpc_error(nil, -32_700, "Parse error", nil)))

      {:error, :invalid_request, id} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(rpc_error(id, -32_600, "Invalid Request", nil)))

      {:error, {:unsupported_protocol_version, version}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(
            rpc_error(
              nil,
              -32_600,
              "Invalid Request",
              %{
                reason: "unsupported MCP-Protocol-Version",
                sent: version,
                supported: Server.supported_protocol_versions()
              }
            )
          )
        )

      {:error, :batch_unsupported} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(
            rpc_error(
              nil,
              -32_600,
              "Invalid Request",
              %{reason: "batch requests are not supported; send one envelope per POST"}
            )
          )
        )

      {:error, :read_body_failed} ->
        send_resp(conn, 400, "failed to read request body")

      {:error, {:unknown_session, session_id}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          404,
          Jason.encode!(
            rpc_error(
              nil,
              -32_002,
              "Unknown session",
              %{"session_id" => session_id}
            )
          )
        )
    end
  end

  # `initialize` spins up a new session. Every other method must
  # arrive with an `Mcp-Session-Id` header that maps to a live
  # Session GenServer. Returning `{:error, {:unknown_session, id}}`
  # bubbles up to `handle_post/1` as a 404 JSON-RPC error.
  defp ensure_session(conn, "initialize") do
    context_opts = %{
      client: client_name(conn),
      base: Glorbo.Filesystem.Hierarchy.default_root()
    }

    case Session.start_session(context_opts) do
      {:ok, session_id} -> {:ok, session_id, conn}
      {:error, reason} -> {:error, {:session_start_failed, reason}}
```

/workspace/glorbo/lib/glorbo_web/mcp/session.ex (L323 to 449)
  Note: `add_subscription/3` immediately subscribes to PubSub topics, and `uri_to_topic/1` only checks slug shape—no existence check or limit—allowing unbounded topic subscriptions.
```
  defp add_subscription(state, uri, topic) do
    # Re-subscribing a URI is a no-op — incrementing the topic refcount
    # on a duplicate would leak the PubSub subscription because the
    # matching unsubscribe cannot observe the duplicate to decrement it
    # twice.
    if MapSet.member?(state.subscribed_uris, uri) do
      state
    else
      subscribed = MapSet.put(state.subscribed_uris, uri)

      # Track how many URIs point at a given topic so we don't
      # unsubscribe the shared topic until the last URI referencing it
      # goes away.
      {topics, newly_subscribed?} =
        case Map.fetch(state.topics, topic) do
          {:ok, n} -> {Map.put(state.topics, topic, n + 1), false}
          :error -> {Map.put(state.topics, topic, 1), true}
        end

      if newly_subscribed?, do: :ok = Phoenix.PubSub.subscribe(@pubsub, topic)

      %{state | subscribed_uris: subscribed, topics: topics}
    end
  end

  defp drop_subscription(state, uri) do
    if MapSet.member?(state.subscribed_uris, uri) do
      case uri_to_topic(uri) do
        {:ok, topic} ->
          subscribed = MapSet.delete(state.subscribed_uris, uri)

          {topics, last?} =
            case Map.fetch(state.topics, topic) do
              {:ok, 1} -> {Map.delete(state.topics, topic), true}
              {:ok, n} -> {Map.put(state.topics, topic, n - 1), false}
              :error -> {state.topics, false}
            end

          if last?, do: Phoenix.PubSub.unsubscribe(@pubsub, topic)
          %{state | subscribed_uris: subscribed, topics: topics}

        _ ->
          %{state | subscribed_uris: MapSet.delete(state.subscribed_uris, uri)}
      end
    else
      state
    end
  end

  defp demonitor_sse(%{sse_monitor_ref: nil} = state), do: state

  defp demonitor_sse(%{sse_monitor_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | sse_monitor_ref: nil}
  end

  defp notify_matching(%{sse_pid: nil}, _filter), do: :ok

  defp notify_matching(%{sse_pid: pid, subscribed_uris: uris}, filter) do
    Enum.each(uris, fn uri ->
      if filter.(uri) do
        send(pid, {:mcp_notification, "notifications/resources/updated", %{"uri" => uri}})
      end
    end)
  end

  # `rel` is the filesystem path from the watcher — e.g.
  # `"channels/general.md"` or `"proposals/hire-writer.md"`. Map the
  # path prefix back to a URI family and, where possible (channels),
  # narrow further by the actual filename so an unrelated channel's
  # event doesn't notify subscribers of a different channel.
  defp notify_for_file_event(state, rel) do
    cond do
      String.starts_with?(rel, "channels/") ->
        case Path.split(rel) do
          ["channels", filename] ->
            ch = Path.basename(filename, ".md")

            notify_matching(state, fn uri ->
              String.starts_with?(uri, "glorbo://chat/") and String.ends_with?(uri, "/" <> ch)
            end)

          _ ->
            :ok
        end

      String.starts_with?(rel, "proposals/") ->
        notify_matching(state, &String.starts_with?(&1, "glorbo://proposals/"))

      String.starts_with?(rel, "projects/") ->
        notify_matching(state, &String.starts_with?(&1, "glorbo://approvals/"))

      true ->
        :ok
    end
  end

  defp new_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # URI → PubSub topic. Keep in sync with Resources.parse_uri.
  defp uri_to_topic(uri) do
    cond do
      String.starts_with?(uri, "glorbo://audit/") ->
        company_topic(uri, "glorbo://audit/", "audit")

      String.starts_with?(uri, "glorbo://approvals/") ->
        company_topic(uri, "glorbo://approvals/", "projects")

      String.starts_with?(uri, "glorbo://proposals/") ->
        company_topic(uri, "glorbo://proposals/", "proposals")

      String.starts_with?(uri, "glorbo://chat/") ->
        chat_topic(uri)

      true ->
        {:error, :unsupported_uri_scheme}
    end
  end

  defp company_topic(uri, prefix, topic_suffix) do
    rest = String.replace_prefix(uri, prefix, "")

    with {:ok, co} <- one_segment(rest),
         true <- Resources.valid_segment?(co) do
      {:ok, "company:#{co}:#{topic_suffix}"}
```

/workspace/glorbo/lib/glorbo_web/mcp/session.ex (L63 to 82)
  Note: `start_session/1` always spawns a new GenServer under the DynamicSupervisor; there is no limiting or cleanup unless explicitly terminated.
```
  @doc """
  Start a new session. Generates a fresh session id and registers
  the GenServer under it in `GlorboWeb.MCP.SessionRegistry`.

  `opts` mirrors the plug's per-request context:

    * `:client` — `mcp:<slug>` actor string (informational)
    * `:base`   — `~/.glorbo` root, used by the Session if it ever
      needs to read filesystem state directly.
  """
  @spec start_session(map()) :: {:ok, String.t()} | {:error, term()}
  def start_session(opts \\ %{}) do
    session_id = new_session_id()

    child_spec = {__MODULE__, Map.put(opts, :session_id, session_id)}

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
```

---

MCP post_message mentions spoof director in agent inboxes
Link: https://chatgpt.com/codex/cloud/security/findings/36b7f4b1fd5481919c2f6d5fd5b63755?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: medium
Status: resolved (commit b012469, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: a33ad90
Author: security@example.invalid
Created: 22.04.2026, 21:04:36
Assignee: Unassigned
Signals: Security

# Summary
Introduced: MCP chat posts can now masquerade as director mentions because the new actor option is not propagated to mention fanout, leaving `from: "director"` hardcoded in mention files.
The commit adds MCP write tooling that calls Actions.post_message/4 with a caller-controlled actor (mcp:<client>). Actions.post_message now records that actor in the channel log and audit entry, but its mention fanout still routes through route_director_mentions/write_director_mention, which writes inbox/mentions files with frontmatter `from: "director"` regardless of the actual actor. Agents consume these mention files directly in their prompt and reply routing, so an MCP client can @mention an agent and have the inbox file claim the instruction came from the director. This breaks provenance and enables spoofed director instructions if /mcp is reachable, undermining trust boundaries around agent triggers and auditability.

# Evidence
/workspace/glorbo/lib/glorbo_web/actions.ex (L225 to 252)
  Note: Mention fanout writes inbox frontmatter with `from: "director"` hardcoded, regardless of the actual actor, enabling director spoofing for MCP-originated posts.
```
  defp route_director_mentions(base, company, channel, body, ts, audit) do
    @mention_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn mentioned ->
      write_director_mention(base, company, channel, mentioned, body, ts, audit)
    end)
  end

  defp write_director_mention(base, company, channel, mentioned, body, ts, audit) do
    agent_dir = Path.join([base, "companies", company, "agents", mentioned])

    if File.dir?(agent_dir) do
      inbox_mentions = Path.join(agent_dir, "inbox/mentions")
      File.mkdir_p!(inbox_mentions)

      now = DateTime.utc_now()
      fname_ts = DateTime.to_unix(now, :millisecond)
      path = Path.join(inbox_mentions, "#{fname_ts}-#{channel}.md")

      frontmatter = """
      ---
      channel: "#{channel}"
      from: "director"
      source_msg: "#{ts}"
      delivered_at: "#{DateTime.to_iso8601(now)}"
      ---
```

/workspace/glorbo/lib/glorbo_web/actions.ex (L65 to 107)
  Note: Actions.post_message uses the actor for the chat entry/audit, but still routes mentions via route_director_mentions without passing actor context.
```
  @spec post_message(String.t(), String.t(), String.t(), keyword()) :: ok_or_err
  def post_message(company, channel, body, opts \\ []) when is_binary(body) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    audit = Keyword.get_lazy(opts, :audit, fn -> resolve_audit(company) end)
    actor = Keyword.get(opts, :actor, "director")

    with :ok <- validate_slug(company),
         :ok <- validate_slug(channel),
         :ok <- validate_body(body),
         path = channel_path(base, company, channel),
         :ok <- ensure_regular_file(path) do
      ts = DateTime.utc_now() |> DateTime.to_iso8601()
      entry = "\n## #{ts} | #{actor}\n#{body}\n"

      case File.write(path, entry, [:append, :sync]) do
        :ok ->
          AuditLog.append(audit, %{
            company: company,
            actor: actor,
            action: "chat.post",
            target: "channels/#{channel}.md",
            channel: channel
          })

          # #238 — rotate the channel file if it crossed size/line
          # thresholds. Rotation is post-append and best-effort:
          # failure here does NOT fail the post — the message is
          # already durably on disk + audited.
          _ = maybe_rotate_channel(company, path, channel, audit)

          # Director mentions wake the named agent(s). Mirrors the
          # Glorbo.Company.Router mention-write shape so the downstream
          # Agent.Server treats it identically (same inbox/mentions/
          # path + `agent.wake` audit with `trigger: "mention"`).
          _ =
            route_director_mentions(
              base,
              company,
              channel,
              body,
              ts,
              audit
            )
```

/workspace/glorbo/lib/glorbo_web/mcp/tools/post_message.ex (L56 to 65)
  Note: MCP tool derives actor from client and passes it into Actions.post_message, enabling non-director actors.
```
  defp do_call(company, channel, body, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    actor = mcp_actor(context)

    case Actions.post_message(
           company,
           channel,
           body,
           Keyword.merge([base: base, actor: actor], audit_opt(context))
         ) do
```
---

Proposal YAML key injection can forge approval fields
Link: https://chatgpt.com/codex/cloud/security/findings/f2a0069ffecc8191a15999baebc6b8d3?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: medium
Status: resolved (commit b012469, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 0caf4f4
Author: security@example.invalid
Created: 22.04.2026, 21:02:58
Assignee: Unassigned
Signals: Security

# Summary
Introduced: proposal serialization now writes untrusted keys verbatim, allowing YAML key injection that can override Router-stamped approval metadata.
The new proposal outbox handler preserves all agent-supplied frontmatter keys and then re-serializes them to YAML with raw key interpolation. Because keys are not quoted or validated, a malicious agent can craft a YAML key containing newline/colon sequences (e.g., "zzz:\nstatus") that becomes multiple YAML lines in the output. Since unknown keys are appended after the canonical keys, this injected line can introduce a second `status`/`approved_by` entry that overrides the Router-stamped values when the proposal file is later parsed. This lets an agent with only `proposals:propose:*` make their proposal appear `approved` (or spoof `approved_by`) and forges audit events emitted by `ProposalsSink`, undermining approval integrity.

# Evidence
/workspace/glorbo/lib/glorbo/company/router.ex (L1140 to 1149)
  Note: create_proposal keeps the entire untrusted meta map (including unknown keys) and only stamps a few fields, leaving attacker-controlled keys intact for serialization.
```
  defp create_proposal(meta, body, sender, perms) do
    with :ok <- ACLMapper.check_action(perms, {"proposals", "propose", "*"}),
         :ok <- require_create_status(meta),
         :ok <- require_nil_approval_fields(meta) do
      stamped =
        meta
        |> Map.put("proposed_by", sender)
        |> Map.put_new_lazy("proposed_at", &iso_now/0)
        |> Map.put("requires_approval", Map.get(meta, "requires_approval", "director"))
```

/workspace/glorbo/lib/glorbo/company/router.ex (L1260 to 1271)
  Note: serialize_proposal appends unknown keys and interpolates key names directly into YAML without quoting/escaping, enabling newline/colon key injection to create extra YAML entries after Router-stamped fields.
```
  defp serialize_proposal(meta, body) do
    canonical = for k <- @proposal_key_order, Map.has_key?(meta, k), do: {k, Map.get(meta, k)}

    extras =
      meta
      |> Map.drop(@proposal_key_order)
      |> Enum.sort_by(fn {k, _} -> k end)

    yaml_lines =
      Enum.map_join(canonical ++ extras, "\n", fn {k, v} ->
        "#{k}: #{Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(v)}"
      end)
```

---

SmartClassifier allows private IPs when explicitly allowlisted
Link: https://chatgpt.com/codex/cloud/security/findings/ae734e1cd9188191b1b1e77d977002d7?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: medium
Status: resolved (commit e477fa7, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 300a3f8
Author: security@example.invalid
Created: 22.04.2026, 21:00:40
Assignee: Unassigned
Signals: Security, Validated

# Summary
Introduced: SmartClassifier’s allowlist check precedes private-IP rejection, enabling allowlisted private IPs to bypass the baseline private-IP deny rule.
In Glorbo.Network.SmartClassifier.classify/2, the rule order checks denylist → allowlist → private_ip → ad_tld. This means any host that matches the allowlist is immediately allowed, even if it is a literal private IP like 127.0.0.1 or 10.0.0.1. The module’s internal comments state that private IPs must never be accepted because the proxy should not reach the host’s private network. When smart mode is wired into the proxy, this ordering allows operator- or agent-supplied allowlist entries to bypass the intended private-IP isolation, enabling SSRF-like access to host-local services via the proxy.

# Validation
## Rubric
- [x] Identify rule order in SmartClassifier.classify/2 and confirm allowlist precedes private_ip? (lib/glorbo/network/smart_classifier.ex:68-76)
- [x] Confirm private_ip? invariant states private IP destinations should never be accepted (lib/glorbo/network/smart_classifier.ex:235-238)
- [x] Verify egress allowlist parsing accepts arbitrary hosts without filtering private IPs (lib/glorbo/agent/parser.ex:158-200)
- [ ] Reproduce runtime classification showing allowlisted private IP returns {:allow, :allowlist} (blocked: Elixir toolchain missing in container)
- [ ] Validate via crash/valgrind/debugger (not applicable for BEAM + toolchain missing)
## Report
Rubric-driven review and attempted dynamic repro. Attempted runtime classification via `mix run -e 'alias Glorbo.Network.SmartClassifier; cfg=%{allow: ["127.0.0.1"], deny: []}; IO.inspect(SmartClassifier.classify("127.0.0.1", cfg))'` but the container lacks Elixir/Erlang; `mix`/`elixir` are missing and mise cannot download tools due to blocked network (command output shows "missing: elixir@1.18.4-otp-28 ... tunnel error ... command not found: mix"). With dynamic validation unavailable, I validated via code inspection. In `SmartClassifier.classify/2`, the rule order checks denylist, then allowlist, then `private_ip?/1` (lib/glorbo/network/smart_classifier.ex:68-76). Because allowlist short-circuits, a host like "127.0.0.1" or "10.0.0.1" present in `egress.allow` will return `{:allow, :allowlist}` and never reach the private-IP rejection. This contradicts the stated invariant that private IPs are never accepted (private_ip?/1 comment: lib/glorbo/network/smart_classifier.ex:235-238). The egress parser accepts arbitrary host strings for allow/deny lists without filtering private IPs (lib/glorbo/agent/parser.ex:158-200), so private IPs can appear in `allow` and trigger the bypass. This supports the finding: allowlisted private IPs bypass the baseline private-IP deny rule.

# Evidence
/workspace/glorbo/lib/glorbo/network/smart_classifier.ex (L235 to 248)
  Note: Commented invariant that private IP destinations should never be accepted, which is contradicted by the allowlist-first rule ordering.
```
  # Treat any RFC1918 / loopback / link-local literal as private.
  # We never accept a private-IP destination from the sandbox: the
  # proxy runs in a netns without a route to the host's private
  # network.
  defp private_ip?(host) do
    cond do
      host == "localhost" -> true
      host == "127.0.0.1" -> true
      host == "::1" -> true
      String.starts_with?(host, "127.") -> true
      String.starts_with?(host, "10.") -> true
      String.starts_with?(host, "192.168.") -> true
      String.starts_with?(host, "169.254.") -> true
      String.match?(host, ~r/^172\.(1[6-9]|2\d|3[0-1])\./) -> true
```

/workspace/glorbo/lib/glorbo/network/smart_classifier.ex (L68 to 78)
  Note: Allowlist check happens before private_ip?/1, so a private IP host that matches the allowlist is allowed without ever reaching the private-IP rejection logic.
```
    cond do
      match_list?(normalised, Map.get(egress_config, :deny, [])) ->
        {:deny, :denylist}

      match_list?(normalised, Map.get(egress_config, :allow, [])) ->
        {:allow, :allowlist}

      private_ip?(normalised) ->
        {:deny, :private_ip}

      ad_tld?(normalised) ->
```

---

Overview goals parsing crashes on non-string goal slug
Link: https://chatgpt.com/codex/cloud/security/findings/cfe22df01554819181cad32f6e0271b0?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: informational (attack path: ignore)
Status: resolved (commit fbbc63a, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 574bdb9
Author: security@example.invalid
Created: 22.04.2026, 20:56:37
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
Introduced a crash in the new goals summary path: malformed goal slug values in `company.md` can cause `to_string/1` to raise and take down the /companies view.
The commit adds goals aggregation for company cards by parsing `company.md` and iterating over each goal entry. The code calls `to_string/1` on `goal.slug` without verifying it is a scalar string/atom/integer. YAML frontmatter is attacker-controlled per the threat model, and a goal like `slug: ["a","b"]` or `slug: {x: y}` will yield a list/map value. `to_string/1` raises `Protocol.UndefinedError` for those types, which crashes the LiveView render path. This creates a denial-of-service for the Overview page whenever a malformed goal entry exists.

# Validation
## Rubric
- [x] Identify OverviewLive’s goals parsing and confirm unguarded `to_string/1` on `goal.slug` (overview_live.ex:329-335).
- [x] Confirm the /companies load path invokes `company_goals/1` (overview_live.ex:270-299).
- [x] Verify frontmatter is untrusted/raw and schema does not enforce goal slug types (frontmatter.ex:1-69; company_md.ex:21-42).
- [ ] Dynamically reproduce crash with malformed slug (blocked: Elixir runtime/mix unavailable; valgrind/gdb missing).
- [x] Produce a minimal malformed `company.md` PoC for reproduction.
## Report
Attempted dynamic reproduction first per guidance, but the container lacks Elixir tooling and network access to install it: `mix test` fails with `bash: command not found: mix` after `mise` cannot download Elixir; `valgrind` and `gdb` are also missing (`command not found`). Static review shows the new OverviewLive path calls `company_goals/1` when loading company cards: `load_company` → `goals_summary` → `company_goals` (lib/glorbo_web/live/overview_live.ex:270-299). In `company_goals/1`, each goal’s `slug` is converted with `to_string/1` without type validation (lib/glorbo_web/live/overview_live.ex:329-335). YAML frontmatter is explicitly treated as untrusted and returned as raw maps from `Glorbo.Filesystem.Frontmatter.parse/1` (lib/glorbo/filesystem/frontmatter.ex:1-69), and the `company.md` schema does not constrain the `goals` structure (lib/glorbo/file_spec/company_md.ex:21-42). A malformed YAML slug such as a list (`slug: ["a", "b"]`) or map will therefore be passed to `to_string/1`, which raises `Protocol.UndefinedError`/`ArgumentError` for non‑String.Chars types, crashing the LiveView render for /companies. PoC company.md with a list slug is included in the artifacts.

# Evidence
/workspace/glorbo/lib/glorbo_web/live/overview_live.ex (L329 to 335)
  Note: Untrusted `goal.slug` is converted with `to_string/1` without type validation; list/map values in frontmatter will raise and crash the LiveView.
```
  defp company_goals(path) do
    case File.read(Path.join(path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"goals" => g}, _} when is_list(g) ->
            for item <- g, is_map(item), slug = to_string(Map.get(item, "slug", "")), slug != "" do
              %{slug: slug}
```

# Attack-path analysis
Final: ignore | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
Although the crash is real, exploitation requires trusted/local access to company.md; the threat model treats this input as operator-controlled and assumes the local OS user is trusted. Impact is limited to a self-DoS of the /companies view and does not cross security boundaries, so the issue is not a security vulnerability in scope.
## Likelihood
low - Trigger requires ability to write company.md (operator/local access) or privileged dashboard access; not reachable by typical external attackers.
## Impact
low - Malformed goal slug crashes the overview LiveView, causing temporary UI unavailability for /companies without affecting data integrity or confidentiality.
## Assumptions
- Attacker can write or influence companies/<slug>/company.md frontmatter (e.g., via local filesystem access or a privileged dashboard file editor).
- No additional runtime validation of company.md goals is enforced before OverviewLive renders.
- Write a non-string goal slug (list/map) into company.md frontmatter goals
## Path
company.md (malformed goals slug)
  -> Frontmatter.parse
  -> OverviewLive.company_goals to_string/1
  -> LiveView crash (/companies)
## Path evidence
- `lib/glorbo_web/live/overview_live.ex:329-335` - company_goals/1 calls to_string/1 on goal.slug without type validation.
- `lib/glorbo/filesystem/frontmatter.ex:9-16` - Frontmatter parser treats YAML from disk as untrusted input.
- `lib/glorbo/file_spec/company_md.ex:22-42` - company.md schema does not constrain goals structure/types.
- `config/runtime.exs:58-85` - Default endpoint binding is 127.0.0.1:4000 (local-only exposure).
## Narrative
OverviewLive reads company.md frontmatter goals and converts each goal.slug with to_string/1 without type checks. Because frontmatter is treated as untrusted YAML, a list/map slug would raise Protocol.UndefinedError and crash the /companies LiveView render. The dashboard binds to 127.0.0.1 by default, and company.md is operator-controlled, so this is a self-DoS rather than a remote security issue.
## Controls
- Localhost binding by default (config/runtime.exs)
- Optional dashboard token gate (router pipeline)
- Frontmatter size cap to limit parser abuse
## Blindspots
- No dynamic reproduction due to missing Elixir tooling; behavior inferred from static review.
- Unclear whether any unprivileged actor can edit company.md via the dashboard file editor without already having admin access.

---

MCP initialize crashes on list params, enabling local DoS
Link: https://chatgpt.com/codex/cloud/security/findings/62e31cffd62c8191b59b1b603e66ce9d?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: low (attack path: low)
Status: resolved (commit 55bf3d5, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 3dee25e
Author: security@example.invalid
Created: 22.04.2026, 20:55:59
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
Introduced bug: initialize now assumes params is a map, but the parser still allows list params, leading to a BadMapError crash on malformed initialize requests.
`handle_initialize/1` now calls `Map.get(params || %{}, "protocolVersion")` to negotiate versions. However, the request parser in `MCP.Plug.extract_request/1` still treats JSON-RPC `params` arrays as valid, so `params` can be a list. `Map.get/2` on a list raises `BadMapError`, crashing the request process and yielding a 500. A local attacker (or any client if the MCP endpoint is exposed) can trigger repeated crashes by sending `{"method":"initialize","params":[]}`.

# Validation
## Rubric
- [x] Confirm MCP endpoint wiring and request flow to extract_request/dispatch.
- [x] Verify extract_request allows list params and passes them through.
- [x] Verify handle_initialize uses Map.get on params without list guard, implying BadMapError on list.
- [ ] Produce a runtime crash/trace with mix/phx server (blocked by missing Elixir/Erlang/tooling).
## Report
Attempted dynamic reproduction: `mix test` and `elixir -v` failed because Elixir/Erlang are not installed and network install is blocked (mise error, `bash: command not found`). `valgrind --version` and `gdb --version` are also unavailable, so crash/valgrind/debugger validation couldn't run. Static trace shows the bug: the MCP router forwards /mcp to GlorboWeb.MCP.Plug (lib/glorbo_web/router.ex:82-88). In POST handling, the plug reads the envelope and calls `extract_request/1` (lib/glorbo_web/mcp/plug.ex:117-130), which explicitly accepts params that are a map or a list (lib/glorbo_web/mcp/plug.ex:337-342). The resulting params are passed to `Server.dispatch/3` without type guarding (lib/glorbo_web/mcp/server.ex:113-117). For "initialize", `handle_initialize/1` calls `Map.get(params || %{}, "protocolVersion")` (lib/glorbo_web/mcp/server.ex:165-166). If params is a list (allowed by the plug), `Map.get/2` raises BadMapError, and there is no rescue in `dispatch_request/5` (lib/glorbo_web/mcp/plug.ex:211-224), so the request process would crash and yield a 500. A JSON-RPC initialize with params [] would trigger this.

# Evidence
/workspace/glorbo/lib/glorbo_web/mcp/plug.ex (L337 to 342)
  Note: extract_request explicitly allows params to be a list, enabling the crashing path in handle_initialize.
```
  defp extract_request(%{"jsonrpc" => "2.0", "method" => method} = env) when is_binary(method) do
    id = Map.get(env, "id")
    params = Map.get(env, "params", %{})

    if is_map(params) or is_list(params) do
      {:ok, method, params, id}
```

/workspace/glorbo/lib/glorbo_web/mcp/server.ex (L165 to 170)
  Note: handle_initialize/1 uses Map.get on params without verifying it is a map, so list params trigger BadMapError.
```
  defp handle_initialize(params) do
    requested = Map.get(params || %{}, "protocolVersion")

    negotiated =
      if is_binary(requested) and requested in @supported_protocol_versions,
        do: requested,
```

# Attack-path analysis
Final: low | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
The issue is a real crash on malformed input, but the impact is limited to request-level DoS with no confidentiality/integrity impact. Default loopback binding and lack of public exposure keep likelihood low; thus severity remains low.
## Likelihood
low - Trigger is trivial (params: []), but the endpoint is intended for localhost only; exploitation requires local access or operator exposure to LAN.
## Impact
low - Impact is limited to crashing the request process for malformed initialize calls, yielding 500 responses and potential local DoS; no data exposure or privilege escalation.
## Assumptions
- Phoenix request-process crash yields a 500 without taking down the entire BEAM VM (standard Phoenix behavior).
- Default deployment binds to 127.0.0.1 unless operators override PHX_HOST/ip or run behind a proxy exposing the port.
- No additional network ACLs or reverse-proxy auth are enforced outside this repo.
- Ability to send HTTP POST requests to /mcp on the Phoenix endpoint
- Send JSON-RPC initialize with params as a list (e.g., params: [])
## Path
n1 -> n2 -> n3 -> n4
POST /mcp (params: []) -> extract_request accepts list -> handle_initialize Map.get -> BadMapError/500
## Path evidence
- `lib/glorbo_web/mcp/plug.ex:335-342` - extract_request accepts params that are a map or a list and forwards them.
- `lib/glorbo_web/mcp/server.ex:165-171` - handle_initialize calls Map.get on params without verifying it is a map, which raises on list.
- `lib/glorbo_web/router.ex:82-88` - /mcp is forwarded to the MCP plug and is not behind the dashboard token pipeline.
- `config/runtime.exs:82-85` - Default endpoint binding is loopback (127.0.0.1), constraining exposure to localhost unless overridden.
## Narrative
The MCP plug explicitly accepts JSON-RPC params as a map or list and forwards them to Server.dispatch. For initialize, handle_initialize calls Map.get(params || %{}, "protocolVersion") without ensuring params is a map. If a client sends params: [] (allowed by extract_request), Map.get/2 raises BadMapError, crashing the request process and returning 500. The /mcp endpoint is not gated by the dashboard token and is intended to be loopback-only via endpoint binding; thus the bug is reachable by local clients (or LAN if the operator exposes the service), resulting in a repeatable but limited DoS on the MCP handler.
## Controls
- Loopback binding to 127.0.0.1 by default
- Origin allowlist in MCP plug to reduce DNS-rebinding
- No dashboard-token auth on /mcp
## Blindspots
- No runtime validation due to missing Elixir toolchain; crash behavior inferred from code.
- No deployment/IaC manifests to confirm whether operators commonly expose the port beyond localhost.
---

MCP endpoint exposed without dashboard token or auth gate
Link: https://chatgpt.com/codex/cloud/security/findings/7a0d03c3b4bc8191baa91cc2a49ef77e?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: low (attack path: low)
Status: resolved (commit fbbc63a, 2026-04-22) — now gated by DashboardToken; bearer-header path

# Metadata
Repo: foobarto/glorbo
Commit: 5b7f130
Author: security@example.invalid
Created: 22.04.2026, 20:58:34
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
Introduced an unauthenticated MCP endpoint not covered by the dashboard bearer-token gate; Origin checks permit originless requests, enabling network clients to access MCP tools if the HTTP endpoint is exposed beyond loopback.
The commit adds a new MCP JSON-RPC endpoint at /mcp and explicitly forwards it outside the :dashboard pipeline that enforces the optional bearer token. The only guard is an Origin host check, but the plug also allows requests with no Origin header (for CLI clients). This means that once the Phoenix endpoint is reachable beyond localhost—e.g., when an operator binds to 0.0.0.0 to access the dashboard remotely—an unauthenticated network client can call the MCP API and list companies. This bypasses the dashboard token protections for LAN exposure and creates an authentication gap for any current or future MCP tools.

# Validation
## Rubric
- [x] /mcp is forwarded outside the :dashboard pipeline (lib/glorbo_web/router.ex:82-88)
- [x] DashboardToken plug is the only bearer-token gate and isn’t applied to /mcp (lib/glorbo_web/plugs/dashboard_token.ex:31-48)
- [x] Origin validation allows missing Origin headers and tests confirm it (lib/glorbo_web/mcp/plug.ex:79-83; test/glorbo_web/mcp/plug_test.exs:196-201)
- [x] MCP tools expose company metadata (lib/glorbo_web/mcp/tools/list_companies.ex:34-69)
- [x] Endpoint defaults to loopback but is configurable, enabling exposure if bound to 0.0.0.0 (config/runtime.exs:82-85)
## Report
Dynamic attempts: `mix test test/glorbo_web/mcp/plug_test.exs:196` failed because Elixir/mix is not installed and the environment cannot fetch Hex builds (exit_code=127). `valgrind` and `gdb` are not present, so valgrind/debugger-based reproduction was not possible. Code review shows the /mcp endpoint is forwarded outside the :dashboard pipeline (lib/glorbo_web/router.ex:82-88), while the bearer-token gate lives only in the :dashboard plug and enforces a query token when configured (lib/glorbo_web/plugs/dashboard_token.ex:31-48). The MCP plug’s Origin validation explicitly allows requests with no Origin header (lib/glorbo_web/mcp/plug.ex:79-83), and the tests confirm that “missing origin is allowed” (test/glorbo_web/mcp/plug_test.exs:196-201). The tool set includes glorbo.list_companies which enumerates ~/.glorbo/companies and returns metadata (lib/glorbo_web/mcp/tools/list_companies.ex:34-69), so unauthenticated access yields information disclosure. Although runtime config binds to 127.0.0.1 by default (config/runtime.exs:82-85), if an operator binds to 0.0.0.0 for LAN exposure, /mcp becomes network-accessible without the dashboard token or Origin requirement, validating the reported auth gap.

# Evidence
/workspace/glorbo/lib/glorbo_web/mcp/plug.ex (L63 to 95)
  Note: Origin validation is the only access control and explicitly allows missing Origin headers, letting non-browser clients access the endpoint without additional authentication.
```
  def call(%Plug.Conn{method: method} = conn, opts) do
    case validate_origin(conn, opts.allowed_origin_hosts) do
      :ok ->
        dispatch_by_method(method, conn)

      {:error, origin} ->
        conn
        |> send_resp(403, "forbidden: origin #{inspect(origin)} not allowed")
        |> halt()
    end
  end

  # ---------------------------------------------------------------------------
  # Origin validation (DNS-rebind protection — MCP spec §Security)
  # ---------------------------------------------------------------------------

  defp validate_origin(conn, allowed_hosts) do
    case get_req_header(conn, "origin") do
      # No Origin header — typical of native CLI clients. Allowed.
      [] ->
        :ok

      [origin | _] ->
        uri = URI.parse(origin)

        # Exact host match (case-insensitive). `[::1]` in the header
        # parses as host `::1`, so compare stripped of brackets.
        host = if uri.host, do: String.downcase(uri.host), else: nil

        if host && host in allowed_hosts,
          do: :ok,
          else: {:error, origin}
    end
```

/workspace/glorbo/lib/glorbo_web/router.ex (L82 to 88)
  Note: The /mcp endpoint is forwarded outside the :dashboard pipeline, so it is not protected by the bearer token gate used for LAN exposure.
```
  # GEP-29 wave (a) — Model Context Protocol server.
  # Streamable HTTP transport, single endpoint. Not behind :dashboard
  # on purpose — MCP clients don't carry the dashboard bearer token,
  # and the Plug applies its own Origin check for DNS-rebind
  # protection. Localhost-binding of the endpoint is the outer
  # boundary.
  forward "/mcp", GlorboWeb.MCP.Plug
```

# Attack-path analysis
Final: low | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
The issue is real (unauthenticated /mcp with missing-Origin allowed), but default loopback binding limits reachability and the current tool impact is limited to metadata disclosure. This reduces impact and likelihood compared to the original medium rating.
## Likelihood
medium - Requires operator to expose the Phoenix port beyond loopback; if exposed, exploitation is trivial with a single unauthenticated HTTP request.
## Impact
low - Unauthenticated callers can list company metadata if /mcp is exposed beyond localhost; current tool set only discloses basic metadata (slug/name/headcount_budget).
## Assumptions
- Operator binds the Phoenix endpoint to a non-loopback interface or forwards port 4000 for LAN access.
- An attacker can reach the exposed host over the local network and send HTTP requests to /mcp.
- Phoenix endpoint exposed beyond loopback (0.0.0.0/port-forward)
- Network attacker can reach port 4000
## Path
[n1] Attacker -> [n2] /mcp -> [n3] Origin check allows missing -> [n4] list_companies -> [n5] metadata
## Path evidence
- `lib/glorbo_web/router.ex:82-88` - /mcp is forwarded outside :dashboard, so no dashboard token gate applies.
- `lib/glorbo_web/mcp/plug.ex:79-83` - Origin validation allows missing Origin headers.
- `test/glorbo_web/mcp/plug_test.exs:196-201` - Test asserts missing Origin is allowed (status 200).
- `lib/glorbo_web/mcp/tools/list_companies.ex:34-69` - Tool enumerates ~/.glorbo/companies and returns metadata.
- `config/runtime.exs:82-85` - Endpoint defaults to loopback binding, limiting exposure unless reconfigured.
## Narrative
The router forwards /mcp outside the :dashboard pipeline (lib/glorbo_web/router.ex:82-88), so the optional dashboard token does not apply. The MCP plug’s Origin validation explicitly allows missing Origin headers (lib/glorbo_web/mcp/plug.ex:79-83), and tests confirm missing Origin is accepted (test/glorbo_web/mcp/plug_test.exs:196-201). The list_companies tool enumerates ~/.glorbo/companies and returns metadata (lib/glorbo_web/mcp/tools/list_companies.ex:34-69). Default binding is loopback (config/runtime.exs:82-85), but if an operator exposes port 4000 to LAN, any network client can call /mcp without authentication and obtain company metadata.
## Controls
- Loopback-only binding by default
- Origin host allowlist (but allows missing Origin)
- Dashboard token gate for :dashboard routes only
## Blindspots
- No deployment manifests to confirm whether production commonly binds to 0.0.0.0.
- Static analysis only; MCP tool set could include additional mutating tools not reviewed here.

---

ProposalsSink trusts proposal metadata for audit actions/actors
Link: https://chatgpt.com/codex/cloud/security/findings/78e3bf861d7c81919e45f8d8fabf833f?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: low (attack path: low)
Status: resolved (commit 55bf3d5, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: 1de4e4b
Author: security@example.invalid
Created: 22.04.2026, 20:58:39
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
Introduced an audit-log integrity issue: proposal status/actor are taken from untrusted frontmatter without verification, enabling spoofed approval/denial events.
ProposalsSink reads any direct-child `proposals/*.md` file and derives the audit `action` and `actor` from the unvalidated frontmatter fields (`status`, `approved_by`, `proposed_by`). Since proposal files are agent-controlled when an agent has `proposals:write`, a malicious agent can set `status: approved` and `approved_by: director` to generate a forged `proposal.approved` audit entry. This undermines audit log integrity for proposal approvals/denials and could mislead operators or downstream automation relying on audit records.

# Validation
## Rubric
- [x] Verify ProposalsSink processes proposals/*.md write events and reads frontmatter (lib/glorbo/company/proposals_sink.ex:82-125).
- [x] Verify action/actor are derived directly from frontmatter status/proposed_by/approved_by (lib/glorbo/company/proposals_sink.ex:149-171).
- [x] Verify emitted audit entry uses these fields and is sent to AuditLog (lib/glorbo/company/proposals_sink.ex:114-176).
- [x] Confirm tests expect approved_by to become actor for proposal.approved (test/glorbo/company/proposals_sink_test.exs:100-127).
- [x] Confirm frontmatter parser does not validate semantic fields (lib/glorbo/filesystem/frontmatter.ex:33-69).
## Report
Dynamic validation attempts: `mix test` failed because Elixir/Erlang are missing and the environment cannot download them (mise install blocked), so crash/valgrind/debugger reproduction was not possible. Code review shows `ProposalsSink` reacts to `proposals/*.md` write events and reads frontmatter to build audit entries (lib/glorbo/company/proposals_sink.ex:82-125). The `classify/1` and `actor_or/3` functions derive `action` and `actor` directly from unvalidated frontmatter fields `status`, `proposed_by`, and `approved_by` (lib/glorbo/company/proposals_sink.ex:149-171), and the resulting entry is emitted to the audit log via `audit_fun`/`AuditLog.append` (lib/glorbo/company/proposals_sink.ex:114-176). The tests explicitly assert that `approved_by` becomes the audit `actor` when `status: approved` (test/glorbo/company/proposals_sink_test.exs:100-127), confirming that any writer of a proposal file can set these fields arbitrarily. The frontmatter parser returns metadata maps without field validation (lib/glorbo/filesystem/frontmatter.ex:33-69). This supports the finding that a user with `proposals:write` can forge `proposal.approved`/`proposal.denied` audit entries by editing frontmatter fields.

# Evidence
/workspace/glorbo/lib/glorbo/company/proposals_sink.ex (L108 to 158)
  Note: The sink reads proposal files and uses unvalidated frontmatter to set audit action/actor; `status` and `approved_by` are attacker-controlled, enabling spoofed audit entries.
```
  defp handle_proposal_event(rel, state) do
    abs_path = Path.join([state.base, "companies", state.company, rel])

    with {:ok, content} <- state.read_fun.(abs_path),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         {:ok, action, actor} <- classify(meta) do
      entry = %{
        company: state.company,
        actor: actor,
        action: action,
        target: rel,
        detail: %{
          subtype: Map.get(meta, "subtype"),
          id: Map.get(meta, "id")
        }
      }

      emit(state, entry)
    else
      {:error, reason} ->
        Logger.warning(
          "[proposals_sink/#{state.company}] skipped #{rel} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      # Best-effort observer: never crash the GenServer on a single
      # bad file. Log and move on.
      Logger.warning(
        "[proposals_sink/#{state.company}] raised on #{rel}: #{Exception.message(e)}"
      )

      :ok
  end

  # Returns {:ok, action, actor} or {:error, reason}. Unknown status
  # values are a skip, not a crash — the watcher sees every write and
  # many will be in-flight edits (e.g. a Director saving a half-typed
  # status field).
  defp classify(meta) do
    case Map.get(meta, "status") do
      "pending-approval" ->
        {:ok, "proposal.requested", actor_or(meta, "proposed_by", "system")}

      "approved" ->
        {:ok, "proposal.approved", actor_or(meta, "approved_by", "director")}

      "denied" ->
        {:ok, "proposal.denied", actor_or(meta, "approved_by", "director")}
```

# Attack-path analysis
Final: low | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
Severity remains low because the issue requires proposals:write access and only affects audit log integrity for proposals; there is no direct privilege escalation, data exfiltration, or cross-tenant impact shown in code.
## Likelihood
medium - Any agent with proposals:write can trivially set status/approved_by in a proposal file; however this requires that permission and only affects internal audit records.
## Impact
low - Integrity of audit log entries for proposal approvals/denials can be spoofed by any agent with proposals:write, but it does not alter actual permissions or execute code; impact is limited to audit/forensics and downstream automation.
## Assumptions
- An attacker can obtain an agent role with `proposals:write:*` permission in its frontmatter.
- ProposalsSink is enabled in production via the company supervisor.
- Downstream users/automation treat audit log entries as authoritative for proposal approvals/denials.
- agent has proposals:write permission
- agent can write proposals/<id>.md in company directory
## Path
Agent(proposals:write)
  -> proposals/<id>.md (status/approved_by)
  -> ProposalsSink.classify(meta)
  -> AuditLog.append(entry)
## Path evidence
- `lib/glorbo/company/proposals_sink.ex:82-176` - Handles proposal file write events, parses frontmatter, classifies status/actor from metadata, and emits audit entry.
- `lib/glorbo/filesystem/frontmatter.ex:23-59` - Frontmatter parser returns a meta map without semantic validation of fields like status/approved_by.
- `lib/glorbo/security/acl_mapper.ex:131-138` - proposals:write grants rwx ACL on proposals directory for agents.
- `lib/glorbo/sandbox/permission_mapper.ex:133-140` - proposals:write binds company proposals directory read-write into the sandbox.
- `test/glorbo/company/proposals_sink_test.exs:100-127` - Test asserts approved_by becomes audit actor for proposal.approved, confirming actor is taken from frontmatter.
## Narrative
ProposalsSink subscribes to proposals file events and, on write, reads frontmatter and calls classify/1 to derive the audit action and actor directly from status/proposed_by/approved_by, then emits the entry to the audit log. The frontmatter parser only returns the YAML map with no semantic validation. Agents granted proposals:write are given rw access to /proposals at both ACL and sandbox levels. Tests explicitly assert that approved_by becomes the audit actor. Therefore, a malicious agent with proposals:write can forge proposal.approved/denied audit entries by editing frontmatter fields, undermining audit log integrity without changing actual approval enforcement.
## Controls
- ACLMapper permission gating for proposals:write
- Sandbox permission mapper binds /proposals only when permitted
- Append-only audit log write path (no delete/update)
## Blindspots
- No dynamic testing of runtime approval enforcement or audit consumers; downstream systems might ignore these entries or apply additional validation not visible here.
- Cannot confirm real-world permission distributions for proposals:write across deployments.

---

InboxLive path approval crashes on malformed paths payload
Link: https://chatgpt.com/codex/cloud/security/findings/49655f9f969c8191b10275a8f90a5f72?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: low (attack path: low)
Status: resolved (commit 55bf3d5, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: c07157a
Author: security@example.invalid
Created: 22.04.2026, 20:59:55
Assignee: Unassigned
Signals: Security, Validated, Attack-path

# Summary
Introduced a crash/DoS vector in the new `approve_path` handler by not validating the decoded JSON shape or guarding atom conversion.
`approve_path` decodes the `paths` value directly from the LiveView event and immediately pattern-matches each element while converting `mode` with `String.to_existing_atom/1`. If a client tampers with the event payload (e.g., non-list JSON, entries missing keys, or a non-existent mode atom), Elixir raises `FunctionClauseError` or `ArgumentError`, terminating the LiveView process. A user with dashboard access (or an attacker if the dashboard is exposed without a token) can repeatedly crash the inbox view, preventing directors from approving/denying path requests.

# Validation
## Rubric
- [x] Locate approve_path handler and identify JSON decode + Enum.map + String.to_existing_atom sequence.
- [x] Verify lack of validation/rescue for malformed JSON shapes or unknown mode atoms.
- [ ] Reproduce crash by invoking handler or equivalent code in a running Elixir environment (blocked: Elixir/OTP not installed, no network).
- [ ] Attempt valgrind/asan or debugger trace (blocked: tools not installed, no binary/runtime).
- [x] Provide a minimal PoC script and reproduction instructions for future validation.
## Report
Dynamic reproduction attempts failed because the container lacks Elixir/OTP tooling and cannot fetch it (network blocked). `mix run -e 'IO.puts("test")'` failed with `bash: command not found: mix` and mise could not download Elixir; `valgrind --version` and `gdb --version` also failed (tools not installed). Code inspection shows the `approve_path` handler decodes client JSON and immediately maps with a strict pattern and `String.to_existing_atom/1` (lib/glorbo_web/live/inbox_live.ex:229-245). If the decoded JSON is not a list, has elements missing "path"/"mode", or uses a non‑existing atom string for mode, `Enum.map/2` will raise `Protocol.UndefinedError`/`FunctionClauseError` and `String.to_existing_atom/1` will raise `ArgumentError`. There is no rescue/validation around this, so the LiveView process will crash on malformed payloads, matching the reported DoS vector.

# Evidence
/workspace/glorbo/lib/glorbo_web/live/inbox_live.ex (L240 to 245)
  Note: Client-controlled JSON is decoded and immediately pattern-matched and converted with String.to_existing_atom/1 without validation or rescue, so malformed payloads raise and crash the LiveView.
```
    granted_paths =
      case Jason.decode(paths_json) do
        {:ok, paths} ->
          Enum.map(paths, fn %{"path" => p, "mode" => m} ->
            %{path: p, mode: String.to_existing_atom(m)}
          end)
```

# Attack-path analysis
Final: low | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
The bug is real and reachable from the LiveView dashboard, but its effect is limited to a per-session LiveView crash. Default localhost binding and optional token gating further constrain exposure. There is no cross-boundary impact or data compromise, so the low severity assessment is appropriate.
## Likelihood
low - Requires dashboard access and a crafted LiveView event; default loopback binding limits exposure to local users unless reconfigured.
## Impact
low - Malformed approve_path payload can crash the InboxLive process, disrupting the inbox UI for the initiating session without broader data or privilege impact.
## Assumptions
- Phoenix LiveView runs a separate process per connected client session, so a crash in InboxLive primarily affects the initiating session.
- Production deployment uses config/runtime.exs defaults (127.0.0.1 bind, port 4000) unless an operator changes them.
- No authentication is required beyond the optional dashboard_token gate; access is constrained by network exposure.
- Access to the dashboard LiveView route /companies/:company/inbox
- Ability to send a LiveView event with a crafted "paths" JSON payload
## Path
Dashboard user -> approve_path event -> decode/map + to_existing_atom -> LiveView crash (session DoS)
## Path evidence
- `lib/glorbo_web/live/inbox_live.ex:230-245` - Client-controlled JSON is decoded and mapped with strict pattern matching and String.to_existing_atom/1 without validation or rescue.
- `lib/glorbo_web/router.ex:13-25` - Dashboard token gate is optional; routes for InboxLive are in the dashboard pipeline.
- `config/runtime.exs:60-85` - Production endpoint binds to 127.0.0.1 by default (localhost exposure).
## Narrative
InboxLive's "approve_path" handler decodes the client-supplied "paths" JSON and immediately pattern-matches each element while converting the "mode" via String.to_existing_atom/1. If a client sends non-list JSON, entries missing keys, or an unknown mode string, Elixir will raise and terminate the LiveView process. This is reachable by any dashboard user and results in a per-session availability loss of the inbox view. The dashboard is bound to 127.0.0.1 by default and the dashboard token is optional, which limits exposure to local users unless the operator changes configuration.
## Controls
- CSRF protection in :browser pipeline
- Optional dashboard bearer-token gate
- Default loopback-only HTTP binding
## Blindspots
- No dynamic reproduction due to missing Elixir runtime/tooling in the environment.
- No deployment manifests to confirm whether operators override the default 127.0.0.1 bind.
- Impact assessment assumes LiveView process isolation per session.

---

Proxy classifier lacks validation and can crash on bad return
Link: https://chatgpt.com/codex/cloud/security/findings/999d44e512348191883327d8d95e69aa?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: informational (attack path: ignore)
Status: resolved (commit 55bf3d5, 2026-04-22)

# Metadata
Repo: foobarto/glorbo
Commit: d86d3b0
Author: security@example.invalid
Created: 22.04.2026, 21:00:18
Assignee: Unassigned
Signals: Validated, Attack-path

# Summary
Introduced a crash path on malformed classifier output; instead of mapping bad returns to :unknown/403, the handler crashes on a non-matching return tuple.
In classify_unlisted/5, the proxy only pattern-matches the expected classifier verdict tuples. safe_classify/3 only rescues raises and exits, but it does not validate or coerce unexpected return values. A classifier that returns nil or any non-matching tuple (for example due to a lookup miss) will trigger a CaseClauseError and crash the connection handler, dropping the client without a response. This contradicts the intended fail-safe behavior and can cause repeated connection crashes if untrusted hostnames drive buggy classifier output.

# Validation
## Rubric
- [x] Identify classify_unlisted/5 only pattern-matches {:allow|:deny|:unknown,_} with no default (proxy.ex:348-373)
- [x] Confirm safe_classify/3 returns raw classifier output without normalization (proxy.ex:379-380)
- [x] Reproduce malformed classifier return via PoC and send CONNECT request
- [x] Observe CaseClauseError and client timeout/no 403 response (poc_output.txt)
## Report
Examined proxy classifier handling: classify_unlisted/5 only matches {:allow|:deny|:unknown, _} and has no default clause (lib/glorbo/network/proxy.ex:348-373). safe_classify/3 simply returns fun.(host, port) without normalizing unexpected values (lib/glorbo/network/proxy.ex:379-380). Reproduced by running a PoC that starts the proxy with classifier_fun returning nil and sends a CONNECT to an unlisted host. The handler crashes with CaseClauseError at proxy.ex:356 and the client receives no response (timeout). Crash evidence from PoC run: "** (CaseClauseError) no case clause matching: nil\n    glorbo/lib/glorbo/network/proxy.ex:356: Glorbo.Network.Proxy.classify_unlisted/5" and "RESPONSE: {:error, :timeout}" (poc_output.txt).

# Evidence
/workspace/glorbo/lib/glorbo/network/proxy.ex (L348 to 373)
  Note: classify_unlisted/5 only matches {:allow|:deny|:unknown, _}; any other classifier return causes a CaseClauseError and no 403 response.
```
  defp classify_unlisted(host, port, client_sock, policy, task_sup) do
    case policy.classifier_fun do
      nil ->
        Logger.info("[network.proxy] reject host-not-in-allowlist host=#{host}")
        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      fun when is_function(fun, 2) ->
        case safe_classify(fun, host, port) do
          {:allow, reason} ->
            Logger.info("[network.proxy] smart-allow host=#{host} reason=#{reason}")
            open_and_splice(host, port, client_sock, task_sup)

          {:deny, reason} ->
            Logger.info("[network.proxy] smart-deny host=#{host} reason=#{reason}")
            write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
            safe_close(client_sock)

          {:unknown, reason} ->
            Logger.info(
              "[network.proxy] smart-unknown host=#{host} reason=#{reason} (treated as deny pending director sentinel)"
            )

            write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
            safe_close(client_sock)
        end
```

/workspace/glorbo/lib/glorbo/network/proxy.ex (L377 to 393)
  Note: safe_classify/3 only handles raises/exits; it does not normalize unexpected return values to :unknown as intended.
```
  # Treat any classifier crash as `:unknown` — fail-safe so a broken
  # classifier never results in silently allowing unknown hosts.
  defp safe_classify(fun, host, port) do
    fun.(host, port)
  rescue
    e ->
      Logger.warning("[network.proxy] classifier raised: #{inspect(e)} — treating as :unknown")

      {:unknown, :classifier_raised}
  catch
    :exit, reason ->
      Logger.warning(
        "[network.proxy] classifier exited: #{inspect(reason)} — treating as :unknown"
      )

      {:unknown, :classifier_exit}
  end
```

# Attack-path analysis
Final: ignore | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
The bug is real but represents a local, per-connection availability failure that requires an optional, operator-supplied classifier_fun to misbehave. It does not enable access, bypass allowlists, or cross any security boundary, and the proxy is loopback-only. Given the minimal security impact and narrow, unlikely preconditions, severity is reduced to ignore.
## Likelihood
low - Requires classifier_fun to be enabled and to return malformed output; not attacker-controlled in normal deployments and proxy is localhost-only.
## Impact
ignore - Only drops the current CONNECT request when a buggy classifier returns an unexpected value; no confidentiality/integrity impact and no cross-boundary compromise.
## Assumptions
- The proxy listener is not reconfigured elsewhere to bind publicly; it uses the in-repo default loopback bind.
- classifier_fun is only set by operator/developer code; untrusted agents cannot directly install or modify it.
- Attackers are limited to local sandboxed agents or local processes using the proxy via HTTPS_PROXY as described in the threat model.
- Glorbo.Network.Proxy started with classifier_fun set
- Attacker can send CONNECT via the proxy (api_only agent or local process)
- classifier_fun returns a non-matching value (e.g., nil) for some host
## Path
[agent] -> [proxy] -> [classifier_fun returns nil] -> [CaseClauseError/drop]
## Path evidence
- `lib/glorbo/network/proxy.ex:127-134` - Proxy binds to 127.0.0.1 (loopback), limiting exposure to localhost.
- `lib/glorbo/network/proxy.ex:348-373` - classify_unlisted/5 only matches {:allow|:deny|:unknown,_} and lacks a default clause; unexpected values will raise CaseClauseError.
- `lib/glorbo/network/proxy.ex:377-380` - safe_classify/3 returns raw classifier output without normalization/validation.
- `lib/glorbo/sandbox/bwrap.ex:60-65` - api_only network policy routes agents through Glorbo.Network.Proxy via HTTPS_PROXY/HTTP_PROXY env vars.
## Narrative
The proxy’s classify_unlisted/5 only matches {:allow|:deny|:unknown,_} and has no default clause, while safe_classify/3 returns the classifier output verbatim. If a configured classifier_fun returns nil or any other unexpected value, the case expression raises CaseClauseError and the connection handler drops the client without a 403 response. The proxy binds to 127.0.0.1 and is only used for api-only agents via HTTPS_PROXY, so this is a local, per-connection availability issue that requires a misbehaving, operator-supplied classifier_fun rather than an attacker-controlled configuration.
## Controls
- Loopback-only listener (127.0.0.1)
- Allowlist gating and CONNECT-only/443-only enforcement (Network.Proxy)
- Sandbox network policy uses proxy env vars for api_only
## Blindspots
- No deployment manifests or runtime configuration to confirm whether classifier_fun is enabled in real deployments.
- Static-only review cannot confirm operational exposure or monitoring behavior for crashes/timeouts.
----

TaskComments parse swaps capture order, misreads entries
Link: https://chatgpt.com/codex/cloud/security/findings/702f4e5c586c81919818d82db7753d27?sev=&repo=https%3A%2F%2Fgithub.com%2Ffoobarto%2Fglorbo
Criticality: informational (attack path: ignore)
Status: invalid (false positive: Regex.scan :all_names returns captures in alphabetical order of names, so [author, body, ts] destructure is correct; existing tests confirm)

# Metadata
Repo: foobarto/glorbo
Commit: ad7a7a8
Author: security@example.invalid
Created: 22.04.2026, 20:57:29
Assignee: Unassigned
Signals: Validated, Attack-path

# Summary
Introduced a parsing bug by destructuring regex captures in the wrong order, leading to incorrect comment entry fields when reading comment threads.
`@message_re` defines named captures in the order `ts`, `author`, `body`. `parse/1` destructures the `Regex.scan(..., capture: :all_names)` results as `[author, body, ts]`, which does not match the capture order returned by Elixir. This causes comment entries to be mis-parsed (author becomes the timestamp, timestamp becomes the body, and body becomes the author). Any consumer that expects a real ISO8601 timestamp or uses the body text will display incorrect data or error when parsing timestamps.

# Validation
## Rubric
- [x] Identify capture order in @message_re and confirm it is ts, author, body (lib/glorbo/task_comments.ex:35-37)
- [x] Verify parse/1 destructures Regex.scan results as [author, body, ts] and maps fields accordingly (lines 96-103)
- [ ] Execute PoC to observe misparsed output (blocked: Elixir/Erlang toolchain unavailable)
- [ ] Attempt valgrind/asan instrumentation (not available in container)
- [ ] Obtain debugger trace (gdb not available)
## Report
Rubric-driven review and bounded attempts at dynamic validation. Dynamic attempts: `elixir -v` and `mix --version` failed because the Elixir/Erlang toolchain is not installed and the environment cannot download via mise; `valgrind --version` and `gdb --version` were also unavailable. Code evidence shows the bug: the regex defines named captures in the order ts, author, body (lib/glorbo/task_comments.ex:35-37). `parse/1` uses `Regex.scan(..., capture: :all_names)` then destructures the result as `[author, body, ts]` and assigns author/timestamp/body accordingly (lines 96-103). Because Elixir returns captures in the order they appear, this swaps fields (author becomes timestamp, timestamp becomes body, body becomes author), matching the reported mis-parse. A runnable PoC script is included in the artifacts for when Elixir is available.

# Evidence
/workspace/glorbo/lib/glorbo/task_comments.ex (L35 to 38)
  Note: Defines the regex capture order as ts, author, body via named captures.
```
  # Same anchor as ChannelLive — body section between two `## <iso>`
  # headers. Matches `Glorbo.Filesystem.Frontmatter`-style parsing.
  @message_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## \d{4}-|\z)/ms
```

/workspace/glorbo/lib/glorbo/task_comments.ex (L96 to 104)
  Note: Parses Regex.scan results assuming [author, body, ts], which mismatches the capture order and swaps fields.
```
  defp parse(content) do
    @message_re
    |> Regex.scan(content, capture: :all_names)
    |> Enum.map(fn [author, body, ts] ->
      %{
        author: String.trim(author),
        timestamp: String.trim(ts),
        body: String.trim_trailing(body)
      }
```

# Attack-path analysis
Final: ignore | Decider: model_decided | Matrix severity: ignore | Policy adjusted: ignore
## Rationale
The code bug is real (capture order mismatch), but it only causes incorrect UI/data labeling. No security boundary is crossed, no sensitive data is exposed, and no privilege escalation is enabled. Therefore it is not a security vulnerability despite being a functional defect.
## Likelihood
ignore - Even if reachable through normal comment creation, the behavior is not exploitable for security impact.
## Impact
ignore - Misparsed comment entries only affect display/metadata integrity; no evidence of auth bypass, data exfiltration, or code execution.
## Assumptions
- Task comment threads are rendered via Glorbo.TaskComments.read/1 in the dashboard UI.
- Default runtime binds to 127.0.0.1:4000 unless overridden by environment configuration.
- Attacker control of comment bodies is plausible via agent/router flows described in the threat model.
- A task comments file exists with entries in the '## <ts> | <author>\n<body>' format
- Glorbo.TaskComments.read/1 is called to parse and render the entries
## Path
comment file -> parse (wrong order) -> UI shows swapped fields
## Path evidence
- `lib/glorbo/task_comments.ex:35-37` - Regex defines named captures in the order ts, author, body.
- `lib/glorbo/task_comments.ex:96-103` - parse/1 destructures captures as [author, body, ts], swapping fields.
- `config/runtime.exs:58-85` - Default runtime binds HTTP to 127.0.0.1:4000 (localhost exposure).
## Narrative
The TaskComments parser defines named captures in the order ts, author, body but destructures Regex.scan results as [author, body, ts], which swaps fields when reading comment threads. This is a data integrity/display bug (author, timestamp, and body are misassigned) and does not expose secrets, bypass authorization, or cross isolation boundaries. The dashboard service is configured to bind to 127.0.0.1:4000 by default, so exposure is localhost; the issue remains non-security even if reachable via normal comment workflows.
## Controls
- Default loopback binding (127.0.0.1:4000) limits network exposure by default.
## Blindspots
- Static analysis only; no runtime execution or integration tests were run.
- Deployment overrides (PHX_HOST/PORT) could change exposure, but this does not change the non-security nature of the issue.

---

