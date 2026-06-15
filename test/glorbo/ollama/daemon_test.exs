defmodule Glorbo.Ollama.DaemonTest do
  use ExUnit.Case, async: true

  alias Glorbo.Ollama.Daemon

  # A fresh long-lived process to stand in for a spawned `ollama serve`,
  # so `Process.monitor` works and we can `kill` it to simulate a crash.
  defp sleeper, do: spawn(fn -> Process.sleep(:infinity) end)

  defp start_daemon(opts) do
    {:ok, pid} = start_supervised({Daemon, Keyword.put(opts, :name, nil)})
    pid
  end

  describe "adopt-if-running (D2)" do
    test "ensure_running adopts an external daemon and never spawns" do
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> true end,
          spawn_fun: fn ->
            send(parent, :spawned)
            {:ok, sleeper()}
          end
        )

      assert {:ok, :external} = Daemon.ensure_running(d)
      assert Daemon.status(d).mode == :external
      refute_received :spawned
    end

    test "stop refuses to touch an external daemon (never stop what we didn't start)" do
      d = start_daemon(probe_fun: fn -> true end, spawn_fun: fn -> {:ok, sleeper()} end)
      {:ok, :external} = Daemon.ensure_running(d)
      assert {:error, :not_managed} = Daemon.stop(d)
      assert {:error, :not_managed} = Daemon.restart(d)
    end
  end

  describe "start-if-not (D2/D3)" do
    test "ensure_running spawns a managed daemon when none is running" do
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> false end,
          spawn_fun: fn ->
            send(parent, :spawned)
            {:ok, sleeper()}
          end
        )

      assert {:ok, :managed} = Daemon.ensure_running(d)
      assert Daemon.status(d).mode == :managed
      assert_received :spawned
    end

    test "a spawn failure surfaces as :down with the reason" do
      d = start_daemon(probe_fun: fn -> false end, spawn_fun: fn -> {:error, :not_installed} end)
      assert {:error, :not_installed} = Daemon.ensure_running(d)
      assert Daemon.status(d).mode == :down
    end

    test "stop terminates a managed daemon" do
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> false end,
          spawn_fun: fn -> {:ok, sleeper()} end,
          stop_fun: fn pid ->
            send(parent, {:stopped, pid})
            Process.exit(pid, :kill)
            :ok
          end
        )

      {:ok, :managed} = Daemon.ensure_running(d)
      assert {:ok, :down} = Daemon.stop(d)
      assert_received {:stopped, _pid}
    end

    test "restart stops and respawns a managed daemon" do
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> false end,
          spawn_fun: fn ->
            send(parent, :spawn)
            {:ok, sleeper()}
          end,
          stop_fun: fn pid ->
            Process.exit(pid, :kill)
            :ok
          end
        )

      {:ok, :managed} = Daemon.ensure_running(d)
      assert_received :spawn
      assert {:ok, :managed} = Daemon.restart(d)
      assert_received :spawn
    end
  end

  describe "external vanish + crash budget" do
    test "status reflects an external daemon appearing and vanishing (no auto-respawn)" do
      {:ok, agent} = start_supervised({Agent, fn -> false end})
      probe = fn -> Agent.get(agent, & &1) end
      parent = self()

      d =
        start_daemon(
          probe_fun: probe,
          spawn_fun: fn ->
            send(parent, :spawned)
            {:ok, sleeper()}
          end
        )

      assert Daemon.status(d).mode == :down
      Agent.update(agent, fn _ -> true end)
      assert Daemon.status(d).mode == :external
      # Vanished external → :down, and we must NOT spawn a replacement.
      Agent.update(agent, fn _ -> false end)
      assert Daemon.status(d).mode == :down
      refute_received :spawned
    end

    test "a crashing managed daemon respawns up to the budget then parks at :down" do
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> false end,
          spawn_fun: fn ->
            send(parent, :spawn)
            {:ok, sleeper()}
          end
        )

      {:ok, :managed} = Daemon.ensure_running(d)
      assert_received :spawn

      # @max_restarts (3) consecutive crashes each respawn.
      for _ <- 1..3 do
        pid = :sys.get_state(d).child_pid
        Process.exit(pid, :kill)
        assert_receive :spawn, 1_000
      end

      # The next crash exhausts the budget → park at :down, no respawn.
      pid = :sys.get_state(d).child_pid
      Process.exit(pid, :kill)
      refute_receive :spawn, 400
      assert :sys.get_state(d).mode == :down
    end

    test "an abnormal exit of a LINKED managed child does not crash the manager" do
      # MuonTrap.Daemon.start_link LINKS the child to the Daemon manager;
      # mimic with spawn_link. Without the unlink guard the child's abnormal
      # exit would propagate over the link and kill the manager before the
      # monitor handler could run the bounded restart.
      parent = self()

      d =
        start_daemon(
          probe_fun: fn -> false end,
          spawn_fun: fn ->
            send(parent, :spawn)
            {:ok, spawn_link(fn -> Process.sleep(:infinity) end)}
          end
        )

      {:ok, :managed} = Daemon.ensure_running(d)
      mref = Process.monitor(d)
      assert_received :spawn

      child = :sys.get_state(d).child_pid
      Process.exit(child, :boom)

      # Manager survived the linked child's abnormal exit and respawned.
      assert_receive :spawn, 1_000
      assert Process.alive?(d)
      assert Daemon.status(d).mode == :managed
      refute_receive {:DOWN, ^mref, :process, ^d, _}, 50
    end
  end
end
