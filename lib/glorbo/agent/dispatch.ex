defmodule Glorbo.Agent.Dispatch do
  @moduledoc """
  Pure dispatch pipeline — budget-check, skills materialise, prompt write,
  adapter resolve, sandbox-run (via dep-injected `run_fun`), usage parse,
  budget record, cleanup.

  This module does NOT open a `Port` or invoke `bwrap`. Plan 03-05 supplies
  the real `Glorbo.Sandbox.Bwrap.start/2` via the `:run_fun` opt; v0.0.1
  unit tests pass a fake that returns a canned result. The pipeline is
  linear and observable:

  ```
  check_budget → resolve_workspace → prepare_run_dir →
    materialize skills → write prompt → resolve adapter →
    verify binary (D8 / provider.unavailable) → build argv → env →
    emit agent.dispatch audit → run_fun → compute duration →
    parse usage → record to BudgetTracker → emit agent.complete audit →
    cleanup run_dir
  ```

  `cleanup` runs in a `try/after` so it executes on ANY exit path
  (success, error, exception) — T-03-22 mitigation; no stale `.glorbo-run`
  directories leak skills or prompts across invocations.

  ## Dep-injected opts

  Every step is dep-injectable via `opts` so unit tests exercise the full
  pipeline without hitting the filesystem, a Port, the Budget GenServer,
  or the audit log:

    * `:base` — glorbo home dir (default `~/.glorbo`)
    * `:workspace_fun` — `(spec -> workspace_path)` (default derives from
      company/agent under `base`)
    * `:budget_tracker_fun` — `(spec -> :ok | {:stop, used, cap})`
    * `:record_usage_fun` — `(spec, task, usage -> :ok)`
    * `:adapter_registry` — `%{provider_string => Adapter module}`
      (default is the three v0.0.1 adapters)
    * `:run_fun` — `(argv, env, spec, ctx -> {:ok, result_map} | {:error,
      reason})`. `ctx` is a map containing resolved dispatch context
      (`prompt, workspace, run_dir, usage_dir, company_path, inbox_path,
      outbox_path, permissions, network_policy, cli_auth_binds, proxy_url,
      timeout_seconds`). Default is
      `&Glorbo.Sandbox.Bwrap.start/2`-based wiring that composes
      `invocation_opts` + `run_opts` from spec + ctx. Legacy 3-arity
      run_funs (returning a 3-arg function) are still supported for
      backward compatibility with existing test callers.
    * `:audit_fun` — `(company, entry -> any)`
    * `:fs_fun` — map of filesystem ops (`mkdir_p!`, `write!`, `rm_rf!`)
    * `:clock_fun` — `(-> integer)` monotonic time for duration; default
      `System.monotonic_time(:millisecond)`
    * `:parse_usage_fun` — override per-adapter usage parsing (for tests
      wanting to stub that step)

  ## Prompt size cap (Pitfall 8 / T-03-23)

  `execute/3` returns `{:error, :prompt_too_large}` when `task.prompt`
  exceeds 5 MB. Prevents stdin-block scenarios on large prompts where the
  CLI hangs waiting for EOF.
  """
  require Logger

  alias Glorbo.CLI.Adapter.ClaudeCode
  alias Glorbo.CLI.Adapter.Codex
  alias Glorbo.CLI.Adapter.GeminiCli
  alias Glorbo.Company.AuditLog
  alias Glorbo.Sandbox.Bwrap
  alias Glorbo.Skills.Resolver

  @prompt_max_bytes 5 * 1024 * 1024

  @default_adapter_registry %{
    "claude-code" => ClaudeCode,
    "gemini-cli" => GeminiCli,
    "codex" => Codex
  }

  @type task :: %{
          required(:task_id) => String.t(),
          required(:task_path) => String.t(),
          required(:prompt) => String.t(),
          required(:trigger) => atom()
        }

  @type dispatch_result ::
          {:ok, %{exit_status: integer(), usage: map(), duration_ms: integer()}}
          | {:stopped, :budget_hard_stop}
          | {:error, term()}

  @doc """
  Execute a single dispatch for `spec` + `task`.
  """
  @spec execute(Glorbo.Agent.Spec.t(), task(), keyword()) :: dispatch_result()
  def execute(%_{} = spec, %{} = task, opts \\ []) do
    run_dir = prepare_run_dir_path(spec, task, opts)

    try do
      do_execute(spec, task, run_dir, opts)
    after
      cleanup_run_dir(run_dir, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Core pipeline
  # ---------------------------------------------------------------------------

  defp do_execute(spec, task, run_dir, opts) do
    with :ok <- check_prompt_size(task.prompt),
         :ok <- check_budget(spec, opts),
         {:ok, adapter} <- resolve_adapter(spec, opts),
         :ok <- verify_binary(spec, adapter, opts),
         {:ok, workspace} <- ensure_workspace(spec, opts),
         :ok <- materialize_skills(spec, run_dir, opts),
         :ok <- write_prompt(run_dir, task.prompt, opts),
         argv <- adapter.args(spec, prompt_path(run_dir), []),
         env <- adapter.env(spec, workspace),
         ctx <- build_run_ctx(spec, task, adapter, workspace, run_dir, opts),
         :ok <- emit_dispatch_audit(spec, task, opts),
         start <- clock(opts),
         {:ok, run_result} <- invoke_run_fun(argv, env, spec, ctx, opts),
         duration_ms <- compute_duration(start, opts),
         {:ok, usage} <- parse_usage_for(adapter, spec, workspace, run_result, opts),
         :ok <- record_usage(spec, task, usage, opts),
         :ok <- emit_complete_audit(spec, task, run_result, duration_ms, opts) do
      {:ok, %{exit_status: run_result[:exit_status] || 0, usage: usage, duration_ms: duration_ms}}
    else
      {:stop, _used, _cap} ->
        {:stopped, :budget_hard_stop}

      {:error, :prompt_too_large} ->
        {:error, :prompt_too_large}

      {:error, :provider_unavailable} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        Logger.warning("dispatch failed for #{spec.slug}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp check_prompt_size(prompt) when is_binary(prompt) do
    if byte_size(prompt) > @prompt_max_bytes, do: {:error, :prompt_too_large}, else: :ok
  end

  defp check_budget(spec, opts) do
    fun = Keyword.get(opts, :budget_tracker_fun, fn _ -> :ok end)

    case fun.(spec) do
      :ok -> :ok
      {:alert, _used, _cap} -> :ok
      {:stop, used, cap} -> {:stop, used, cap}
      other -> other
    end
  end

  defp resolve_adapter(spec, opts) do
    registry = Keyword.get(opts, :adapter_registry, @default_adapter_registry)

    case Map.fetch(registry, spec.provider) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_provider, spec.provider}}
    end
  end

  defp verify_binary(spec, adapter, opts) do
    binary_fun = Keyword.get(opts, :binary_fun, fn mod -> mod.binary() end)

    case binary_fun.(adapter) do
      nil ->
        emit_unavailable_audit(spec, opts)
        {:error, :provider_unavailable}

      path when is_binary(path) ->
        :ok
    end
  end

  defp ensure_workspace(spec, opts) do
    fun =
      Keyword.get(opts, :workspace_fun, fn ->
        base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
        Path.join([base, "companies", spec.company, "agents", spec.slug, "workspace"])
      end)

    path = if is_function(fun, 0), do: fun.(), else: fun.(spec)
    fs = fs_fun(opts)
    fs.mkdir_p!.(path)
    {:ok, path}
  end

  defp materialize_skills(spec, run_dir, opts) do
    target = Path.join(run_dir, ".glorbo-skills")

    skills_opts = [
      base: Keyword.get(opts, :base, Path.expand("~/.glorbo")),
      company: spec.company,
      agent_slug: spec.slug,
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.append/2)
    ]

    case Resolver.materialize(spec.skills, target, skills_opts) do
      {:ok, _resolved} -> :ok
      {:error, _} = err -> err
    end
  end

  defp write_prompt(run_dir, prompt, opts) do
    fs = fs_fun(opts)
    fs.mkdir_p!.(run_dir)
    fs.write!.(prompt_path(run_dir), prompt)
    :ok
  end

  defp invoke_run_fun(argv, env, spec, ctx, opts) do
    fun = Keyword.get(opts, :run_fun, &default_bwrap_run_fun/4)
    result = call_run_fun(fun, argv, env, spec, ctx)

    case result do
      {:ok, r} when is_map(r) -> {:ok, r}
      {:error, _} = err -> err
      other -> {:error, {:run_fun_bad_return, other}}
    end
  end

  # Dispatch the run_fun honouring both the 4-arity (new, ctx-aware) and
  # 3-arity (legacy) signatures. Test callers in this codebase still pass
  # 3-arg funs; production Agent.Server wires the 4-arg
  # default_bwrap_run_fun/4.
  defp call_run_fun(fun, argv, env, spec, ctx) when is_function(fun, 4),
    do: fun.(argv, env, spec, ctx)

  defp call_run_fun(fun, argv, env, spec, _ctx) when is_function(fun, 3),
    do: fun.(argv, env, spec)

  # Build the run context fed to the run_fun. Everything the default
  # Bwrap wiring needs to assemble an invocation — resolved from spec,
  # task, adapter, and pre-computed workspace/run_dir.
  defp build_run_ctx(spec, task, adapter, workspace, run_dir, opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    company_path = Path.join([base, "companies", spec.company])
    agent_dir = Path.join([company_path, "agents", spec.slug])

    usage_dir =
      case adapter.usage_path(spec, workspace) do
        {:jsonl_dir, dir} -> dir
        {:jsonl_file, path} -> Path.dirname(path)
        :stdout -> nil
      end

    %{
      prompt: task.prompt,
      workspace: workspace,
      run_dir: run_dir,
      usage_dir: usage_dir,
      company_path: company_path,
      inbox_path: Path.join(agent_dir, "inbox"),
      outbox_path: Path.join(agent_dir, "outbox"),
      permissions: spec.permissions,
      network_policy: spec.network,
      cli_auth_binds: Keyword.get(opts, :cli_auth_binds, []),
      proxy_url: Keyword.get(opts, :proxy_url),
      timeout_seconds: spec.timeout_seconds,
      adapter: adapter
    }
  end

  # Default run_fun: compose Bwrap invocation_opts + run_opts from ctx/spec,
  # call Glorbo.Sandbox.Bwrap.start/2, normalise the return shape.
  @doc false
  def default_bwrap_run_fun(_argv, env, spec, ctx) do
    adapter = ctx.adapter

    invocation_opts = %{
      agent_workspace: ctx.workspace,
      inbox_path: ctx.inbox_path,
      outbox_path: ctx.outbox_path,
      company_path: ctx.company_path,
      permissions: ctx.permissions,
      network_policy: ctx.network_policy,
      cli_auth_binds: ctx.cli_auth_binds,
      cli_env: env,
      proxy_url: ctx.proxy_url,
      timeout_seconds: ctx.timeout_seconds
    }

    cli_binary = adapter.binary()
    prompt_path_in_run_dir = prompt_path(ctx.run_dir)

    run_opts = [
      cli_binary: cli_binary,
      cli_args: adapter.args(spec, prompt_path_in_run_dir, []),
      prompt: ctx.prompt,
      usage_dir: ctx.usage_dir
    ]

    Bwrap.start(invocation_opts, run_opts)
  end

  defp compute_duration(start, opts) do
    now = clock(opts)
    max(now - start, 0)
  end

  defp parse_usage_for(adapter, spec, workspace, run_result, opts) do
    override = Keyword.get(opts, :parse_usage_fun)

    if is_function(override, 4) do
      {:ok, override.(adapter, spec, workspace, run_result)}
    else
      do_default_parse_usage(adapter, spec, workspace, run_result)
    end
  end

  defp do_default_parse_usage(adapter, spec, workspace, run_result) do
    case adapter.usage_path(spec, workspace) do
      :stdout ->
        blob = run_result[:stdout] || ""
        finalize_parse(adapter.parse_usage({:stdout, blob}), spec)

      {:jsonl_dir, dir} ->
        parse_from_dir(adapter, spec, dir)

      {:jsonl_file, path} ->
        finalize_parse(adapter.parse_usage({:jsonl_file, path}), spec)
    end
  end

  defp parse_from_dir(adapter, spec, dir) do
    case latest_jsonl(dir) do
      nil -> conservative_zero({:error, :no_usage_file}, spec)
      path -> finalize_parse(adapter.parse_usage({:jsonl_file, path}), spec)
    end
  end

  defp finalize_parse({:ok, usage}, spec), do: {:ok, fill_model(usage, spec)}
  defp finalize_parse({:error, _} = err, spec), do: conservative_zero(err, spec)

  # Pitfall 5: record 0 tokens when usage is missing/malformed rather than
  # crash dispatch. Dispatch still emits agent.complete — just with zero
  # usage and a Logger.warning noting the cause.
  defp conservative_zero({:error, reason}, spec) do
    Logger.warning(
      "dispatch.usage_parse_error: agent=#{spec.slug} reason=#{inspect(reason)} — recording 0 tokens (Pitfall 5)"
    )

    {:ok, %{prompt_tokens: 0, completion_tokens: 0, model: spec.model}}
  end

  defp fill_model(%{model: nil} = usage, spec), do: %{usage | model: spec.model}
  defp fill_model(usage, _spec), do: usage

  defp latest_jsonl(dir) do
    # WR-09: use File.stat/1 (non-bang) and skip entries whose stat fails —
    # CLI tools rotate session files concurrently, so a file listed by
    # File.ls/1 can disappear before we stat it. File.stat! would raise
    # File.Error, escape the caller's `with` via unwind, and cause
    # conservative_zero recovery to be skipped → lost usage record →
    # budget undercount.
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
          [{path, _mtime} | _] -> path
        end

      _ ->
        nil
    end
  end

  defp record_usage(spec, task, usage, opts) do
    fun = Keyword.get(opts, :record_usage_fun, fn _spec, _task, _usage -> :ok end)
    fun.(spec, task, usage)
    :ok
  rescue
    e ->
      Logger.warning("dispatch.record_usage failed: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Run-dir lifecycle
  # ---------------------------------------------------------------------------

  defp prepare_run_dir_path(spec, task, opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))

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
  end

  defp cleanup_run_dir(run_dir, opts) do
    override = Keyword.get(opts, :cleanup_fun)

    if is_function(override, 1) do
      override.(run_dir)
    else
      Resolver.cleanup(run_dir)
    end
  end

  defp prompt_path(run_dir), do: Path.join(run_dir, "task-prompt.md")

  # ---------------------------------------------------------------------------
  # Audit emission
  # ---------------------------------------------------------------------------

  defp emit_dispatch_audit(spec, task, opts) do
    audit = Keyword.get(opts, :audit_fun, &AuditLog.append/2)

    entry = %{
      action: "agent.dispatch",
      actor: "system",
      agent: spec.slug,
      task_path: task.task_path,
      provider: spec.provider,
      model: spec.model,
      container_id: "bwrap-inline"
    }

    audit.(spec.company, entry)
    :ok
  rescue
    e ->
      Logger.warning("dispatch audit emit failed: #{Exception.message(e)}")
      :ok
  end

  defp emit_complete_audit(spec, task, run_result, duration_ms, opts) do
    audit = Keyword.get(opts, :audit_fun, &AuditLog.append/2)

    entry = %{
      action: "agent.complete",
      actor: spec.slug,
      agent: spec.slug,
      task_path: task.task_path,
      duration_ms: duration_ms,
      exit_status: to_string(run_result[:exit_status] || 0)
    }

    audit.(spec.company, entry)
    :ok
  rescue
    e ->
      Logger.warning("dispatch complete audit emit failed: #{Exception.message(e)}")
      :ok
  end

  defp emit_unavailable_audit(spec, opts) do
    audit = Keyword.get(opts, :audit_fun, &AuditLog.append/2)

    entry = %{
      action: "provider.unavailable",
      actor: "system",
      agent: spec.slug,
      provider: spec.provider
    }

    audit.(spec.company, entry)
    :ok
  rescue
    e ->
      Logger.warning("provider.unavailable audit emit failed: #{Exception.message(e)}")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp clock(opts) do
    fun = Keyword.get(opts, :clock_fun, fn -> System.monotonic_time(:millisecond) end)
    fun.()
  end

  defp fs_fun(opts) do
    Keyword.get(opts, :fs_fun, %{
      mkdir_p!: &File.mkdir_p!/1,
      write!: &File.write!/2,
      rm_rf!: &File.rm_rf!/1
    })
  end
end
