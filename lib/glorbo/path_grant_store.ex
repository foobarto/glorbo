defmodule Glorbo.PathGrantStore do
  @moduledoc """
  ETS-backed store for ephemeral, task-scoped path grants (GEP-27).

  Grants are keyed by `{company, agent_slug, task_id}` and removed
  after dispatch completion. A BEAM restart clears all grants —
  agents must re-request, which is correct for task-scoped access.

  The table is owned by this application-level GenServer and named
  `:glorbo_path_grants` for efficient concurrent reads. Company path gates
  register themselves with the owner; when a gate terminates, all grants for
  that company are revoked fail-closed.

  ## Grant shape

      %{
        company: "acme",
        agent: "engineer",
        task_id: "deploy-01",
        paths: [
          %{host_path: "/etc/myapp/config.yaml", sandbox_path: "/external/config.yaml", mode: :read},
          %{host_path: "/shared/data", sandbox_path: "/external/data", mode: :write}
        ],
        granted_at: DateTime
      }
  """

  use GenServer

  @table :glorbo_path_grants

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    {:ok, %{companies: %{}, monitors: %{}}}
  end

  @doc """
  Ensure the supervised store exists. The application starts it normally;
  the fallback start supports isolated tests that do not boot the application.
  """
  @spec ensure_started :: :ok
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start path grant store: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Register the process whose lifetime owns a company's grants.

  Re-registering replaces the previous monitor. Any termination of the owner
  revokes the company's grants, including abrupt gate crashes.
  """
  @spec register_company(String.t(), pid()) :: :ok
  def register_company(company, owner_pid \\ self())
      when is_binary(company) and is_pid(owner_pid) do
    ensure_started()
    GenServer.call(__MODULE__, {:register_company, company, owner_pid})
  end

  @doc """
  Store a grant for `{company, agent, task_id}`. Overwrites any
  existing grant for the same key (idempotent — the director may
  re-approve with a modified set of paths).
  """
  @spec grant(String.t(), String.t(), String.t(), [map()], DateTime.t()) :: :ok
  def grant(company, agent, task_id, paths, granted_at) do
    ensure_started()
    key = {company, agent, task_id}

    value = %{
      company: company,
      agent: agent,
      task_id: task_id,
      paths: paths,
      granted_at: granted_at
    }

    :ets.insert(@table, {key, value})
    :ok
  end

  @doc """
  Look up all active grants for a `{company, agent, task_id}` tuple.
  Returns `{:ok, paths}` or `:not_found`.
  """
  @spec lookup(String.t(), String.t(), String.t()) :: {:ok, [map()]} | :not_found
  def lookup(company, agent, task_id) do
    ensure_started()
    key = {company, agent, task_id}

    case :ets.lookup(@table, key) do
      [{^key, %{paths: paths}}] -> {:ok, paths}
      [] -> :not_found
    end
  end

  @doc """
  Revoke a grant for `{company, agent, task_id}`. No-op if not found.
  """
  @spec revoke(String.t(), String.t(), String.t()) :: :ok
  def revoke(company, agent, task_id) do
    ensure_started()
    key = {company, agent, task_id}
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  Revoke all grants for a company. Called when a company supervisor
  shuts down.
  """
  @spec revoke_all(String.t()) :: :ok
  def revoke_all(company) do
    ensure_started()
    match_key = {{company, :_, :_}, :_}
    :ets.select_delete(@table, [{match_key, [], [true]}])
    :ok
  end

  @doc """
  List all active grants (for debugging / UI).
  """
  @spec list_all() :: [map()]
  def list_all do
    ensure_started()
    :ets.foldl(fn {_key, value}, acc -> [value | acc] end, [], @table)
  end

  @doc """
  List active grants for a specific company.
  """
  @spec list_for_company(String.t()) :: [map()]
  def list_for_company(company) do
    ensure_started()
    match_key = {{company, :_, :_}, :"$1"}
    :ets.select(@table, [{match_key, [], [:"$1"]}])
  end

  @doc """
  List active grants for a specific agent within a company.
  """
  @spec list_for_agent(String.t(), String.t()) :: [map()]
  def list_for_agent(company, agent) do
    ensure_started()
    match_key = {{company, agent, :_}, :"$1"}
    :ets.select(@table, [{match_key, [], [:"$1"]}])
  end

  @doc """
  Look up active grants by task_id across all agents in a company.
  Returns a list of grant values (each containing agent, paths, etc.).
  """
  @spec lookup_by_task_id(String.t(), String.t()) :: [map()]
  def lookup_by_task_id(company, task_id) do
    ensure_started()
    match_key = {{company, :"$1", task_id}, :"$2"}
    :ets.select(@table, [{match_key, [], [:"$2"]}])
  end

  @impl true
  def handle_call({:register_company, company, owner_pid}, _from, state) do
    state = drop_company_monitor(state, company)
    ref = Process.monitor(owner_pid)

    {:reply, :ok,
     %{
       state
       | companies: Map.put(state.companies, company, {owner_pid, ref}),
         monitors: Map.put(state.monitors, ref, company)
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {company, monitors} ->
        revoke_all(company)
        {:noreply, %{state | companies: Map.delete(state.companies, company), monitors: monitors}}
    end
  end

  defp drop_company_monitor(state, company) do
    case Map.pop(state.companies, company) do
      {nil, _companies} ->
        state

      {{_pid, ref}, companies} ->
        Process.demonitor(ref, [:flush])
        %{state | companies: companies, monitors: Map.delete(state.monitors, ref)}
    end
  end
end
