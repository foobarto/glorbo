defmodule Glorbo.CLI.UpTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "up" do
    test "writes pidfile + returns :up tuple on fresh start" do
      flunk("TODO(plan-02): implement up happy path")
    end

    test "refuses when pidfile present and pid alive (exit 2)" do
      flunk("TODO(plan-02): implement up-already-running")
    end

    test "proceeds past stale pidfile (dead pid)" do
      flunk("TODO(plan-02): implement up stale-pidfile recovery")
    end
  end
end
