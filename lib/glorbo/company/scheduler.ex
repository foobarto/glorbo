defmodule Glorbo.Company.Scheduler do
  @moduledoc """
  Per-company cron-driven heartbeat scheduler (AGT-02).

  For each registered agent, parses the `heartbeat:` cron expression from
  `AGENT.md`, computes the next run-time against the dep-injected clock, and
  arms a `Process.send_after/3` one-shot timer. When the timer fires we
  consult `HEARTBEAT.md` (GEP-14) — present → dispatch the agent and emit
  `agent.wake` (trigger=heartbeat); missing/blank/oversize → emit
  `agent.heartbeat_skipped` and skip dispatch. Re-arm from the CURRENT
  wall-clock regardless — **never** by incrementing the prior armed-time
  (Pitfall 3 — send_after delays drift under long VM pauses; wall-clock
  recompute self-heals).

  **Stateless across restarts (D-45):** on crash, state is lost but the
  source of truth is each agent's `AGENT.md`; callers re-register agents
  from their own supervisors.

  **Dep-injection:** `clock_fun`, `send_after_fun`, `audit_fun`, and
  `heartbeat_file_fun` are keyword opts for tests — mocks return fixed
  values and capture the `(dest, msg, delay)` triple in the test's
  mailbox without actually arming a BEAM timer or touching the disk.
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

  # GEP-14: cap for HEARTBEAT.md content. Reasonable default — longer
  # than a cron expression, short enough that oversize = user error.
  @heartbeat_max_bytes 10 * 1024

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)

    state = %{
      company: company,
      base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root()),
      agents: %{},
      clock_fun: Keyword.get(opts, :clock_fun, &DateTime.utc_now/0),
      send_after_fun: Keyword.get(opts, :send_after_fun, &Process.send_after/3),
      audit_fun: Keyword.get(opts, :audit_fun, &default_audit_fun/2),
      heartbeat_file_fun:
        Keyword.get(
          opts,
          :heartbeat_file_fun,
          &Glorbo.Company.Scheduler.default_heartbeat_lookup/3
        )
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
        # GEP-14: HEARTBEAT.md is the agent-authored cron-wake contract.
        # Missing/blank/oversize → skip dispatch (no-op wakes hide
        # "this agent has nothing to do" in the audit log; an explicit
        # skip event makes that state visible).
        case heartbeat_status(state, agent_slug) do
          :ok ->
            safe_dispatch(dispatch_fun, agent_slug)

            emit_audit(state, %{
              action: "agent.wake",
              actor: "system",
              company: state.company,
              agent: agent_slug,
              trigger: "heartbeat"
            })

          {:skip, reason} ->
            emit_audit(state, %{
              action: "agent.heartbeat_skipped",
              actor: "system",
              company: state.company,
              agent: agent_slug,
              reason: reason
            })
        end

        # Pitfall 3: recompute next-run from current wall-clock, regardless
        # of whether dispatch ran — a skipped heartbeat still re-arms.
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
    delay_ms = compute_delay_ms(expr, now, agent_slug, reg_or_entry, state)

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

  defp compute_delay_ms(expr, %DateTime{} = now, agent_slug, reg_or_entry, state) do
    naive = DateTime.to_naive(now)

    case CronScheduler.get_next_run_date(expr, naive) do
      {:ok, next_naive} ->
        next_dt = DateTime.from_naive!(next_naive, "Etc/UTC")
        DateTime.diff(next_dt, now, :millisecond)

      {:error, reason} ->
        # WR-03: audit the parseable-but-unfireable cron (e.g. `0 0 30 2 *` —
        # Feb 30th never fires). Without this, an operator sees only the
        # application-log warning and their agent silently heartbeats every
        # hour forever.
        emit_audit(state, %{
          action: "scheduler.cron_never_fires",
          actor: "system",
          company: state.company,
          agent: agent_slug,
          cron: Map.get(reg_or_entry, :cron),
          reason: inspect(reason),
          fallback_delay_ms: 3_600_000
        })

        Logger.warning(
          "scheduler: get_next_run_date failed for #{agent_slug} " <>
            "(#{inspect(reason)}); defaulting to 1h delay"
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
  catch
    :exit, reason ->
      Logger.error("scheduler audit emit exited: #{inspect(reason)}")
      :error
  end

  # AuditLog.append/2 expects a GenServer.server reference, not a company
  # slug string. Resolve via Registry and fall back to the default-named
  # AuditLog (test mode / init orchestration edge cases).
  # Mirrors Router.default_audit_fun/2 (R28 fix).
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

  # ---------------------------------------------------------------------------
  # GEP-14 — HEARTBEAT.md contract
  # ---------------------------------------------------------------------------

  @doc false
  # Default resolver: `<base>/companies/<co>/agents/<slug>/HEARTBEAT.md`.
  # Returns `{:ok, binary} | {:error, atom}`.
  @spec default_heartbeat_lookup(Path.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, atom()}
  def default_heartbeat_lookup(base, company, agent_slug) do
    path =
      Path.join([
        base,
        "companies",
        company,
        "agents",
        agent_slug,
        "HEARTBEAT.md"
      ])

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size > @heartbeat_max_bytes ->
        {:error, :file_too_large}

      {:ok, _stat} ->
        File.read(path)

      {:error, :enoent} ->
        {:error, :no_heartbeat_file}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp heartbeat_status(state, agent_slug) do
    case state.heartbeat_file_fun.(state.base, state.company, agent_slug) do
      {:ok, content} ->
        if String.trim(content) == "",
          do: {:skip, "no_heartbeat_file"},
          else: :ok

      {:error, :no_heartbeat_file} ->
        {:skip, "no_heartbeat_file"}

      {:error, :file_too_large} ->
        {:skip, "file_too_large"}

      {:error, reason} ->
        {:skip, "read_error:#{inspect(reason)}"}
    end
  end
end
