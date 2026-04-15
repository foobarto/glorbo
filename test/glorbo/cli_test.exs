defmodule Glorbo.CLITest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit tests for the pure `Glorbo.CLI.dispatch/1` function used by the
  Burrito release binary's argv branch in `Glorbo.Application.start/2`.

  `dispatch/1` is a PURE function — it returns `{verb, exit_code, output}`
  without side effects. `Application.start/2` handles IO + `System.halt/1`.
  """

  alias Glorbo.CLI

  test "dispatch([]) returns :help, exit_code 0, help text" do
    {verb, code, output} = CLI.dispatch([])
    assert verb == :help
    assert code == 0
    assert output =~ "USAGE"
    assert output =~ "doctor"
  end

  test "dispatch([\"--help\"]) returns :help" do
    {:help, 0, output} = CLI.dispatch(["--help"])
    assert output =~ "USAGE"
  end

  test "dispatch([\"-h\"]) returns :help" do
    {:help, 0, _output} = CLI.dispatch(["-h"])
  end

  test "dispatch([\"help\"]) returns :help" do
    {:help, 0, _output} = CLI.dispatch(["help"])
  end

  test "dispatch([\"doctor\"]) runs checks and returns :doctor with table output" do
    {verb, code, output} = CLI.dispatch(["doctor"])
    assert verb == :doctor
    # Phase 2 (D-45): severity-weighted exit code 0/1/2.
    assert code in [0, 1, 2]
    assert output =~ "Glorbo Doctor"

    # Phase-1 check names still present (D-44 additive-only).
    for name <- ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"] do
      assert output =~ name
    end

    # Phase-2 check names also present.
    for name <- ["podman", "ollama", "ollama_daemon", "runtime_image", "audit_dir"] do
      assert output =~ name
    end
  end

  test ~S|dispatch(["doctor", "--json"]) returns parseable JSON| do
    {verb, _code, output} = CLI.dispatch(["doctor", "--json"])
    assert verb == :doctor
    decoded = Jason.decode!(output)
    assert decoded["version"] == "0.1.0"
    # Phase 2: 5 Phase-1 + 8 Phase-2 = 13 checks.
    assert length(decoded["checks"]) == 13
    assert Map.has_key?(decoded, "exit_code")
    assert Map.has_key?(decoded, "all_passed")
    # Additive severity field on every check (D-44).
    assert Enum.all?(decoded["checks"], &Map.has_key?(&1, "severity"))
  end

  test "dispatch([\"bogus\"]) returns :unknown with exit_code 1 and help text" do
    {verb, code, output} = CLI.dispatch(["bogus"])
    assert verb == :unknown
    assert code == 1
    assert output =~ "Unknown command: bogus"
    assert output =~ "USAGE"
  end

  test "help_text references DESIGN.md" do
    assert CLI.help_text() =~ "DESIGN.md"
  end

  test "help_text advertises the init verb (Plan 04 D-22)" do
    assert CLI.help_text() =~ "init"
    assert CLI.help_text() =~ "--skip-pull"
    assert CLI.help_text() =~ "--force"
  end

  describe ~S{dispatch(["init" | ...]) (Plan 04, D-22, D-23)} do
    alias Glorbo.Company.AuditLog
    alias Glorbo.Test.TmpGlorboHome

    setup do
      # Isolate to a tmp base by rebinding HOME for the duration of the test.
      base = TmpGlorboHome.setup()
      original_home = System.get_env("HOME")
      System.put_env("HOME", base)
      on_exit(fn -> if original_home, do: System.put_env("HOME", original_home) end)

      # Ensure no lingering named AuditLog from a prior test.
      case Process.whereis(AuditLog) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      {:ok, base: base}
    end

    test "returns :init tuple with exit_code 0/1/2 and a rendered summary", %{base: _base} do
      {verb, code, output} = CLI.dispatch(["init", "--skip-pull", "--no-example"])
      assert verb == :init
      assert code in [0, 1, 2]
      assert output =~ "Glorbo init"
      assert output =~ "Next steps:"
      assert output =~ "OLLAMA_HOST=unix"
    end

    test ~S|dispatch(["init", "--skip-pull"]) skips binary_bootstrap + image_pull| do
      {:init, _, output} = CLI.dispatch(["init", "--skip-pull", "--no-example"])
      assert output =~ "binary_bootstrap — --skip-pull"
      assert output =~ "image_pull — --skip-pull"
    end

    test ~S|dispatch(["init", "--force"]) parses without error| do
      {:init, _, output} = CLI.dispatch(["init", "--force", "--skip-pull", "--no-example"])
      assert output =~ "Glorbo init"
    end
  end

  describe ~S|dispatch(["doctor", "--fix"]) (Plan 04, D-46)| do
    test "accepts --fix flag and emits Phase-5 deferral notice" do
      {verb, code, output} = CLI.dispatch(["doctor", "--fix"])
      assert verb == :doctor
      assert code in [0, 1, 2]
      assert output =~ "Phase 5"
    end

    test "--fix with --json returns JSON only (no notice noise in machine output)" do
      {verb, _code, output} = CLI.dispatch(["doctor", "--fix", "--json"])
      assert verb == :doctor
      refute output =~ "Phase 5"
      # Still parses as JSON.
      assert %{"checks" => _} = Jason.decode!(output)
    end
  end
end
