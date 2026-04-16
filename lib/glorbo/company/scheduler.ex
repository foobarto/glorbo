defmodule Glorbo.Company.Scheduler do
  @moduledoc """
  Per-company cron-driven heartbeat scheduler (AGT-02).

  For each registered agent, parses the `heartbeat:` cron expression from
  `agent.md`, computes the next run-time against the dep-injected clock, and
  arms a `Process.send_after/3` one-shot timer. When the timer fires we
  invoke the agent's `dispatch_fun.(:heartbeat)` callback, emit an
  `agent.wake` audit event, and re-arm from the CURRENT wall-clock —
  **never** by incrementing the prior armed-time (Pitfall 3 — send_after
  delays drift under long VM pauses; wall-clock recompute self-heals).

  **Stateless across restarts (D-45):** on crash, state is lost but the
  source of truth is each agent's `agent.md`; callers re-register agents
  from their own supervisors.

  **Dep-injection:** `clock_fun` and `send_after_fun` are keyword opts for
  tests — a mock clock returns a fixed `DateTime` and a mock
  `send_after_fun` captures the `(dest, msg, delay)` triple in the test's
  mailbox without actually arming a BEAM timer.
  """
  use GenServer
  require Logger

  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler
  alias Glorbo.Company.AuditLog

  @type agent_reg :: %{
          required(:cron) => String.t(),
          required(:dispatch_fun) => (atom() -> any())
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register an agent's cron-driven heartbeat. Returns `:ok` on success, or
  `{:error, :invalid_cron}` if the cron string fails to parse (the agent is
  skipped; other agents continue).
  """
  @spec register(GenServer.server(), String.t(), agent_reg()) ::
          :ok | {:error, :invalid_cron}
  def register(server, agent_slug, reg) when is_binary(agent_slug) and is_map(reg) do
    GenServer.call(server, {:register, agent_slug, reg})
  end

  @doc "Cancel the pending heartbeat timer for `agent_slug` and remove from state."
  @spec unregister(GenServer.server(), String.t()) :: :ok
  def unregister(server, agent_slug) when is_binary(agent_slug) do
    GenServer.call(server, {:unregister, agent_slug})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      company: Keyword.fetch!(opts, :company),
      agents: %{},
      clock_fun: Keyword.get(opts, :clock_fun, &DateTime.utc_now/0),
      send_after_fun: Keyword.get(opts, :send_after_fun, &Process.send_after/3),
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.append/2)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:register, agent_slug, reg}, _from, state) do
    case CronParser.parse(reg.cron) do
      {:ok, expr} ->
        state =
          state
          |> cancel_timer_for(agent_slug)
          |> arm_timer(agent_slug, expr, reg)

        {:reply, :ok, state}

      {:error, reason} ->
        emit_audit(state, %{
          action: "scheduler.invalid_cron",
          actor: "system",
          company: state.company,
          agent: agent_slug,
          cron: reg.cron,
          reason: inspect(reason)
        })

        {:reply, {:error, :invalid_cron}, state}
    end
  end

  def handle_call({:unregister, agent_slug}, _from, state) do
    state = cancel_timer_for(state, agent_slug)
    {:reply, :ok, %{state | agents: Map.delete(state.agents, agent_slug)}}
  end

  @impl GenServer
  def handle_info({:heartbeat, agent_slug}, state) do
    case Map.fetch(state.agents, agent_slug) do
      {:ok, %{dispatch_fun: dispatch_fun, expr: expr} = entry} ->
        safe_dispatch(dispatch_fun, agent_slug)

        emit_audit(state, %{
          action: "agent.wake",
          actor: "system",
          company: state.company,
          agent: agent_slug,
          trigger: "heartbeat"
        })

        # Pitfall 3: recompute next-run from current wall-clock
        state = arm_timer(state, agent_slug, expr, entry)
        {:noreply, state}

      :error ->
        # Agent was unregistered after timer armed — drop silently
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp cancel_timer_for(state, agent_slug) do
    case Map.get(state.agents, agent_slug) do
      %{timer_ref: ref} when is_reference(ref) ->
        _ = Process.cancel_timer(ref)
        state

      _ ->
        state
    end
  end

  defp arm_timer(state, agent_slug, expr, reg_or_entry) do
    now = state.clock_fun.()
    delay_ms = compute_delay_ms(expr, now)

    timer_ref =
      state.send_after_fun.(self(), {:heartbeat, agent_slug}, max(0, delay_ms))

    entry = %{
      cron: Map.get(reg_or_entry, :cron),
      expr: expr,
      dispatch_fun: Map.fetch!(reg_or_entry, :dispatch_fun),
      timer_ref: timer_ref
    }

    %{state | agents: Map.put(state.agents, agent_slug, entry)}
  end

  defp compute_delay_ms(expr, %DateTime{} = now) do
    naive = DateTime.to_naive(now)

    case CronScheduler.get_next_run_date(expr, naive) do
      {:ok, next_naive} ->
        next_dt = DateTime.from_naive!(next_naive, "Etc/UTC")
        DateTime.diff(next_dt, now, :millisecond)

      {:error, reason} ->
        Logger.warning(
          "scheduler: get_next_run_date failed (#{inspect(reason)}); defaulting to 1h delay"
        )

        3_600_000
    end
  end

  defp safe_dispatch(dispatch_fun, agent_slug) do
    dispatch_fun.(:heartbeat)
    :ok
  rescue
    e ->
      Logger.error(
        "scheduler dispatch_fun for #{agent_slug} raised: #{Exception.message(e)} — agent continues"
      )

      :error
  end

  defp emit_audit(state, entry) do
    state.audit_fun.(state.company, entry)
    :ok
  rescue
    e ->
      Logger.error("scheduler audit emit failed: #{Exception.message(e)}")
      :error
  end
end
