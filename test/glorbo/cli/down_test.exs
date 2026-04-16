defmodule Glorbo.CLI.DownTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "down" do
    test "sends SIGTERM to the pid in the pidfile + removes it" do
      flunk("TODO(plan-02): implement down happy path (SIGTERM + pidfile rm)")
    end

    test "no-pidfile returns exit 3 (not running) per D-28" do
      flunk("TODO(plan-02): implement down no-pidfile path")
    end

    test "stale pidfile is cleaned up without signal" do
      flunk("TODO(plan-02): implement down stale-pidfile cleanup")
    end
  end
end
