defmodule Glorbo.Agent.Server do
  @moduledoc """
  Per-agent GenServer with a wake-queue state machine (D-25..D-28; T-03-18;
  AGT-01 crash isolation).

  Under `Glorbo.Company.AgentSupervisor`, each agent gets a small 2-child
  `one_for_all` sub-supervisor with:

    1. `Task.Supervisor` (sibling placement, D-28) — runs the dispatch
       invocation via `Task.Supervisor.async_nolink/3` so a Task crash
       sends `:DOWN` (not `EXIT`) and does NOT cascade to this Server.
    2. This `Agent.Server` — owns the wake-queue + dispatches tasks.

  Crash semantics: killing either child restarts BOTH (clean slate). The
  parent AgentSupervisor is untouched; other agents are unaffected.

  ## Wake triggers (AGT-02)

  Accepted via `wake/2,3`:

    * `:inbox` — inotify inbox event (Plan 03-05 wires Watcher → here)
    * `:heartbeat` — cron-driven (Plan 03-02 Scheduler)
    * `:mention` — Router fans out `@<name>` mentions
    * `:director_approval` — Gate releases sentinel-blocked task
    * `:director_request` — Director-initiated dispatch

  Unknown triggers return `{:error, :unknown_trigger}` (A8).

  ## Wake-queue (D-26 / T-03-18)

  While busy, at most ONE wake is queued. Additional wakes coalesce into
  that single slot with the most-recent trigger winning. Dispatch
  completion pops the queued wake and immediately schedules the next
  invocation. Chatty inotify bursts produce at most one additional
  dispatch per burst.

  ## Dep-injection

    * `:dispatch_fun` — `(spec, task, opts -> dispatch_result)` (default
      `&Glorbo.Agent.Dispatch.execute/3`). Tests supply a fake that sends
      `{:dispatch_done, result}` to a coordinator pid.
    * `:inbox_scan_fun` — `(spec -> task() | nil)`. Real impl scans the
      agent's inbox for the oldest unread message; tests pass a stub.
  """
  use GenServer
  require Logger

  alias Glorbo.Agent.Dispatch

  @valid_triggers ~w(inbox heartbeat mention director_approval director_request)a

  @type trigger :: :inbox | :heartbeat | :mention | :director_approval | :director_request
  @type status :: %{
          state: :idle | :busy,
          current_task: String.t() | nil,
          pending_wake: {trigger(), DateTime.t()} | nil,
          last_exit_status: term() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a per-agent GenServer.

  Required opts:

    * `:spec` — `%Glorbo.Agent.Spec{}` (provides slug, provider, model).
    * `:company` — company slug (must match `spec.company` in production).
    * `:task_supervisor` — name of this agent's `Task.Supervisor`
      (provided by `Glorbo.Company.AgentSupervisor.start_agent/2`).

  Optional:

    * `:registry` — `Glorbo.Agent.Registry` by default.
    * `:name` — `:via` tuple; when absent, derived from
      `Glorbo.Agent.Registry.via(:agent_server, company, spec.slug)`.
    * `:dispatch_fun` — `(spec, task, opts -> dispatch_result)`.
    * `:inbox_scan_fun` — `(spec -> task() | nil)`.
    * `:dispatch_opts` — extra opts passed through to the dispatch fun.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    spec = Keyword.fetch!(opts, :spec)
    company = Keyword.fetch!(opts, :company)

    name =
      Keyword.get_lazy(opts, :name, fn ->
        registry = Keyword.get(opts, :registry, Glorbo.Agent.Registry)
        {:via, Registry, {registry, {:agent_server, company, spec.slug}}}
      end)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Enqueue a wake. Returns `:ok` or `{:error, :unknown_trigger}`.

  The dispatch work is ALWAYS async (Task.Supervisor); this call blocks
  only for the GenServer state update (microseconds).
  """
  @spec wake(GenServer.server(), trigger(), map() | nil) ::
          :ok | {:error, :unknown_trigger}
  def wake(server, trigger, task \\ nil) do
    GenServer.call(server, {:wake, trigger, task})
  end

  @doc """
  Snapshot of the agent's scheduling state.
  """
  @spec status(GenServer.server()) :: status()
  def status(server) do
    GenServer.call(server, :status)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    spec = Keyword.fetch!(opts, :spec)
    company = Keyword.fetch!(opts, :company)
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    state = %{
      spec: spec,
      company: company,
      task_supervisor: task_sup,
      dispatch_fun: Keyword.get(opts, :dispatch_fun, &default_dispatch_fun/3),
      inbox_scan_fun: Keyword.get(opts, :inbox_scan_fun, fn _spec -> nil end),
      dispatch_opts: Keyword.get(opts, :dispatch_opts, []),
      status: :idle,
      current_task: nil,
      current_task_ref: nil,
      pending_wake: nil,
      last_exit_status: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:wake, trigger, _task}, _from, state) when trigger not in @valid_triggers do
    {:reply, {:error, :unknown_trigger}, state}
  end

  def handle_call({:wake, trigger, task}, _from, state) do
    if state.status == :idle do
      handle_wake_idle(state, trigger, task)
    else
      # Busy: queue (or replace) pending wake with most-recent-wins
      # semantics (D-26). At most ONE slot.
      {:reply, :ok, %{state | pending_wake: {trigger, DateTime.utc_now()}}}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       state: state.status,
       current_task: state.current_task,
       pending_wake: state.pending_wake,
       last_exit_status: state.last_exit_status
     }, state}
  end

  defp handle_wake_idle(state, trigger, task) do
    case resolve_task(state, trigger, task) do
      nil ->
        # Trigger with no resolvable task — stay idle. Not an error;
        # inbox scan may legitimately find nothing.
        {:reply, :ok, state}

      resolved ->
        {:reply, :ok, start_dispatch(state, resolved)}
    end
  end

  # Dispatch Task completed normally — demonitor + update state + pop pending
  @impl true
  def handle_info({ref, result}, %{current_task_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    finish(state, {:result, result})
  end

  # Dispatch Task crashed — convert to exit-status + update state + pop pending
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current_task_ref: ref} = state
      ) do
    finish(state, {:crashed, reason})
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Dispatch lifecycle
  # ---------------------------------------------------------------------------

  defp start_dispatch(state, task) do
    task_fn = fn ->
      state.dispatch_fun.(state.spec, task, state.dispatch_opts)
    end

    %Task{ref: ref} = Task.Supervisor.async_nolink(state.task_supervisor, task_fn)

    %{
      state
      | status: :busy,
        current_task: task.task_id,
        current_task_ref: ref,
        pending_wake: nil
    }
  end

  defp finish(state, {:result, result}) do
    exit_status = dispatch_result_to_exit_status(result)

    new_state = %{
      state
      | status: :idle,
        current_task: nil,
        current_task_ref: nil,
        last_exit_status: exit_status
    }

    pop_pending(new_state)
  end

  defp finish(state, {:crashed, reason}) do
    new_state = %{
      state
      | status: :idle,
        current_task: nil,
        current_task_ref: nil,
        last_exit_status: {:crashed, reason}
    }

    pop_pending(new_state)
  end

  defp pop_pending(%{pending_wake: nil} = state), do: {:noreply, state}

  defp pop_pending(%{pending_wake: {trigger, _ts}} = state) do
    case resolve_task(state, trigger, nil) do
      nil ->
        {:noreply, %{state | pending_wake: nil}}

      resolved ->
        {:noreply, start_dispatch(%{state | pending_wake: nil}, resolved)}
    end
  end

  defp resolve_task(_state, _trigger, %{} = explicit_task), do: explicit_task

  defp resolve_task(state, _trigger, nil) do
    state.inbox_scan_fun.(state.spec)
  end

  defp dispatch_result_to_exit_status({:ok, %{exit_status: s}}), do: s
  defp dispatch_result_to_exit_status({:stopped, :budget_hard_stop}), do: "budget_hard_stop"
  defp dispatch_result_to_exit_status({:error, reason}), do: {:error, reason}
  defp dispatch_result_to_exit_status(other), do: {:unexpected, other}

  defp default_dispatch_fun(spec, task, opts) do
    Dispatch.execute(spec, task, opts)
  end
end
