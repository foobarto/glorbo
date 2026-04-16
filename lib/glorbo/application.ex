defmodule Glorbo.Application do
  @moduledoc false
  use Application

  alias Burrito.Util.Args, as: BurritoArgs

  @impl Application
  def start(_type, _args) do
    if running_standalone?() do
      run_cli_and_halt(release_argv())
    else
      start_supervision_tree()
    end
  end

  @impl Application
  def config_change(changed, _new, removed) do
    GlorboWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # ------ internals ------

  # Returns true UNLESS we are running inside a Burrito-wrapped binary. Burrito
  # sets the `__BURRITO` env var when launching the wrapped release. Gating on
  # the env var keeps the CLI branch physically unreachable from `mix test`,
  # `iex -S mix`, or a regular `mix phx.server`, so Plan 01's
  # application_test.exs stays green under ExUnit. Under Burrito — even with
  # zero argv — we dispatch to `Glorbo.CLI.dispatch([])` which prints help and
  # halts 0 (user-confirmed A6: no-args `./glorbo` prints help + exits 0).
  defp running_standalone? do
    System.get_env("__BURRITO") != nil and
      Code.ensure_loaded?(BurritoArgs) and
      function_exported?(BurritoArgs, :argv, 0)
  end

  defp release_argv do
    BurritoArgs.argv()
  end

  defp start_supervision_tree do
    children = [
      Glorbo.Repo,
      {DNSCluster, query: Application.get_env(:glorbo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Glorbo.PubSub},
      # Shared Finch pool — used by Glorbo.Container.WorkerClient over Unix
      # domain sockets (Phase 2 Plan 03) and by Init downloads (Plan 02).
      {Finch, name: Glorbo.Finch},
      GlorboWeb.Telemetry,
      # CR-04: DaemonSupervisor MUST start before ContainerManager so
      # persistent-mode launches register Daemons out-of-band instead of
      # linking them to ContainerManager (crash isolation invariant).
      {DynamicSupervisor, name: Glorbo.Container.DaemonSupervisor, strategy: :one_for_one},
      Glorbo.ContainerManager,
      # Plan 03-05: Agent.Registry MUST start before CompanySupervisor — the
      # per-agent sub-supervisors register their Server/Task.Supervisor pids
      # here via :via tuples during company boot.
      Glorbo.Agent.Registry,
      {DynamicSupervisor, name: Glorbo.CompanySupervisor, strategy: :one_for_one},
      # Phase 4 Wave 0: per-agent-page stdout tail streamers. AgentLive
      # spawns children on mount; crash in one streamer does not affect
      # other streamers or the LiveView (LV uses Process.monitor/1 for
      # cleanup — see GlorboWeb.StdoutStreamer moduledoc).
      {DynamicSupervisor, name: GlorboWeb.StdoutStreamer.Supervisor, strategy: :one_for_one},
      GlorboWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Glorbo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Release-binary CLI path. The BEAM requires start/2 to return `{:ok, pid}`;
  # we start a trivial empty supervisor and schedule the halt on the timer
  # wheel so the OS exit happens AFTER the Application callback returns.
  #
  # WR-06: using `:timer.apply_after/4` (no extra unlinked process) is more
  # deterministic than `Task.start` under scheduler contention.
  defp run_cli_and_halt(argv) do
    {_verb, exit_code, output} = Glorbo.CLI.dispatch(argv)
    IO.puts(output)

    {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, _tref} = :timer.apply_after(0, :erlang, :halt, [exit_code])
    {:ok, pid}
  end
end
