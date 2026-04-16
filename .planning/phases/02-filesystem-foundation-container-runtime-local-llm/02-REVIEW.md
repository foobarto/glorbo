---
phase: 02-filesystem-foundation-container-runtime-local-llm
reviewed: 2026-04-16T00:00:00Z
depth: standard
files_reviewed: 52
files_reviewed_list:
  - .github/workflows/runtime-image.yml
  - containers/glorbo-runtime/Containerfile
  - containers/glorbo-runtime/requirements.txt
  - containers/glorbo-runtime/tests/conftest.py
  - containers/glorbo-runtime/tests/test_worker.py
  - containers/glorbo-runtime/worker/__init__.py
  - containers/glorbo-runtime/worker/context.py
  - containers/glorbo-runtime/worker/dispatch.py
  - containers/glorbo-runtime/worker/main.py
  - containers/glorbo-runtime/worker/routes.py
  - lib/glorbo/agent.ex
  - lib/glorbo/application.ex
  - lib/glorbo/audit_event.ex
  - lib/glorbo/cli.ex
  - lib/glorbo/company.ex
  - lib/glorbo/company/audit_log.ex
  - lib/glorbo/company/supervisor.ex
  - lib/glorbo/container/invocation.ex
  - lib/glorbo/container/socket.ex
  - lib/glorbo/container/worker_client.ex
  - lib/glorbo/container_manager.ex
  - lib/glorbo/doctor.ex
  - lib/glorbo/doctor/formatter.ex
  - lib/glorbo/filesystem/frontmatter.ex
  - lib/glorbo/filesystem/hierarchy.ex
  - lib/glorbo/filesystem/reindex.ex
  - lib/glorbo/filesystem/reindex_state.ex
  - lib/glorbo/filesystem/watcher.ex
  - lib/glorbo/init.ex
  - lib/glorbo/init/binary_bootstrap.ex
  - lib/glorbo/init/example_company.ex
  - lib/glorbo/init/image_pull.ex
  - lib/glorbo/init/orchestrator.ex
  - lib/glorbo/init/versions.ex
  - mix.exs
  - priv/repo/migrations/20260415120001_create_companies.exs
  - priv/repo/migrations/20260415120002_create_agents.exs
  - priv/repo/migrations/20260415120003_create_audit_events.exs
  - priv/repo/migrations/20260415120004_create_reindex_state.exs
  - test/glorbo/application_test.exs
  - test/glorbo/cli_test.exs
  - test/glorbo/company/audit_log_test.exs
  - test/glorbo/container/invocation_test.exs
  - test/glorbo/container/socket_test.exs
  - test/glorbo/container/worker_client_test.exs
  - test/glorbo/doctor_test.exs
  - test/glorbo/filesystem/frontmatter_test.exs
  - test/glorbo/filesystem/hierarchy_test.exs
  - test/glorbo/filesystem/reindex_test.exs
  - test/glorbo/filesystem/watcher_test.exs
  - test/glorbo/init/binary_bootstrap_test.exs
  - test/glorbo/init/example_company_test.exs
  - test/glorbo/init/orchestrator_test.exs
  - test/glorbo/init/versions_test.exs
  - test/glorbo/stubs_test.exs
  - test/integration/airplane_mode_test.exs
  - test/integration/container_isolation_test.exs
  - test/integration/container_lifecycle_test.exs
  - test/integration/image_pull_test.exs
  - test/integration/reindex_roundtrip_test.exs
  - test/support/doctor_helpers.ex
  - test/support/ollama_case.ex
  - test/support/podman_case.ex
  - test/support/tmp_glorbo_home.ex
  - test/test_helper.exs
findings:
  critical: 7
  warning: 16
  info: 17
  total: 40
status: issues_found
---

# Phase 2: Code Review Report

**Reviewed:** 2026-04-16T00:00:00Z
**Depth:** standard
**Files Reviewed:** 52 (Elixir source + tests + Python worker + container infra)
**Status:** issues_found

## Summary

Phase 2 delivers filesystem foundation, container runtime, and local-LLM bootstrap with strong test discipline and careful honouring of the CLAUDE.md invariants. The security-critical code (`Glorbo.Container.Invocation`, `Glorbo.Company.AuditLog`, `Glorbo.Filesystem.Frontmatter`, `Glorbo.Init.BinaryBootstrap`) is well-constructed: SHA-256 verification before extraction, staging-dir zip-slip mitigation, safe YAML loading with size cap, fsync-after-every-write for audit log, negative security assertions on container argv, and the "Python never runs on host" invariant is enforced in CI by running pytest *inside* the built image.

Findings below are primarily correctness issues: a genuine bug in the AuditLog month-bucketing that rolls over weeks early on non-UTC timestamps, a reindex ordering edge case when agents exist without a sibling `company.md`, several concurrency/lifecycle issues in the container manager and worker routes, and a handful of minor quality items. No hardcoded secrets; no injection vectors in argv construction.

Invariant-check pass/fail:
- Filesystem = source of truth, SQLite derived → **PASS** (AuditLog FS-05 fsync-first; Reindex roundtrip test confirms reconstruction).
- Append-only audit log → **PASS** (stubs_test.exs negative assertions, no update/delete/edit exported).
- Company isolation absolute → **PASS** in invocation construction (`--volume <co>:/company`, `--network none`). Verified by `container_isolation_test.exs`.
- Python only inside container → **PASS** (Containerfile + CI in-image pytest + no Python on host paths).
- Inbox/outbox one-way flow → **NOT TESTED at POSIX level** (expected Phase 3); watcher correctly routes events without touching contents.
- Permission enforcement at Router + ACLs → **NOT IN PHASE 2 SCOPE** (ACL layer is Phase 3+).

## Critical Issues

### CR-01: Reindex silently creates orphan Agent rows when `company.md` is missing

**File:** `lib/glorbo/filesystem/reindex.ex:87, 207-227`
**Issue:** `do_run/1` sorts by `{path_kind(&1), &1}`, grouping all `company.md` files first and agents second across the whole tree. If a directory layout has `companies/acme/agents/ceo/agent.md` but no `companies/acme/company.md`, `upsert_agent/2` calls `Repo.get_by(Company, name: "acme")`, gets `nil`, and inserts an Agent row with `company_id: nil`. The `agents.company_id` migration does not declare `null: false`, so the orphan persists. On next reindex, the agent still exists without a parent — the FS-03/FS-04 invariant "SQLite fully reconstructible from disk" holds, but the reconstructed state is wrong.

This also subtly interacts with Phase 3's Router, which will look up agents by company_id and silently ignore orphans.

**Fix:** Either (a) make `company_id` `NOT NULL` in migration + schema, and return `{:skip, :missing_parent_company}` from `upsert_agent/2`; or (b) group by company prefix and process each sub-tree as a unit, skipping entire sub-trees lacking a `company.md`:

```elixir
defp do_run(companies_dir) do
  files = safe_markdown_files(companies_dir)
  by_company = Enum.group_by(files, &company_prefix/1)

  {indexed, skipped} =
    Enum.reduce(by_company, {0, 0}, fn {_co, paths}, {i, s} ->
      if Enum.any?(paths, &String.ends_with?(&1, "/company.md")) do
        ordered = Enum.sort_by(paths, &{path_kind(&1), &1})
        Enum.reduce(ordered, {i, s}, &accumulate_result/2)
      else
        Logger.warning("reindex skipped orphan agents: no company.md in #{hd(paths)}")
        {i, s + length(paths)}
      end
    end)
  # ...
end
```

### CR-02: AuditLog month-bucket uses local-date conversion, not UTC

**File:** `lib/glorbo/company/audit_log.ex:140-145`
**Issue:** `month_bucket/1` calls `DateTime.to_date(dt)` without converting to UTC. `entry_ts/1` accepts any `%DateTime{}` from the caller — including non-UTC. A `2026-03-31T23:00:00-05:00` entry (UTC `2026-04-01T04:00:00Z`) lands in `2026-03.jsonl` instead of the UTC-correct `2026-04.jsonl`.

Since the append-only audit log depends on deterministic bucketing, mis-bucketed entries are effectively lost to consumers that iterate months in UTC. Two buckets can both contain "the first entry of April," and global ordering is violated.

**Fix:**
```elixir
defp month_bucket(%DateTime{} = dt) do
  dt
  |> DateTime.shift_zone!("Etc/UTC")
  |> DateTime.to_date()
  |> Date.to_string()
  |> String.slice(0, 7)
end
```

Or normalise in `entry_ts/1`: always return `DateTime.shift_zone!(dt, "Etc/UTC")` so both the JSONL `ts` field and the bucket derive from the same UTC view.

### CR-03: Container launch races stale container with same name

**File:** `lib/glorbo/container_manager.ex:87-104`
**Issue:** `start_container/2` runs `Socket.cleanup_stale/3` but does NOT remove stale Podman containers named `glorbo-<company>-<agent>`. If a prior `:ephemeral` launch was SIGKILLed before `--rm` ran (OOM, host reboot, supervisor brutal kill), Podman retains the container metadata. The next launch fails with `Error: creating container storage: ... already in use` and the operator must manually `podman rm -f` to recover.

For `:persistent` mode the problem is identical — the Daemon start fails and propagates an error up, but nothing auto-heals.

**Fix:** Best-effort remove any container with the target name before launch:

```elixir
defp pre_clean_container(company, agent) do
  name = "glorbo-#{company}-#{agent}"
  _ = System.cmd(@podman, ["rm", "-f", name], stderr_to_stdout: true)
  :ok
end

def handle_call({:start_container, company, opts}, _from, state) do
  agent = Keyword.fetch!(opts, :agent)
  # ...
  Socket.ensure_dir!(base, company)
  Socket.cleanup_stale(base, company, agent)
  pre_clean_container(company, agent)
  # ...
end
```

### CR-04: Persistent container Daemon is unsupervised — violates crash isolation invariant

**File:** `lib/glorbo/container_manager.ex:131-142`
**Issue:** `launch(:persistent, ...)` calls `MuonTrap.Daemon.start_link` and discards the pid. The Daemon is linked to `ContainerManager` (a long-lived GenServer). Consequences:

1. If the Daemon crashes, it kills the `ContainerManager` link — which takes down ALL companies' container management. This violates CLAUDE.md's "Agent crash → only that agent restarts" invariant.
2. `stop_container/1` only knows the container name, not the Daemon pid, so it can't cleanly stop the Daemon — `podman stop` exits, the Daemon sees the exit and dies, taking the link with it.
3. No restart policy: a crashed podman process is NOT automatically restarted; the pattern delivers no reliability benefit over bare `System.cmd`.

**Fix:** Start Daemons under a `DynamicSupervisor` anchored in the app tree, and track the pid:

```elixir
# application.ex
children = [
  # ...
  {DynamicSupervisor, name: Glorbo.Container.DaemonSupervisor, strategy: :one_for_one},
  Glorbo.ContainerManager,
  # ...
]

# container_manager.ex
defp launch(:persistent, argv, company, agent) do
  spec = %{
    id: "glorbo-#{company}-#{agent}",
    start: {MuonTrap.Daemon, :start_link, [@podman, argv, [log_output: :info, stderr_to_stdout: true]]},
    restart: :transient
  }

  case DynamicSupervisor.start_child(Glorbo.Container.DaemonSupervisor, spec) do
    {:ok, pid} ->
      # Track {name -> pid} in state so stop_container/1 can stop the Daemon cleanly.
      {:ok, "glorbo-#{company}-#{agent}"}
    {:error, reason} ->
      {:error, {:daemon_failed, reason}}
  end
end
```

### CR-05: Worker /run double-wraps task in create_task + wait_for

**File:** `containers/glorbo-runtime/worker/routes.py:57-71`
**Issue:** `asyncio.create_task(run_task(...))` then `asyncio.wait_for(task, timeout)` creates the task twice-through: once by `create_task`, and `wait_for` *does not* create its own task when passed a `Task` (it awaits it directly). On `TimeoutError`, `wait_for` cancels the task — but the task is tracked in `_live_tasks` and a concurrent `/cancel` request sees an already-cancelling task and returns `cancelled=True` for a request that really timed out.

More critically: the `request_id` duplication case is unprotected. If two `/run` calls arrive with the same `request_id`, the second overwrites `_live_tasks[request_id]` with the new task; the first task becomes unreachable from `/cancel` AND the first handler's `finally` clause (on completion) pops the SECOND request's entry by mistake. Subsequent `/cancel` on the second request returns `cancelled=False`.

**Fix:** (a) Reject duplicate `request_id` at entry; (b) rely on `wait_for`'s own task:

```python
@router.post("/run", response_model=RunResponse)
async def run(req: RunRequest) -> RunResponse:
    if req.request_id in _live_tasks:
        return RunResponse(ok=False, error="duplicate request_id")
    try:
        ctx = load_task_context(req.task_path, req.skills)
    except FileNotFoundError as exc:
        return RunResponse(ok=False, error=str(exc))

    timeout = req.timeout_seconds or 300
    task = asyncio.ensure_future(
        run_task(ctx, req.provider, req.model, req.api_key, timeout)
    )
    _live_tasks[req.request_id] = task
    try:
        result = await asyncio.wait_for(asyncio.shield(task), timeout=timeout)
        return RunResponse(ok=True, result=result)
    except asyncio.TimeoutError:
        task.cancel()
        return RunResponse(ok=False, error="timeout")
    except asyncio.CancelledError:
        return RunResponse(ok=False, error="cancelled")
    except Exception as exc:  # noqa: BLE001
        return RunResponse(ok=False, error=_scrub(str(exc), req.api_key))
    finally:
        _live_tasks.pop(req.request_id, None)
```

### CR-06: ContainerManager public API ignores configurable :name

**File:** `lib/glorbo/container_manager.ex:40, 57, 62, 29-32`
**Issue:** `start_link/1` accepts and honours a `:name` option (`Keyword.put_new(opts, :name, __MODULE__)`), but `ensure_image/1`, `start_container/2`, and `stop_container/1` hardcode `GenServer.call(__MODULE__, ...)`. A test or alternate wiring that starts ContainerManager under a different name cannot call its public API — the call goes to `__MODULE__` and crashes with `** (exit) no such process`.

**Fix:** Add `server \\ __MODULE__` to every public function, matching `Glorbo.Company.AuditLog.append/2`:

```elixir
@spec ensure_image(GenServer.server(), String.t()) :: :ok | {:error, term()}
def ensure_image(server \\ __MODULE__, image) do
  GenServer.call(server, {:ensure_image, image}, 60_000)
end

@spec start_container(GenServer.server(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
def start_container(server \\ __MODULE__, company, opts) do
  GenServer.call(server, {:start_container, company, opts}, 30_000)
end

# ... same for stop_container/2
```

### CR-07: Worker dispatch may echo api_key to Elixir via litellm error

**File:** `containers/glorbo-runtime/worker/dispatch.py:29-47`, `containers/glorbo-runtime/worker/routes.py:68-69`
**Issue:** `kwargs["api_key"] = api_key` is passed to `litellm.completion`. On exception, `str(exc)` can include request kwargs (varies per litellm version and provider shim; OpenRouter and community backends have historically echoed). The `/run` handler catches with `except Exception as exc: return RunResponse(ok=False, error=str(exc))`, and that error string flows back to the Elixir host, where it is logged and potentially audited. D-37 ("keys live in request-scope memory only, never env var, never disk") is correctly honoured on the happy path but leaks are possible on the error path.

**Fix:** Scrub the error string against the request's `api_key` before returning:

```python
def _scrub(text: str, api_key: Optional[str]) -> str:
    if api_key and api_key in text:
        return text.replace(api_key, "[REDACTED]")
    return text

# in routes.py /run handler
except Exception as exc:  # noqa: BLE001
    return RunResponse(ok=False, error=_scrub(str(exc), req.api_key))
```

Also set `litellm.suppress_debug_info = True` / `litellm.set_verbose = False` at worker startup (defaults but belt-and-braces).

## Warnings

### WR-01: Frontmatter split breaks on CRLF line endings (worker)

**File:** `containers/glorbo-runtime/worker/context.py:45-50`
**Issue:** `_split_frontmatter` matches `text.startswith("---\n")` and splits on `"---\n"`. A file authored on Windows (CRLF) or with mixed endings falls through to the empty-meta branch — the agent silently loses its system prompt. No warning surfaces.

**Fix:**
```python
def _split_frontmatter(text: str) -> Tuple[dict, str]:
    normalized = text.replace("\r\n", "\n")
    if normalized.startswith("---\n"):
        parts = normalized.split("---\n", 2)
        if len(parts) == 3:
            _, fm, body = parts
            return yaml.safe_load(fm) or {}, body
    return {}, normalized
```

### WR-02: Frontmatter parser inconsistent fence check (Elixir vs Python)

**File:** `lib/glorbo/filesystem/frontmatter.ex:38`
**Issue:** `String.starts_with?(content, "---")` accepts `--- foo bar` on a single line, forwarding to `YamlFrontMatter.parse/1` which then errors. The Python worker uses stricter `"---\n"`. Files that straddle this divergence parse on one side but not the other.

**Fix:** Align to `"---\n"` in Elixir (normalising CRLF first):

```elixir
normalized = String.replace(content, "\r\n", "\n")
cond do
  byte_size(normalized) > @max_content_bytes -> {:error, :too_large}
  not String.starts_with?(normalized, "---\n") -> {:ok, %{}, normalized}
  true -> do_parse(normalized)
end
```

### WR-03: Reindex cleanup is O(N*3) per vanished file

**File:** `lib/glorbo/filesystem/reindex.ex:252-270`
**Issue:** For each vanished file, three `delete_all` statements run (ReindexState + Company + Agent each). For a large cleanup, this is 3N queries. Also, since Company migration has `on_delete: :delete_all` for agents, the Agent delete-by-file_path is redundant when the vanished file is `company.md`.

**Fix:** Batch by collecting the full `vanished` list and issuing three aggregate deletes with `where: r.file_path in ^vanished`.

### WR-04: Doctor probe files race under concurrent invocations

**File:** `lib/glorbo/doctor.ex:192-194, 362-363, 381-382`
**Issue:** `check_glorbo_dir`, `check_audit_dir`, `check_sockets_dir` all use a fixed probe filename `.doctor_probe`. Two concurrent `mix glorbo.doctor` invocations race: the second `File.write!` succeeds but the first's `File.rm!` sees the second's overwrite as its own and removes it, leaving the second to crash on `File.rm!` with `:enoent`.

Unlikely in real usage, but doctor is documented as idempotent.

**Fix:** Unique probe name per invocation:

```elixir
probe = Path.join(path, ".doctor_probe_#{System.unique_integer([:positive])}")
```

### WR-05: Orchestrator bootstrap failures bypass continue-on-error (D-20)

**File:** `lib/glorbo/init/orchestrator.ex:52-57`
**Issue:** `Hierarchy.ensure!(base)` and `start_audit_log/1` both run before the pipeline's `Enum.map`. If either raises (e.g. EACCES on non-writable `$HOME`), the exception escapes `Orchestrator.run/1` without ever producing a `:hierarchy` step result. The caller sees an uncaught exception, not the contracted `{:error, summary}` tuple.

**Fix:** Wrap setup in try/rescue and synthesise an early-exit summary:

```elixir
try do
  Hierarchy.ensure!(base)
  start_audit_log(base)
rescue
  e ->
    failure = %{step: :hierarchy, status: :error, detail: Exception.message(e)}
    summary = %{results: [failure], exit_code: 1, failures: [failure], next_steps: []}
    throw({:return, {:error, summary}})
end

# catch throw({:return, result}) and return it
```

### WR-06: Application CLI halt uses unlinked Task

**File:** `lib/glorbo/application.ex:62-69`
**Issue:** `Task.start(fn -> System.halt(exit_code) end)` is an unlinked, unsupervised fire-and-forget. In practice the BEAM schedules the halt *after* `start/2` returns, but there is no guarantee — under scheduler contention the halt-task could run before the supervisor init completes, producing odd exit codes.

**Fix:** `:timer.apply_after(0, :erlang, :halt, [exit_code])` gives the same effect with no extra process, or use `:erlang.send_after` to a named process that halts. Current code is a known-fragile pattern; replace when convenient.

### WR-07: Watcher pending-timer map unbounded

**File:** `lib/glorbo/filesystem/watcher.ex:70-76`
**Issue:** `state.pending` accumulates one entry per distinct path. A buggy or malicious actor writing 1M distinct paths fills the map and consumes timer-wheel slots indefinitely. No cap, no eviction.

**Fix:** Add a size cap:

```elixir
@max_pending 10_000

if map_size(state.pending) >= @max_pending do
  Logger.warning("[watcher/#{state.company}] pending map at cap (#{@max_pending}); dropping event")
  {:noreply, state}
else
  # ... existing timer-cancel + schedule logic
end
```

### WR-08: ImagePull default `image_cached?/1` hits real podman

**File:** `lib/glorbo/init/image_pull.ex:52-59`
**Issue:** The module is otherwise carefully DI'd, but `image_cached?/1`'s default body hardcodes `System.cmd("podman", ...)`. A test that injects `ensure_image_fun:` but not `image_cached_fun:` invokes real podman. Orchestrator tests pass both but nothing enforces the pairing.

**Fix:** Require both functions together, or document that `image_cached_fun:` defaults to the real podman cmd. Consider a guard:

```elixir
if Keyword.has_key?(opts, :ensure_image_fun) and not Keyword.has_key?(opts, :image_cached_fun) do
  raise ArgumentError, "ensure_image_fun: must be paired with image_cached_fun: for hermetic tests"
end
```

### WR-09: `combine/1` loses :downloaded info on mixed error+success

**File:** `lib/glorbo/init/orchestrator.ex:165-172`
**Issue:** When results are a mix of `{:ok, :downloaded, path}` and `{:error, _}`, the returned detail is `"binary bootstrap had errors: [...]"` but the successfully-downloaded binaries are absent from the summary. Operators see "error" and don't know podman actually installed.

**Fix:** Include downloaded paths in the error detail:

```elixir
downloaded = Enum.filter(results, &match?({:ok, :downloaded, _}, &1))
errors = Enum.filter(results, &match?({:error, _}, &1))

%{
  status: :error,
  errors: errors,
  downloaded: downloaded,
  detail: "binary bootstrap had errors: #{inspect(errors)}; downloaded: #{inspect(downloaded)}"
}
```

### WR-10: AuditLog atom/string key collision is implementation-defined

**File:** `lib/glorbo/company/audit_log.ex:84-100`
**Issue:** `entry[:actor] || entry["actor"]` picks atom first; `drop_known_keys/1` drops both. A caller passing `%{actor: "ceo", "actor" => "director"}` gets atom ("ceo") wins. This is surprising and undocumented.

**Fix:** Normalise keys up-front:

```elixir
defp normalize_entry(entry) do
  for {k, v} <- entry, into: %{}, do: {to_string(k), v}
end
```

Then drop the dual-key defensiveness in all helpers.

### WR-11: Dispatch model-string logic mis-routes slashed Ollama tags

**File:** `containers/glorbo-runtime/worker/dispatch.py:27-28`
**Issue:** `model_str = f"{provider}/{model}" if "/" not in model else model`. For `provider="ollama"` with `model="hf.co/user/model"` (a legitimate HuggingFace-hosted Ollama tag), `"/" in model` is true, so `model_str = "hf.co/user/model"` without the `ollama/` prefix, and litellm misroutes.

**Fix:** Only skip prefixing when the model already starts with a known provider slug:

```python
KNOWN_PROVIDER_PREFIXES = ("openrouter/", "together_ai/", "bedrock/")
if any(model.startswith(p) for p in KNOWN_PROVIDER_PREFIXES):
    model_str = model
else:
    model_str = f"{provider}/{model}"
```

Or document the no-slash-in-ollama-models convention and raise on violation.

### WR-12: BinaryBootstrap tar extraction lacks explicit absolute-path + owner flags

**File:** `lib/glorbo/init/binary_bootstrap.ex:134, 157`
**Issue:** `System.cmd("tar", ["-xzf", tar_gz, "-C", staging])` relies on default GNU tar behaviour to strip leading `/` and not preserve owner. Default behaviour IS safe, but a system tar built with `-P` default or a `$TAR_OPTIONS=-P` env leak could change that. Explicit is better.

**Fix:**
```elixir
System.cmd("tar", ["--no-absolute-names", "--no-same-owner", "-xzf", tar_gz, "-C", staging], ...)
System.cmd("tar", ["--no-absolute-names", "--no-same-owner", "--zstd", "-xf", tar_zst, "-C", staging], ...)
```

### WR-13: Formatter version captured at compile time

**File:** `lib/glorbo/doctor/formatter.ex:10`
**Issue:** `@version Mix.Project.config()[:version] || "0.1.0"` fixes the version at compile time. A release binary reused across environments reports the compile-time version even if the app spec version changed via release upgrade.

**Fix:** Runtime read:

```elixir
defp version do
  :glorbo |> Application.spec(:vsn) |> to_string()
end
```

### WR-14: Reindex MD5 computation lacks size cap

**File:** `lib/glorbo/filesystem/reindex.ex:142`
**Issue:** `File.read!(path)` loads the full file into memory for MD5. Frontmatter.parse/1 has a 10MB cap but reindex reads the file first, before the Frontmatter parser gets to reject it. A 2GB markdown file OOMs the BEAM.

**Fix:** Stat-check before read, stream-hash like `BinaryBootstrap.verify_sha256/2`:

```elixir
defp process_file(path) do
  stat = File.stat!(path)
  if stat.size > @max_file_bytes do
    {:skip, :too_large}
  else
    content = File.read!(path)
    digest = :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
    # ...
  end
end
```

### WR-15: Watcher does not monitor FileSystem subprocess

**File:** `lib/glorbo/filesystem/watcher.ex:52-53`
**Issue:** `FileSystem.start_link/1` is called without a monitor. If the inotify limit (`fs.inotify.max_user_watches`) is exceeded, the FileSystem proc crashes silently. The Watcher GenServer stays alive, thinking it's watching, but events never arrive. No self-diagnostic log appears.

**Fix:** Monitor the pid and treat DOWN as fatal:

```elixir
def init(opts) do
  # ...
  {:ok, pid} = FileSystem.start_link(dirs: [company_dir], recursive: true)
  FileSystem.subscribe(pid)
  Process.monitor(pid)
  {:ok, state}
end

def handle_info({:DOWN, _ref, :process, pid, reason}, %{fs_pid: pid} = state) do
  Logger.error("[watcher/#{state.company}] FileSystem process died: #{inspect(reason)}")
  {:stop, {:filesystem_down, reason}, state}
end
```

### WR-16: Worker _live_tasks is process-global — incompatible with multi-worker uvicorn

**File:** `containers/glorbo-runtime/worker/routes.py:30`
**Issue:** `_live_tasks` is module-global. If uvicorn is ever launched with `--workers 2+` (multi-process), `/cancel` routes to a random worker that may not hold the `request_id`. Also `--reload` on dev would reset the dict. `Invocation.build_argv/4` does not pass `--workers`, so this is currently single-process by accident, not contract.

**Fix:** Add a startup assertion in `worker/main.py`:

```python
import os
# /cancel relies on in-process state; multi-worker uvicorn would break routing.
assert int(os.getenv("WEB_CONCURRENCY", "1")) == 1, \
    "glorbo-agent-worker must run single-process"
```

Or document the constraint in `Invocation.build_argv/4`'s moduledoc so a future refactor doesn't silently add `--workers 4`.

## Info

### IN-01: context.py "company" path heuristic is fragile

**File:** `containers/glorbo-runtime/worker/context.py:67-75`
**Issue:** `_load_skills` searches for the literal string `"company"` in `task_path.parts`. Works because the bind-mount lands at `/company/`, but breaks if any user-named directory in a dev chain happens to be named `company`.

**Fix:** Use the `GLORBO_COMPANY` env var (already injected by `Invocation.build_argv/4`) or a fixed `GLORBO_COMPANY_ROOT=/company` env var:

```python
COMPANY_ROOT = Path(os.getenv("GLORBO_COMPANY_ROOT", "/company"))

def _load_skills(task_path: Path, skills: List[str]) -> List[str]:
    skills_dir = COMPANY_ROOT / "skills"
    return [
        (skills_dir / f"{s}.md").read_text()
        for s in skills
        if (skills_dir / f"{s}.md").exists()
    ]
```

### IN-02: ExampleCompany references README that is never scaffolded

**File:** `lib/glorbo/init/example_company.ex:101`, `lib/glorbo/init/orchestrator.ex:252`
**Issue:** Orchestrator's `build_next_steps/1` mentions `EXAMPLE_COMPANY_README.md`, but no such file is created by `ExampleCompany.scaffold!/1`. Operators following the next-steps hit a missing-file dead end.

**Fix:** Either scaffold the README, or remove the reference from `build_next_steps/1`.

### IN-03: Reindex.mark_dirty/2 discards failure reason

**File:** `lib/glorbo/filesystem/reindex.ex:43-47`
**Issue:** `mark_dirty/2` always returns `:ok`, swallowing `{:skip, reason}` from `process_path/2`. The watcher cannot surface "corrupt YAML" to operators; the only visibility is Logger.warning from inside the reindex.

**Fix:** Return the tagged tuple, let the watcher log on `{:skip, _}`:

```elixir
def mark_dirty(company, path), do: process_path(company, path)
```

Callers that want fire-and-forget can `_ = Reindex.mark_dirty(...)`.

### IN-04: ~/.glorbo default path duplicated across 10+ modules

**Files:** `lib/glorbo/container_manager.ex:90`, `lib/glorbo/container/invocation.ex:45`, `lib/glorbo/container/worker_client.ex:41`, `lib/glorbo/filesystem/hierarchy.ex:56`, `lib/glorbo/filesystem/reindex.ex:70`, `lib/glorbo/filesystem/watcher.ex:48`, `lib/glorbo/init/orchestrator.ex:49`, `lib/glorbo/init/binary_bootstrap.ex:82`, `lib/glorbo/doctor.ex:188, 248, 375`
**Issue:** `Path.expand("~/.glorbo")` is scattered. `Hierarchy.default_root/0` exists but is not the single source of truth.

**Fix:** Mechanical refactor: route every default through `Hierarchy.default_root/0`.

### IN-05: stubs_test.exs references modules that don't exist in Phase 2

**File:** `test/glorbo/stubs_test.exs:11-18`
**Issue:** `@modules` includes `Glorbo.Company.FileWatcher` (renamed to `Glorbo.Filesystem.Watcher`) and `Glorbo.Agent.Server` (not yet implemented). `Code.ensure_loaded?/1` returns false, the assertion fails.

**Fix:** Update to Phase 2 reality:

```elixir
@modules [
  Glorbo.ContainerManager,
  Glorbo.Filesystem.Watcher,
  Glorbo.Company.Router,
  Glorbo.Company.Scheduler,
  Glorbo.Company.BudgetTracker,
  Glorbo.Company.AuditLog
]
```

### IN-06: Example agent.md declares unreachable chat permissions

**File:** `lib/glorbo/init/example_company.ex:47-49`
**Issue:** `chat:write:general` and `chat:read:*` refer to a chat subsystem that does not exist until Phase 4. Operators inspecting the example and attempting to exercise chat get silent no-ops.

**Fix:** Either trim to Phase-2-reachable verbs or add a YAML comment:
```yaml
permissions:
  - projects:read:*
  - tasks:create:*
  - agents:list
  - budget:read:self
  # Phase 4+: chat:write:general, chat:read:*
```

### IN-07: Shared @base "/tmp/..." test module attributes

**Files:** `test/glorbo/container/invocation_test.exs:7`, `test/glorbo/container/worker_client_test.exs:7`
**Issue:** `@base "/tmp/glorbo-invocation-test"` is shared across tests in the module. Tests don't write to it so it's currently fine, but the pattern is brittle against future refactors and breaks hermeticity if two checkouts run tests in parallel.

**Fix:** Use `TmpGlorboHome.setup()` in a `setup` block.

### IN-08: podman exit code 125 not classified

**File:** `lib/glorbo/container_manager.ex:71-85, 106-114, 124-129`
**Issue:** `ensure_image/1`, `stop_container/1`, ephemeral launch — all treat any non-zero exit as one failure tag. Podman uses 125 (podman-level error), 126 (exec error), 127 (not found). Callers can't distinguish.

**Fix:** Low priority. Classify in Phase 3 when the Router needs finer-grained error recovery.

### IN-09: airplane_mode_test.exs Q-A3 disposition never surfaced

**File:** `test/integration/airplane_mode_test.exs:36-40`
**Issue:** Moduledoc references Q-A3 (litellm `unix://` support vs httpx fallback), but the test body doesn't distinguish which dispatch path was taken. A fallback shim silently passing looks identical to litellm native support.

**Fix:** Assert on `resp["result"]["model"]` or add a dispatch-path tag to the worker response.

### IN-10: Containerfile uses --break-system-packages

**File:** `containers/glorbo-runtime/Containerfile:28`
**Issue:** `pip3 install --break-system-packages` suppresses PEP 668. Pragmatic inside a container but a venv would be cleaner and makes future image extensions safer.

**Fix:** Optional — `RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt` + `ENV PATH=/opt/venv/bin:$PATH`.

### IN-11: Variable `or_` avoids `or` shadowing awkwardly

**File:** `lib/glorbo/init/orchestrator.ex:112-114`
**Issue:** `pr = podman_fun.(opts); or_ = ollama_fun.(opts); combine([pr, or_])` is hard to scan. Domain names would read better.

**Fix:**
```elixir
podman_result = podman_fun.(opts)
ollama_result = ollama_fun.(opts)
combine([podman_result, ollama_result])
```

### IN-12: Hierarchy writes empty string where touch! would read clearer

**File:** `lib/glorbo/filesystem/hierarchy.ex:43-46`
**Issue:** `File.write!(full, "")` is equivalent to `File.touch!(full)`, and the latter signals intent.

**Fix:**
```elixir
Enum.each(@files, fn {path, default} ->
  full = Path.join(base, path)
  unless File.exists?(full) do
    if default == "", do: File.touch!(full), else: File.write!(full, default)
  end
end)
```

### IN-13: Watcher via/1 declares cluster-unique name but no clustering exists

**File:** `lib/glorbo/filesystem/watcher.ex:42-43`
**Issue:** `{:global, {:glorbo_watcher, company}}` claims cluster-global uniqueness, but Phase 2 is single-node and there's no coordination for which node owns which watcher in a cluster scenario.

**Fix:** Phase 2 moot. Add a note in the moduledoc: "cluster coordination deferred to Phase N."

### IN-14: FastAPI /openapi.json still exposed despite docs being off

**File:** `containers/glorbo-runtime/worker/main.py:15`
**Issue:** `docs_url=None, redoc_url=None` disable HTML UIs but `/openapi.json` is still served. An agent-process client inside the container can GET it and enumerate routes.

**Fix:** `FastAPI(title="glorbo-agent-worker", docs_url=None, redoc_url=None, openapi_url=None)`.

### IN-15: Reindex spec loose on {:skip, reason} shape

**File:** `lib/glorbo/filesystem/reindex.ex:57`
**Issue:** `@spec process_path/2 :: :indexed | :unchanged | {:skip, term()}` is correct but unspecific. Could document the skip-reason taxonomy (`:too_large`, `{:yaml_error, _}`, etc.).

**Fix:** Refine once reasons stabilise. Phase 3 concern.

### IN-16: requirements.txt pins inconsistently

**File:** `containers/glorbo-runtime/requirements.txt:10-21`
**Issue:** Mix of `==X.Y.*` and `==X.*`. `pyyaml==6.*` is much broader than `fastapi==0.115.*`. For reproducibility, pin patch versions for first release.

**Fix:** Lock to exact versions in a commit; loosen only when an update is vetted.

### IN-17: airplane_mode_test.exs on_exit registered after destructive command

**File:** `test/integration/airplane_mode_test.exs:58-67`
**Issue:** `on_exit(fn -> nmcli networking on end)` is registered *after* `nmcli networking off` succeeds. If the test is SIGKILLed between those two lines, networking stays off until manual recovery. The code does NOT register the rollback before the failure-path `flunk`, so the off-command never ran — which is safe — but the happy-path ordering is fragile.

**Fix:** Register the rollback before running the destructive command. The rollback is idempotent (`nmcli networking on` on an already-on host is a no-op):

```elixir
on_exit(fn -> System.cmd("sudo", ["-n", "nmcli", "networking", "on"], stderr_to_stdout: true) end)

case System.cmd("sudo", ["-n", "nmcli", "networking", "off"], stderr_to_stdout: true) do
  {_, 0} -> :ok
  {out, code} -> flunk("Could not disable networking (exit #{code}): #{out}")
end
```

---

_Reviewed: 2026-04-16T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
