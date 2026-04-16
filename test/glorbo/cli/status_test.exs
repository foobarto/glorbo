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

  describe "status" do
    test "no pidfile exits 3 with human-readable table", %{glorbo_home: _home} do
      assert {:status, 3, out} = Status.run([])
      assert out =~ "glorbo status"
      assert out =~ "running"
      assert out =~ "no"
      assert out =~ "port 4000"
      assert out =~ "dashboard_url"
    end

    test "alive pidfile + closed port still exits 3 (both conditions required)",
         %{glorbo_home: home} do
      # Our own BEAM pid → pidfile.status == :running, but port 4000 is
      # not listening under mix test → exit 3.
      Pidfile.write!(System.pid() |> String.to_integer(), home)

      assert {:status, 3, out} = Status.run([])
      assert out =~ "running"
      assert out =~ "yes"
    end

    test "--json emits valid JSON with all 4 keys", %{glorbo_home: _home} do
      assert {:status, 3, out} = Status.run(["--json"])
      assert {:ok, parsed} = Jason.decode(out)
      assert Map.has_key?(parsed, "running")
      assert Map.has_key?(parsed, "pid")
      assert Map.has_key?(parsed, "port_listening")
      assert Map.has_key?(parsed, "dashboard_url")
      assert parsed["running"] == false
      assert parsed["pid"] == nil
      assert parsed["port_listening"] == false
      assert parsed["dashboard_url"] == "http://127.0.0.1:4000"
    end

    test "--json with alive pid reports pid in payload", %{glorbo_home: home} do
      my_pid = System.pid() |> String.to_integer()
      Pidfile.write!(my_pid, home)

      assert {:status, 3, out} = Status.run(["--json"])
      assert {:ok, parsed} = Jason.decode(out)
      assert parsed["running"] == true
      assert parsed["pid"] == my_pid
    end

    test "--help returns help text" do
      assert {:status, 0, out} = Status.run(["--help"])
      assert out =~ "glorbo status"
      assert out =~ "EXIT CODES"
    end
  end
end
