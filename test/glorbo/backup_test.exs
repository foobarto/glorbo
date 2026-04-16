defmodule Glorbo.BackupTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "Glorbo.Backup.run/1" do
    test "happy path produces tar.gz with allowlist contents (companies/, config.md, audit/, glorbo.db)" do
      flunk("TODO(plan-03): implement backup happy path")
    end

    test "excludes bin/, models/, containers/, runtime/, run/ (derived/re-downloadable)" do
      flunk("TODO(plan-03): assert derived dirs excluded")
    end

    test "WAL-checkpoint-busy returns {:error, {:checkpoint_busy, _}}" do
      flunk("TODO(plan-03): exercise WAL-busy error path")
    end

    test "refuses with pidfile present (D-21)" do
      flunk("TODO(plan-03): assert D-21 pidfile guard")
    end

    test "--force-live bypasses pidfile guard" do
      flunk("TODO(plan-03): assert --force-live overrides guard")
    end
  end
end
