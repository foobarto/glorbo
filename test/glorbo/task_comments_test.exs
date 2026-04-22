defmodule Glorbo.TaskCommentsTest do
  @moduledoc """
  Unit tests for the `Glorbo.TaskComments` sibling-file reader +
  writer (GEP-30 D8).
  """
  use ExUnit.Case, async: true

  alias Glorbo.TaskComments

  setup do
    tmp = Path.join(System.tmp_dir!(), "glorbo_tc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "path_for/1" do
    test "derives sibling path from a task file path" do
      assert TaskComments.path_for("projects/blog/tasks/blog-2.md") ==
               "projects/blog/tasks/blog-2.comments.md"
    end

    test "works on absolute paths" do
      assert TaskComments.path_for("/base/companies/acme/projects/blog/tasks/blog-2.md") ==
               "/base/companies/acme/projects/blog/tasks/blog-2.comments.md"
    end
  end

  describe "read/1" do
    test "returns {:ok, []} for a missing file", %{tmp: tmp} do
      assert {:ok, []} = TaskComments.read(Path.join(tmp, "missing.comments.md"))
    end

    test "parses two entries in on-disk order", %{tmp: tmp} do
      path = Path.join(tmp, "blog-2.comments.md")

      File.write!(path, """
      ---
      kind: task-comments/v1
      task_id: blog-2
      ---

      ## 2026-04-22T10:00:00Z | director
      First message.

      ## 2026-04-22T10:12:00Z | ceo
      Second message across
      multiple lines.
      """)

      assert {:ok, [first, second]} = TaskComments.read(path)
      assert first.author == "director"
      assert first.timestamp == "2026-04-22T10:00:00Z"
      assert first.body == "First message."
      assert second.author == "ceo"
      assert second.body =~ "Second message"
      assert second.body =~ "multiple lines."
    end
  end

  describe "append/4" do
    test "bootstraps the file with frontmatter on first write", %{tmp: tmp} do
      path = Path.join(tmp, "blog-2.comments.md")

      assert :ok = TaskComments.append(path, "director", "hello", ts: "2026-04-22T10:00:00Z")

      content = File.read!(path)
      assert content =~ "kind: task-comments/v1"
      assert content =~ "task_id: blog-2"
      assert content =~ "## 2026-04-22T10:00:00Z | director"
      assert content =~ "hello"
    end

    test "second append preserves the first", %{tmp: tmp} do
      path = Path.join(tmp, "blog-2.comments.md")

      :ok = TaskComments.append(path, "director", "first", ts: "2026-04-22T10:00:00Z")
      :ok = TaskComments.append(path, "ceo", "second", ts: "2026-04-22T10:01:00Z")

      assert {:ok, [a, b]} = TaskComments.read(path)
      assert a.body == "first"
      assert a.author == "director"
      assert b.body == "second"
      assert b.author == "ceo"
    end

    test "creates the parent directory when it doesn't exist", %{tmp: tmp} do
      path = Path.join([tmp, "deep", "nested", "blog-2.comments.md"])

      assert :ok = TaskComments.append(path, "director", "hi", ts: "2026-04-22T10:00:00Z")
      assert File.exists?(path)
    end
  end
end
