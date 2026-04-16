defmodule Glorbo.RestoreTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "Glorbo.Restore.run/2" do
    test "non-empty base without --force returns exit 2" do
      flunk("TODO(plan-03): implement non-empty-base guard")
    end

    test "--force bypasses non-empty-base guard" do
      flunk("TODO(plan-03): implement --force override")
    end

    test "traversal-guard rejects archive with ../etc/passwd entry" do
      flunk("TODO(plan-03): implement tar traversal guard")
    end

    test "happy path: extract → migrate → reindex → doctor --fix chain (D-22)" do
      flunk("TODO(plan-03): implement full restore chain")
    end
  end
end
