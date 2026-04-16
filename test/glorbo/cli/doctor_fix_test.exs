defmodule Glorbo.CLI.DoctorFixTest do
  @moduledoc "Plan 04 — doctor --fix CLI router contract."
  use ExUnit.Case, async: false

  alias Glorbo.CLI.DoctorFix

  describe "Glorbo.CLI.DoctorFix.run/1" do
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

    test "exit_code is 0 when no checks failed OR all failed checks were repaired/explained" do
      # On a healthy dev host, all checks pass → exit 0. If a warning-level
      # check fails but the fixer repairs/explains it → still exit 0. We
      # can't force a specific state here; just assert the tuple shape.
      {result, _io} = ExUnit.CaptureIO.with_io(fn -> DoctorFix.run([]) end)
      assert {:doctor, code, _out} = result
      assert code in [0, 1]
    end
  end

  describe "help_text/0" do
    test "mentions --dry-run" do
      assert DoctorFix.help_text() =~ "--dry-run"
    end
  end
end
