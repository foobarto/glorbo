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
    assert code in [0, 1]
    assert output =~ "Glorbo Doctor"

    for name <- ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"] do
      assert output =~ name
    end
  end

  test "dispatch([\"doctor\", \"--json\"]) returns parseable JSON" do
    {verb, _code, output} = CLI.dispatch(["doctor", "--json"])
    assert verb == :doctor
    decoded = Jason.decode!(output)
    assert decoded["version"] == "0.1.0"
    assert length(decoded["checks"]) == 5
    assert Map.has_key?(decoded, "exit_code")
    assert Map.has_key?(decoded, "all_passed")
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
end
