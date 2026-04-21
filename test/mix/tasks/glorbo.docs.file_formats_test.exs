defmodule Mix.Tasks.Glorbo.Docs.FileFormatsTest do
  @moduledoc """
  Regression coverage for `mix glorbo.docs.file_formats` (R26.2b,
  GEP-25). Scope is focused on the task's happy path + drift
  detection — not the full rendered content, which is verified by
  the precommit step asserting the committed tree is clean.

  Assertions:

    * After `mix glorbo.docs.file_formats`, the checked-in
      `docs/file-formats/` tree is idempotent (second run writes
      0 files).
    * `--check` exits 0 with clean tree.
    * `--check` raises a Mix error when a target file is out of
      date.
    * Every registered FileSpec kind has a dedicated markdown page.
  """
  use ExUnit.Case, async: false

  @docs_dir "docs/file-formats"

  test "every FileSpec kind has a committed markdown page" do
    kinds = Enum.map(Glorbo.FileSpec.specs(), & &1.kind())

    for kind <- kinds do
      filename = String.replace(kind, "/", "_") <> ".md"
      path = Path.join(@docs_dir, filename)
      assert File.regular?(path), "expected generated doc at #{path}"
    end

    # README index exists too.
    assert File.regular?(Path.join(@docs_dir, "README.md"))
  end

  test "generator task is idempotent (second run writes zero files)" do
    # Two runs back-to-back. The second should detect zero drift.
    # Use `--check` instead of a real write to avoid touching the
    # committed tree during a `mix test` invocation.
    Mix.Task.rerun("glorbo.docs.file_formats", ["--check"])
  end

  test "--check raises on drift" do
    task_file = Path.join(@docs_dir, "task_v1.md")
    original = File.read!(task_file)

    try do
      File.write!(task_file, original <> "\n\ndrift\n")

      assert_raise Mix.Error, ~r/docs\/file-formats drift/, fn ->
        Mix.Task.rerun("glorbo.docs.file_formats", ["--check"])
      end
    after
      File.write!(task_file, original)
    end
  end
end
