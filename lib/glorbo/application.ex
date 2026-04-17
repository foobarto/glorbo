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

  @doc """
  Public entrypoint used by `glorbo serve` + `glorbo run` (Plan 05-02).

  Delegates to the private `start_supervision_tree/0` the Burrito / test
  boot paths already exercise. Tolerates a supervisor that's already
  started (Phoenix `ConnCase`, LiveView tests, or an earlier `serve` in
  the same BEAM) by returning `{:ok, :already_started, pid}` — callers
  that just need to know the tree is up (both CLI verbs) can pattern-match
  on `{:ok, _}`.
  """
  @spec start_supervision_tree_for_serve() ::
          {:ok, pid()} | {:ok, :already_started, pid()} | {:error, term()}
  def start_supervision_tree_for_serve do
    case start_supervision_tree() do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, :already_started, pid}

      {:error, _} = err ->
        err
    end
  end

  defp start_supervision_tree do
    children = [
      Glorbo.Repo,
      {DNSCluster, query: Application.get_env(:glorbo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Glorbo.PubSub},
      {Finch, name: Glorbo.Finch},
      GlorboWeb.Telemetry,
      # Plan 03-05: Agent.Registry MUST start before CompanySupervisor — the
      # per-agent sub-supervisors register their Server/Task.Supervisor pids
      # here via :via tuples during company boot.
      Glorbo.Agent.Registry,
      # GEP-8: CLI provider registry. MUST start before CompanySupervisor
      # so Agent.Server can resolve its provider at agent-boot time.
      # Load-validation failure is a hard crash by design (GEP-8 D9).
      Glorbo.CLI.Registry,
      {DynamicSupervisor, name: Glorbo.CompanySupervisor, strategy: :one_for_one},
      # M-series fix: enumerate companies on disk at boot and start a
      # per-company supervisor for each. Without this, the dashboard
      # has no AuditLog/Router/Gate/etc. registered — every Director
      # write-action would time out and crash the LiveView.
      # Disabled under `mix test` via config (:glorbo, :auto_start_companies, false).
      Glorbo.CompanyBoot,
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
