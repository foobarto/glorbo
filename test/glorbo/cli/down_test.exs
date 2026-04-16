defmodule Glorbo.CLI.DownTest do
  @moduledoc """
  Plan 05-02 Task 1 — `Glorbo.CLI.Lifecycle.Down`.

  Spawns real `/bin/sleep` children for the happy path so we can assert
  the SIGTERM + poll + pidfile-cleanup behaviour end-to-end. The stale
  and not-running cases use pure pidfile manipulation.
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.{Down, Pidfile}

  describe "down" do
    test "sends SIGTERM to the pid in the pidfile + removes it", %{glorbo_home: home} do
      # Spawn a real long-running child we can kill.
      port = Port.open({:spawn_executable, "/bin/sleep"}, [
        :binary,
        :exit_status,
        :hide,
        args: ["60"]
      ])

      {:os_pid, child_pid} = Port.info(port, :os_pid)
      Pidfile.write!(child_pid, home)

      # Sanity — child is alive.
      assert Pidfile.status(home) == :running

      on_exit(fn ->
        _ = System.cmd("kill", ["-KILL", Integer.to_string(child_pid)], stderr_to_stdout: true)
      end)

      assert {:down, 0, out} = Down.run([])
      assert out =~ "glorbo stopped"

      # Pidfile cleaned.
      refute File.exists?(Path.join([home, "run", "glorbo.pid"]))

      # Child dead (SIGTERM gracefully exits sleep).
      :timer.sleep(100)
      assert Pidfile.status(home) == :stopped
    end

    test "no-pidfile returns exit 3 (not running) per D-28", %{glorbo_home: _home} do
      assert {:down, 3, out} = Down.run([])
      assert out =~ "not running"
    end

    test "stale pidfile is cleaned up without signal", %{glorbo_home: home} do
      Pidfile.write!(99_999_999, home)
      assert Pidfile.status(home) == :stale

      assert {:down, 0, out} = Down.run([])
      assert out =~ "stale pidfile"

      refute File.exists?(Path.join([home, "run", "glorbo.pid"]))
    end

    test "--help returns help text" do
      assert {:down, 0, out} = Down.run(["--help"])
      assert out =~ "glorbo down"
      assert out =~ "SIGTERM"
    end
  end
end
