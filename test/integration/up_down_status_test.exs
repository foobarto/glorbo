defmodule Glorbo.Integration.UpDownStatusTest do
  @moduledoc """
  Plan 02 integration — live Burrito subprocess lifecycle.

  Tagged `:integration` (excluded from default suite) + `:pending`
  (Plan 02 toggles to live).
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :pending

  test "up spawns burrito subprocess, status reports running, down kills it cleanly" do
    flunk("TODO(plan-02): implement full up/status/down subprocess lifecycle")
  end
end
