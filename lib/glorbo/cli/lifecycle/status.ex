defmodule Glorbo.CLI.Lifecycle.Status do
  @moduledoc """
  `glorbo status` — D-09: report orchestrator run-state.

  Checks:

    1. `Pidfile.status/1` — `:running` iff pidfile present AND pid alive.
    2. `:gen_tcp.connect/4` on `127.0.0.1:4000` with 500ms timeout —
       probes the Phoenix endpoint.

  Exit 0 iff BOTH checks pass; otherwise exit 3 (D-28 "not running"
  convention, matches `systemctl is-active`).

  Output modes:

    * default (human): 4-row table (running / pid / port / dashboard_url).
    * `--json`: `Jason.encode!` of `%{running: bool, pid: int|nil,
      port_listening: bool, dashboard_url: "..."}` with pretty-print.
  """

  alias Glorbo.CLI.Lifecycle.Pidfile

  @dashboard_url "http://127.0.0.1:4000"
  @port 4000
  @tcp_timeout_ms 500
  @switches [help: :boolean, json: :boolean]

  @spec run([String.t()], keyword()) :: Glorbo.CLI.result()
  def run(argv, run_opts \\ []) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    if opts[:help], do: {:status, 0, help_text()}, else: do_run(opts, run_opts)
  end

  defp do_run(opts, run_opts) do
    base = glorbo_home()
    status_map = build_status_map(base, run_opts)
    exit_code = if status_map.running and status_map.port_listening, do: 0, else: 3

    output =
      if opts[:json] do
        Jason.encode!(status_map, pretty: true) <> "\n"
      else
        format_table(status_map)
      end

    {:status, exit_code, output}
  end

  defp build_status_map(base, run_opts) do
    pidfile_status = Pidfile.status(base)
    running? = pidfile_status == :running

    pid =
      if running? do
        try do
          Pidfile.read!(base)
        rescue
          _ -> nil
        end
      else
        nil
      end

    port_check = Keyword.get(run_opts, :port_check_fun, &port_listening?/0)

    %{
      running: running?,
      pid: pid,
      port_listening: port_check.(),
      dashboard_url: @dashboard_url
    }
  end

  defp port_listening? do
    case :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: false], @tcp_timeout_ms) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp format_table(%{running: r, pid: p, port_listening: pl, dashboard_url: url}) do
    """
    glorbo status
      running       : #{if r, do: "yes", else: "no"}
      pid           : #{p || "-"}
      port #{@port}     : #{if pl, do: "listening", else: "closed"}
      dashboard_url : #{url}
    """
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo status — report orchestrator run-state.

    USAGE
      glorbo status [--json] [--help]

    EXIT CODES
      0   Running (pidfile present AND pid alive AND port 4000 listening).
      3   Not running.
    """
  end
end
