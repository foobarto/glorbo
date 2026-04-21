defmodule Glorbo.PathGrantStore do
  @moduledoc """
  ETS-backed store for ephemeral, task-scoped path grants (GEP-27).

  Grants are keyed by `{company, agent_slug, task_id}` and removed
  after dispatch completion. A BEAM restart clears all grants —
  agents must re-request, which is correct for task-scoped access.

  The table is created on first call via `ensure_started/0` and
  named `:glorbo_path_grants` for easy lookup from any process.

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

  @table :glorbo_path_grants

  @doc """
  Ensure the ETS table exists. Idempotent — safe to call from any
  process at any time. Called by `Company.Supervisor` at boot.
  """
  @spec ensure_started :: :ok
  def ensure_started do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, {:read_concurrency, true}])
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Store a grant for `{company, agent, task_id}`. Overwrites any
  existing grant for the same key (idempotent — the director may
  re-approve with a modified set of paths).
  """
  @spec grant(String.t(), String.t(), String.t(), [map()], DateTime.t()) :: :ok
  def grant(company, agent, task_id, paths, granted_at) do
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
    key = {company, agent, task_id}

    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, key)
    end

    :ok
  end

  @doc """
  Revoke all grants for a company. Called when a company supervisor
  shuts down.
  """
  @spec revoke_all(String.t()) :: :ok
  def revoke_all(company) do
    match_key = {{company, :_, :_}, :_}
    :ets.select_delete(@table, [{match_key, [], [true]}])
    :ok
  end

  @doc """
  List all active grants (for debugging / UI).
  """
  @spec list_all() :: [map()]
  def list_all do
    :ets.foldl(fn {_key, value}, acc -> [value | acc] end, [], @table)
  end

  @doc """
  List active grants for a specific company.
  """
  @spec list_for_company(String.t()) :: [map()]
  def list_for_company(company) do
    match_key = {{company, :_, :_}, :"$1"}
    :ets.select(@table, [{match_key, [], [:"$1"]}])
  end

  @doc """
  List active grants for a specific agent within a company.
  """
  @spec list_for_agent(String.t(), String.t()) :: [map()]
  def list_for_agent(company, agent) do
    match_key = {{company, agent, :_}, :"$1"}
    :ets.select(@table, [{match_key, [], [:"$1"]}])
  end

  @doc """
  Look up active grants by task_id across all agents in a company.
  Returns a list of grant values (each containing agent, paths, etc.).
  """
  @spec lookup_by_task_id(String.t(), String.t()) :: [map()]
  def lookup_by_task_id(company, task_id) do
    case :ets.info(@table) do
      :undefined ->
        []

      _ ->
        match_key = {{company, :"$1", task_id}, :"$2"}
        :ets.select(@table, [{match_key, [], [:"$2"]}])
    end
  end
end
