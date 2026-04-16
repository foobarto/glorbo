defmodule Glorbo.Agent.Registry do
  @moduledoc """
  Process registry for per-agent GenServers and Task.Supervisors
  (T-03-21 mitigation).

  Keys are 3-tuples `{kind, company_slug, agent_slug}` where `kind` is one of:

    * `:agent_server` — the `Glorbo.Agent.Server` for this agent.
    * `:agent_task_sup` — the per-agent `Task.Supervisor` (D-28 sibling).
    * `:agent_subtree` — the 2-child `one_for_all` Supervisor owning both of
      the above (used by `Glorbo.Company.AgentSupervisor` for `stop_agent/2`
      lookups).

  The registry is started as a top-level supervisor child by Plan 03-05's
  application wiring; `child_spec/1` below provides the canonical child
  spec.
  """

  @doc """
  Child spec suitable for inclusion in a top-level supervisor. Starts a
  `Registry` with `keys: :unique` registered under this module name.
  """
  def child_spec(_opts) do
    Registry.child_spec(keys: :unique, name: __MODULE__)
  end

  @doc """
  Build a `:via` tuple suitable for naming a process registered in this
  registry. Use as the `name:` option of `GenServer.start_link/2`,
  `Task.Supervisor.start_link/1`, or `Supervisor.start_link/2`.
  """
  @spec via(atom(), String.t(), String.t()) ::
          {:via, Registry, {__MODULE__, {atom(), String.t(), String.t()}}}
  def via(kind, company, agent)
      when is_atom(kind) and is_binary(company) and is_binary(agent) do
    {:via, Registry, {__MODULE__, {kind, company, agent}}}
  end
end
