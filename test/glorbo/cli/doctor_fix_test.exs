defmodule Glorbo.CLI.DoctorFixTest do
  @moduledoc "Stubs — filled in by Plan 03."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "doctor --fix (fixer registry)" do
    test "glorbo_dir fixer creates ~/.glorbo/" do
      flunk("TODO(plan-03): exercise glorbo_dir fixer via mocked Doctor result")
    end

    test "audit_dir fixer creates audit/_system/" do
      flunk("TODO(plan-03): exercise audit_dir fixer")
    end

    test "sockets_dir fixer creates runtime/sockets/ at mode 0700" do
      flunk("TODO(plan-03): exercise sockets_dir fixer")
    end

    test "runtime_image fixer runs podman pull" do
      flunk("TODO(plan-03): exercise runtime_image fixer (mocked podman)")
    end

    test "bwrap fixer explains (no auto-install)" do
      flunk("TODO(plan-03): assert bwrap returns :explain tuple")
    end

    test "--dry-run prints what would be fixed without running repairs (D-17)" do
      flunk("TODO(plan-03): exercise --dry-run preview")
    end
  end
end
