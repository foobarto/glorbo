defmodule Glorbo.CLI.DoctorFixTest do
  @moduledoc "Plan 04 — doctor --fix CLI router + per-fixer unit contract."
  use ExUnit.Case, async: false

  alias Glorbo.CLI.DoctorFix
  alias Glorbo.Doctor.Fixer

  describe "Glorbo.CLI.DoctorFix.run/1 (thin router)" do
    test "delegates to Glorbo.Doctor.Fixer.run/1 and returns its tuple" do
      # The Fixer prints progress lines — capture the IO so the test reporter
      # stays quiet. We only care about the tuple shape here.
      {result, _io} = ExUnit.CaptureIO.with_io(fn -> DoctorFix.run([]) end)
      assert {:doctor, code, out} = result
      assert is_integer(code)
      assert is_binary(out)
    end

    test "--dry-run mode produces 'would repair' or 'nothing to repair' output" do
      {result, _captured} =
        ExUnit.CaptureIO.with_io(fn -> DoctorFix.run(dry_run: true) end)

      assert {:doctor, _code, out} = result

      # If all checks pass on the dev host, out contains "nothing to repair".
      # If any fail, the dry-run printed "would repair: <check>" to stdout
      # (captured) and the summary footer in `out` reflects attempted>0.
      assert out =~ "nothing to repair" or out =~ "doctor --fix summary"
    end

    test "exit_code is severity-weighted per Doctor.exit_code/1" do
      # WR-05 fix: after repairs, exit code comes from Doctor.exit_code/1
      # on a fresh run_checks. Valid codes are 0 (all pass), 1 (blocker
      # failing), 2 (only warnings failing). The previous [0, 1]
      # assertion was tied to the broken `failed > 0` heuristic.
      {result, _io} = ExUnit.CaptureIO.with_io(fn -> DoctorFix.run([]) end)
      assert {:doctor, code, _out} = result
      assert code in [0, 1, 2]
    end

    test "delegation is literal: DoctorFix.run/1 is equivalent to Fixer.run/1" do
      # Both paths should return identical tuple shapes (Fixer is non-deterministic
      # on the live host — same inputs yield the same outputs in a single test run
      # when called back-to-back with the same opts).
      {delegated, _io1} =
        ExUnit.CaptureIO.with_io(fn -> DoctorFix.run(dry_run: true) end)

      {direct, _io2} =
        ExUnit.CaptureIO.with_io(fn -> Fixer.run(dry_run: true) end)

      {:doctor, d_code, _} = delegated
      {:doctor, f_code, _} = direct
      # Codes match since the underlying doctor check set is the same.
      assert d_code == f_code
    end
  end

  describe "per-fixer unit contracts (exercised via Fixer.fixers/0)" do
    test "glorbo_dir fixer returns {:ok, _}" do
      assert {:ok, detail} = Fixer.fix_glorbo_dir(%{name: "glorbo_dir"})
      assert is_binary(detail)
    end

    test "audit_dir fixer returns {:ok, _}" do
      assert {:ok, detail} = Fixer.fix_audit_dir(%{name: "audit_dir"})
      assert is_binary(detail)
    end

    test "sockets_dir fixer returns {:ok, _} (and is idempotent)" do
      assert {:ok, d1} = Fixer.fix_sockets_dir(%{name: "sockets_dir"})
      assert {:ok, d2} = Fixer.fix_sockets_dir(%{name: "sockets_dir"})
      assert is_binary(d1)
      assert is_binary(d2)
    end

    test "bwrap fixer returns {:explain, _} (no auto-install per T-05-12)" do
      assert {:explain, guidance} = Fixer.explain_bwrap(%{name: "bwrap"})
      assert guidance =~ "bubblewrap"
      assert guidance =~ "Install"
    end
  end

  describe "help_text/0" do
    test "mentions --dry-run" do
      assert DoctorFix.help_text() =~ "--dry-run"
    end

    test "mentions the Fixer module as the repair registry" do
      assert DoctorFix.help_text() =~ "Glorbo.Doctor.Fixer"
    end
  end
end
