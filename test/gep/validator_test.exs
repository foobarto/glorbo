defmodule Gep.ValidatorTest do
  use ExUnit.Case, async: true

  alias Gep.Validator

  describe "valid GEP" do
    test "passes all per-record checks" do
      tmp_dir = tmp_gep_dir([valid_gep(1)])
      results = Validator.validate_all(tmp_dir)

      assert no_errors_for_gep(results, 1)
      File.rm_rf!(tmp_dir)
    end
  end

  describe "missing required fields" do
    test "missing title produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | title: nil}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required field: title")
      File.rm_rf!(tmp_dir)
    end

    test "missing author produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | author: nil}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required field: author")
      File.rm_rf!(tmp_dir)
    end

    test "missing status produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | status: nil}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required field: status")
      File.rm_rf!(tmp_dir)
    end

    test "missing type produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | type: nil}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required field: type")
      File.rm_rf!(tmp_dir)
    end

    test "missing history produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | history: []}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required field: history")
      File.rm_rf!(tmp_dir)
    end
  end

  describe "enum validation" do
    test "invalid status produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | status: "Banana"}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Invalid status 'Banana'")
      File.rm_rf!(tmp_dir)
    end

    test "invalid type produces error" do
      tmp_dir = tmp_gep_dir([%{valid_gep(1) | type: "Banana"}])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Invalid type 'Banana'")
      File.rm_rf!(tmp_dir)
    end
  end

  describe "filename match" do
    test "filename number must match gep field" do
      tmp_dir =
        tmp_gep_dir_with_filenames([
          {"0002-mismatch.md", %{valid_gep(1) | number: 1}}
        ])

      results = Validator.validate_all(tmp_dir)
      # gep_number is derived from filename (2), not frontmatter (1)
      assert has_error(results, 2, "Filename says 2, frontmatter says gep: 1")
      File.rm_rf!(tmp_dir)
    end
  end

  describe "status/history consistency" do
    test "top-level status must match last history entry" do
      gep = %{
        valid_gep(1)
        | status: "Draft",
          history: [
            %{"date" => "2026-01-01", "status" => "Accepted", "note" => "Approved"}
          ]
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(
               results,
               1,
               ~r/Top-level status says .*Draft.*last history entry says.*Accepted/
             )

      File.rm_rf!(tmp_dir)
    end
  end

  describe "history entries" do
    test "missing date in history produces error" do
      gep = %{
        valid_gep(1)
        | history: [%{"status" => "Draft", "note" => "Initial"}]
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "history[1] missing date")
      File.rm_rf!(tmp_dir)
    end

    test "invalid date format produces error" do
      gep = %{
        valid_gep(1)
        | history: [%{"date" => "01-01-2026", "status" => "Draft"}]
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "history[1] invalid date format")
      File.rm_rf!(tmp_dir)
    end

    test "missing status in history produces error" do
      gep = %{
        valid_gep(1)
        | history: [%{"date" => "2026-01-01", "note" => "Initial"}]
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "history[1] missing status")
      File.rm_rf!(tmp_dir)
    end
  end

  describe "bidirectional links" do
    test "supersedes without reciprocal superseded-by produces error" do
      gep1 = valid_gep(1)
      gep2 = %{valid_gep(2) | supersedes: [1]}

      tmp_dir = tmp_gep_dir([gep1, gep2])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 2, ~r/supersedes.*but.*no superseded-by/)
      File.rm_rf!(tmp_dir)
    end

    test "proper supersedes/superseded-by pair passes" do
      gep1 = %{
        valid_gep(1)
        | status: "Superseded",
          superseded_by: 2,
          history: [%{"date" => "2026-01-01", "status" => "Superseded"}]
      }

      gep2 = %{valid_gep(2) | supersedes: [1]}

      tmp_dir = tmp_gep_dir([gep1, gep2])
      results = Validator.validate_all(tmp_dir)

      assert no_errors_for_gep(results, 1)
      assert no_errors_for_gep(results, 2)
      File.rm_rf!(tmp_dir)
    end
  end

  describe "cross-references" do
    test "reference to non-existent GEP produces error" do
      gep = %{valid_gep(1) | requires: [99]}
      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "references GEP-0099 which does not exist")
      File.rm_rf!(tmp_dir)
    end

    test "valid reference passes" do
      gep1 = valid_gep(1)
      gep2 = %{valid_gep(2) | requires: [1]}
      tmp_dir = tmp_gep_dir([gep1, gep2])
      results = Validator.validate_all(tmp_dir)

      assert no_errors_for_gep(results, 2)
      File.rm_rf!(tmp_dir)
    end
  end

  describe "superseded status" do
    test "superseded-by without Superseded status produces error" do
      gep = %{
        valid_gep(1)
        | superseded_by: 2,
          status: "Draft",
          history: [%{"date" => "2026-01-01", "status" => "Draft"}]
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, ~r/superseded-by.*status is.*Draft.*expected.*Superseded/)
      File.rm_rf!(tmp_dir)
    end
  end

  describe "required sections" do
    test "Draft Standards GEP missing Decision log produces error" do
      gep = %{
        valid_gep(1)
        | type: "Standards",
          status: "Draft",
          history: [%{"date" => "2026-01-01", "status" => "Draft", "note" => "Initial"}],
          body: """
          ## Problem
          Something is broken.

          ## Goals
          Fix it.

          ## Non-goals
          Not doing X.

          ## Design
          Here's the design.

          ## Migration / rollout
          Step by step.

          ## Failure modes
          Things break.

          ## Test strategy
          Tests go here.
          """
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert has_error(results, 1, "Missing required sections for Standards: Decision log")
      File.rm_rf!(tmp_dir)
    end

    test "Informational GEP skips section validation" do
      gep = %{
        valid_gep(1)
        | type: "Informational",
          body: """
          ## Purpose
          Something.
          """
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      # No section check result at all for non-Standards
      assert no_errors_for_gep(results, 1)
      File.rm_rf!(tmp_dir)
    end

    test "Accepted Standards GEP skips section validation" do
      gep = %{
        valid_gep(1)
        | type: "Standards",
          body: ""
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      # No section check result at all for Accepted Standards
      assert no_errors_for_gep(results, 1)
      File.rm_rf!(tmp_dir)
    end

    test "Draft Standards GEP with all required sections passes" do
      gep = %{
        valid_gep(1)
        | type: "Standards",
          body: """
          ## Problem
          Something is broken.

          ## Goals
          Fix it.

          ## Non-goals
          Not doing X.

          ## Design
          Here's the design.

          ## Migration / rollout
          Step by step.

          ## Failure modes
          Things break.

          ## Test strategy
          Tests go here.

          ## Decision log
          D1. We chose X.
          """
      }

      tmp_dir = tmp_gep_dir([gep])
      results = Validator.validate_all(tmp_dir)

      assert no_errors_for_gep(results, 1)
      File.rm_rf!(tmp_dir)
    end
  end

  describe "sequential numbering" do
    test "gap in numbering produces warning" do
      gep1 = valid_gep(1)
      gep3 = valid_gep(3)
      tmp_dir = tmp_gep_dir([gep1, gep3])
      results = Validator.validate_all(tmp_dir)

      assert has_warning(results, ~r/Gap.*GEP-0002/)
      File.rm_rf!(tmp_dir)
    end

    test "no gaps produces pass" do
      tmp_dir = tmp_gep_dir([valid_gep(1), valid_gep(2)])
      results = Validator.validate_all(tmp_dir)

      assert has_pass(results, "Numbering")
      File.rm_rf!(tmp_dir)
    end
  end

  describe "README index" do
    test "missing from index produces error" do
      tmp_dir = tmp_gep_dir([valid_gep(1)])
      readme = Path.join(tmp_dir, "README.md")

      File.write!(
        readme,
        "# Index\n\n| # | Title | Type | Status |\n|---|-------|------|--------|\n"
      )

      results = Validator.validate_all(tmp_dir)
      assert has_error(results, ~r/GEP-0001.*not in README index/)
      File.rm_rf!(tmp_dir)
    end

    test "status mismatch produces error" do
      tmp_dir = tmp_gep_dir([valid_gep(1)])
      readme = Path.join(tmp_dir, "README.md")

      File.write!(readme, """
      # Index

      | #    | Title                                       | Type          | Status   |
      |------|---------------------------------------------|---------------|----------|
      | 0001 | [Test](./0001-test.md)                      | Informational | Draft    |
      """)

      results = Validator.validate_all(tmp_dir)
      assert has_error(results, ~r/README says.*Draft.*file says.*Accepted/)
      File.rm_rf!(tmp_dir)
    end

    test "matching index passes" do
      tmp_dir = tmp_gep_dir([valid_gep(1)])
      readme = Path.join(tmp_dir, "README.md")

      File.write!(readme, """
      # Index

      | #    | Title                                       | Type          | Status   |
      |------|---------------------------------------------|---------------|----------|
      | 0001 | [Test](./0001-test.md)                      | Informational | Accepted |
      """)

      results = Validator.validate_all(tmp_dir)
      assert has_pass(results, "README index")
      File.rm_rf!(tmp_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp valid_gep(n) do
    %{
      number: n,
      filename: "#{String.pad_leading("#{n}", 4, "0")}-test-#{n}.md",
      title: "Test GEP #{n}",
      author: "Test Author <test@example.com>",
      status: "Accepted",
      type: "Informational",
      created: "2026-01-01",
      updated: nil,
      history: [%{"date" => "2026-01-01", "status" => "Accepted", "note" => "Initial"}],
      requires: nil,
      supersedes: nil,
      superseded_by: nil,
      extended_by: nil,
      see_also: nil,
      implemented_in: nil,
      body: """
      ## Problem
      Something.

      ## Design
      Something.

      ## Decision log
      D1. Decision.
      """
    }
  end

  defp tmp_gep_dir(geps) do
    tmp_dir = Path.join(System.tmp_dir!(), "gep_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    Enum.each(geps, fn gep ->
      write_gep(tmp_dir, gep)
    end)

    tmp_dir
  end

  defp tmp_gep_dir_with_filenames(filename_gep_pairs) do
    tmp_dir = Path.join(System.tmp_dir!(), "gep_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    Enum.each(filename_gep_pairs, fn {filename, gep} ->
      write_gep_with_filename(tmp_dir, filename, gep)
    end)

    tmp_dir
  end

  defp write_gep(dir, gep) do
    frontmatter = build_frontmatter(gep)
    body = gep.body || ""
    File.write!(Path.join(dir, gep.filename), frontmatter <> "\n" <> body)
  end

  defp write_gep_with_filename(dir, filename, gep) do
    frontmatter = build_frontmatter(gep)
    body = gep.body || ""
    File.write!(Path.join(dir, filename), frontmatter <> "\n" <> body)
  end

  defp build_frontmatter(gep) do
    history_yaml =
      Enum.map_join(gep.history, "\n", fn h ->
        "  - date: #{h["date"]}\n    status: #{h["status"]}\n    note: #{h["note"]}"
      end)

    optional_fields =
      [
        {"superseded-by", gep.superseded_by},
        {"supersedes", gep.supersedes},
        {"requires", gep.requires},
        {"extended-by", gep.extended_by},
        {"see-also", gep.see_also}
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)
      |> Enum.map_join("\n", fn {k, v} ->
        yaml_val =
          if is_list(v) do
            "[" <> Enum.map_join(v, ", ", &to_string/1) <> "]"
          else
            to_string(v)
          end

        "#{k}: #{yaml_val}"
      end)

    optional_block =
      if optional_fields != "" do
        "\n" <> optional_fields
      else
        ""
      end

    """
    ---
    kind: task/v1
    gep: #{gep.number}
    title: #{gep.title}
    author: #{gep.author}
    status: #{gep.status}
    type: #{gep.type}
    created: #{gep.created}
    history:
    #{history_yaml}#{optional_block}
    ---
    """
  end

  defp has_error(results, gep_number, pattern) when is_integer(gep_number) do
    Enum.any?(results, fn r ->
      r.severity == :error and r[:gep_number] == gep_number and r.detail =~ pattern
    end)
  end

  defp has_error(results, pattern) when is_binary(pattern) do
    Enum.any?(results, fn r ->
      r.severity == :error and r.detail =~ pattern
    end)
  end

  defp has_error(results, pattern) when is_struct(pattern, Regex) do
    Enum.any?(results, fn r ->
      r.severity == :error and Regex.match?(pattern, r.detail)
    end)
  end

  defp has_warning(results, pattern) do
    Enum.any?(results, fn r ->
      r.severity == :warning and Regex.match?(pattern, r.detail)
    end)
  end

  defp has_pass(results, label) do
    Enum.any?(results, fn r ->
      r.severity == :pass and r.label == label
    end)
  end

  defp no_errors_for_gep(results, number) do
    not Enum.any?(results, fn r -> r[:gep_number] == number and r.severity == :error end)
  end
end
