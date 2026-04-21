defmodule GlorboWeb.Components.TaskDetailFormTest do
  @moduledoc """
  `GlorboWeb.Components.TaskDetailForm.task_detail_form/1` focused
  on the comment-body render path.

  Round 12 (#276) — task-ID tokens in comment bodies render as
  anchor tags to the kanban deep-link, consistent with channel
  message rendering. Raw HTML in comment text stays escaped.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [sigil_H: 2]

  alias GlorboWeb.Components.TaskDetailForm

  defp render_form(comments) do
    assigns = %{
      task: %{
        task_id: "foo-1",
        task_path: "projects/foo/tasks/foo-1.md",
        title: "Foo",
        status: "todo",
        assigned_to: "ceo",
        priority: "",
        severity: "",
        requires_approval: "",
        denial_reason: "",
        schedule: "",
        body: "",
        comments: comments
      },
      company_slug: "acme",
      assignee_options: []
    }

    rendered_to_string(~H"""
    <TaskDetailForm.task_detail_form
      task={@task}
      company_slug={@company_slug}
      assignee_options={@assignee_options}
    />
    """)
  end

  test "plain-text comment body renders unchanged when there are no task-IDs" do
    html =
      render_form([
        %{author: "director", timestamp: "2026-04-21T05:00:00Z", body: "just a plain note"}
      ])

    assert html =~ "just a plain note"
    refute html =~ "gl-task-ref"
  end

  test "task-ID token in comment body becomes an anchor to the kanban deep-link" do
    html =
      render_form([
        %{
          author: "director",
          timestamp: "2026-04-21T05:00:00Z",
          body: "please sync with abc-02 before starting"
        }
      ])

    assert html =~ ~s(<a class="gl-task-ref")
    assert html =~ ~s(href="/companies/acme/kanban?task=projects/abc/tasks/abc-02.md")
    assert html =~ ">abc-02</a>"
  end

  test "multiple task-IDs in the same comment all become anchors" do
    html =
      render_form([
        %{
          author: "director",
          timestamp: "2026-04-21T05:00:00Z",
          body: "blocks: abc-02, web-15, glorbo-7"
        }
      ])

    assert html =~ ">abc-02</a>"
    assert html =~ ">web-15</a>"
    assert html =~ ">glorbo-7</a>"
  end

  test "HTML in comment body is escaped — no XSS through linkify" do
    html =
      render_form([
        %{
          author: "director",
          timestamp: "2026-04-21T05:00:00Z",
          body: "<script>alert('xss')</script> innocent text abc-02"
        }
      ])

    # Script tag is escaped — no raw <script> in output.
    refute html =~ "<script>alert('xss')</script>"
    assert html =~ "&lt;script&gt;"
    # The task-ID after the script is still linkified.
    assert html =~ ">abc-02</a>"
  end
end
