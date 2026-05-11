defmodule Glorbo.CLI.StatusTest do
  @moduledoc """
  Plan 05-02 Task 1 — `Glorbo.CLI.Lifecycle.Status`.

  Port 4000 is closed in the test env (Phoenix endpoint test-mode is
  `http: false`), so every running-pidfile test still exits 3 per D-09
  (running AND port_listening required). That's the right contract: a
  BEAM with no endpoint isn't actually serving.
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Lifecycle.{Pidfile, Status}

  # Stubbed port probe — fixed return so tests don't depend on whatever
  # is (or isn't) bound to port 4000 on the host running `mix test`.
  defp port_closed, do: [port_check_fun: fn -> false end]
  defp port_open, do: [port_check_fun: fn -> true end]

  describe "status" do
    test "no pidfile exits 3 with human-readable table", %{glorbo_home: _home} do
      assert {:status, 3, out} = Status.run([], port_closed())
      assert out =~ "glorbo status"
      assert out =~ "running"
      assert out =~ "no"
      assert out =~ "port 4000"
      assert out =~ "dashboard_url"
    end

    test "alive pidfile + closed port still exits 3 (both conditions required)",
         %{glorbo_home: home} do
      # Our own BEAM pid → pidfile.status == :running; stub port 4000 as
      # closed so this test asserts the AND contract without depending on
      # whether a dev server happens to be running.
      Pidfile.write!(System.pid() |> String.to_integer(), home)

      assert {:status, 3, out} = Status.run([], port_closed())
      assert out =~ "running"
      assert out =~ "yes"
    end

    test "--json emits valid JSON with dashboard_url containing token", %{glorbo_home: home} do
      # Config.load auto-generates a token when config.md is absent.
      {:ok, cfg} = Glorbo.Config.load(home)

      assert {:status, 3, out} = Status.run(["--json"], port_closed())
      assert {:ok, parsed} = Jason.decode(out)
      assert Map.has_key?(parsed, "running")
      assert Map.has_key?(parsed, "pid")
      assert Map.has_key?(parsed, "port_listening")
      assert Map.has_key?(parsed, "dashboard_url")
      assert parsed["running"] == false
      assert parsed["dashboard_url"] =~ "http://127.0.0.1:4000/?token="
      assert parsed["dashboard_url"] =~ cfg.dashboard_token
    end

    test "human table includes token URL", %{glorbo_home: _home} do
      assert {:status, 3, out} = Status.run([], port_closed())
      assert out =~ "http://127.0.0.1:4000/?token="
    end

    test "--json with alive pid reports pid in payload", %{glorbo_home: home} do
      my_pid = System.pid() |> String.to_integer()
      Pidfile.write!(my_pid, home)

      assert {:status, 3, out} = Status.run(["--json"], port_closed())
      assert {:ok, parsed} = Jason.decode(out)
      assert parsed["running"] == true
      assert parsed["pid"] == my_pid
    end

    test "alive pidfile + open port exits 0 (both conditions met)",
         %{glorbo_home: home} do
      Pidfile.write!(System.pid() |> String.to_integer(), home)

      assert {:status, 0, out} = Status.run([], port_open())
      assert out =~ "running"
      assert out =~ "yes"
      assert out =~ "listening"
    end

    test "--help returns help text" do
      assert {:status, 0, out} = Status.run(["--help"])
      assert out =~ "glorbo status"
      assert out =~ "EXIT CODES"
    end
  end
end
