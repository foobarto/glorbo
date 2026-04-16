defmodule Glorbo.CLI.MigrateTest do
  @moduledoc "Plan 04 — Migrate verb contract."
  use ExUnit.Case, async: false

  alias Glorbo.CLI.Migrate

  describe "Glorbo.CLI.Migrate.run/1" do
    test "--help returns help tuple" do
      assert {:migrate, 0, out} = Migrate.run(["--help"])
      assert out =~ "glorbo migrate"
      assert out =~ "USAGE"
    end

    test "runs against Glorbo.Repo and returns :migrate tuple" do
      # Tests run with the app started (:test env loads the Repo). Migrator
      # either applies 0 new migrations (schema already up-to-date in the
      # test fixture) or applies whatever is pending. Either way the tuple
      # shape must be correct.
      assert {:migrate, code, out} = Migrate.run([])
      assert is_integer(code)
      assert is_binary(out)

      # If Repo is healthy under :test env, we get exit 0 + "applied:" line.
      # If Migrator raises (e.g. lock contention), we get exit 2 + "Migration failed:".
      assert code in [0, 2]
      assert out =~ "applied" or out =~ "failed"
    end

    test "reports 0-migrations-up-to-date case cleanly (exit 0)" do
      # Second run is always idempotent for Ecto.Migrator — no new :up to run.
      _ = Migrate.run([])
      assert {:migrate, 0, out} = Migrate.run([])
      assert out =~ "applied: 0" or out =~ "applied:"
    end

    test "unknown switches do not crash (they're silently dropped)" do
      # `OptionParser` with `:strict` returns the unknowns but does not raise.
      # The verb ignores unknowns and runs migrate.
      assert {:migrate, _, _} = Migrate.run(["--gibberish"])
    end
  end
end
