defmodule Glorbo.Integration.PortabilityTest do
  @moduledoc """
  Plan 03 integration — full two-root simulation per D-23 and
  RESEARCH.md §Pattern 6 blueprint. Stages two separate tmp roots
  (host A, host B), runs backup → move → restore → doctor --fix → up,
  and asserts the ceo agent can dispatch a task post-restore.

  Tagged `:integration` + `:pending`.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :pending

  test "host A → backup → host B → restore → doctor --fix → up → agent dispatch" do
    flunk("TODO(plan-03): implement full portability A → B simulation")
  end
end
