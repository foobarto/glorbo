defmodule Glorbo.Application do
  @moduledoc false
  use Application

  alias Burrito.Util.Args, as: BurritoArgs

  @impl Application
  def start(_type, _args) do
    case release_argv() do
      [] -> start_supervision_tree()
      argv -> run_cli_and_halt(argv)
    end
  end

  @impl Application
  def config_change(changed, _new, removed) do
    GlorboWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ------ internals ------

  # Returns [] UNLESS we are running inside a Burrito-wrapped binary. Burrito
  # sets the `__BURRITO` env var when launching the wrapped release; `Util.Args.argv/0`
  # itself falls back to `System.argv/0` outside a wrapped binary — which would
  # incorrectly pick up `mix test` argv. Gating on the env var keeps the argv
  # branch physically unreachable from `mix test`, `iex -S mix`, or a regular
  # `mix phx.server`, so Plan 01's application_test.exs stays green.
  defp release_argv do
    if System.get_env("__BURRITO") != nil and
         Code.ensure_loaded?(BurritoArgs) and
         function_exported?(BurritoArgs, :argv, 0) do
      BurritoArgs.argv()
    else
      []
    end
  end

  defp start_supervision_tree do
    children = [
      Glorbo.Repo,
      {DNSCluster, query: Application.get_env(:glorbo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Glorbo.PubSub},
      GlorboWeb.Telemetry,
      Glorbo.ContainerManager,
      {DynamicSupervisor, name: Glorbo.CompanySupervisor, strategy: :one_for_one},
      GlorboWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Glorbo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Release-binary CLI path. The BEAM requires start/2 to return `{:ok, pid}`;
  # we start a trivial empty supervisor and schedule System.halt/1 in a Task
  # so the OS exit happens after the Application callback returns cleanly.
  defp run_cli_and_halt(argv) do
    {_verb, exit_code, output} = Glorbo.CLI.dispatch(argv)
    IO.puts(output)

    {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
    Task.start(fn -> System.halt(exit_code) end)
    {:ok, pid}
  end
end
