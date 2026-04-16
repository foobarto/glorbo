defmodule Glorbo.Doctor.FixerTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use ExUnit.Case, async: true

  @moduletag :pending

  describe "@fixers registry" do
    test "every registered fixer returns {:ok, _} | {:error, _} | {:explain, _}" do
      flunk("TODO(plan-03): iterate @fixers and assert return shape")
    end

    test "unknown check name returns {:error, :no_fixer}" do
      flunk("TODO(plan-03): implement no-fixer fallback")
    end
  end
end
