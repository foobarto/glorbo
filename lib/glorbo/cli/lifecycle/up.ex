defmodule Glorbo.CLI.Lifecycle.Up do
  @moduledoc """
  `glorbo up` — D-07: start glorbo in the background.

  Flow:

    1. Check `Pidfile.status/1`. `:running` → refuse (exit 2). `:stale` →
       remove pidfile and proceed. `:stopped` → proceed.
    2. Get the Erlang distribution cookie via `Glorbo.Config.erl_cookie/1`.
       The cookie is opaque and MUST NEVER be logged (threat T-05-02).
    3. Discover the Burrito binary (`__BURRITO_BIN_PATH` in prod,
       `GLORBO_BINARY_PATH` override in tests).
    4. Delegate to `Glorbo.CLI.Lifecycle.Daemon.spawn_detached/2` to
       re-exec the binary under `setsid`, inheriting `RELEASE_COOKIE` via
       the env.
    5. Write the child OS pid to the pidfile; emit `cli.up.start` +
       `cli.up.complete` audit entries.

  Returns `{:up, 0, msg}` on success, `{:up, 2, msg}` on any refusal /
  failure (D-28 — operational failure with actionable hint).
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Lifecycle.{Daemon, Pidfile}

  @switches [help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    if opts[:help], do: {:up, 0, help_text()}, else: do_run()
  end

  defp do_run do
    base = glorbo_home()

    case Pidfile.status(base) do
      :running ->
        pid = Pidfile.read!(base)

        {:up, 2, "glorbo is already running (pid=#{pid}). Run `glorbo down` first.\n"}

      :stale ->
        :ok = Pidfile.rm(base)
        start_daemon(base)

      :stopped ->
        start_daemon(base)
    end
  end

  defp start_daemon(base) do
    Audit.emit("up", "start", %{})

    with {:ok, cookie} <- Glorbo.Config.erl_cookie(base),
         {:ok, binary} <- locate_binary(),
         env <- [
           {~c"RELEASE_COOKIE", String.to_charlist(cookie)},
           # Phoenix endpoints default to `server: false` in a Burrito
           # release; runtime.exs only flips `:server` to true when
           # PHX_SERVER is set. Without this the daemon comes up with
           # the supervision tree healthy but port 4000 unbound — the
           # browser fails to connect even though `glorbo status` reports
           # running. Set it here so `up` always serves.
           {~c"PHX_SERVER", ~c"1"}
         ],
         {:ok, os_pid} <- Daemon.spawn_detached(binary, env),
         :ok <- safe_pidfile_write(os_pid, base) do
      # NOTE: detail MUST NOT include the cookie (T-05-02).
      Audit.emit("up", "complete", %{pid: os_pid})

      # Derive the dashboard URL from config. GEP-0053 D18: state-aware —
      # `?token=` (→ /setup) only in bootstrap; bare /login once a passphrase
      # is set (the token is MCP/CLI-only then and shouldn't be reprinted).
      dashboard_url =
        case Glorbo.Config.load(base) do
          {:ok, cfg} ->
            Glorbo.CLI.Lifecycle.Banner.dashboard_url(
              "http://127.0.0.1:4000",
              cfg.director_password_hash,
              cfg.dashboard_token
            )

          _ ->
            "http://127.0.0.1:4000  (see ~/.glorbo/config.md)"
        end

      {:up, 0, "glorbo up (pid=#{os_pid}). Dashboard: #{dashboard_url}\n"}
    else
      {:error, {:pidfile_write, os_pid, reason}} ->
        # WR-04: daemon was already spawned by setsid but we cannot
        # record its pid. SIGKILL to avoid leaking a hidden orphan BEAM.
        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

        {:up, 2,
         "Failed to start glorbo: could not write pidfile (#{inspect(reason)}); " <>
           "daemon killed to avoid orphan. Run `glorbo doctor` to diagnose.\n"}

      {:error, reason} ->
        {:up, 2, "Failed to start glorbo: #{inspect(reason)}. Run `glorbo doctor` to diagnose.\n"}
    end
  end

  # WR-04: wrap Pidfile.write!/2 so a raise (disk full, EACCES, etc.)
  # becomes an error tuple the caller can act on. The orphan-kill branch
  # lives in start_daemon/1's else clause.
  defp safe_pidfile_write(os_pid, base) do
    Pidfile.write!(os_pid, base)
    :ok
  rescue
    e -> {:error, {:pidfile_write, os_pid, Exception.message(e)}}
  end

  defp locate_binary do
    case System.get_env("__BURRITO_BIN_PATH") || System.get_env("GLORBO_BINARY_PATH") do
      nil ->
        {:error, :binary_not_found}

      path ->
        {:ok, path}
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo up — start the orchestrator in the background.

    USAGE
      glorbo up [--help]

    SIDE EFFECTS
      Re-execs the Glorbo release binary under `setsid`, writes the OS pid
      to ~/.glorbo/run/glorbo.pid (mode 0600), exports RELEASE_COOKIE so
      Erlang distribution is wired for `glorbo console`, and binds the
      dashboard at http://127.0.0.1:4000.

    EXIT CODES
      0   Daemon started successfully.
      2   Already running, binary not found, or spawn failure (message
          names the remediation verb).

    SEE ALSO
      glorbo down, glorbo status, glorbo serve
    """
  end
end
