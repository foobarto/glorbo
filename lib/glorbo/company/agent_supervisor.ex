defmodule Glorbo.Company.AgentSupervisor do
  @moduledoc """
  Per-company `DynamicSupervisor` that owns one sub-tree per agent
  (AGT-01, D-25, D-28).

  Each `start_agent/2` call spins up a 2-child `Supervisor` with strategy
  `:one_for_all`:

    1. `Task.Supervisor` (sibling of Agent.Server; D-28).
    2. `Glorbo.Agent.Server` (owns the wake-queue; tests dispatch_fun).

  `one_for_all` means killing either child restarts BOTH — the clean-slate
  recovery avoids stale references between Server and Task.Supervisor.

  The 2-child sub-supervisor itself registers at
  `{:agent_subtree, company, slug}` so `stop_agent/2` can look it up and
  terminate it cleanly.

  ## API

    * `start_link/1` — opts `[name: :required, company: :required]`.
    * `start_agent/2` — spawns the sub-tree for `spec`; returns
      `{:ok, pid}` or `{:error, {:already_started, pid}}`.
    * `stop_agent/2` — terminates the sub-tree by slug.
  """
  use DynamicSupervisor

  alias Glorbo.Agent.Registry, as: AgentRegistry
  alias Glorbo.Agent.Server, as: AgentServer

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @spec start_agent(GenServer.server(), Glorbo.Agent.Spec.t(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_agent(sup, %_{} = spec, agent_opts \\ []) do
    company = spec.company
    slug = spec.slug
    registry = Keyword.get(agent_opts, :registry, AgentRegistry)

    task_sup_name = {:via, Registry, {registry, {:agent_task_sup, company, slug}}}
    server_name = {:via, Registry, {registry, {:agent_server, company, slug}}}
    subtree_name = {:via, Registry, {registry, {:agent_subtree, company, slug}}}

    children = [
      {Task.Supervisor, name: task_sup_name},
      %{
        id: AgentServer,
        start:
          {AgentServer, :start_link,
           [
             Keyword.merge(
               [
                 spec: spec,
                 company: company,
                 task_supervisor: task_sup_name,
                 registry: registry,
                 name: server_name
               ],
               Keyword.drop(agent_opts, [:registry])
             )
           ]}
      }
    ]

    child_spec = %{
      id: {:agent_subtree, company, slug},
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all, name: subtree_name]]},
      restart: :transient,
      type: :supervisor
    }

    DynamicSupervisor.start_child(sup, child_spec)
  end

  @spec stop_agent(GenServer.server(), String.t(), String.t(), module()) ::
          :ok | {:error, :not_found}
  def stop_agent(sup, company, slug, registry \\ AgentRegistry) do
    case Registry.lookup(registry, {:agent_subtree, company, slug}) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(sup, pid)

      [] ->
        {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # DynamicSupervisor callback
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
