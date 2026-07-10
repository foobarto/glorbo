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
      # GEP-0053 D18: a fresh install is in BOOTSTRAP (no passphrase yet),
      # so the banner points at /setup?token= to set one. Once a passphrase
      # exists it would print a bare /login instead.
      assert out =~ "http://127.0.0.1:4000/setup?token="

      pidfile_path = Path.join([home, "run", "glorbo.pid"])
      assert File.exists?(pidfile_path)

      # Mode 0600 (pidfile invariant from Plan 05-01 Task 1).
      {:ok, %File.Stat{mode: mode}} = File.stat(pidfile_path)
      assert Bitwise.band(mode, 0o777) == 0o600

      pid = Pidfile.read!(home)
      assert pid > 0
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

    test "exports PHX_SERVER=1 to the daemon child env", %{home: home, tracker: t} do
      # Regression: in a Burrito release runtime.exs only sets `server: true`
      # when PHX_SERVER is set; without this, `glorbo up` spawned a daemon
      # whose Phoenix endpoint never bound port 4000.
      System.put_env("GLORBO_BINARY_PATH", fake_daemon_binary!(home))
      on_exit(fn -> System.delete_env("GLORBO_BINARY_PATH") end)

      assert {:up, 0, _out} = Up.run([])

      track_pid(t, Pidfile.read!(home))

      env_path = Path.join(home, "fake_glorbo.env")

      # Poll for the fake daemon's env dump rather than a fixed sleep —
      # codex review flagged the 100ms wait as a small but real timing
      # race. 2s deadline is generous for a single shell-script write.
      assert wait_for_env_file(env_path, 2_000) == "PHX_SERVER=1"
    end
  end

  # Poll-with-deadline for `fake_glorbo.env` populated by the fake
  # daemon's startup script. Returns the trimmed file contents the
  # moment they appear; flunks on timeout.
  defp wait_for_env_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_for_env_file(path, deadline)
  end

  defp poll_for_env_file(path, deadline) do
    case File.read(path) do
      {:ok, body} when byte_size(body) > 0 ->
        String.trim(body)

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("fake daemon env file never appeared at #{path} within deadline")
        else
          Process.sleep(20)
          poll_for_env_file(path, deadline)
        end
    end
  end
end
