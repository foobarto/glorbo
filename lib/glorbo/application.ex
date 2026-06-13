defmodule Glorbo.Application do
  @moduledoc false
  use Application
  require Logger

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
    # Write the BEAM pid to `<base>/run/glorbo.pid` so operators + the
    # `glorbo status` / `glorbo down` / `mix glorbo.kill` verbs can find
    # this process without pgrep-golf. Gated under test env so ExUnit
    # doesn't churn `~/.glorbo/run/glorbo.pid` on every mix test run.
    maybe_write_pidfile()

    children = [
      Glorbo.Repo,
      Glorbo.DB.Bootstrap,
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
      # GEP-32 phase 3: host-side native-provider model catalog cache.
      Glorbo.Providers.ModelCatalog,
      # GEP-23 Phase 5: ephemeral per-dispatch Proxy-Authorization tokens.
      # Reaper GenServer also owns the ETS table; starts before
      # CompanySupervisor so the first dispatch can register + the
      # Proxy can resolve without racing table creation.
      Glorbo.Network.ProxyTokens,
      # GEP-33 Phase 2b: durable-history transaction buffer. Wraps
      # `HomeHistory.commit_marked/3` with the §6.1 debounce window
      # so multi-file logical operations land as one commit. Safe to
      # run when `.git/` is absent — flush translates the
      # `:not_initialised` strict error into a clean no-op so Phase 2c
      # callers can ignore the result. Disabled under `mix test` via
      # config (:glorbo, :start_home_history_tx, false) so per-test
      # Tx instances pinned to tmp bases can register the canonical
      # name without clashing.
      Glorbo.HomeHistory.Tx,
      # GEP-33 Phase 3: watcher-fallback bridge. Catches manual edits
      # to tracked-scope paths via the existing per-company watcher
      # and emits `External` provenance commits.
      Glorbo.HomeHistory.WatcherBridge,
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
      {DynamicSupervisor,
       name: GlorboWeb.StdoutStreamer.Supervisor, strategy: :one_for_one, max_restarts: 100},
      # GEP-29 wave (d.2): per-MCP-session state (subscriptions + SSE
      # pid) under a DynamicSupervisor, addressed via a :unique Registry
      # keyed by the Mcp-Session-Id header.
      {Registry, keys: :unique, name: GlorboWeb.MCP.SessionRegistry},
      # Threatmodel T5: cap concurrent MCP sessions so a local-only
      # misbehaving client can't exhaust memory by spamming `initialize`
      # without ever sending DELETE. 256 is well above legitimate
      # usage (every editor tab + agent tends to use a single session)
      # but low enough that a runaway loop can't take the BEAM down.
      {DynamicSupervisor,
       name: GlorboWeb.MCP.SessionSupervisor,
       strategy: :one_for_one,
       max_restarts: 100,
       max_children: 256},
      # GEP-0053 D14/D15: escalating-delay throttle for /login passphrase
      # attempts. O(1) global state; must be up before the Endpoint serves.
      GlorboWeb.LoginThrottle,
      GlorboWeb.Endpoint
    ]

    # GEP-33 Phase 2c: under `mix test`, drop the Tx server from the
    # supervised tree so per-test instances can claim the canonical
    # registered name without a clash. Production + dev keep it.
    # The Phase 3 WatcherBridge is gated by the same flag — tests
    # that exercise the bridge spin up their own pinned instance.
    children =
      if Application.get_env(:glorbo, :start_home_history_tx, true) do
        children
      else
        Enum.reject(children, fn child ->
          child in [Glorbo.HomeHistory.Tx, Glorbo.HomeHistory.WatcherBridge]
        end)
      end

    # GEP-37 Phase 1: surface selection. `:web` (default) keeps the
    # current Endpoint-only tree; `:tui` swaps `Endpoint` for the
    # `Glorbo.Shell.Supervisor` subtree (EventBus + Runtime, see
    # GEP-37 D6); `:headless` strips both. Setting :surface is the
    # job of the CLI verb (`glorbo shell` / `glorbo serve`) before
    # Application boot. Per-test isolation: the shell modules are
    # spun up directly by `test/glorbo/shell/*_test.exs` against
    # unique registered names, so the canonical names stay free.
    children = apply_surface(children, Application.get_env(:glorbo, :surface, :web))

    # #145: raise the parent supervisor's restart intensity too — when
    # streamer test tests rapidly churn children, the default
    # `max_restarts: 3, max_seconds: 5` can cascade and kill the whole
    # tree (Ecto.Repo, PubSub, Registry). Production agents don't churn
    # anywhere near this rate, so a higher tolerance is pure test ergonomics.
    opts = [strategy: :one_for_one, name: Glorbo.Supervisor, max_restarts: 100, max_seconds: 5]
    Supervisor.start_link(children, opts)
  end

  # GEP-37 Phase 1 — surface selection, see runtime-shape section in
  # docs/geps/0037-glorbo-shell.md. Phase 1 ships the OTP plumbing;
  # Phase 2 will wire the term_ui app module into Runtime. The
  # default `:web` keeps existing behaviour; `:tui` swaps in the
  # shell subtree; `:headless` runs neither and is reserved for
  # CI / orchestrator-only deployments (no UI surface, no MCP
  # endpoint that depends on Endpoint).
  defp apply_surface(children, :web), do: children

  defp apply_surface(children, :tui) do
    children
    |> Enum.reject(&match?(GlorboWeb.Endpoint, &1))
    |> Kernel.++([{Glorbo.Shell.Supervisor, [eventbus_opts: shell_eventbus_opts()]}])
  end

  defp apply_surface(children, :headless) do
    Enum.reject(children, &match?(GlorboWeb.Endpoint, &1))
  end

  defp apply_surface(children, _other), do: children

  defp shell_eventbus_opts do
    # Phase 1 ships an empty roster; the shell currently surfaces no
    # views so live PubSub traffic has nowhere to render. Phase 2
    # will enumerate companies from `Glorbo.Repo` at boot time and
    # subscribe per-company before the first view paints.
    [companies: []]
  end

  defp maybe_write_pidfile do
    if Application.get_env(:glorbo, :write_pidfile_on_boot, true) do
      try do
        pid = System.pid() |> String.to_integer()
        Glorbo.CLI.Lifecycle.Pidfile.write!(pid)
      rescue
        # Best-effort: if the base dir isn't writable, log and continue.
        # The server still boots; status/kill tooling just won't find us.
        e -> Logger.warning("pidfile write failed: #{Exception.message(e)}")
      end
    end
  end

  # Release-binary CLI path. The BEAM requires start/2 to return `{:ok, pid}`;
  # we start a trivial empty supervisor and schedule the halt on the timer
  # wheel so the OS exit happens AFTER the Application callback returns.
  #
  # WR-06: using `:timer.apply_after/4` (no extra unlinked process) is more
  # deterministic than `Task.start` under scheduler contention.
  defp run_cli_and_halt(argv) do
    # GEP-61: one-time, best-effort migration of provider config + credentials
    # out of ~/.glorbo into the XDG config root. Runs only on the real binary
    # (this path is gated on a non-empty release argv), before any verb reads
    # provider config. Idempotent + self-rescuing — never blocks the CLI.
    _ = Glorbo.Filesystem.ConfigMigration.run()

    {_verb, exit_code, output} = Glorbo.CLI.dispatch(argv)
    IO.puts(output)

    {:ok, pid} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, _tref} = :timer.apply_after(0, :erlang, :halt, [exit_code])
    {:ok, pid}
  end
end
