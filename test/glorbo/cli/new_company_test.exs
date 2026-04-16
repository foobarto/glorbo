defmodule Glorbo.CLI.NewCompanyTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "new company" do
    test "valid slug scaffolds companies/<slug>/" do
      flunk("TODO(plan-02): implement new-company happy path")
    end

    test "invalid slug (Acme!) returns exit 1" do
      flunk("TODO(plan-02): implement new-company slug validation")
    end

    test "re-run is idempotent (`⏭ already exists`)" do
      flunk("TODO(plan-02): implement new-company idempotency")
    end
  end
end
