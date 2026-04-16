defmodule Glorbo.Integration.BackupRestoreRoundtripTest do
  @moduledoc """
  Plan 03 integration — same-host A → archive → B roundtrip.

  Tagged `:integration` + `:pending`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :pending

  test "A → archive → B: markdown byte-equality + DB rebuildable post-restore" do
    flunk("TODO(plan-03): implement backup-restore roundtrip")
  end
end
