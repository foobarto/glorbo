defmodule Glorbo.Doctor.FixerTest do
  @moduledoc "Plan 04 — Fixer registry shape + individual fixer assertions."
  use ExUnit.Case, async: false

  alias Glorbo.Doctor.Fixer

  describe "@fixers registry" do
    test "every registered fixer is a 1-arity function reference" do
      for {name, fixer} <- Fixer.fixers() do
        assert is_binary(name), "check name must be a string, got: #{inspect(name)}"
        assert is_function(fixer, 1), "fixer for #{name} must be arity 1"
      end
    end

    test "expected fixer names are registered (matches Doctor.run_checks/0 names)" do
      registered = Fixer.fixers() |> Map.keys() |> Enum.sort()

      expected =
        ~w(glorbo_dir audit_dir sockets_dir bwrap)
        |> Enum.sort()

      assert registered == expected
    end

    test "every registered fixer returns {:ok, _} | {:error, _} | {:explain, _}" do
      fake_check = %{name: "fake", pass: false, severity: :warning, detail: "", required: ""}

      for {name, fixer} <- Fixer.fixers() do
        result = fixer.(%{fake_check | name: name})

        assert match?({:ok, _}, result) or
                 match?({:error, _}, result) or
                 match?({:explain, _}, result),
               "fixer #{name} returned unexpected shape: #{inspect(result)}"
      end
    end

    test "explain_bwrap returns an :explain tuple with install guidance" do
      assert {:explain, guidance} = Fixer.explain_bwrap(%{name: "bwrap"})
      assert guidance =~ "bubblewrap"
      assert guidance =~ "fedora"
    end

    test "fix_glorbo_dir creates ~/.glorbo (idempotent if already present)" do
      # Opportunistic — ~/.glorbo almost certainly exists on the dev host
      # (otherwise this whole project would be broken). The fixer is
      # idempotent via `File.mkdir_p/1`, so assert it returns :ok.
      assert {:ok, _} = Fixer.fix_glorbo_dir(%{name: "glorbo_dir"})
    end
  end

  describe "run/1" do
    test "returns :doctor tuple with exit_code + summary string" do
      # This calls real Doctor.run_checks/0. Capture IO so that summary
      # lines printed by handle_check/3 don't pollute the test reporter.
      {result, _io} =
        ExUnit.CaptureIO.with_io(fn -> Fixer.run(dry_run: true) end)

      assert {:doctor, code, out} = result
      assert is_integer(code)
      assert is_binary(out)
    end

    test "dry_run: true does not invoke real fixers (verified by shape)" do
      # We can't easily inject a fake Doctor.run_checks/0 result here, but
      # we can assert the return tuple remains well-formed under dry-run.
      {result, _io} =
        ExUnit.CaptureIO.with_io(fn -> Fixer.run(dry_run: true) end)

      assert {:doctor, _code, _out} = result
    end
  end
end
