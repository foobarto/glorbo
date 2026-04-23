defmodule Mix.Tasks.Glorbo.ReleaseFormulaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Glorbo.ReleaseFormula, as: ReleaseFormulaTask

  test "parse_sha256sums/1 keeps valid digests for required assets" do
    body = """
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  glorbo-linux-x86_64
    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  glorbo-linux-aarch64
    cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  glorbo-darwin-x86_64
    dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd  glorbo-darwin-arm64
    """

    shas = ReleaseFormulaTask.parse_sha256sums(body)

    assert shas["glorbo-linux-x86_64"] == String.duplicate("a", 64)
    assert shas["glorbo-linux-aarch64"] == String.duplicate("b", 64)
    assert shas["glorbo-darwin-x86_64"] == String.duplicate("c", 64)
    assert shas["glorbo-darwin-arm64"] == String.duplicate("d", 64)
  end

  test "parse_sha256sums/1 rejects non-hex digests" do
    body = "not-a-sha  glorbo-linux-x86_64\n"

    assert_raise Mix.Error, ~r/invalid sha256/, fn ->
      ReleaseFormulaTask.parse_sha256sums(body)
    end
  end

  test "validate_assets!/1 rejects malformed required digests" do
    shas = %{
      "glorbo-linux-x86_64" => String.duplicate("a", 64),
      "glorbo-linux-aarch64" => String.duplicate("b", 64),
      "glorbo-darwin-x86_64" => "bogus",
      "glorbo-darwin-arm64" => String.duplicate("d", 64)
    }

    assert_raise Mix.Error, ~r/invalid sha256 for required asset `glorbo-darwin-x86_64`/, fn ->
      ReleaseFormulaTask.validate_assets!(shas)
    end
  end
end
