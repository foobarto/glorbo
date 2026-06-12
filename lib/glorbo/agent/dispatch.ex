defmodule Glorbo.Agent.Dispatch do
  @moduledoc """
  Pure dispatch pipeline (post-GEP-8 rewrite).

  Responsibilities:

    1. Enforce the prompt size cap (5 MiB; mitigates stdin-block hangs).
    2. Check the per-agent budget.
    3. Resolve the provider from `Glorbo.CLI.Registry` (by `spec.provider`).
    4. Refuse if provider has `usage_parser = "none"` and agent's
       `agent.md` lacks `allow_untracked_budget: true` (GEP-8 D15).
    5. Ensure workspace + run_dir exist; materialise skills.
    6. Write the prompt file (audit + stdin source).
    7. Invoke via `Glorbo.CLI.Dispatcher.invoke/3` — which expands
       templates, runs the CLI in the sandbox, reads the reply file,
       and parses usage.
    8. Record usage (if tracked); emit audit events; cleanup run_dir.

  ## Dep-injected opts

  Every filesystem / process / time call is dep-injectable so tests
  exercise the full pipeline without hitting disk, the Registry
  process, or the sandbox.

    * `:base` — glorbo home dir (default `~/.glorbo`).
    * `:workspace_fun` — `(spec -> workspace)`.
    * `:budget_tracker_fun` — `(spec -> :ok | {:alert, ...} | {:stop, ...})`.
    * `:record_usage_fun` — `(spec, task, usage -> :ok)`.
    * `:provider_fun` — `(provider_name -> Provider.t() | nil)` — default
      reads from `Glorbo.CLI.Registry`. Tests pass a function returning
      a handcrafted Provider struct.
    * `:run_fun` — passed through to Dispatcher.invoke (see
      `Glorbo.CLI.Dispatcher`).
    * `:audit_fun` — `(company, entry -> any)`.
    * `:fs_fun` — map of filesystem ops.
    * `:clock_fun` — monotonic clock for duration measurement.

  ## Cleanup guarantee

  `execute/3` runs under `try/after` so `.glorbo-run/<task_id>` is
  always cleaned, regardless of error, timeout, or exception
  (T-03-22).
  """
  require Logger

  alias Glorbo.CLI.Dispatcher
  alias Glorbo.CLI.Registry
  alias Glorbo.Company.AuditLog
  alias Glorbo.Skills.Resolver

  @prompt_max_bytes 5 * 1024 * 1024

  # C-033: `usage.json` is sandbox-visible and attacker-controlled — a
  # compromised provider CLI can emit an arbitrarily long `audit_events`
  # array (or oversized target/detail strings) so the dispatcher performs
  # thousands of fsync'd audit writes, flooding the append-only audit log
  # and exhausting disk/IO. Cap both the event COUNT per dispatch and the
  # per-string byte size before any audit write.
  @max_tool_audit_events 50
  @max_tool_audit_target_bytes 1_024
  @max_tool_audit_detail_bytes 4_096

  @type task :: %{
          required(:task_id) => String.t(),
          required(:task_path) => String.t(),
          required(:prompt) => String.t(),
          required(:trigger) => atom()
        }

  @type dispatch_result ::
          {:ok, %{exit_status: integer(), usage: map(), duration_ms: integer()}}
          | {:stopped, :budget_hard_stop}
          | {:throttled, :company_dispatch_cap}
          | {:error, term()}

  @doc """
  Execute a single dispatch for `spec` + `task`.
  """
  @spec execute(Glorbo.Agent.Spec.t(), task(), keyword()) :: dispatch_result()
  def execute(%_{} = spec, %{} = task, opts \\ []) do
    # #248 T1-A — session resilience: retry on recoverable failures
    # (:timeout, :reply_file_missing) up to `spec.max_retries` times.
    # Other errors don't retry — config failures don't self-resolve.
    attempt_with_retries(spec, task, opts, 0)
  end

  defp attempt_with_retries(spec, task, opts, attempt) do
    run_dir = prepare_run_dir_path(spec, task, opts)

    result =
      try do
        do_execute(spec, task, run_dir, opts)
      after
        cleanup_run_dir(run_dir, opts)
      end

    max = Map.get(spec, :max_retries, 2)

    if retryable?(result) and attempt < max do
      # C-087: a malicious provider can do expensive work and then time
      # out / omit the reply file so the failed attempt's cost is never
      # recorded. Re-run the budget gate BEFORE burning another attempt
      # so retries are capped against budget — an agent that has already
      # crossed its (per-agent or per-company) cap is stopped here
      # instead of getting `max_retries` more free invocations. This
      # turns the unbounded "retry regardless of spend" loop into one
      # bounded by both `max_retries` AND the budget ledger.
      case retry_budget_gate(spec, opts) do
        {:stop, _used, _cap} ->
          {:stopped, :budget_hard_stop}

        :ok ->
          emit_retry_audit(spec, task, result, attempt + 1, opts)
          retry_task = build_retry_task(task, result, attempt + 1)
          attempt_with_retries(spec, retry_task, opts, attempt + 1)
      end
    else
      result
    end
  end

  # C-087: pre-retry budget gate. Mirrors the in-pipeline `check_budget`
  # / `check_company_budget` steps but runs in `attempt_with_retries`
  # *between* attempts so the decision to retry sees the budget. Treats
  # `:alert` as "may proceed" (same contract as the pipeline) and any
  # `:stop` (agent- or company-level) as a hard stop.
  defp retry_budget_gate(spec, opts) do
    with :ok <- check_budget(spec, opts),
         :ok <- check_company_budget(spec, opts) do
      :ok
    else
      {:stop, used, cap} -> {:stop, used, cap}
      _other -> :ok
    end
  end

  # Retryable failures are the ones a retry can plausibly fix.
  # `:timeout` — provider stalled; another turn often gets through.
  # `:reply_file_missing` — agent finished without writing the reply
  #   file (forgot the contract); the retry note reminds them.
  # `:reply_file_empty` — same shape: the file exists but the body
  #   is empty. Often a one-turn model glitch (e.g. completion
  #   truncated to nothing); retry with the same conservative-
  #   tool-use reminder.
  # `:provider_unavailable` — the per-dispatch provider lookup
  #   transiently failed (network flap, registry mid-reload). Real
  #   outages exhaust `max_retries` quickly anyway and surface as
  #   a stuck sentinel via `LoopDetector`; retrying twice is far
  #   cheaper than a Director ping.
  # Everything else stays non-retryable (config errors, security
  #  refusals, prompt-too-large) — a retry would loop forever.
  defp retryable?({:error, :timeout}), do: true
  defp retryable?({:error, :reply_file_missing}), do: true
  defp retryable?({:error, :reply_file_empty}), do: true
  defp retryable?({:error, :provider_unavailable}), do: true
  defp retryable?(_), do: false

  defp build_retry_task(task, {:error, reason}, attempt) do
    note =
      """

      ---
      ## Retry ##{attempt}

      The previous attempt ended with #{inspect(reason)}. Try again —
      be more conservative with tool use, and write the reply file
      before wrapping up.
      """

    Map.update(task, :prompt, note, &(&1 <> note))
  end

  defp emit_retry_audit(spec, task, {:error, reason}, attempt, opts) do
    audit = audit_fun(opts)

    try do
      audit.(spec.company, %{
        company: spec.company,
        actor: "system",
        action: "agent.retry",
        target: task.task_path,
        agent: spec.slug,
        attempt: attempt,
        reason: inspect(reason)
      })
    rescue
      _ -> :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Core pipeline
  # ---------------------------------------------------------------------------

  defp do_execute(spec, task, run_dir, opts) do
    # Generate the invocation_id up-front so `agent.dispatch` and
    # `agent.complete` audit entries carry the same id — that's what
    # lets the AgentLive Runs tab group before/after events into a
    # single run record. Tests inject via `:invocation_id_fun` (a
    # zero-arity function returning the deterministic id).
    invocation_id =
      case Keyword.get(opts, :invocation_id_fun) do
        nil -> gen_invocation_id()
        fun when is_function(fun, 0) -> fun.()
      end

    # GEP-23 Phase 5: allocate the per-dispatch proxy token BEFORE the
    # with-pipeline so the `after` at the bottom can revoke it on any
    # exit — success, error, or exception. `proxy_token_result` is
    # `{:ok, url, token}` for `:proxy` agents, `{:ok, nil, nil}` for
    # others, `{:error, _}` for registration / URL-builder failure.
    dispatch_timeout_s = Map.get(spec, :timeout_seconds, 300)
    proxy_token_result = resolve_proxy_url(spec, invocation_id, dispatch_timeout_s, opts)

    # GEP-0055: mint a second per-dispatch token for the in-process
    # inference proxy — only when the resolved provider has
    # `auth = "via_proxy"`. The provider is resolved up-front (same
    # registry lookup the with-pipeline consumes below) so the mint
    # can key off `provider.auth` and carry `provider.name` as the
    # token's `provider_alias`. The token reaches the sandbox as
    # `GLORBO_PROXY_TOKEN`; the listener resolves it per request to
    # attribute the call and select the upstream. Revoked in the
    # cleanup section at the bottom of this function, next to the
    # GEP-23 token.
    provider_result = resolve_provider(spec, task, opts)

    openai_proxy_result =
      case provider_result do
        {:ok, %{auth: :via_proxy} = provider} ->
          resolve_openai_proxy_token(spec, provider, invocation_id, dispatch_timeout_s, opts)

        _ ->
          {:ok, nil, nil}
      end

    proxy_token =
      case proxy_token_result do
        {:ok, _url, token} -> token
        _ -> nil
      end

    {openai_proxy_url, openai_proxy_token} =
      case openai_proxy_result do
        {:ok, url, token} -> {url, token}
        _ -> {nil, nil}
      end

    # GEP-46: claim a per-company dispatch slot. `:throttled` propagates
    # back to the caller so `Agent.Server` can fall back into its
    # pending_wake slot and retry on the next slot-free signal. The
    # token is released in the bottom of this function regardless of
    # success or failure.
    semaphore_result = acquire_dispatch_slot(spec, invocation_id, opts)

    semaphore_token =
      case semaphore_result do
        {:ok, token} -> token
        _ -> nil
      end

    result =
      with {:ok, _slot_token} <- semaphore_result,
           :ok <- check_emergency_stop(spec, opts),
           :ok <- check_prompt_size(task.prompt),
           :ok <- check_budget(spec, opts),
           :ok <- check_company_budget(spec, opts),
           {:ok, provider} <- provider_result,
           :ok <- check_untracked_allowed(spec, provider, opts),
           :ok <- verify_installed(spec, provider, opts),
           {:ok, proxy_url, _token} <- proxy_token_result,
           # GEP-0055: {:ok, nil, nil} for non-via_proxy providers; a
           # via_proxy provider whose proxy is unreachable (or whose
           # agent isn't `network: :proxy`) fails the dispatch here,
           # loudly, before the sandbox boots.
           {:ok, _openai_url, _openai_token} <- openai_proxy_result,
           {:ok, cli_binary} <- resolve_cli_binary(provider, opts),
           {:ok, workspace} <- ensure_workspace(spec, opts),
           :ok <- materialize_skills(spec, run_dir, opts),
           :ok <- write_prompt(run_dir, task.prompt, opts),
           :ok <- emit_dispatch_audit(spec, task, provider, invocation_id, opts),
           start <- clock(opts),
           ctx <-
             build_ctx(
               spec,
               task,
               workspace,
               run_dir,
               provider,
               %{
                 proxy_url: proxy_url,
                 invocation_id: invocation_id,
                 cli_binary: cli_binary,
                 openai_proxy_url: openai_proxy_url,
                 openai_proxy_token: openai_proxy_token
               },
               opts
             ),
           {:ok, dispatcher_result} <- Dispatcher.invoke(provider, ctx, dispatcher_opts(opts)),
           :ok <- check_runtime_untracked_allowed(spec, dispatcher_result, opts),
           duration_ms <- compute_duration(start, opts),
           usage <- finalize_usage(dispatcher_result, spec, task),
           :ok <- record_usage(spec, task, usage, opts),
           :ok <- emit_tool_audits(spec, task, usage, invocation_id, opts),
           merged_result <- Map.put(dispatcher_result, :usage, usage),
           :ok <-
             emit_complete_audit(spec, task, merged_result, duration_ms, invocation_id, opts),
           :ok <- maybe_auto_mark_task_done(task, dispatcher_result),
           :ok <- maybe_check_loop(spec, opts),
           :ok <- maybe_check_task_budget(spec, task, usage, opts) do
        {:ok,
         %{
           exit_status: dispatcher_result.exit_status,
           usage: usage,
           duration_ms: duration_ms,
           reply: dispatcher_result.reply,
           reply_path: dispatcher_result.reply_path
         }}
      else
        :throttled ->
          {:throttled, :company_dispatch_cap}

        {:stop, _used, _cap} ->
          {:stopped, :budget_hard_stop}

        {:error, :emergency_stopped} ->
          Logger.info("dispatch refused: #{spec.company} is emergency-stopped")
          {:error, :emergency_stopped}

        {:error, :prompt_too_large} ->
          {:error, :prompt_too_large}

        {:error, :provider_unavailable} ->
          {:error, :provider_unavailable}

        {:error, {:unknown_provider, _} = reason} ->
          Logger.warning("dispatch: unknown provider for #{spec.slug}: #{inspect(reason)}")
          {:error, :unknown_provider}

        {:error, :untracked_disallowed} = err ->
          err

        {:error, reason} ->
          Logger.warning("dispatch failed for #{spec.slug}: #{inspect(reason)}")
          {:error, reason}
      end

    # GEP-27: revoke any approved external paths after dispatch completes
    # (success or failure). Grants are task-scoped and ephemeral.
    _ = Glorbo.PathGrantStore.revoke(spec.company, spec.slug, task.task_id)

    # GEP-23 Phase 5: revoke the per-dispatch proxy token. Tokens
    # have a 2× timeout expiry as a failsafe, but immediate revocation
    # keeps the in-memory registry size proportional to concurrent
    # dispatches, not cumulative ones.
    if proxy_token, do: _ = Glorbo.Network.ProxyTokens.revoke(proxy_token)

    # GEP-0055: revoke the inference-proxy token on the same
    # boundary. A replayed token after this point gets the
    # listener's 401 (`token unknown or expired`).
    if openai_proxy_token, do: _ = Glorbo.Network.ProxyTokens.revoke(openai_proxy_token)

    # GEP-46: release the per-company dispatch slot. Semaphore monitors
    # the holder pid as a safety net, but immediate release keeps the
    # in_flight map size proportional to live dispatches, not cumulative.
    release_dispatch_slot(spec, semaphore_token, opts)

    result
  end

  # ---------------------------------------------------------------------------
  # Steps
  # ---------------------------------------------------------------------------

  defp check_prompt_size(prompt) when is_binary(prompt) do
    if byte_size(prompt) > @prompt_max_bytes, do: {:error, :prompt_too_large}, else: :ok
  end

  # GEP-46: acquire a per-company dispatch slot via
  # `Glorbo.Company.DispatchSemaphore`. `:throttled` propagates up so
  # the caller can queue and retry. Tests inject `:dispatch_semaphore_fun`
  # to bypass the real GenServer (a 0-arity function returning
  # `{:ok, token}` keeps the contract simple).
  defp acquire_dispatch_slot(spec, invocation_id, opts) do
    fun =
      Keyword.get(opts, :dispatch_semaphore_fun, fn ->
        server = Glorbo.Company.Supervisor.via(spec.company, :dispatch_semaphore)

        try do
          Glorbo.Company.DispatchSemaphore.acquire(server, %{
            agent: spec.slug,
            invocation_id: invocation_id
          })
        catch
          # Semaphore not running (test harnesses without a Company.Supervisor,
          # or boot-order edge case): fall through to allow the dispatch.
          # The cap is observability/throttling, not a security boundary
          # (GEP-46 D7).
          :exit, _ -> {:ok, :unsupervised}
        end
      end)

    case fun.() do
      {:ok, token} -> {:ok, token}
      :throttled -> :throttled
      _ -> {:ok, :unsupervised}
    end
  end

  defp release_dispatch_slot(_spec, nil, _opts), do: :ok
  defp release_dispatch_slot(_spec, :unsupervised, _opts), do: :ok

  defp release_dispatch_slot(spec, token, opts) do
    fun =
      Keyword.get(opts, :dispatch_semaphore_release_fun, fn ->
        server = Glorbo.Company.Supervisor.via(spec.company, :dispatch_semaphore)

        try do
          Glorbo.Company.DispatchSemaphore.release(server, token)
        catch
          :exit, _ -> :ok
        end
      end)

    fun.()
    :ok
  end

  # T2-C — refuse dispatch when the company's emergency-stop sentinel
  # is present. Dep-injectable so tests can toggle the check without
  # touching disk.
  defp check_emergency_stop(spec, opts) do
    fun =
      Keyword.get(opts, :emergency_stop_fun, fn company ->
        Glorbo.EmergencyStop.engaged?(company,
          base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
        )
      end)

    if fun.(spec.company) do
      {:error, :emergency_stopped}
    else
      :ok
    end
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

  # #245 per-company cap check. Fires after per-agent `check_budget`
  # so agent-level `{:stop, ...}` keeps its existing contract. On
  # company-level overshoot we return the same shape so the outer
  # `with` converts it to {:stopped, :budget_hard_stop}.
  defp check_company_budget(spec, opts) do
    fun =
      Keyword.get(opts, :company_budget_fun, fn company ->
        Glorbo.Budget.CompanyCap.check(company,
          base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
        )
      end)

    case fun.(spec.company) do
      :ok -> :ok
      {:alert, _used, _cap} -> :ok
      {:stop, used, cap} -> {:stop, used, cap}
      other -> other
    end
  end

  # #235 per-task override: task's :provider can ONLY pin to the
  # agent's own spec.provider. threatmodel M10: accepting any
  # provider from task frontmatter let an agent with tasks:write
  # pick a more-privileged provider whose auth_binds mount host
  # secrets. Provider is now derived from the agent spec; the
  # `task.provider` hint is only respected when it equals
  # `spec.provider` (exact match) — any mismatch is logged and
  # ignored. Per-task *model* selection (task.model) is still
  # handled elsewhere via the agent's own model alias map, which
  # was never the attack surface.
  defp resolve_provider(spec, task, opts) do
    fun = Keyword.get(opts, :provider_fun, &Registry.get/1)
    name = reconcile_task_provider(task, spec)

    case fun.(name) do
      nil -> {:error, {:unknown_provider, name}}
      %{} = provider -> {:ok, provider}
    end
  end

  defp reconcile_task_provider(%{provider: p}, spec)
       when is_binary(p) and p != "" and p != "" do
    if p == spec.provider do
      p
    else
      require Logger

      Logger.warning(
        "ignoring task.provider=#{inspect(p)} != agent.provider=#{inspect(spec.provider)}; pinning to agent spec (threatmodel M10)"
      )

      spec.provider
    end
  end

  defp reconcile_task_provider(_, spec), do: spec.provider

  # #236 — resolve task's `model:` value. If it matches a named alias
  # in `spec.models`, expand to the concrete model name. Otherwise
  # treat it as a literal model string. Concrete-name overrides still
  # work, preserving #235 semantics.
  defp task_model_override(%{model: m}, spec) when is_binary(m) and m != "" do
    case Map.get(spec.models || %{}, m) do
      nil -> m
      concrete when is_binary(concrete) -> concrete
    end
  end

  defp task_model_override(_task, _spec), do: nil

  defp check_untracked_allowed(spec, %{usage_parser: "none"}, _opts) do
    if Map.get(spec, :allow_untracked_budget) == true do
      :ok
    else
      Logger.warning(
        "dispatch: agent #{spec.slug} lacks allow_untracked_budget; cannot route to untracked provider"
      )

      {:error, :untracked_disallowed}
    end
  end

  defp check_untracked_allowed(_spec, _provider, _opts), do: :ok

  defp check_runtime_untracked_allowed(spec, %{usage: %{tracked: false}}, _opts) do
    if Map.get(spec, :allow_untracked_budget) == true do
      :ok
    else
      Logger.warning(
        "dispatch: agent #{spec.slug} lacks allow_untracked_budget; runtime usage was untracked"
      )

      {:error, :untracked_disallowed}
    end
  end

  # Gemini round-3 finding: only the `tracked: false` shape was
  # gated. A usage parser that crashes or a provider that emits
  # un-parseable output yields `%{usage: nil, usage_error: <reason>}`
  # — that map fell through the wildcard catch-all and skipped
  # budget enforcement entirely. A malicious agent could
  # deliberately corrupt its `usage.json` (or pick a provider whose
  # parser crashes on its output) to record zero spend against a
  # tracked-only budget. Use the `:usage_error` field to
  # differentiate intentional skip (`usage: nil, usage_error: nil`
  # for the `"none"` parser — already caught at pre-flight by
  # `check_untracked_allowed/3`) from parse failure (`usage_error`
  # set). Only the parse-failure path is the bypass.
  defp check_runtime_untracked_allowed(spec, %{usage: nil, usage_error: err}, _opts)
       when not is_nil(err) do
    if Map.get(spec, :allow_untracked_budget) == true do
      :ok
    else
      Logger.warning(
        "dispatch: agent #{spec.slug} lacks allow_untracked_budget; " <>
          "runtime usage parse failed (#{inspect(err)})"
      )

      {:error, :untracked_disallowed}
    end
  end

  defp check_runtime_untracked_allowed(_spec, _dispatcher_result, _opts), do: :ok

  defp verify_installed(spec, provider, opts) do
    if provider_available?(provider) do
      :ok
    else
      emit_unavailable_audit(spec, provider, opts)
      {:error, :provider_unavailable}
    end
  end

  defp provider_available?(%{kind: :native, installed?: true}), do: true

  defp provider_available?(provider) do
    Map.get(provider, :installed?, false) and not is_nil(Map.get(provider, :resolved_path))
  end

  defp ensure_workspace(spec, opts) do
    fun =
      Keyword.get(opts, :workspace_fun, fn ->
        base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
        Path.join([base, "companies", spec.company, "agents", spec.slug, "workspace"])
      end)

    path = if is_function(fun, 0), do: fun.(), else: fun.(spec)
    fs = fs_fun(opts)
    fs.mkdir_p!.(path)

    # Also ensure the agent's canonical sibling dirs exist so bwrap
    # can `--bind` them (inbox + outbox are required; workspace/state/
    # history are convenience). A user-created agent dir with only
    # AGENT.md would otherwise crash bwrap with:
    #   bwrap: Can't find source path …/agents/<slug>/outbox
    agent_root = Path.dirname(path)
    Enum.each(~w(inbox outbox history state), &fs.mkdir_p!.(Path.join(agent_root, &1)))

    # A-001 / B-023 / B-026: providers that relocate XDG data/state into
    # the sandbox workspace (stado sets XDG_DATA_HOME=/workspace/.local/share
    # and XDG_STATE_HOME=/workspace/.local/state) need those parent dirs to
    # exist on the host side of the rw workspace bind before dispatch, so
    # the CLI can mkdir its own subdir under them. These are agent-private
    # (per-company workspace), so nothing is shared across companies.
    #
    # Gemini round-3 finding: `mkdir_p!` follows symlinks. The
    # workspace is rw-mounted INSIDE the sandbox, so a previous
    # dispatch could have left `.local` as a symlink pointing at
    # another host directory (e.g. another company's state dir, or
    # a path the OS user owns). The next dispatch's host-side
    # `mkdir_p!` would then create `share` / `state` under the
    # symlink target. Walk every ancestor segment with `lstat` and
    # refuse if any is a symlink — fall back to removing the trap
    # and recreating fresh so dispatch can still proceed.
    Enum.each(
      [".local/share", ".local/state", ".config"],
      &ensure_workspace_subdir!(path, &1, fs)
    )

    {:ok, path}
  end

  # Walk each segment of `subpath` (relative to `base`) and refuse
  # if any intermediate is a symlink. On detection, attempt to
  # remove the symlink and recreate as a regular dir — the
  # workspace is agent-controlled and we'd rather lose a malicious
  # in-flight chain than let `mkdir_p!` follow it.
  defp ensure_workspace_subdir!(base, subpath, fs) do
    # Walk segments left-to-right, building a path accumulator and
    # checking each candidate before mkdir. The accumulator IS the
    # candidate path for the next iteration; we ignore the final
    # return value (the deepest path) by binding `_walked`.
    _walked =
      subpath
      |> Path.split()
      |> Enum.reduce(base, fn seg, acc ->
        candidate = Path.join(acc, seg)
        ensure_one_workspace_segment!(candidate, fs)
        candidate
      end)

    :ok
  end

  defp ensure_one_workspace_segment!(candidate, fs) do
    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        Logger.warning(
          "dispatch: workspace path #{candidate} is a symlink; removing and recreating"
        )

        remove_suspect_entry!(candidate)
        fs.mkdir_p!.(candidate)

      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{}} ->
        # Pre-existing non-directory (regular file, fifo, …) at a
        # segment that should be a directory. Same defense: nuke
        # and recreate.
        Logger.warning(
          "dispatch: workspace path #{candidate} is not a directory; removing and recreating"
        )

        remove_suspect_entry!(candidate)
        fs.mkdir_p!.(candidate)

      {:error, :enoent} ->
        fs.mkdir_p!.(candidate)

      {:error, reason} ->
        # Fail closed: refusing dispatch is better than blindly
        # following an unknown stat error into a `mkdir_p!` call
        # that would resolve through whatever's there.
        raise File.Error,
          reason: reason,
          action: "stat workspace subdir",
          path: candidate
    end
  end

  # Copilot review on PR #35: the previous shape was
  # `_ = File.rm(candidate)` followed by `mkdir_p!`. If `rm` failed
  # (EACCES, EBUSY, ...) the symlink stayed in place; `mkdir_p!`
  # then followed it (a symlink to a directory satisfies the
  # post-condition), restoring the very bypass the fix was meant
  # to close. Raise loudly on rm failure so the caller's dispatch
  # short-circuits rather than silently following the suspect
  # entry.
  defp remove_suspect_entry!(candidate) do
    case File.rm(candidate) do
      :ok ->
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "remove suspect workspace entry",
          path: candidate
    end
  end

  defp materialize_skills(spec, run_dir, opts) do
    target = Path.join(run_dir, ".glorbo-skills")

    skills_opts = [
      base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root()),
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
    ensure_safe_run_dir!(run_dir)
    fs.mkdir_p!.(run_dir)
    ensure_safe_prompt_path!(prompt_path(run_dir))
    fs.write!.(prompt_path(run_dir), prompt)
    :ok
  end

  # Symlink-swap defense (threatmodel T3). The agent controls its
  # workspace and the heartbeat `task_id` is a constant ("heartbeat"),
  # so a malicious agent can pre-create `.glorbo-run/heartbeat/` as a
  # symlink to a sensitive host directory, causing the subsequent
  # prompt write to escape the sandbox. Reject any pre-existing
  # non-directory entry at the run path before `mkdir_p!`.
  defp ensure_safe_run_dir!(run_dir) do
    case File.lstat(run_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{}} ->
        raise File.Error,
          reason: :not_a_regular_directory,
          action: "prepare run_dir",
          path: run_dir

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat run_dir", path: run_dir
    end
  end

  # Paired defense: even when run_dir is a real directory, a symlinked
  # `task-prompt.md` inside it would still redirect the write. Reject
  # anything other than a missing path or regular file.
  defp ensure_safe_prompt_path!(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{}} ->
        raise File.Error,
          reason: :not_a_regular_file,
          action: "prepare task-prompt.md",
          path: path

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat task-prompt.md", path: path
    end
  end

  # GEP-23 Phase 5. For `:proxy` agents, allocate a per-dispatch
  # token via `Glorbo.Network.ProxyTokens` and embed it in the
  # `HTTPS_PROXY` URL's userinfo. The proxy reads the token from
  # the incoming CONNECT's `Proxy-Authorization: Basic` header
  # and resolves `{company, agent, dispatch_id}`. `nil` in the
  # `proxy_token_fun` opts skips token allocation — used by tests
  # that don't exercise the auth layer. The `{url, token}` tuple
  # flows through `do_execute/4`'s `after` block so the token is
  # revoked on completion.
  defp resolve_proxy_url(
         %{network: :proxy, company: company, slug: slug},
         dispatch_id,
         timeout_s,
         opts
       ) do
    fun = Keyword.get(opts, :proxy_url_fun, &default_proxy_url/1)
    token_fun = Keyword.get(opts, :proxy_token_fun, &register_proxy_token/4)

    with {:ok, base_url} <- normalize_proxy_url_fn(fun.(company)),
         {:ok, token} <- token_fun.(company, slug, dispatch_id, timeout_s) do
      {:ok, apply_token_to_url(base_url, token), token}
    end
  end

  defp resolve_proxy_url(_spec, _dispatch_id, _timeout_s, _opts), do: {:ok, nil, nil}

  # GEP-0055: mint the per-dispatch token for the in-process
  # inference proxy. The caller gates on the resolved provider's
  # `auth == :via_proxy`; this function additionally requires
  # `network: :proxy` — the pasta netns is what forwards the
  # listener's loopback port into the sandbox, so any other network
  # policy cannot reach the proxy at the kernel layer and the
  # dispatch must fail rather than boot an agent with no usable
  # endpoint.
  #
  # Same `ProxyTokens` registry and 2× dispatch-timeout TTL as the
  # GEP-23 CONNECT token, but a second, distinct token per dispatch:
  # the entry's `provider_alias` is what lets the listener resolve
  # the upstream endpoint + `api_key_env` without re-reading
  # AGENT.md. Tests inject `:openai_proxy_url_fun` via opts (same
  # seam shape as GEP-23's `:proxy_url_fun`).
  defp resolve_openai_proxy_token(
         %{network: :proxy, company: company, slug: slug},
         provider,
         dispatch_id,
         timeout_s,
         opts
       ) do
    fun = Keyword.get(opts, :openai_proxy_url_fun, &default_openai_proxy_url/2)

    with {:ok, base_url} <- normalize_proxy_url_fn(fun.(company, slug)),
         {:ok, token} <-
           Glorbo.Network.ProxyTokens.register(%{
             company: company,
             agent: slug,
             dispatch_id: dispatch_id,
             expires_in_ms: timeout_s * 2_000,
             provider_alias: provider.name
           }) do
      {:ok, base_url, token}
    end
  end

  defp resolve_openai_proxy_token(_spec, _provider, _dispatch_id, _timeout_s, _opts),
    do: {:error, :via_proxy_requires_proxy_network}

  defp default_openai_proxy_url(company, _slug) do
    # Resolve the real per-company proxy port. The proxy is started
    # by `Glorbo.Company.Supervisor` (GEP-0055 conditional append)
    # and registers itself under `via(company, :openai_proxy)`. The
    # `:via` tuple is the only stable handle — the actual port is
    # ephemeral. When the listener isn't running (provider flipped
    # to via_proxy after company start, or supervisor scan said no),
    # the call exits and the dispatch fails with a typed error.
    proxy = Glorbo.Company.Supervisor.via(company, :openai_proxy)

    try do
      {:ok, "http://127.0.0.1:#{Glorbo.OpenAIProxy.port(proxy)}"}
    catch
      :exit, _ -> {:error, :openai_proxy_unavailable}
    end
  end

  defp normalize_proxy_url_fn(url) when is_binary(url), do: {:ok, url}
  defp normalize_proxy_url_fn({:ok, url}) when is_binary(url), do: {:ok, url}
  defp normalize_proxy_url_fn({:error, _} = err), do: err
  defp normalize_proxy_url_fn(other), do: {:error, {:proxy_url_bad_return, other}}

  # `nil` token skips auth (backward-compat + test injection). A
  # string token is embedded as userinfo.
  defp apply_token_to_url(url, nil), do: url

  defp apply_token_to_url("http://" <> rest, token) when is_binary(token) do
    "http://#{token}@" <> rest
  end

  defp apply_token_to_url(url, _token), do: url

  defp register_proxy_token(company, agent, dispatch_id, timeout_s) do
    # Tokens expire at 2× the dispatch timeout. A dispatch that
    # overruns its timeout will still have a token briefly valid
    # during teardown — caller is expected to `revoke/1` at the end
    # of `do_execute/4`.
    Glorbo.Network.ProxyTokens.register(%{
      company: company,
      agent: agent,
      dispatch_id: dispatch_id,
      expires_in_ms: timeout_s * 2_000
    })
  end

  defp default_proxy_url(company) do
    proxy = Glorbo.Company.Supervisor.via(company, :network_proxy)

    try do
      "http://127.0.0.1:#{Glorbo.Network.Proxy.port(proxy)}"
    catch
      :exit, _ -> {:error, :proxy_unavailable}
    end
  end

  defp build_ctx(spec, task, workspace, run_dir, provider, runtime, opts) do
    # workspace shape: `<base>/companies/<co>/agents/<slug>/workspace`.
    # `Path.dirname(workspace)` → `…/agents/<slug>`, which is the agent
    # root — parent of inbox/outbox. The previous code stripped one
    # dirname too many, landing at `…/agents/` and pointing bwrap at
    # `…/agents/outbox` (no such path → `bwrap: Can't find source path
    # …/agents/outbox` → CLI exits 1 → :reply_file_missing).
    agent_root = Path.dirname(workspace)

    # #235 per-task override: prefer task.model over spec.model when
    # the task explicitly requests a specific model.
    model = task_model_override(task, spec) || spec.model

    # GEP-27: look up any approved external paths for this dispatch.
    approved_paths =
      case Glorbo.PathGrantStore.lookup(spec.company, spec.slug, task.task_id) do
        {:ok, paths} -> paths
        :not_found -> []
      end

    %{
      task_id: task.task_id,
      model: model,
      provider: provider.name,
      workspace: workspace,
      prompt: task.prompt,
      http_timeout_s: Map.get(spec, :http_timeout_s, 120),
      http_max_retries: Map.get(spec, :http_max_retries, 3),
      web_fetch_timeout_s: Map.get(spec, :web_fetch_timeout_s, 30),
      max_tool_calls_per_turn: Map.get(spec, :max_tool_calls_per_turn, 50),
      prompt_path: prompt_path(run_dir),
      invocation_id: runtime.invocation_id,
      agent_slug: spec.slug,
      company: spec.company,
      host_cli_binary: runtime.cli_binary.host_path,
      cli_binary: runtime.cli_binary.sandbox_path,
      bwrap_opts: %{
        company: spec.company,
        agent_workspace: workspace,
        inbox_path: Path.join(agent_root, "inbox"),
        outbox_path: Path.join(agent_root, "outbox"),
        company_path: Path.dirname(Path.dirname(agent_root)),
        permissions: spec.permissions,
        network_policy: spec.network,
        proxy_url: runtime.proxy_url,
        # GEP-0055: bwrap derives the second pasta `-T` forward port
        # from this URL so a via_proxy CLI can reach the inference
        # proxy at the kernel layer. nil for non-via_proxy dispatches.
        openai_proxy_url: runtime.openai_proxy_url,
        timeout_seconds: spec.timeout_seconds,
        cli_env: proxy_cli_env(spec, provider, runtime, opts),
        cli_auth_binds:
          resolve_auth_binds(provider) ++
            native_credentials_binds(provider) ++
            [cli_binary_bind(runtime.cli_binary)],
        approved_paths: approved_paths
      }
    }
  end

  # GEP-0055: per-shape `*_BASE_URL` env injection for `auth = "via_proxy"`
  # providers. The agent's CLI process inside the sandbox reads this
  # env var to discover its API endpoint. We set the *per-CLI* name
  # (e.g. `OPENAI_BASE_URL` for Codex/opencode/harness,
  # `ANTHROPIC_BASE_URL` for claude-code/Kiro) and the universal
  # `GLORBO_PROXY_*` vars for any client that prefers those.
  #
  # The URLs point at the GEP-0055 inference proxy
  # (`runtime.openai_proxy_url`), never at the GEP-23 CONNECT proxy:
  # the two are different listeners on different loopback ports, and
  # the CONNECT proxy's URL carries its own token in userinfo — it
  # must stay confined to `HTTPS_PROXY`. Both runtime fields are
  # guaranteed non-nil here: the dispatch with-pipeline fails before
  # build_ctx when a via_proxy provider has no reachable proxy.
  #
  # Empty for non-`via_proxy` providers (their `cli_env` is
  # provider.env, not the proxy env).
  defp proxy_cli_env(_spec, provider, runtime, _opts) do
    if provider.auth == :via_proxy do
      base_env = %{
        "GLORBO_PROXY_BASE_URL" => runtime.openai_proxy_url,
        "GLORBO_PROXY_TOKEN" => runtime.openai_proxy_token
      }

      shape_env = %{proxy_base_url_env_for(provider) => runtime.openai_proxy_url}
      Map.merge(base_env, shape_env)
    else
      %{}
    end
  end

  # Per-CLI `*_BASE_URL` env var name lookup. Native providers
  # (`glorbo harness`) speak OpenAI v1, so always get
  # `OPENAI_BASE_URL`. The CLI rows are forward-looking: the loader
  # currently restricts `via_proxy` to `kind = "native"` (GEP-0055
  # slice boundary), so the `:cli` clause is unreachable until that
  # restriction lifts with the per-CLI injection slice (D11). Kept —
  # it implements the GEP's CLI-runtime table. Note claude-code will
  # use the D11 settings.json mount in production, not
  # ANTHROPIC_BASE_URL; the row is the conservative env fallback.
  #
  # Closed set by design (GEP-12 / T-03-15): never derive an atom
  # from user input. An unrecognised CLI binary falls back to
  # "GLORBO_PROXY_BASE_URL" — the universal vars still reach the
  # agent; no raise.
  @cli_base_url_env_map %{
    # OpenAI v1
    "codex" => "OPENAI_BASE_URL",
    "opencode" => "OPENAI_BASE_URL",
    "openai" => "OPENAI_BASE_URL",
    "hermes" => "OPENAI_BASE_URL",
    "pi" => "OPENAI_BASE_URL",
    # Anthropic Messages
    "claude" => "ANTHROPIC_BASE_URL",
    "claude-code" => "ANTHROPIC_BASE_URL",
    "kiro" => "ANTHROPIC_BASE_URL",
    # Google Gemini
    "gemini" => "GOOGLE_GEMINI_BASE_URL",
    "gemini-cli" => "GOOGLE_GEMINI_BASE_URL"
  }

  defp proxy_base_url_env_for(%{kind: :native}), do: "OPENAI_BASE_URL"

  defp proxy_base_url_env_for(%{kind: :cli, binary: binary}) when is_binary(binary) do
    basename = Path.basename(binary)
    Map.get(@cli_base_url_env_map, basename, "GLORBO_PROXY_BASE_URL")
  end

  defp proxy_base_url_env_for(_), do: "GLORBO_PROXY_BASE_URL"

  defp resolve_self_binary(opts) do
    case Keyword.get(opts, :self_binary_fun) do
      nil -> Glorbo.CLI.Lifecycle.Daemon.self_binary()
      fun when is_function(fun, 0) -> fun.()
    end
  end

  # 12-char lowercase-hex id; unique-enough across a single dispatch
  # context. Mirrors `Glorbo.CLI.Dispatcher.gen_invocation_id/1` so the
  # two subsystems produce the same shape even if Agent.Dispatch starts
  # pinning ids up-front (what we do here).
  defp gen_invocation_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end

  # Threatmodel T5: do not mirror arbitrary host directories into the
  # sandbox just to make a CLI binary executable. Resolve the provider
  # binary to its final regular file and bind only that file into a
  # fixed sandbox path under /tmp, so agents cannot enumerate the
  # binary's host-side parent directories.
  defp resolve_cli_binary(%{kind: :native}, opts) do
    resolve_cli_binary_path(resolve_self_binary(opts), "native-harness")
  end

  defp resolve_cli_binary(%{resolved_path: path, name: name}, _opts) when is_binary(path) do
    resolve_cli_binary_path(path, name)
  end

  defp resolve_cli_binary(_provider, _opts), do: {:error, :provider_unavailable}

  defp resolve_cli_binary_path(path, provider_name) when is_binary(path) do
    case resolve_regular_binary(path) do
      {:ok, host_path} ->
        basename = Path.basename(host_path)

        {:ok,
         %{
           host_path: host_path,
           sandbox_path: "/tmp/glorbo-cli-#{safe_cli_name(provider_name)}-#{basename}"
         }}

      _ ->
        {:error, :provider_unavailable}
    end
  end

  defp cli_binary_bind(%{host_path: host_path, sandbox_path: sandbox_path}) do
    {host_path, sandbox_path}
  end

  defp resolve_regular_binary(path),
    do: resolve_regular_binary(Path.expand(path), MapSet.new(), 0)

  defp resolve_regular_binary(_path, _seen, depth) when depth >= 16,
    do: {:error, :symlink_loop}

  defp resolve_regular_binary(path, seen, depth) do
    if MapSet.member?(seen, path) do
      {:error, :symlink_loop}
    else
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          {:ok, path}

        {:ok, %File.Stat{type: :symlink}} ->
          case File.read_link(path) do
            {:ok, target} ->
              next = Path.expand(target, Path.dirname(path))
              resolve_regular_binary(next, MapSet.put(seen, path), depth + 1)

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, %File.Stat{}} ->
          {:error, :not_a_regular_file}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp safe_cli_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
  end

  # GEP-0055: `auth = "via_proxy"` providers route their LLM calls
  # through the in-process proxy, so the host-side credentials file
  # (which Glorbo itself doesn't need either) is not mounted. The
  # proxy reads the upstream key from `System.get_env/1` at request
  # time using the provider's `api_key_env` field. No file ends up
  # in the sandbox.
  defp native_credentials_binds(%{kind: :native, auth: :via_proxy}), do: []

  defp native_credentials_binds(%{kind: :native} = provider) do
    case native_credentials_path(provider) do
      nil -> []
      path -> [{path, "/creds/provider.toml"}]
    end
  end

  defp native_credentials_binds(_), do: []

  defp native_credentials_path(%{name: name}) when is_binary(name) do
    candidate =
      Glorbo.Filesystem.Hierarchy.native_credentials_dir()
      |> Path.join("#{name}.toml")

    if File.exists?(candidate), do: candidate, else: nil
  end

  # GEP-8 auth_binds → bwrap 4-tuples `{host, sandbox, mode, type}`.
  #
  # - Expands `~` / `$HOME` in host paths so the TOML can use
  #   `~/.claude`.
  # - Filters out binds whose host path doesn't exist on this box,
  #   because `--ro-bind`ing a non-existent path crashes bwrap. A dev
  #   without claude-code installed shouldn't have `claude` dispatches
  #   fail for a missing `~/.claude/`; the CLI itself will fail the
  #   invocation anyway with a clearer error.
  # - `mode` is `:rw` or `:ro` (default). bwrap.ex emits `--bind` for
  #   `:rw` and `--ro-bind` otherwise.
  # - `type` is `:dir` or `:file`. For `:dir`, bwrap.ex emits a
  #   `--dir <sandbox>` before the bind so non-standard sandbox paths
  #   like `/project` (TODO B5) are created on the tmpfs root before
  #   the bind tries to overlay them.
  # D5: auto-mark a task `done` after a clean dispatch.
  #
  # Tasks under `companies/<co>/projects/` are mounted ro inside the
  # bwrap sandbox (GEP-5 / GEP-2) so an agent that completes its work
  # cannot rewrite its own task file. Without intervention, every
  # task stays at its authored status (typically `pending` for
  # operator-handed tasks) even on exit 0, and the operator has to
  # `sed` it manually after every dispatch.
  #
  # Auto-transition rules:
  #
  #   - Skip when the task has a `schedule:` field. Recurring tasks
  #     are expected to stay non-terminal so the scheduler re-fires
  #     them on the next tick.
  #   - Skip when `exit_status` is non-zero — the dispatch failed,
  #     `done` is not the right outcome.
  #   - Skip when status is already terminal (`done`, `denied`,
  #     `cancelled`) or director-gated (`pending-approval`). The
  #     director-gated case in particular must NOT be silently
  #     promoted past the approval workflow.
  #   - Otherwise (`todo` / `in-progress` / `pending` / `approved`)
  #     rewrite to `done` via `FrontmatterWriter.update_keys/3` —
  #     atomic, preserves comments and unknown keys.
  #
  # Best-effort: a write failure is logged via the FrontmatterWriter
  # error path but never breaks the dispatch result. The
  # FilesystemWatcher picks up the new mtime + content and emits the
  # usual file_event so the dashboard re-renders.
  defp maybe_auto_mark_task_done(task, %{exit_status: 0}) do
    # Pull fields with Map.get so the function tolerates both
    # `Glorbo.TaskDefinition` structs (production) and the lighter
    # task maps used in unit tests.
    schedule = task |> Map.get(:schedule) |> to_string() |> String.trim()
    status = Map.get(task, :status, "")
    file_path = Map.get(task, :file_path)
    task_path = Map.get(task, :task_path, "?")

    cond do
      schedule != "" ->
        :ok

      status not in ["todo", "in-progress", "pending", "approved"] ->
        :ok

      not is_binary(file_path) ->
        :ok

      true ->
        case Glorbo.Filesystem.FrontmatterWriter.update_keys(file_path, %{status: "done"}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[dispatch] D5 auto-complete failed for #{task_path}: #{inspect(reason)}"
            )

            :ok
        end
    end
  end

  defp maybe_auto_mark_task_done(_, _), do: :ok

  defp resolve_auth_binds(%{auth_binds: binds}) when is_list(binds) do
    binds
    |> Enum.map(fn %{host: host, sandbox: sandbox} = bind ->
      expanded = Path.expand(host)
      type = if File.dir?(expanded), do: :dir, else: :file
      {expanded, sandbox, Map.get(bind, :mode, :ro), type}
    end)
    |> Enum.filter(fn {host, _s, _m, _t} -> File.exists?(host) end)
  end

  defp resolve_auth_binds(_), do: []

  defp dispatcher_opts(opts) do
    taken = Keyword.take(opts, [:run_fun, :fs_fun, :now_fun, :rand_fun])
    # In production, wire the Dispatcher's `run_fun` seam through to
    # `Glorbo.Sandbox.Bwrap.start/2`. Tests that want to stub the
    # subprocess still pass their own `:run_fun` which wins via
    # Keyword.put_new/3. Without this bridge, every agent invocation
    # errors at `:no_run_fun_configured`.
    Keyword.put_new(taken, :run_fun, &default_run_fun/4)
  end

  # Adapts the Dispatcher's 4-arity run_fun contract
  #   (args, env, bwrap_opts, run_opts_map)
  # to Bwrap.start/2's (invocation_opts, run_opts) shape. `run_opts_map`
  # carries the CLI binary + cli_args + prompt + usage_dir; `env` is the
  # per-invocation env the CLI expects (GLORBO_REPLY_PATH et al).
  defp default_run_fun(_args, env, bwrap_opts, run_opts_map) when is_map(run_opts_map) do
    # Env values target the CLI running INSIDE bwrap, where the host
    # workspace is mounted at `/workspace`. Dispatcher template-expands
    # env vars with the host path (correct for the host side — Dispatcher
    # uses them for reply_path bookkeeping), but inside the sandbox the
    # host path doesn't exist. Rewrite it here at the bwrap boundary.
    host_workspace = Map.fetch!(bwrap_opts, :agent_workspace)
    sandbox_env = rewrite_env_to_sandbox(env, host_workspace)

    invocation_opts =
      bwrap_opts
      |> Map.put(:cli_env, merge_cli_env(bwrap_opts, sandbox_env))
      |> Map.put_new(:approved_paths, [])

    # GEP-46 D5 — per-invocation stdout log so concurrent invocations
    # don't interleave. `GLORBO_INVOCATION_ID` was injected into env
    # by `Glorbo.CLI.Dispatcher.build_env/6`. Falls back to the legacy
    # shared `stdout.log` path when the env var is missing (e.g.
    # tests that hand-roll bwrap_opts without going through the
    # full dispatcher pipeline).
    agent_root = Path.dirname(host_workspace)
    invocation_id = Map.get(env, "GLORBO_INVOCATION_ID")

    stdout_log_path =
      if is_binary(invocation_id) and invocation_id != "" do
        Path.join(agent_root, "stdout-#{invocation_id}.log")
      else
        Path.join(agent_root, "stdout.log")
      end

    run_opts = [
      cli_binary: Map.fetch!(run_opts_map, :cli_binary),
      host_cli_binary: Map.get(run_opts_map, :host_cli_binary),
      cli_args: Map.get(run_opts_map, :cli_args, []),
      prompt: Map.get(run_opts_map, :prompt, ""),
      usage_dir: Map.get(run_opts_map, :usage_dir),
      stdout_log: stdout_log_path
    ]

    # R30.2: on macOS / bwrap-absent hosts, fall back to the
    # unsandboxed runner. For unsandboxed runs we must use the
    # HOST env (not the sandbox-rewritten one) — there's no
    # /workspace mount, the CLI sees the real host paths.
    # threatmodel H4: Linux hosts with bwrap missing are a
    # silent-sandbox-bypass risk. Refuse to run and emit a
    # prominent audit event. macOS keeps the fallback.
    case Glorbo.Sandbox.Bwrap.availability() do
      :ok ->
        if proxy_netns_unavailable?(bwrap_opts) do
          emit_netns_unavailable_audit_once(bwrap_opts)
          {:error, :netns_unavailable}
        else
          Glorbo.Sandbox.Bwrap.start(invocation_opts, run_opts)
        end

      {:error, :unavailable} ->
        if linux?() do
          emit_sandbox_refused_audit(bwrap_opts)
          {:error, :sandbox_unavailable}
        else
          host_invocation_opts =
            Map.put(bwrap_opts, :cli_env, merge_cli_env(bwrap_opts, env))

          emit_sandbox_unavailable_audit_once(bwrap_opts)

          host_run_opts =
            Keyword.put(
              run_opts,
              :cli_binary,
              Map.get(run_opts_map, :host_cli_binary, Map.fetch!(run_opts_map, :cli_binary))
            )

          Glorbo.Sandbox.Unsandboxed.start(host_invocation_opts, host_run_opts)
        end
    end
  end

  defp linux?, do: match?({:unix, :linux}, :os.type())

  defp proxy_netns_required?(%{network_policy: :proxy}), do: true
  defp proxy_netns_required?(_), do: false

  defp proxy_netns_unavailable?(bwrap_opts) do
    linux?() and proxy_netns_required?(bwrap_opts) and
      Glorbo.Sandbox.Bwrap.pasta_availability() != :ok
  end

  # On Linux, bwrap missing is treated as a hard failure. We still
  # emit an audit so directors see *why* dispatch failed.
  defp emit_sandbox_refused_audit(%{} = bwrap_opts) do
    company = Map.get(bwrap_opts, :company) || "_system"

    entry = %{
      action: "agent.sandbox_refused",
      actor: "system",
      target: nil,
      detail: %{
        os: "linux",
        note: "bwrap not on PATH on Linux; dispatch refused (threatmodel H4)"
      }
    }

    try do
      audit_fun(base: nil).(company, entry)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  # R30.2: per-company once-per-BEAM-boot audit for unsandboxed
  # execution. Uses `:persistent_term` to flag the company so we
  # don't spam the audit log on every dispatch. Directors see
  # exactly one `agent.sandbox_unavailable` row per company boot
  # signalling "agents run outside the kernel sandbox on this host".
  defp emit_sandbox_unavailable_audit_once(%{} = bwrap_opts) do
    company = Map.get(bwrap_opts, :company) || "_system"
    key = {__MODULE__, :sandbox_unavailable_notified, company}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      entry = %{
        action: "agent.sandbox_unavailable",
        actor: "system",
        target: nil,
        detail: %{
          os: to_string(:os.type() |> elem(1)),
          note: "bwrap not on PATH; agents running unsandboxed (pre-1.0 macOS fallback)"
        }
      }

      try do
        audit_fun(base: nil).(company, entry)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp emit_netns_unavailable_audit_once(%{} = bwrap_opts) do
    company = Map.get(bwrap_opts, :company) || "_system"
    key = {__MODULE__, :netns_unavailable_notified, company}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      entry = %{
        action: "agent.netns_unavailable",
        actor: "system",
        target: nil,
        detail: %{
          os: "linux",
          note: "pasta not on PATH; network: proxy dispatches refused until passt is installed"
        }
      }

      try do
        audit_fun(base: nil).(company, entry)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp rewrite_env_to_sandbox(env, host_workspace) when is_map(env) do
    Map.new(env, fn {k, v} -> {k, rewrite_env_value(v, host_workspace)} end)
  end

  defp rewrite_env_value(value, host) when is_binary(value) and is_binary(host) do
    String.replace(value, host, "/workspace")
  end

  defp rewrite_env_value(value, _host), do: value

  defp merge_cli_env(bwrap_opts, dispatcher_env) do
    base = Map.get(bwrap_opts, :cli_env, %{})
    Map.merge(base, dispatcher_env || %{})
  end

  defp compute_duration(start, opts) do
    now = clock(opts)
    max(now - start, 0)
  end

  defp finalize_usage(%{usage: nil}, spec, task) do
    # Either :none parser (untracked), or a parse error that the
    # Dispatcher already recorded in :usage_error. Record zeros so
    # the budget ledger stays consistent (Pitfall 5).
    %{prompt_tokens: 0, completion_tokens: 0, model: effective_model(spec, task)}
  end

  defp finalize_usage(%{usage: %{model: nil} = usage}, spec, task),
    do: %{usage | model: effective_model(spec, task)}

  defp finalize_usage(%{usage: usage}, _spec, _task), do: usage

  defp effective_model(spec, task), do: task_model_override(task, spec) || spec.model

  # Budget-ledger recording is load-bearing for "you always know what
  # each agent cost" — swallowing failures silently would let budget
  # overages accumulate undetected. Surface the error to the caller; the
  # dispatch pipeline's `with` chain converts it into
  # {:error, {:record_usage_failed, reason}} (TODO.md Important #4).
  defp record_usage(spec, task, usage, opts) do
    fun = Keyword.get(opts, :record_usage_fun, fn _spec, _task, _usage -> :ok end)

    try do
      case fun.(spec, task, usage) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:record_usage_failed, reason}}
        other -> {:error, {:record_usage_bad_return, other}}
      end
    rescue
      e ->
        Logger.warning("dispatch.record_usage raised: #{Exception.message(e)}")
        {:error, {:record_usage_raised, Exception.message(e)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Run-dir lifecycle
  # ---------------------------------------------------------------------------

  defp prepare_run_dir_path(spec, task, opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    :ok = validate_task_id!(task.task_id)

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

  # Threatmodel H5 (wave 4): task.task_id is Path.join'd into the run
  # directory. A task file's `task_id` field is agent-reachable (via
  # outbox writes / projects:write), so we must reject anything that
  # can traverse out of `.glorbo-run/`. Canonical IDs are either
  # `[a-z0-9][a-z0-9._-]*` (project-prefixed per GEP-13, heartbeat,
  # etc.) — no slashes, no `..`, no control chars.
  @task_id_re ~r/\A[a-z0-9][a-z0-9._-]*\z/
  defp validate_task_id!(id) when is_binary(id) do
    cond do
      id == ".." or String.contains?(id, "/") ->
        raise ArgumentError, "unsafe task_id: #{inspect(id)}"

      String.contains?(id, <<0>>) ->
        raise ArgumentError, "unsafe task_id: #{inspect(id)}"

      not Regex.match?(@task_id_re, id) ->
        raise ArgumentError, "unsafe task_id: #{inspect(id)}"

      true ->
        :ok
    end
  end

  defp validate_task_id!(other),
    do: raise(ArgumentError, "task_id must be a binary, got: #{inspect(other)}")

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

  defp emit_dispatch_audit(spec, task, provider, invocation_id, opts) do
    audit = audit_fun(opts)

    entry = %{
      action: "agent.dispatch",
      actor: "system",
      agent: spec.slug,
      task_path: task.task_path,
      provider: provider.name,
      model: effective_model(spec, task),
      container_id: "bwrap-inline",
      invocation_id: invocation_id,
      trigger: Map.get(task, :trigger, :unknown) |> to_string()
    }

    audit.(spec.company, entry)
    :ok
  rescue
    e ->
      Logger.warning("dispatch audit emit failed: #{Exception.message(e)}")
      :ok
  end

  defp emit_complete_audit(spec, task, result, duration_ms, invocation_id, opts) do
    audit = audit_fun(opts)
    tool_calls = extract_tool_calls(result)
    usage = Map.get(result, :usage) || %{}

    entry =
      %{
        action: "agent.complete",
        actor: spec.slug,
        agent: spec.slug,
        task_path: task.task_path,
        duration_ms: duration_ms,
        exit_status: to_string(result.exit_status),
        invocation_id: invocation_id,
        reply_preview: preview(result.reply)
      }
      |> maybe_put_tool_calls(tool_calls)
      |> maybe_put_tokens(usage)
      |> maybe_put_cost(usage, spec, task)

    audit.(spec.company, entry)
    :ok
  rescue
    e ->
      Logger.warning("dispatch complete audit emit failed: #{Exception.message(e)}")
      :ok
  end

  # #246 — surface tokens + cost on agent.complete so RunLog /
  # AgentLive can render them. Always emit tokens (even as 0 — a
  # non-usage-parsing provider will show `0 in / 0 out`, which is
  # a correct "no data" signal). Emit cost ONLY when we can
  # compute it from the model pricing table; absence = no price
  # known, which the UI renders as "—".
  defp maybe_put_tokens(entry, usage) do
    prompt = Map.get(usage, :prompt_tokens) || 0
    completion = Map.get(usage, :completion_tokens) || 0
    Map.merge(entry, %{prompt_tokens: prompt, completion_tokens: completion})
  end

  defp maybe_put_cost(entry, usage, spec, task) do
    cents = cost_cents_from_usage(usage, spec)
    model = Map.get(usage, :model) || effective_model(spec, task)

    if cents > 0 or pricing_known?(spec.provider, model) do
      Map.put(entry, :cost_usd_cents, cents)
    else
      entry
    end
  end

  defp pricing_known?(provider, model) do
    Glorbo.Budget.Ledger.compute_cost_cents(provider, model, 1, 1) > 0
  rescue
    _ -> false
  end

  # paperclip-ux-gaps §2 — surface tool-call counts on agent.complete
  # audit entries so AgentLive Runs tab + CompanyLive roster can show
  # "ran 2 tool calls (Bash×1, Read×1)". `usage.tool_calls` is a map
  # `%{tool_name => count}` populated by ClaudeJsonl; other parsers
  # don't supply it yet, which surfaces as `nil` → audit entry omits
  # the field entirely.
  defp extract_tool_calls(%{usage: %{tool_calls: calls}}) when is_map(calls), do: calls
  defp extract_tool_calls(_), do: nil

  defp emit_tool_audits(spec, task, %{audit_events: events}, invocation_id, opts)
       when is_list(events) do
    audit = audit_fun(opts)

    # Gemini round-3 finding: `event.action` flowed verbatim from
    # parsed CLI output into the audit log's `action` field. While
    # `Glorbo.CLI.Parsers.NativeV1.parse_audit_events/1` filters at
    # parse time, the gate at the EMISSION boundary was missing —
    # any parser that forwards `action` unvalidated, or any future
    # parser regression, would let an agent forge `agent.complete`
    # (defeats `LoopDetector`), `budget.usage` (poisons the reindex
    # spend rebuild), or `approval.granted` (poisons approval
    # rebuild). Re-validate against the same whitelist here as a
    # defense-in-depth boundary check.
    {valid, rejected} =
      Enum.split_with(events, fn event ->
        Glorbo.CLI.Harness.Tools.valid_audit_action?(Map.get(event, :action))
      end)

    if rejected != [] do
      # Copilot review on PR #35: `sample_actions` stored raw
      # `Map.get(event, :action)` values into the audit detail
      # JSON. The whole reason these events were rejected is the
      # action was something unexpected — non-binary terms,
      # arbitrarily large strings, agent-controlled payloads.
      # Bound + stringify each sample so the audit row stays
      # JSON-safe and size-bounded (and an attacker can't exfil
      # via the rejection feedback loop).
      bad_actions =
        rejected
        |> Enum.map(&sanitise_rejected_action(Map.get(&1, :action)))
        |> Enum.uniq()

      Logger.warning(
        "dispatch: agent #{spec.slug} attempted to emit unrecognised audit actions " <>
          "(#{inspect(bad_actions)}); dropping #{length(rejected)} event(s)"
      )

      audit.(spec.company, %{
        actor: spec.slug,
        action: "agent.tool_audit_rejected",
        agent: spec.slug,
        task_path: task.task_path,
        invocation_id: invocation_id,
        detail: %{rejected: length(rejected), sample_actions: Enum.take(bad_actions, 5)}
      })
    end

    # C-033: hard-cap the event count per dispatch so an attacker-
    # controlled `audit_events` list can't drive unbounded fsync'd audit
    # writes. When the list overflows the cap, drop the overflow and emit
    # a single `agent.tool_audit_truncated` marker so the truncation is
    # itself auditable.
    total = length(valid)
    capped = Enum.take(valid, @max_tool_audit_events)

    Enum.each(capped, fn event ->
      entry =
        %{
          actor: spec.slug,
          action: event.action,
          agent: spec.slug,
          task_path: task.task_path,
          invocation_id: invocation_id
        }
        |> maybe_put_target(bound_target(Map.get(event, :target)))
        |> maybe_put_detail(bound_detail(Map.get(event, :detail)))

      audit.(spec.company, entry)
    end)

    if total > @max_tool_audit_events do
      Logger.warning(
        "dispatch: agent #{spec.slug} emitted #{total} tool audit events; capped at #{@max_tool_audit_events}"
      )

      audit.(spec.company, %{
        actor: spec.slug,
        action: "agent.tool_audit_truncated",
        agent: spec.slug,
        task_path: task.task_path,
        invocation_id: invocation_id,
        detail: %{emitted: total, cap: @max_tool_audit_events}
      })
    end

    :ok
  rescue
    e ->
      Logger.warning("dispatch tool audit emit failed: #{Exception.message(e)}")
      :ok
  end

  defp emit_tool_audits(_spec, _task, _usage, _invocation_id, _opts), do: :ok

  defp maybe_put_tool_calls(entry, nil), do: entry

  defp maybe_put_tool_calls(entry, calls) when calls == %{}, do: entry

  defp maybe_put_tool_calls(entry, calls) when is_map(calls),
    do: Map.put(entry, :tool_calls, calls)

  defp maybe_put_target(entry, target) when is_binary(target), do: Map.put(entry, :target, target)
  defp maybe_put_target(entry, _target), do: entry

  defp maybe_put_detail(entry, detail) when detail == %{}, do: entry
  defp maybe_put_detail(entry, detail) when is_map(detail), do: Map.put(entry, :detail, detail)
  defp maybe_put_detail(entry, _detail), do: entry

  # C-033: bound the per-event target string so a single oversized value
  # can't bloat the audit JSONL. Non-binary targets are left untouched
  # (maybe_put_target drops them).
  defp bound_target(target) when is_binary(target) do
    # Codex deep-dive follow-up: `binary_part/3` slices by raw bytes
    # and can split a multi-byte UTF-8 codepoint, producing an invalid
    # binary that crashes `Jason.encode!` in the audit writer — which
    # then drops the audit record entirely (because `Audit.emit/3`
    # swallows the failure). Route through `Glorbo.Util.UTF8.safe_byte_slice/2`
    # so the cap lands on a codepoint boundary.
    Glorbo.Util.UTF8.safe_byte_slice(target, @max_tool_audit_target_bytes)
  end

  defp bound_target(target), do: target

  # C-033: bound the serialized size of the detail map. Detail is an
  # arbitrary attacker-supplied map; cap its JSON byte size and replace
  # it with a small truncation marker when it overflows rather than
  # writing megabytes per audit line.
  defp bound_detail(detail) when is_map(detail) and detail != %{} do
    case Jason.encode(detail) do
      {:ok, json} when byte_size(json) <= @max_tool_audit_detail_bytes ->
        detail

      {:ok, json} ->
        %{truncated: true, bytes: byte_size(json), cap: @max_tool_audit_detail_bytes}

      _ ->
        %{truncated: true, cap: @max_tool_audit_detail_bytes}
    end
  end

  defp bound_detail(detail), do: detail

  # Copilot review on PR #35: rejected actions feed back into the
  # audit log via `sample_actions`. Coerce each entry to a short
  # printable string so non-binary terms (atoms, integers, maps,
  # …) don't crash `Jason.encode`, and oversized strings can't
  # bloat the audit row or smuggle data out via the rejection
  # feedback channel.
  @rejected_action_sample_bytes 80
  defp sanitise_rejected_action(action) when is_binary(action) do
    Glorbo.Util.UTF8.safe_byte_slice(action, @rejected_action_sample_bytes)
  end

  defp sanitise_rejected_action(other) do
    other
    |> inspect(limit: 5, printable_limit: @rejected_action_sample_bytes)
    |> Glorbo.Util.UTF8.safe_byte_slice(@rejected_action_sample_bytes)
  end

  # Post-dispatch loop check — reads this month's audit jsonl for
  # consecutive failures on the same task_path and, on threshold,
  # writes a director-actionable sentinel + emits
  # `agent.loop_detected`. Best-effort; any error is logged but
  # doesn't propagate into the dispatch result (detection failure
  # must never mask a successful dispatch).
  #
  # Injection: `opts[:loop_check_fun]` overrides the real detector
  # in tests — a zero-arity `fn -> :ok end` stub keeps the
  # existing dispatch test harness working unchanged.
  # #243 — per-task budget cap. Post-dispatch only: we don't know the
  # cost until usage is parsed. If the dispatch exceeded the cap we
  # emit `task.budget_exceeded` audit so the director sees it in the
  # audit stream. Hard-stop enforcement (refuse the NEXT dispatch of
  # the same task when prior ones already crossed the cap) is a
  # follow-up: that wants a pre-check that looks up prior spend for
  # `task.task_path`.
  defp maybe_check_task_budget(spec, task, usage, opts) do
    cap = Map.get(task, :budget_usd_cents)

    if is_integer(cap) and cap > 0 do
      cost = cost_cents_from_usage(usage, spec)

      if cost > cap do
        emit_task_overspend(spec, task, cost, cap, opts)
      end
    end

    :ok
  end

  defp cost_cents_from_usage(%{cost_usd_cents: c}, _spec) when is_integer(c), do: c

  defp cost_cents_from_usage(%{prompt_tokens: p, completion_tokens: c, model: model}, spec) do
    Glorbo.Budget.Ledger.compute_cost_cents(spec.provider, model, p || 0, c || 0)
  rescue
    _ -> 0
  end

  defp cost_cents_from_usage(_, _), do: 0

  defp emit_task_overspend(spec, task, cost, cap, opts) do
    audit = audit_fun(opts)

    try do
      audit.(spec.company, %{
        company: spec.company,
        actor: "system",
        action: "task.budget_exceeded",
        target: task.task_path,
        agent: spec.slug,
        cost_usd_cents: cost,
        cap_usd_cents: cap
      })
    rescue
      _ -> :ok
    end
  end

  defp maybe_check_loop(spec, opts) do
    fun =
      Keyword.get_lazy(opts, :loop_check_fun, fn ->
        base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())

        fn ->
          Glorbo.Agent.LoopDetector.check(spec.company, spec.slug,
            base: base,
            audit_fun: audit_fun(opts)
          )

          :ok
        end
      end)

    fun.()
    :ok
  rescue
    e ->
      Logger.warning("loop-check skipped for #{spec.slug}: #{Exception.message(e)}")
      :ok
  end

  # First non-empty line of the reply, capped for audit storage.
  defp preview(nil), do: ""

  defp preview(reply) when is_binary(reply) do
    reply
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.slice(0, 160)
  end

  defp preview(_), do: ""

  # Default audit_fun for production wires the per-company AuditLog via
  # its Registry via-tuple. AuditLog.append(server, entry) expects `server`
  # to be a valid GenServer.name — a company slug isn't, so we translate.
  # Tests continue to pass their own `:audit_fun` unchanged.
  defp audit_fun(opts) do
    Keyword.get(opts, :audit_fun, &default_audit_fun/2)
  end

  defp default_audit_fun(company, entry) when is_binary(company) do
    server =
      case resolve_audit_server(company) do
        {:ok, via} -> via
        :not_found -> AuditLog
      end

    AuditLog.append(server, Map.put(entry, :company, company))
  end

  defp resolve_audit_server(company) do
    key = {:company_child, company, :audit_log}

    case Elixir.Registry.lookup(Glorbo.Agent.Registry, key) do
      [{_pid, _}] -> {:ok, {:via, Elixir.Registry, {Glorbo.Agent.Registry, key}}}
      _ -> :not_found
    end
  end

  defp emit_unavailable_audit(spec, provider, opts) do
    audit = audit_fun(opts)

    entry = %{
      action: "provider.unavailable",
      actor: "system",
      agent: spec.slug,
      provider: Map.get(provider, :name, spec.provider)
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
