defmodule Glorbo.CLI.ConsoleTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "console" do
    test "when not running returns exit 3" do
      flunk("TODO(plan-03): implement console not-running path")
    end

    test "when running, spawns iex --remsh with --cookie from config" do
      flunk("TODO(plan-03): assert Port.open argv contains --remsh/--sname/--cookie")
    end
  end
end
