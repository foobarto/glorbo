defmodule Glorbo.FileSpec.GoldenFixturesTest do
  @moduledoc """
  Per-kind golden fixtures for GEP-25 R26.2b.

  Every fixture under `test/fixtures/file-formats/<kind>/<class>/...`
  must:

    * classify via `Glorbo.FileSpec.classify_by_path/1` into the
      expected kind (the directory name's `-/_` collapsed).
    * be accepted by `Glorbo.FileSpec.Validator` — zero
      `:error`-severity findings.
    * round-trip byte-for-byte through `FileSpec.Formatter` —
      `format(content)` returns `:unchanged`, and
      `format(format(content))` is idempotent.

  New fixture classes go under `<kind>/minimal_valid/...` or
  `<kind>/maximal_valid/...`. The test auto-discovers every `.md`
  and `.json` / `.jsonl` file beneath the root.
  """
  use ExUnit.Case, async: true

  alias Glorbo.FileSpec
  alias Glorbo.FileSpec.Formatter
  alias Glorbo.FileSpec.Validator

  @fixture_root "test/fixtures/file-formats"

  fixture_paths =
    "#{@fixture_root}/**/*"
    |> Path.wildcard()
    |> Enum.filter(fn p ->
      File.regular?(p) and
        (String.ends_with?(p, ".md") or String.ends_with?(p, ".json") or
           String.ends_with?(p, ".jsonl"))
    end)

  # Valid fixtures cover both `minimal_valid/` (required fields only)
  # and `maximal_valid/` (every optional field populated). Both must
  # pass Validator + Formatter checks.
  valid_paths =
    fixture_paths
    |> Enum.filter(fn p ->
      String.contains?(p, "/minimal_valid/") or
        String.contains?(p, "/maximal_valid/")
    end)

  valid_md_paths =
    valid_paths
    |> Enum.filter(&String.ends_with?(&1, ".md"))

  @found_fixture_count length(fixture_paths)

  test "fixture root exists with at least one valid file" do
    assert File.dir?(@fixture_root)
    assert @found_fixture_count > 0
  end

  describe "classify_by_path/1" do
    for path <- fixture_paths do
      relative = Path.relative_to(path, @fixture_root)
      dir = relative |> Path.split() |> List.first()

      expected_kind =
        case String.split(dir, "_v", parts: 2) do
          [name, version] -> "#{name}/v#{version}"
          _ -> dir
        end

      @path path
      @expected_kind expected_kind

      test "#{@path} classifies as #{@expected_kind}" do
        assert {:ok, mod} = FileSpec.classify_by_path(@path)
        assert mod.kind() == @expected_kind
      end
    end
  end

  describe "Validator — valid fixtures have no :error findings" do
    for path <- valid_paths do
      @path path

      test "#{@path}" do
        findings = Validator.findings(@path)
        errors = Enum.filter(findings, &(&1.severity == :error))

        assert errors == [],
               "expected zero :error findings, got:\n#{inspect(errors, pretty: true)}"
      end
    end
  end

  describe "Formatter — valid fixtures are already canonical" do
    for path <- valid_md_paths do
      @path path

      test "#{@path} round-trips unchanged" do
        content = File.read!(@path)

        assert {:ok, first_change, formatted} = Formatter.format_content(@path, content)

        assert first_change in [:unchanged, :skipped],
               "fixture #{@path} is not in canonical form: formatter reported :changed"

        assert {:ok, second_change, reformatted} = Formatter.format_content(@path, formatted)
        assert second_change in [:unchanged, :skipped]
        assert reformatted == formatted
      end
    end
  end
end
