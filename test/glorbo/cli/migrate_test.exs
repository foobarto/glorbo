defmodule Glorbo.CLI.MigrateTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "migrate" do
    test "runs Ecto.Migrator :up over Glorbo.Repo (D-18)" do
      flunk("TODO(plan-03): implement migrate :up")
    end

    test "reports 0-migrations-up-to-date case cleanly" do
      flunk("TODO(plan-03): implement up-to-date path")
    end

    test "error path returns exit 2" do
      flunk("TODO(plan-03): implement migration failure exit code")
    end
  end
end
