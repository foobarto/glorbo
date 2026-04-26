defmodule Glorbo.Shell.Supervisor do
  @moduledoc """
  GEP-37 Phase 1 — supervisor for the `glorbo shell` subtree.

  `:rest_for_one` strategy over two children, in declared order:

    1. `Glorbo.Shell.EventBus` — PubSub bridge from Glorbo's
       per-company topics into Runtime.
    2. `Glorbo.Shell.Runtime` — state holder (Phase 2 will turn
       this into a `term_ui` app module driving the render loop).

  Per GEP-37 D6, this supervisor is a *sibling* of
  `Glorbo.CompanySupervisor` under `Glorbo.Application`, NOT a
  parent. A shell crash cannot kill agents, the router, audit, or
  any other core service — bounded blast radius per GEP-2 D2.
  """
  use Supervisor

  alias Glorbo.Shell.{EventBus, Runtime}

  @doc """
  Start the shell subtree under the application supervisor.

  Options:

    * `:name` — supervisor's registered name (default: this module).
    * `:eventbus_opts` — opts forwarded to `EventBus.start_link/1`.
    * `:runtime_opts` — opts forwarded to `Runtime.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    runtime_name = Keyword.get(opts, :runtime_name, Runtime)
    eventbus_name = Keyword.get(opts, :eventbus_name, EventBus)

    runtime_opts =
      opts
      |> Keyword.get(:runtime_opts, [])
      |> Keyword.put_new(:name, runtime_name)

    eventbus_opts =
      opts
      |> Keyword.get(:eventbus_opts, [])
      |> Keyword.put_new(:name, eventbus_name)
      |> Keyword.put_new(:runtime, runtime_name)

    children = [
      {EventBus, eventbus_opts},
      {Runtime, runtime_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
