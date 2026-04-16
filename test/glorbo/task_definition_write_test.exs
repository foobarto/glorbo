defmodule Glorbo.TaskDefinitionWriteTest do
  @moduledoc """
  Plan 04-01 Task 2: `TaskDefinition.write/2` atomic frontmatter mutation.

  Contract:
    * `:status` + `:denial_reason` allowed; anything else returns
      `{:error, {:unsupported_key, k}}` WITHOUT touching the file.
    * Atomic: writes to `<path>.tmp` first, `File.rename/2` onto the
      target — partial state never visible to the Watcher.
    * File without frontmatter returns `{:error, :no_frontmatter}`.
    * Unknown frontmatter keys and comments preserved verbatim.
  """
  use ExUnit.Case, async: true

  alias Glorbo.TaskDefinition
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    path = Path.join(base, "t-01.md")
    {:ok, base: base, path: path}
  end

  defp seed_task(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  describe "supported keys" do
    test "rewrites status in place; preserves other frontmatter verbatim", %{path: path} do
      seed_task(path, """
      ---
      title: "Deploy landing page"
      status: pending
      assigned_to: ceo
      requires_approval: director
      ---

      Ship it.
      """)

      assert :ok = TaskDefinition.write(path, %{status: "approved"})

      updated = File.read!(path)
      assert updated =~ "status: approved"
      assert updated =~ "title: \"Deploy landing page\""
      assert updated =~ "assigned_to: ceo"
      assert updated =~ "requires_approval: director"
      assert updated =~ "Ship it."
    end

    test "rewrites denial_reason when missing; adds value inline", %{path: path} do
      seed_task(path, """
      ---
      title: "Deploy landing page"
      status: pending
      denial_reason: ""
      ---

      Ship it.
      """)

      assert :ok = TaskDefinition.write(path, %{denial_reason: "budget exceeded"})

      updated = File.read!(path)
      # Quoted because 'budget exceeded' contains a space (YAML-ambiguous).
      assert updated =~ ~s(denial_reason: "budget exceeded")
    end

    test "accepts string keys as well as atom keys", %{path: path} do
      seed_task(path, """
      ---
      status: pending
      ---

      body
      """)

      assert :ok = TaskDefinition.write(path, %{"status" => "denied"})
      assert File.read!(path) =~ "status: denied"
    end
  end

  describe "rejection + atomicity" do
    test "unsupported key — {:error, {:unsupported_key, k}}, file untouched", %{path: path} do
      original = """
      ---
      status: pending
      ---

      body
      """

      seed_task(path, original)

      assert {:error, {:unsupported_key, :title}} =
               TaskDefinition.write(path, %{title: "New title"})

      # File is byte-identical to the seed.
      assert File.read!(path) == original
    end

    test "missing frontmatter — {:error, :no_frontmatter}, file untouched", %{path: path} do
      original = "# Just a heading, no frontmatter\n"
      seed_task(path, original)

      assert {:error, :no_frontmatter} = TaskDefinition.write(path, %{status: "approved"})
      assert File.read!(path) == original
    end

    test "non-existent file — read error propagates, no tmp created", %{base: base} do
      missing = Path.join(base, "missing.md")
      assert {:error, :enoent} = TaskDefinition.write(missing, %{status: "approved"})
      refute File.exists?(missing <> ".tmp")
    end

    test "no .tmp artifact remains after success", %{path: path} do
      seed_task(path, """
      ---
      status: pending
      ---

      body
      """)

      assert :ok = TaskDefinition.write(path, %{status: "approved"})
      refute File.exists?(path <> ".tmp")
    end
  end

  describe "yaml-ambiguity quoting" do
    test "reserved-word values are quoted (null)", %{path: path} do
      seed_task(path, """
      ---
      denial_reason: ok
      ---

      body
      """)

      assert :ok = TaskDefinition.write(path, %{denial_reason: "null"})
      assert File.read!(path) =~ ~s(denial_reason: "null")
    end

    test "simple identifiers remain unquoted", %{path: path} do
      seed_task(path, """
      ---
      status: pending
      ---

      body
      """)

      assert :ok = TaskDefinition.write(path, %{status: "approved"})
      # No quotes around "approved" — it's a plain identifier.
      assert File.read!(path) =~ "status: approved"
      refute File.read!(path) =~ ~s(status: "approved")
    end
  end

  describe "frontmatter round-trip remains parseable" do
    test "after write, parse_file/2 succeeds with the new status", %{base: base} do
      co_dir = Path.join([base, "companies", "acme", "projects", "site", "tasks"])
      File.mkdir_p!(co_dir)
      task_path = Path.join(co_dir, "t-01.md")

      File.write!(task_path, """
      ---
      title: "Deploy"
      status: pending
      assigned_to: ceo
      requires_approval: director
      ---

      Ship it.
      """)

      assert :ok = TaskDefinition.write(task_path, %{status: "approved"})

      assert {:ok, td} =
               TaskDefinition.parse_file(task_path, base: base, company: "acme")

      assert td.status == "approved"
      assert td.title == "Deploy"
      assert td.requires_approval == :director
    end
  end
end
