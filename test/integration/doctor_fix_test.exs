defmodule Glorbo.Integration.DoctorFixTest do
  @moduledoc """
  Plan 04 integration — each registered filesystem-fixer exercised
  end-to-end, plus the full `Fixer.run/1` orchestrator against real
  `Doctor.run_checks/0` output.

  Note: fixers that touch `~/.glorbo` (fix_glorbo_dir, fix_audit_dir,
  fix_sockets_dir) ALWAYS act on `Path.expand("~/.glorbo/*")` — so this
  test mutates the real dev host's `~/.glorbo`. This is acceptable
  because:

    * The fixers are idempotent (`mkdir_p` + `chmod` are safe to re-run).
    * The dev host always needs these directories anyway.
    * The test runs under `@moduletag :integration` so CI opts in
      explicitly; dev boxes run with the default exclude.

  Binary-bootstrap fixers (fix_podman / fix_ollama / fix_runtime_image)
  are NOT exercised here — they shell out to network/podman and are
  covered by the test/integration/image_pull_test.exs suite.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  describe "individual fixer end-to-end" do
    test "fix_glorbo_dir creates ~/.glorbo if absent (idempotent when present)" do
      target = Path.expand("~/.glorbo")
      # Don't delete; just confirm it becomes :ok regardless of prior state.
      assert {:ok, detail} = Glorbo.Doctor.Fixer.fix_glorbo_dir(%{name: "glorbo_dir"})
      assert File.exists?(target)
      assert is_binary(detail)
    end

    test "fix_audit_dir creates ~/.glorbo/audit/_system" do
      target = Path.expand("~/.glorbo/audit/_system")
      File.rm_rf!(target)

      assert {:ok, _} = Glorbo.Doctor.Fixer.fix_audit_dir(%{name: "audit_dir"})
      assert File.dir?(target)
    end

    test "fix_sockets_dir creates ~/.glorbo/runtime/sockets at mode 0700" do
      target = Path.expand("~/.glorbo/runtime/sockets")
      File.rm_rf!(target)

      assert {:ok, _} = Glorbo.Doctor.Fixer.fix_sockets_dir(%{name: "sockets_dir"})
      assert File.dir?(target)

      mode = File.stat!(target).mode |> Bitwise.band(0o777)
      assert mode == 0o700, "sockets_dir should be 0700, got #{Integer.to_string(mode, 8)}"
    end

    test "explain_bwrap returns :explain tuple regardless of host state" do
      assert {:explain, guidance} = Glorbo.Doctor.Fixer.explain_bwrap(%{name: "bwrap"})
      assert guidance =~ "bubblewrap"
    end
  end

  describe "Fixer.run/1 end-to-end" do
    test "returns {:doctor, code, summary} against live Doctor.run_checks/0" do
      {result, _io} =
        ExUnit.CaptureIO.with_io(fn -> Glorbo.Doctor.Fixer.run(dry_run: true) end)

      assert {:doctor, code, out} = result
      assert is_integer(code)
      assert is_binary(out)
    end
  end
end
