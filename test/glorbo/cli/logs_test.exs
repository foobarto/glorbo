defmodule Glorbo.CLI.LogsTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "logs <company>" do
    test "backfills 50 lines by default (D-14)" do
      flunk("TODO(plan-02): implement audit-log backfill")
    end

    test "--lines 10 respected" do
      flunk("TODO(plan-02): implement --lines N")
    end

    test "<company> <agent> routes to agents/<ag>/stdout.log (D-15)" do
      flunk("TODO(plan-02): implement agent stdout routing")
    end

    test "--follow tails forever (inotify + poll fallback)" do
      flunk("TODO(plan-02): implement --follow mode")
    end
  end
end
