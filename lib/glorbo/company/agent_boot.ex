defmodule Glorbo.Company.AgentBoot do
  @moduledoc """
  One-shot boot hook that enumerates `<base>/companies/<co>/agents/*/`
  at company-supervisor start and wires each agent into the runtime:

    1. Parse `AGENT.md` via `Glorbo.Agent.Parser.parse_file/1` — legacy
       `agent.md` still accepted per GEP-15's soft migration.
    2. Call `AgentSupervisor.start_agent/2` so the agent's
       `Task.Supervisor` + `Agent.Server` sub-tree boots.
    3. If the spec carries a `heartbeat:` cron, call
       `Scheduler.register/3` so GEP-14's wake path fires on schedule.
       Agents with `heartbeat: null` opt out of cron wakes entirely.

  Runs once under `Glorbo.Company.Supervisor` as a `Task` child, last in
  the children list so everything it depends on (AgentSupervisor,
  Scheduler, AuditLog) is already alive when it starts. Errors are
  logged — one malformed `AGENT.md` doesn't take down the company.

  Gated by `config :glorbo, :auto_boot_agents` (default true; tests
  that manage agents themselves can set it false).
  """
  require Logger

  alias Glorbo.Agent.FileLayout
  alias Glorbo.Agent.Parser, as: AgentParser
  alias Glorbo.Agent.Server, as: AgentServer
  alias Glorbo.Company.AgentSupervisor
  alias Glorbo.Company.Scheduler
  alias Glorbo.Company.Supervisor, as: CompanySup
  alias Glorbo.Providers.ModelCatalog

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :run, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec run(keyword()) :: {:ok, pid()}
  def run(opts) do
    Task.start_link(fn -> do_boot(opts) end)
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp do_boot(opts) do
    if Application.get_env(:glorbo, :auto_boot_agents, true) do
      company = Keyword.fetch!(opts, :company)
      base = Keyword.fetch!(opts, :base)

      agents_dir = Path.join([base, "companies", company, "agents"])

      case File.ls(agents_dir) do
        {:ok, slugs} ->
          slugs
          |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.each(&boot_one(company, &1, Path.join(agents_dir, &1), base))

        _ ->
          :ok
      end
    end

    :ok
  end

  defp boot_one(company, slug, agent_dir, base) do
    agent_md = FileLayout.agent_md(agent_dir)

    case AgentParser.parse_file(agent_md) do
      {:ok, spec} ->
        maybe_warn_unknown_model(spec)
        start_and_register(company, slug, spec, base)

      {:error, reason} ->
        Logger.warning("agent_boot: skipped #{company}/#{slug}: #{inspect(reason)} (#{agent_md})")
    end
  end

  defp start_and_register(company, slug, spec, base) do
    sup = CompanySup.via(company, :agent_sup)

    # codex C-108: auto-booted agents (the heartbeat/inbox-driven
    # production path) previously started with no `:dispatch_opts`, so
    # `Dispatch.execute` fell back to the no-op `budget_tracker_fun` +
    # `record_usage_fun` defaults — the per-agent budget gate AND the
    # ledger write were both disabled, and the company cap (which sums
    # the ledger) read zero. The SEC-05 hard stop was effectively dead
    # for every auto-booted agent. Wire the real per-company BudgetTracker
    # + the resolved base so budget enforcement and usage recording are
    # live on the production wake path (also fixes C-114: base now flows
    # into dispatch instead of defaulting to ~/.glorbo).
    agent_opts = [dispatch_opts: production_dispatch_opts(company, base)]

    case AgentSupervisor.start_agent(sup, spec, agent_opts) do
      {:ok, _pid} ->
        maybe_register_heartbeat(company, slug, spec)

      {:error, {:already_started, _pid}} ->
        maybe_register_heartbeat(company, slug, spec)

      {:error, reason} ->
        Logger.warning("agent_boot: failed to start #{company}/#{slug}: #{inspect(reason)}")
    end
  end

  defp maybe_register_heartbeat(_company, _slug, %{heartbeat: nil}), do: :ok
  defp maybe_register_heartbeat(_company, _slug, %{heartbeat: ""}), do: :ok

  defp maybe_register_heartbeat(company, slug, %{heartbeat: cron}) when is_binary(cron) do
    sched = CompanySup.via(company, :scheduler)
    dispatch_fun = build_dispatch_fun(company, slug)

    case Scheduler.register(sched, slug, %{cron: cron, dispatch_fun: dispatch_fun}) do
      :ok ->
        :ok

      {:error, :invalid_cron} ->
        # Scheduler already audits + logs; don't double-log.
        :ok
    end
  end

  defp maybe_register_heartbeat(_, _, _), do: :ok

  defp maybe_warn_unknown_model(%{provider: provider, model: model}) do
    case ModelCatalog.model_known?(provider, model) do
      :unknown ->
        Logger.warning(
          "agent_boot: model #{inspect(model)} for provider #{inspect(provider)} is absent from the cached model catalog; dispatch still allowed"
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # The dispatch_fun runs inside the Scheduler process when the timer
  # fires. It calls into the AgentServer's wake queue by registered
  # name so we don't hold on to a pid that might have restarted.
  # codex C-108 / C-114: the production dispatch options every auto-booted
  # agent's `Agent.Server` carries, threaded into `Dispatch.execute` on
  # each wake. `budget_tracker_fun` + `record_usage_fun` route to this
  # company's `BudgetTracker` (mirroring the proven wiring in
  # `budget_hard_stop_e2e_test`); `base` is the resolved GLORBO_HOME so
  # dispatch reads the right filesystem root rather than defaulting to
  # `~/.glorbo`. Without these, budget enforcement + usage recording are
  # silently disabled for the heartbeat/inbox wake path.
  defp production_dispatch_opts(company, base) do
    tracker = CompanySup.via(company, :budget_tracker)

    [
      base: base,
      budget_tracker_fun: fn spec ->
        Glorbo.Company.BudgetTracker.check_budget(tracker, spec.slug)
      end,
      record_usage_fun: fn spec, task, usage ->
        Glorbo.Company.BudgetTracker.record(tracker, %{
          agent_slug: spec.slug,
          provider: Map.get(usage, :provider) || spec.provider || "",
          model: Map.get(usage, :model) || spec.model || "",
          prompt_tokens: Map.get(usage, :prompt_tokens, 0),
          completion_tokens: Map.get(usage, :completion_tokens, 0),
          task_id: Map.get(task, :task_id) || ""
        })
      end
    ]
  end

  defp build_dispatch_fun(company, slug) do
    fn trigger ->
      name = {:via, Registry, {Glorbo.Agent.Registry, {:agent_server, company, slug}}}

      try do
        AgentServer.wake(name, trigger)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end
end
