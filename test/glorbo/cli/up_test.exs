defmodule Glorbo.CLI.UpTest do
  @moduledoc """
  Plan 05-02 Task 1 — `Glorbo.CLI.Lifecycle.Up`.

  Exercises the tuple shape + pidfile side-effects without fully
  re-execing a Burrito binary. We point `GLORBO_BINARY_PATH` at a
  long-lived shell script (`fake_daemon_binary!/1` from `CLICase`) so
  the daemon spawns a real child whose OS pid we can assert + clean up.
  The prior `/bin/sleep` fixture flaked on Fedora coreutils: it rejected
  the `serve` argv entry with an error and exited before
  `Port.info(port, :os_pid)` could read the child pid.
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.{Pidfile, Up}

  # On-exit hook: kill any child we may have spawned, regardless of
  # success/failure path. We use an Agent so the tracking survives
  # across the test → on_exit process boundary.
  setup %{glorbo_home: home} do
    {:ok, tracker} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      # Read pids BEFORE stopping the Agent — on_exit may run after the
      # Agent dies if the test process crashes. Use try/catch to be safe.
      pids =
        try do
          Agent.get(tracker, & &1)
        catch
          :exit, _ -> []
        end

      Enum.each(pids, fn pid ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
      end)

      _ = File.rm_rf(Path.join(home, "run"))
    end)

    {:ok, tracker: tracker, home: home}
  end

  defp track_pid(tracker, pid) do
    Agent.update(tracker, fn pids -> [pid | pids] end)
  end

  describe "up" do
    test "writes pidfile + returns :up tuple on fresh start", %{home: home, tracker: t} do
      System.put_env("GLORBO_BINARY_PATH", fake_daemon_binary!(home))
      on_exit(fn -> System.delete_env("GLORBO_BINARY_PATH") end)

      assert {:up, 0, out} = Up.run([])
      assert out =~ "glorbo up"
      assert out =~ "pid="
      assert out =~ "http://127.0.0.1:4000"

      pidfile_path = Path.join([home, "run", "glorbo.pid"])
      assert File.exists?(pidfile_path)

      # Mode 0600 (pidfile invariant from Plan 05-01 Task 1).
      {:ok, %File.Stat{mode: mode}} = File.stat(pidfile_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      pid = Pidfile.read!(home)
      assert is_integer(pid) and pid > 0
      track_pid(t, pid)
    end

    test "refuses when pidfile present and pid alive (exit 2)", %{home: home} do
      # Use our own BEAM pid — guaranteed alive.
      my_pid = System.pid() |> String.to_integer()
      Pidfile.write!(my_pid, home)

      assert {:up, 2, out} = Up.run([])
      assert out =~ "already running"
      assert out =~ "glorbo down"
      assert out =~ Integer.to_string(my_pid)
    end

    test "proceeds past stale pidfile (dead pid)", %{home: home, tracker: t} do
      # 99_999_999 is well above realistic max pid — guaranteed dead.
      Pidfile.write!(99_999_999, home)
      assert Pidfile.status(home) == :stale

      System.put_env("GLORBO_BINARY_PATH", fake_daemon_binary!(home))
      on_exit(fn -> System.delete_env("GLORBO_BINARY_PATH") end)

      assert {:up, 0, _out} = Up.run([])

      # New pidfile should contain a DIFFERENT pid (not the stale
      # 99_999_999 we wrote pre-call).
      new_pid = Pidfile.read!(home)
      assert new_pid != 99_999_999
      track_pid(t, new_pid)
    end

    test "returns error tuple when binary cannot be located", %{home: _home} do
      System.delete_env("GLORBO_BINARY_PATH")
      System.delete_env("__BURRITO_BIN_PATH")

      assert {:up, 2, out} = Up.run([])
      assert out =~ "Failed to start"
      assert out =~ "binary_not_found"
    end

    test "--help returns help text" do
      assert {:up, 0, out} = Up.run(["--help"])
      assert out =~ "glorbo up"
      assert out =~ "USAGE"
    end
  end
end
