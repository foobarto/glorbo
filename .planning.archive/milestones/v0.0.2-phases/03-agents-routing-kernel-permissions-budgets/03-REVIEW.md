---
phase: 03-agents-routing-kernel-permissions-budgets
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 45
files_reviewed_list:
  - .gitignore
  - config/config.exs
  - config/llm_rates.exs
  - config/network_policy.exs
  - containers/glorbo-runtime/worker/context.py
  - containers/glorbo-runtime/worker/dispatch.py
  - containers/glorbo-runtime/worker/routes.py
  - containers/glorbo-runtime/worker/usage.py
  - containers/glorbo-runtime/tests/test_routes.py
  - containers/glorbo-runtime/tests/test_usage.py
  - containers/glorbo-runtime/tests/test_worker.py
  - lib/glorbo/agent/dispatch.ex
  - lib/glorbo/agent/parser.ex
  - lib/glorbo/agent/registry.ex
  - lib/glorbo/agent/server.ex
  - lib/glorbo/agent/spec.ex
  - lib/glorbo/application.ex
  - lib/glorbo/approvals/gate.ex
  - lib/glorbo/budget.ex
  - lib/glorbo/budget/ledger.ex
  - lib/glorbo/cli/adapter.ex
  - lib/glorbo/cli/claude_code.ex
  - lib/glorbo/cli/codex.ex
  - lib/glorbo/cli/gemini_cli.ex
  - lib/glorbo/company/agent_supervisor.ex
  - lib/glorbo/company/budget_tracker.ex
  - lib/glorbo/company/router.ex
  - lib/glorbo/company/scheduler.ex
  - lib/glorbo/company/supervisor.ex
  - lib/glorbo/doctor.ex
  - lib/glorbo/filesystem/watcher.ex
  - lib/glorbo/init/versions.ex
  - lib/glorbo/network/proxy.ex
  - lib/glorbo/runtime/uid_allocator.ex
  - lib/glorbo/sandbox/bwrap.ex
  - lib/glorbo/sandbox/permission_mapper.ex
  - lib/glorbo/security/acl_mapper.ex
  - lib/glorbo/skills/resolver.ex
  - lib/glorbo/task_definition.ex
  - lib/glorbo/tasks_approval_state.ex
  - mix.exs
  - priv/repo/migrations/20260416120001_create_budgets.exs
  - priv/repo/migrations/20260416120002_create_tasks_approval_state.exs
  - priv/repo/migrations/20260416120003_add_permissions_hash_to_agents.exs
  - test/fixtures/claude_session_sample.jsonl
  - test/fixtures/codex_rollout_sample.jsonl
  - test/fixtures/gemini_stdout_sample.json
  - test/glorbo/sandbox/bwrap_test.exs
  - test/glorbo/sandbox/permission_mapper_test.exs
  - test/glorbo/network/proxy_test.exs
  - test/glorbo/company/router_test.exs
  - test/glorbo/cli/claude_code_test.exs
  - test/glorbo/cli/codex_test.exs
  - test/glorbo/cli/gemini_cli_test.exs
  - test/integration/agent_create_denial_test.exs
  - test/integration/budget_hard_stop_e2e_test.exs
  - test/integration/approval_gate_e2e_test.exs
  - test/integration/sandbox_filesystem_test.exs
  - test/integration/sandbox_network_none_test.exs
  - test/integration/sandbox_network_api_only_test.exs
findings:
  critical: 2
  warning: 9
  info: 6
  total: 17
status: issues_found
---

# Phase 3: Code Review Report

**Reviewed:** 2026-04-16
**Depth:** standard
**Files Reviewed:** 45
**Status:** issues_found

## Summary

Phase 3 lands the kernel-layer isolation primitive (`Bwrap` + `PermissionMapper`), the CONNECT-allowlist proxy (`Network.Proxy`), the permission enforcement choke point (`Company.Router`), the approval gate (`Approvals.Gate`), and three CLI adapters. The security architecture is coherent: Router is the sole permission choke point with belt-and-braces agent-create rejection, `PermissionMapper` correctly returns `[]` for Router-mediated families (`chat:write`, `agents:message`), scoped project permissions correctly avoid mounting the parent tree (preserving sibling invisibility per D-10), `--unshare-net` is emitted for `:none`, and all user input goes through string allowlists without `String.to_atom`.

Two **critical** bugs were identified:

1. **`Bwrap.run_via_port` never closes stdin.** The code comment acknowledges the limitation but ships anyway — CLI tools that wait for EOF on stdin will hang until the 300s timeout fires, turning every dispatch into a 5-minute wall-clock wait. This is a correctness issue, not security, but it will prevent any real dispatch from completing.
2. **`Network.Proxy.init/1` calls `Task.Supervisor.start_link/1` inside `init`.** This links the Task.Supervisor to the Proxy GenServer. A crash in the acceptor or any tunnel Task (via the unlinked async_nolink in the acceptor — but start_child in tunnels is linked) can cascade back through the Task.Supervisor link and kill the Proxy. More importantly, on Proxy termination the Task.Supervisor is not explicitly stopped, leaking in-flight tunnels.

Nine warnings cover: Gate's path-traversal gap via PubSub events, Router-written inbox files with no YAML escaping of sender-controlled body, scheduler drift after long VM pauses, usage-report cost source trust, and a handful of minor robustness issues.

Six info-level items flag dead code, dev-only debug state (the erl_crash.dump file in git tree), and documentation drift.

---

## Critical Issues

### CR-01: `Bwrap.run_via_port` never closes stdin — CLI tools will hang until timeout

**File:** `lib/glorbo/sandbox/bwrap.ex:310-316`

**Issue:** After writing the prompt via `Port.command/2`, the code sends `send(port, {self(), {:command, ""}})` — an empty data chunk, not an EOF signal. The inline comment acknowledges this:

> `:eof is signalled by closing the stdin-half — Port.close/1 would close the whole port. Use :erlang.port_close after the process has exited.`

All three adapters (`claude --print`, `codex exec -`, `gemini -p` with stdin) explicitly wait for EOF on stdin before processing. Without it they block indefinitely. Every dispatch will run to the 300s `:timeout_seconds` cap, return `{:error, :timeout}`, and abort. No real invocation can complete.

The correct approach is to use `Port.open` with `:in` closed (stdout-only) and pass the prompt via a temp file argument, OR use `MuonTrap.cmd/3` with `input:` option, OR drop the port and spawn `bwrap` via `:exec.run/2` from `erlexec`, OR use `System.cmd/3` with `input:` (OTP 26+).

**Fix:**

```elixir
# Option A — write prompt to a file that bwrap passes via --bind + <
defp run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir) do
  prompt_path = Path.join(System.tmp_dir!(), "glorbo-prompt-#{System.unique_integer([:positive])}")
  File.write!(prompt_path, prompt)

  # Splice a --ro-bind for the prompt path, then use shell redirection
  argv_with_prompt = [argv, ["--ro-bind", prompt_path, "/tmp/.prompt"]] |> List.flatten()

  port = Port.open(
    {:spawn_executable, bwrap_bin},
    [:binary, :exit_status, :stderr_to_stdout, :use_stdio, :hide, args: argv_with_prompt]
  )
  # ... rely on the CLI reading /tmp/.prompt

# Option B — use erlexec or MuonTrap.cmd with :input
# Option C (OTP 26+) — System.cmd with :input option
def run(bwrap_bin, argv, prompt, timeout_s, _usage_dir) do
  task = Task.async(fn ->
    System.cmd(bwrap_bin, argv, input: prompt, stderr_to_stdout: true)
  end)
  case Task.yield(task, timeout_s * 1_000) || Task.shutdown(task, :brutal_kill) do
    {:ok, {output, status}} -> {:ok, %{exit_status: status, stdout: output, usage_dir: nil}}
    nil -> {:error, :timeout}
  end
end
```

Integration tests `BS1`/`BS2`/`BS3` in `test/integration/sandbox_filesystem_test.exs` pass because they invoke `/bin/echo` and `/bin/sh -c "..."` which don't read stdin — they don't exercise the broken code path. Add a regression test that pipes a multi-kilobyte prompt to `cat` inside the sandbox and asserts stdout equals the prompt.

---

### CR-02: `Network.Proxy` spawns a Task.Supervisor inside `init/1` — leaks + kill cascade on crash

**File:** `lib/glorbo/network/proxy.ex:107-112, 130-133`

**Issue:** `Task.Supervisor.start_link/1` is called from `Proxy.init/1` without `on_exit` or a supervised `child_spec`. This creates two problems:

1. **Link cascade:** the Task.Supervisor is linked to the Proxy GenServer. Any start-child failure, or the acceptor task's abnormal exit, can trap back to the Proxy and kill it. More dangerously, a tunnel `Task.Supervisor.start_child(task_sup, fn -> handle_connection(...) end)` starts a *linked* child — a crash in `handle_connection` will terminate the Task.Supervisor, which will terminate the Proxy's acceptor loop silently because `handle_info({:DOWN, ...}, state)` ignores it.
2. **Resource leak on stop:** `terminate/2` closes the listen socket but does NOT stop the Task.Supervisor — its pid leaks. Any live tunnel tasks continue until their 60s `pipe/2` timeout expires, keeping open the now-orphaned client/upstream sockets.

The comment on line 137 claims "Ignore the acceptor Task's :DOWN — we keep the socket open until stop," but the code doesn't correlate the `:DOWN` ref with the acceptor task — it just catches *any* `:DOWN` and keeps running. A tunnel-task crash silently stops processing new connections without the operator noticing.

**Fix:**

```elixir
# In Company.Supervisor, add the Task.Supervisor as a SIBLING child:
children = [
  ...,
  {Task.Supervisor, name: task_sup_name(company, :proxy)},
  {Glorbo.Network.Proxy,
   [name: ..., task_supervisor: task_sup_name(company, :proxy), ...]}
]

# In Proxy.init/1, look up the sibling instead of start_link:
def init(opts) do
  task_sup = Keyword.fetch!(opts, :task_supervisor)
  ...
  # Use async_nolink consistently for both acceptor AND tunnels:
  Task.Supervisor.async_nolink(task_sup, fn -> accept_loop(...) end)
  ...
end

# In accept_loop — use async_nolink (not start_child) so tunnel crashes don't
# take down the Task.Supervisor. Track the acceptor's ref and re-arm it on :DOWN:
def handle_info({:DOWN, ref, :process, _pid, reason}, %{acceptor_ref: ref} = state) do
  Logger.warning("[network.proxy] acceptor died: #{inspect(reason)} — restarting")
  # Re-arm acceptor
  new_ref = start_acceptor(state.listen_sock, state.allowlist, state.task_sup)
  {:noreply, %{state | acceptor_ref: new_ref}}
end
```

Also: `handle_info/2` currently discards all `:DOWN` refs without distinguishing acceptor from tunnels. At minimum, log tunnel-task deaths so proxy failures are observable.

---

## Warnings

### WR-01: `Approvals.Gate.handle_projects_event` has a path-traversal gap

**File:** `lib/glorbo/approvals/gate.ex:271-288`

**Issue:** The handler receives `rel_path` from the `"company:<co>:projects"` PubSub topic and builds `abs_path = Path.join([state.base, "companies", state.company, rel_path])`. `Path.join/1` does NOT normalize `..` segments. The `@project_task_re` regex `~r{\Aprojects/.+/tasks/.+\.md\z}` allows `..` anywhere inside the `.+` captures.

`TaskDefinition.parse_file` has a `relative_task_path` guard (line 158-166), but that guard is a prefix-match on the raw string, not on the realpath. `Path.join("/base/co/acme", "projects/../../../etc/passwd.md")` is `"/base/co/acme/projects/../../../etc/passwd.md"` — a string that still `starts_with?` the prefix. `File.read/1` *will* resolve `..` and read `/etc/passwd.md`.

In production this event comes from the inotify subprocess watching `<base>/companies/<co>/`, so the vector is not attacker-reachable today. But `subscribe?: true` means any other BEAM process that can broadcast on Glorbo.PubSub can inject events (test isolation, a future admin RPC, etc.). Treat this as defense-in-depth hardening.

**Fix:**

```elixir
defp handle_projects_event(rel_path, state) do
  # Reject any .. segments before touching the filesystem
  if String.contains?(rel_path, "..") do
    audit(state, %{action: "approval.rejected_traversal", task_path: rel_path, company: state.company})
    :ok
  else
    abs_path = Path.join([state.base, "companies", state.company, rel_path])
    # ... existing body
  end
end
```

Alternatively, use `Path.safe_relative_to/2` (OTP 25+) to reject any rel_path that resolves outside the company dir.

---

### WR-02: `Company.Router` writes agent-inbox files with sender-controlled body + unescaped frontmatter values

**File:** `lib/glorbo/company/router.ex:197-207, 244-252`

**Issue:** The Router writes frontmatter using naive string interpolation:

```elixir
frontmatter = """
---
from: "#{msg.sender}"
msg_id: "#{msg.msg_id}"
delivered_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
---
"""
```

`msg.sender` is validated via `verify_sender_slug/2` against the outbox path (slug must be an existing directory name), which in practice means the `Parser.parse_file` slug regex `~r/\A[a-z][a-z0-9_-]{0,63}\z/`. That's safe.

But `msg.msg_id` has NO validation anywhere in the pipeline. `validate_message/1` only checks `is_binary(id)`. A sender with an existing outbox entry at `<outbox>/"malicious-id\n---\nfrom: ceo\n---\n.md"` can control the msg_id verbatim. If an agent (or future dashboard) parses this frontmatter back, the injected `from: ceo` line poisons the derived metadata.

Same issue applies to `msg.to` in the rejection-notice frontmatter (line 330, `"#{msg.to}"`) — `to` is parsed via `parse_to/1` which only checks the prefix, so `chat:general"\n---\nstatus: approved` is a valid `to` that the parser accepts and which then gets interpolated into YAML.

**Fix:**

```elixir
# Add YAML-scalar escaping via yaml_elixir or inline guard:
defp yaml_escape(s) when is_binary(s) do
  if String.contains?(s, ["\n", "\r", "\"", "\\"]) do
    # reject or escape; rejecting via validate_message is simplest
    raise ArgumentError, "unsafe control chars in yaml scalar"
  else
    s
  end
end

# And tighten validate_message/1 to reject control chars in msg_id + to:
defp validate_message(%{msg_id: id, to: to} = msg)
    when is_binary(id) and is_binary(to) do
  cond do
    String.contains?(id, ["\n", "\r", "/"]) -> {:error, {:invalid_message, :control_chars_in_msg_id}}
    String.contains?(to, ["\n", "\r"]) -> {:error, {:invalid_message, :control_chars_in_to}}
    true -> :ok
  end
end
```

---

### WR-03: `Company.Scheduler.compute_delay_ms` drifts silently when `get_next_run_date` returns an error

**File:** `lib/glorbo/company/scheduler.ex:166-180`

**Issue:** On a cron-parse success the timer arms correctly. But `Crontab.Scheduler.get_next_run_date/2` returns `{:error, reason}` for expressions that are valid-syntax-but-never-fire (e.g. `0 0 30 2 *` — Feb 30th). The code falls back to a hardcoded 1-hour delay, emits a Logger.warning, but never audits the problem. An operator who set a malformed-but-parseable schedule will see the agent silently firing every hour forever.

**Fix:**

Emit a `scheduler.cron_never_fires` audit event (or reuse `scheduler.invalid_cron`) before falling back to the 1h default, so the operator sees it in the audit log rather than only in application logs. Also: consider rejecting the registration entirely — a cron that can't compute a next run is almost certainly a config bug the operator wants flagged loudly.

---

### WR-04: `Bwrap.build_argv` binds `/etc` read-only — leaks host resolv.conf, PKI, hostname, and every system config

**File:** `lib/glorbo/sandbox/bwrap.ex:180-181`

**Issue:** `--ro-bind /etc /etc` exposes the full host `/etc` to the sandbox. For CLI tools this is necessary (TLS needs `/etc/ssl/certs`, DNS needs `/etc/resolv.conf`, user-group lookup needs `/etc/passwd`/`/etc/group`), but it also exposes:

- `/etc/shadow` (root-readable only, but still visible via stat)
- `/etc/sudoers` and `/etc/sudoers.d/*` (contains hostnames and usernames)
- `/etc/ssh/sshd_config`, `/etc/ssh/ssh_host_*_key.pub`
- `/etc/hosts` (leaks local network topology)
- `/etc/nsswitch.conf`, `/etc/pam.d/*`
- Any user-installed `/etc/cron.*/`, `/etc/systemd/system/*`
- Application configs if present (`/etc/nginx/`, `/etc/postgres/`, `/etc/gitconfig`)

The sandbox inherits this via `--ro-bind`, meaning a malicious agent's CLI prompt-injection payload can exfiltrate any of these via the outbox.

For this phase the tradeoff is documented (implicit in D-09). But the review calls this out because (a) the module docstring claims "`/etc` — host resolv.conf + PKI" which undersells the exposure, (b) users deploying on a dev laptop will leak much more than a server user expects.

**Fix (defense-in-depth, deferred OK but document):**

```elixir
# Bind only the specific files agents need; use tmpfs for the rest
defp root_fs_flags do
  [
    "--ro-bind", "/usr", "/usr",
    # ... symlinks ...
    "--tmpfs", "/etc",                                # empty /etc baseline
    "--ro-bind", "/etc/ssl", "/etc/ssl",             # TLS trust store
    "--ro-bind", "/etc/ca-certificates", "/etc/ca-certificates",
    "--ro-bind", "/etc/pki", "/etc/pki",             # Fedora
    "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf",
    "--ro-bind", "/etc/hosts", "/etc/hosts",
    "--ro-bind", "/etc/nsswitch.conf", "/etc/nsswitch.conf",
    # Minimal passwd/group so getpwuid(3) works for the spawning UID
    "--ro-bind", "/etc/passwd", "/etc/passwd",
    "--ro-bind", "/etc/group", "/etc/group",
    ...
  ]
end
```

If retaining full `--ro-bind /etc`, update the moduledoc to explicitly list the exposure and add a D-09b note in `03-05-PLAN.md`.

---

### WR-05: `Bwrap.run_via_port` uses `Port.open` instead of supervised spawn — no cgroup cleanup

**File:** `lib/glorbo/sandbox/bwrap.ex:296-318`

**Issue:** The moduledoc (lines 60-73) promises a "triple-layer cleanup" via `MuonTrap.Daemon` + `--unshare-pid` + `--die-with-parent`. But `run_via_port` opens a raw `Port.open/2` — NOT `MuonTrap.Daemon` or `MuonTrap.cmd/3`. The cgroup-backed kill trap promised in the docs is not wired up.

`--die-with-parent` covers the bwrap process, `--unshare-pid` reaps children in the new pidns. But if the Elixir BEAM process is killed with SIGKILL (OOM-kill, kernel panic), the child bwrap process may still be in a pending-reap state where its children have not been torn down. Without MuonTrap's cgroup fallback, some edge cases (orphaned descendants before ns init, pid-ns kill races) can leak processes.

The inline comment at line 294 says "We use Port directly rather than MuonTrap.cmd because the latter lacks a stdin-input option." But MuonTrap DOES accept stdin input via the `:stdin` keyword in newer releases. The actual reason is the stdin-EOF problem flagged in CR-01.

**Fix:**

Once CR-01 is addressed (by passing the prompt via bind-mounted file), switch to `MuonTrap.cmd/3` or `MuonTrap.Daemon.start_link/2`. This also fixes CR-01 and unifies the process-supervision story.

---

### WR-06: `Company.Router.handle_call({:route, ...})` serializes ALL routing through one GenServer — per-company global lock

**File:** `lib/glorbo/company/router.ex:92-96`

**Issue:** Router is a single GenServer per company handling every `route/2` call synchronously. The inbox writes and channel appends inside `perform_routing` do disk I/O (mkdir_p, write, fsync). Under burst load (e.g. 20 agents each producing 10 outbox messages per second), every message queues behind the previous one's disk sync. Latency scales linearly with queue depth.

This is a deliberate design choice (documented at line 27: "Channel writes use `[:append, :sync]` — fsync after every write serializes concurrent writers at the OS file-handle level"). But the rationale would be served equally by a per-channel serializer with a pool of routers. The current design makes the Router a company-wide bottleneck.

Not a bug per se, but note it as a scaling ceiling. For v0.0.1 the single-director use case this is fine; add a perf benchmark to `.planning/phases/03.../VALIDATION.md` that measures steady-state route throughput so we catch degradation early.

**Fix:** Document the tradeoff explicitly in the Router moduledoc and benchmark throughput. Optional future work: split into per-resource-type routers (ChannelRouter, AgentInboxRouter, ApprovalRouter) under a DynamicSupervisor.

---

### WR-07: `Bwrap.env_flags` does not validate env var keys/values — shell metachar injection possible via agent.md

**File:** `lib/glorbo/sandbox/bwrap.ex:234-246`

**Issue:** `cli_env` is a map from user-influenced values (adapters compute paths from `workspace`, which traces back to `spec.company` and `spec.slug` — both validated) but nothing guards against keys or values containing `\0`, `=`, `\n`. A newline in a value is passed verbatim to `--setenv KEY VALUE` — bwrap itself doesn't interpret shell syntax (it uses execve), so this is not a classical command injection. However:

1. `\0` in either KEY or VALUE will truncate the env var at the null byte silently (execve semantics).
2. `=` in KEY will either split the var in bwrap's internal parsing or produce a key-with-equal that the CLI reads as `KEY=val` where val starts with `=`.
3. `proxy_url` on line 242 is user-supplied via `:proxy_url` opt. If a caller passes `"http://evil.com:9999\nOTHER_VAR=injected"`, bwrap treats it as a single string (execve-safe), but when some tools in future may `echo "$HTTPS_PROXY"` into a shell, the newline becomes a shell metachar.

Adapters (`ClaudeCode.env/2`, `Codex.env/2`, `GeminiCli.env/2`) currently produce keys that are hardcoded strings, so this is not reachable today. Flag as defense-in-depth.

**Fix:**

```elixir
defp env_flags(opts) do
  cli_env = Map.get(opts, :cli_env, %{})
  proxy_env = proxy_env_for(opts)

  (Map.to_list(cli_env) ++ proxy_env)
  |> Enum.flat_map(fn {k, v} ->
       unless safe_env?(k, v), do: raise ArgumentError, "unsafe env #{inspect({k, v})}"
       ["--setenv", k, v]
     end)
end

defp safe_env?(k, v) when is_binary(k) and is_binary(v) do
  not String.contains?(k, ["\0", "=", "\n"]) and
    not String.contains?(v, ["\0", "\n"])
end
defp safe_env?(_, _), do: false
```

---

### WR-08: `Runtime.UidAllocator.find_user_subuid` crashes on malformed `/etc/subuid` entries

**File:** `lib/glorbo/runtime/uid_allocator.ex:47-54`

**Issue:** `String.to_integer(base_str)` on line 50 raises `ArgumentError` if `base_str` is non-numeric. `/etc/subuid` is user-owned (well, root-owned but editable by a distro package) and can in theory contain malformed lines. A corrupt entry for the current user (e.g. from a broken shadow-utils upgrade) would crash the allocator at startup.

**Fix:**

```elixir
defp find_user_subuid(lines, user) do
  Enum.find_value(lines, {:error, :no_subuid_entry}, fn line ->
    case String.split(line, ":") do
      [^user, base_str | _] ->
        case Integer.parse(base_str) do
          {base, ""} when base > 0 -> {:ok, base}
          _ -> nil
        end
      _ -> nil
    end
  end)
end
```

Use `Integer.parse` + guard, same pattern as the rest of the codebase.

---

### WR-09: `Dispatch.latest_jsonl` uses `File.stat!/1` — crashes if a JSONL file is deleted between `ls` and `stat`

**File:** `lib/glorbo/agent/dispatch.ex:273-285`

**Issue:** `File.ls/1` lists entries, then `File.stat!/1` is called on each path. If a concurrent cleanup (or the CLI itself rotating session files) removes a file between the `ls` and the `stat!`, the `stat!` raises `File.Error`. This aborts the entire `parse_usage` path, causing zero usage to be recorded for the invocation — the `conservative_zero` recovery (line 262) never runs because the exception escapes the `with`.

Probability is low (sub-100ms race window) but the consequence is a lost usage record → budget undercount.

**Fix:**

```elixir
defp latest_jsonl(dir) do
  case File.ls(dir) do
    {:ok, entries} ->
      entries
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.flat_map(fn path ->
           case File.stat(path) do
             {:ok, stat} -> [{path, stat.mtime}]
             {:error, _} -> []
           end
         end)
      |> Enum.sort_by(fn {_path, mtime} -> mtime end, :desc)
      |> case do
           [] -> nil
           [{path, _} | _] -> path
         end

    _ -> nil
  end
end
```

---

## Info

### IN-01: `/var/home/user/Documents/glorbo/erl_crash.dump` is tracked in the working tree

**File:** `erl_crash.dump` (working tree state, not in the commit)

**Issue:** `git status` reports `erl_crash.dump` in the working tree. `.gitignore` line 20 does list it, so it won't be committed. Noting for cleanliness — consider a post-test cleanup hook.

**Fix:** `rm erl_crash.dump` after test runs. No code change required.

---

### IN-02: `Approvals.Gate.resolve_approval/3` has an unused `_status` argument

**File:** `lib/glorbo/approvals/gate.ex:126-132`

**Issue:** The test-facing shortcut function takes a `_status` arg but ignores it entirely, deriving status from the task file on disk instead. The type signature claims it matters; it doesn't.

**Fix:** Either use the status (to synthesize a file-event-less fast path) or drop the argument:

```elixir
@spec resolve_approval(GenServer.server(), String.t()) :: :ok
def resolve_approval(server, task_path) do
  send(server, {:file_event, task_path, [:modified]})
  _ = :sys.get_state(server)
  :ok
end
```

---

### IN-03: `Company.BudgetTracker` moduledoc says `reload_config/1` is a cast but impl is a call

**File:** `lib/glorbo/company/budget_tracker.ex:92-99, 160-162`

**Issue:** Minor doc-vs-impl drift — the `@doc` for `reload_config/1` doesn't specify cast/call, but the pattern elsewhere in the module (`record/2` is cast) implies cast. The impl is `GenServer.call(:reload_config)`. No bug, just inconsistency.

**Fix:** Either document explicitly ("synchronous; returns `:ok` once cache cleared") or convert to cast since no return value is semantically needed.

---

### IN-04: `Agent.Parser.validate_budget/1` silently coerces invalid values to `nil` instead of erroring

**File:** `lib/glorbo/agent/parser.ex:295-297`

**Issue:**

```elixir
defp validate_budget(nil), do: {:ok, nil}
defp validate_budget(v) when is_integer(v) and v >= 0, do: {:ok, v}
defp validate_budget(_), do: {:ok, nil}
```

A user who writes `budget_usd_cents_month: "500"` (string instead of int) or `budget_usd_cents_month: -100` (negative) gets silently coerced to `nil` → no budget enforcement. Other validators in the file error loudly (`:invalid_provider`, `:invalid_network`, etc.).

Compare `validate_timeout/1` (line 299-302): same pattern of silent coercion.

**Fix:** Return `{:error, {:invalid_budget, raw}}` for non-nil non-integer values, matching the rest of the validators:

```elixir
defp validate_budget(nil), do: {:ok, nil}
defp validate_budget(v) when is_integer(v) and v >= 0, do: {:ok, v}
defp validate_budget(other), do: {:error, {:invalid_budget, other}}
```

Same for `validate_timeout/1`.

---

### IN-05: `containers/glorbo-runtime/worker/context.py` directory-resolution has a fragile assumption

**File:** `containers/glorbo-runtime/worker/context.py:76-87`

**Issue:** `_load_skills` looks for the substring `"company"` in path parts to locate the skills dir. Any company whose slug contains the literal word "company" will get a false-positive match; any tree that doesn't have `/company` as an ancestor (e.g. a custom bind mount) silently returns an empty skills list. Same issue with `_find_agent_md` on line 66-73.

Python `worker/` is dormant in this phase per CLAUDE.md ("Python never runs on the host"), so this is not a production hazard. Flag for future Phase 4 work.

**Fix:** Pass the company root as a parameter instead of searching for it:

```python
def load_task_context(task_path: str, company_root: str, skills: List[str], ...) -> dict:
    ...
```

---

### IN-06: `Glorbo.Sandbox.Bwrap.start/2` never logs the composed argv even at debug level — observability gap

**File:** `lib/glorbo/sandbox/bwrap.ex:279-290`

**Issue:** The bwrap argv is the entire security policy materialized as strings. Debugging a misbehaving sandbox (a bind target that doesn't exist, a permission that was dropped silently by `PermissionMapper`) requires seeing the argv. Currently there is no log line emitting it, even at `Logger.debug`.

**Fix:**

```elixir
def start(%{} = opts, run_opts) when is_list(run_opts) do
  ...
  argv = build_argv(opts) ++ ["--", cli_bin] ++ cli_args
  Logger.debug("[sandbox.bwrap] argv=#{inspect(argv)}")
  run_via_port(bwrap_bin, argv, prompt, timeout_s, usage_dir)
end
```

Redact env values that might contain credentials (e.g. if a future adapter ends up with `ANTHROPIC_API_KEY` in cli_env).

---

_Reviewed: 2026-04-16_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
