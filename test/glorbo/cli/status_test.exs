defmodule Glorbo.CLI.StatusTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "status" do
    test "running (pidfile alive + port 4000 listening) exits 0" do
      flunk("TODO(plan-02): implement status running path")
    end

    test "not running (no pidfile) exits 3" do
      flunk("TODO(plan-02): implement status not-running path")
    end

    test "--json emits machine-readable output" do
      flunk("TODO(plan-02): implement status --json")
    end
  end
end
