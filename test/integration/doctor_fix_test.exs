defmodule Glorbo.Integration.DoctorFixTest do
  @moduledoc """
  Plan 03 integration — each registered fixer exercised against a
  deliberately-broken hermetic base.

  Tagged `:integration` + `:pending`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :pending

  test "each registered fixer repairs a deliberately-broken hermetic base" do
    flunk("TODO(plan-03): iterate @fixers against broken-base fixtures")
  end
end
