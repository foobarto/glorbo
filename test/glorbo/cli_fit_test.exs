defmodule Glorbo.CLIFitTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the `glorbo fit` CLI verb (GEP-59). Flag parsing, error
  handling, help, and the JSON/human output modes go through the pure
  `Glorbo.CLI.dispatch/1` tuple. The happy path runs the real host probe
  — which degrades safely on any host — so we assert structure, not
  specific hardware.
  """

  alias Glorbo.CLI

  test "fit appears in the global help text" do
    {:help, 0, out} = CLI.dispatch([])
    assert out =~ "fit"
    assert out =~ "recommend a local"
  end

  test "help fit prints verb-specific usage" do
    {:help, 0, out} = CLI.dispatch(["help", "fit"])
    assert out =~ "glorbo fit"
    assert out =~ "--use-case"
    assert out =~ "--host"
    assert out =~ "GEP-59"
  end

  test "unknown switch is rejected with exit 1 + help" do
    {:fit, 1, out} = CLI.dispatch(["fit", "--bogus"])
    assert out =~ "unknown switch"
  end

  test "invalid --use-case is rejected with exit 1" do
    {:fit, 1, out} = CLI.dispatch(["fit", "--use-case", "nonsense"])
    assert out =~ "unknown --use-case"
    assert out =~ "general"
  end

  test "happy path: dispatch returns :fit verb and human-readable output" do
    {verb, code, out} = CLI.dispatch(["fit"])

    assert verb == :fit
    assert code in [0, 1]
    assert out =~ "glorbo fit"
    assert out =~ "Host:"
    assert out =~ "RAM:"
  end

  test "--json emits valid JSON with the system + use_case" do
    {:fit, code, out} = CLI.dispatch(["fit", "--json"])

    assert code in [0, 1]
    decoded = Jason.decode!(out)
    assert decoded["use_case"] == "general"
    assert is_map(decoded["system"])
    assert Map.has_key?(decoded, "ranked")
  end

  test "--use-case coding is accepted and threads into the JSON" do
    {:fit, _code, out} = CLI.dispatch(["fit", "--use-case", "coding", "--json"])
    assert Jason.decode!(out)["use_case"] == "coding"
  end

  test "--limit bounds the human-readable ranked list" do
    {:fit, _code, out} = CLI.dispatch(["fit", "--limit", "2"])
    # Count the ranked rows (lines starting with two spaces + a model-ish token).
    ranked_section =
      out
      |> String.split("Ranked", parts: 2)
      |> List.last()

    rows =
      ranked_section
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.match?(&1, ~r/^\s{2}\S/))

    assert length(rows) <= 2
  end
end
