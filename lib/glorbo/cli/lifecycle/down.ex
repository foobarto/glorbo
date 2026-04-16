defmodule Glorbo.CLI.Lifecycle.Down do
  @moduledoc """
  `glorbo down` — D-08: stop the running glorbo daemon.

  Flow (pidfile-driven):

    * `:stopped` (no pidfile) → exit 3 (`"glorbo is not running."`), matches
      `systemctl is-active`-style D-28 "not running" convention.
    * `:stale` (pidfile but dead pid) → clean up pidfile, exit 0.
    * `:running` (pidfile + alive pid) → SIGTERM, poll up to 10s in 100ms
      ticks, SIGKILL if still alive, remove pidfile, exit 0.

  Emits `cli.down.start` + `cli.down.complete` audit entries for every
  non-stopped path (no audit for the "not running" fast-path because
  there's nothing to record — D-28 treats this as user-error-ish).
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Lifecycle.Pidfile

  @switches [help: :boolean, force: :boolean]

  # 10s total wait (100 iterations of 100ms) before escalating to SIGKILL.
  @poll_ms 100
  @max_iters 100

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    if opts[:help], do: {:down, 0, help_text()}, else: do_run()
  end

  defp do_run do
    base = glorbo_home()

    case Pidfile.status(base) do
      :stopped ->
        {:down, 3, "glorbo is not running.\n"}

      :stale ->
        Audit.emit("down", "start", %{reason: "stale_pidfile"})
        :ok = Pidfile.rm(base)
        Audit.emit("down", "complete", %{reason: "stale_pidfile"})

        {:down, 0,
         "glorbo stopped (stale pidfile cleaned; no running process).\n"}

      :running ->
        pid = Pidfile.read!(base)
        stop_running(pid, base)
    end
  end

  defp stop_running(pid, base) do
    Audit.emit("down", "start", %{pid: pid})

    _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

    {final_status, escalated?} = wait_for_exit(base, pid, 0)

    case final_status do
      :running ->
        # WR-06: before escalating to SIGKILL, re-read the pidfile. In
        # the 10s SIGTERM grace window the original pid may have exited
        # and the OS may have recycled it for an unrelated process —
        # killing it would be a cross-user footgun. Only SIGKILL if the
        # pidfile still points at the SAME pid we started with.
        case Pidfile.status(base) do
          :running ->
            current = Pidfile.read!(base)

            if current == pid do
              _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
              :ok = Pidfile.rm(base)
              Audit.emit("down", "complete", %{pid: pid, escalated: true})

              {:down, 0,
               "glorbo stopped (SIGKILL after 10s SIGTERM grace; pid=#{pid}).\n"}
            else
              # pidfile contents changed mid-shutdown — treat as
              # already-stopped to avoid targeting an unrelated pid.
              :ok = Pidfile.rm(base)
              Audit.emit("down", "complete", %{pid: pid, escalated: false, pidfile_changed: true})

              {:down, 0,
               "glorbo stopped (pidfile changed during shutdown; not escalating).\n"}
            end

          _stopped_or_stale ->
            :ok = Pidfile.rm(base)
            Audit.emit("down", "complete", %{pid: pid, escalated: false})
            {:down, 0, "glorbo stopped.\n"}
        end

      _stopped_or_stale ->
        :ok = Pidfile.rm(base)
        Audit.emit("down", "complete", %{pid: pid, escalated: escalated?})
        {:down, 0, "glorbo stopped.\n"}
    end
  end

  # Poll every @poll_ms up to @max_iters; short-circuit on any non-running
  # status (:stopped = pidfile-gone-from-under-us, :stale = pid died).
  defp wait_for_exit(_base, _pid, iter) when iter >= @max_iters do
    {:running, false}
  end

  defp wait_for_exit(base, pid, iter) do
    Process.sleep(@poll_ms)

    case Pidfile.status(base) do
      :running -> wait_for_exit(base, pid, iter + 1)
      other -> {other, false}
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo down — stop the running orchestrator daemon.

    USAGE
      glorbo down [--help]

    BEHAVIOR
      Reads ~/.glorbo/run/glorbo.pid, sends SIGTERM, waits up to 10s for
      graceful shutdown, then SIGKILL if still alive. Removes pidfile.

    EXIT CODES
      0   Daemon stopped (or was already dead; stale pidfile cleaned).
      3   No pidfile — glorbo is not running.
    """
  end
end
