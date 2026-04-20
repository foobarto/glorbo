defmodule GlorboWeb.TaskLiveTest do
  @moduledoc """
  `GlorboWeb.TaskLive` — `/companies/:company/tasks/:task_id`.

  Covers happy-path render, invalid task-id shape, missing task
  file, and the comment post.
  """
  use GlorboWeb.LiveCase, async: false

  setup %{base: base} do
    # Seed one project + one task so TaskLive has real data to load.
    tasks_dir = Path.join([base, "companies/acme/projects/foo/tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([base, "companies/acme/projects/foo/project.md"]), """
    ---
    slug: foo
    name: foo
    ---
    # foo
    """)

    File.write!(Path.join(tasks_dir, "foo-1.md"), """
    ---
    title: hello task
    assigned_to: ceo
    status: todo
    priority: high
    ---

    original prompt body

    ## 2026-04-20T10:00:00Z | director
    first comment
    """)

    :ok
  end

  test "renders task detail with prompt + comments", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/companies/acme/tasks/foo-1")
    assert html =~ "foo-1"
    assert html =~ "hello task"
    assert html =~ "original prompt body"
    assert html =~ "first comment"
    assert html =~ "← back to kanban"
  end

  test "redirects on invalid task-id shape", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme"}}} =
             live(conn, "/companies/acme/tasks/bogus")
  end

  test "redirects when task file doesn't exist", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             live(conn, "/companies/acme/tasks/ghost-1")
  end

  test "empty comment flashes error", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")
    html = render_submit(view, "comment_task", %{"comment" => ""})
    assert html =~ "Comment is empty"
  end

  test "valid comment appends to task body", %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")
    render_submit(view, "comment_task", %{"comment" => "ping"})

    path = Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"])
    content = File.read!(path)
    assert content =~ "ping"
    assert content =~ "| director"
  end

  test "save_task rewrites frontmatter via shared TaskDetailForm",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")

    render_submit(view, "save_task", %{
      "title" => "renamed task",
      "status" => "in-progress",
      "assigned_to" => "ceo",
      "priority" => "low",
      "severity" => ""
    })

    path = Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"])
    content = File.read!(path)
    assert content =~ ~r/title: "?renamed task"?/
    assert content =~ "status: in-progress"
    assert content =~ "priority: low"
  end

  test "delete_task moves file to history/deleted/",
       %{conn: conn, base: base} do
    {:ok, view, _} = live(conn, ~p"/companies/acme/tasks/foo-1")

    assert {:error, {:live_redirect, %{to: "/companies/acme/kanban"}}} =
             render_click(view, "delete_task", %{
               "path" => "projects/foo/tasks/foo-1.md"
             })

    refute File.exists?(Path.join([base, "companies/acme/projects/foo/tasks/foo-1.md"]))

    deleted =
      [base, "companies/acme/projects/foo/history/deleted"]
      |> Path.join()
      |> File.ls!()
      |> Enum.filter(&String.contains?(&1, "foo-1.md"))

    assert deleted != []
  end
end
