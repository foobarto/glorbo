defmodule Mix.Tasks.Glorbo.Kill do
  @moduledoc """
  Stop a running `mix phx.server` (or `glorbo up`) by reading the PID
  from `~/.glorbo/run/glorbo.pid`.

  ## Usage

      mix glorbo.kill            # SIGTERM
      mix glorbo.kill --force    # SIGKILL
      mix glorbo.kill --base /custom/glorbo/root

  Exit codes:

    * `0` — signal delivered, process no longer alive when we last
      checked.
    * `1` — no pidfile found.
    * `2` — pidfile present but pid isn't alive (stale). File is
      removed.
    * `3` — signal delivered but pid still alive after a short grace.

  Complements the existing `glorbo down` CLI verb — this is the
  dev-ergonomic shortcut to kill a `mix phx.server` session without
  pgrep-golf.
  """
  @shortdoc "Stop the running Glorbo server via ~/.glorbo/run/glorbo.pid"

  use Mix.Task

  alias Glorbo.CLI.Lifecycle.Pidfile

  @switches [force: :boolean, base: :string, help: :boolean]
  @grace_ms 500

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      exit_with(0)
    end

    base = opts[:base] || Pidfile.default_base()
    force? = Keyword.get(opts, :force, false)

    case Pidfile.status(base) do
      :stopped ->
        Mix.shell().error("no pidfile at #{Pidfile.path(base)} — nothing to stop")
        exit_with(1)

      :stale ->
        Mix.shell().info([:yellow, "pidfile is stale (pid not alive); removing it"])
        Pidfile.rm(base)
        exit_with(2)

      :running ->
        kill_running(base, force?)
    end
  end

  defp kill_running(base, force?) do
    pid = Pidfile.read!(base)
    signal = if force?, do: "KILL", else: "TERM"

    Mix.shell().info([
      :cyan,
      "  signal ",
      :reset,
      "sending SIG#{signal} to pid #{pid}"
    ])

    case System.cmd("kill", ["-#{signal}", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(@grace_ms)
        verify_stopped(base, pid, signal, force?)

      {out, code} ->
        Mix.shell().error("kill exit #{code}: #{out}")
        exit_with(3)
    end
  end

  defp verify_stopped(base, pid, signal, force?) do
    if pid_alive?(pid) do
      Mix.shell().error("pid #{pid} still alive after SIG#{signal} (grace #{@grace_ms}ms)")
      unless force?, do: Mix.shell().info("hint: re-run with --force to SIGKILL")
      exit_with(3)
    else
      Mix.shell().info([:green, "  ok     ", :reset, "pid #{pid} stopped"])
      Pidfile.rm(base)
      exit_with(0)
    end
  end

  defp pid_alive?(pid) when is_integer(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # Wrap exit so tests that invoke `run/1` don't tear down ExUnit — but
  # mix tasks are one-shots in production, so `exit({:shutdown, N})` is
  # the right signal for the OS.
  defp exit_with(0), do: :ok
  defp exit_with(code), do: exit({:shutdown, code})
end
