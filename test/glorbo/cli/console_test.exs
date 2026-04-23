defmodule Glorbo.CLI.ConsoleTest do
  @moduledoc "Plan 04 — console verb contract."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Console

  describe "Glorbo.CLI.Console.run/2" do
    test "--help returns help tuple" do
      assert {:console, 0, out} = Console.run(["--help"])
      assert out =~ "glorbo console"
      assert out =~ "--remsh"
    end

    test "when not running returns exit 3", %{glorbo_home: home} do
      # CLICase already set GLORBO_HOME to hermetic tmp; no pidfile written.
      assert {:console, 3, out} = Console.run([], base: home)
      assert out =~ "not running"
    end

    test "when stale pidfile returns exit 3", %{glorbo_home: home} do
      File.mkdir_p!(Path.join(home, "run"))
      # PID 99999999 is overwhelmingly unlikely to be alive.
      File.write!(Path.join([home, "run", "glorbo.pid"]), "99999999")

      assert {:console, 3, out} = Console.run([], base: home)
      assert out =~ "not running"
    end

    test "when running, preview contains --remsh/--name without leaking the cookie", %{
      glorbo_home: home
    } do
      # Write a live pidfile using our own PID + let Config.erl_cookie/1
      # auto-bootstrap a config.md with an erl_cookie key.
      File.mkdir_p!(Path.join(home, "run"))
      File.write!(Path.join([home, "run", "glorbo.pid"]), "#{System.pid()}")

      assert {:ok, cookie} = Glorbo.Config.erl_cookie(home)

      # Use :skip_exec to avoid actually launching iex.
      assert {:console, 0, out} = Console.run([], base: home, skip_exec: true)
      assert out =~ "--remsh"
      assert out =~ "glorbo@127.0.0.1"
      assert out =~ "--name"
      assert out =~ "console@127.0.0.1"
      assert out =~ "ERL_AFLAGS=<redacted>"
      refute out =~ "--cookie"
      refute out =~ cookie, "preview should not contain the actual cookie value"
    end

    test "uses --name (not --sname) per WR-09 correction", %{glorbo_home: home} do
      File.mkdir_p!(Path.join(home, "run"))
      File.write!(Path.join([home, "run", "glorbo.pid"]), "#{System.pid()}")
      {:ok, _} = Glorbo.Config.erl_cookie(home)

      assert {:console, 0, out} = Console.run([], base: home, skip_exec: true)
      assert out =~ "--name"
      refute out =~ "--sname ", "Console must use --name (long-name), not --sname"
    end
  end
end
