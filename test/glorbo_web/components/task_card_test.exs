defmodule GlorboWeb.Components.TaskCardTest do
  @moduledoc """
  TaskCard rendering — focus on #237 recurring-task glyph.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GlorboWeb.Components.TaskCard

  defp render_card(task) do
    assigns = %{
      task: task,
      company_slug: "acme",
      __changed__: nil
    }

    TaskCard.task_card(assigns) |> rendered_to_string()
  end

  defp base_task do
    %{
      task_id: "t-01",
      task_path: "projects/foo/tasks/t-01.md",
      title: "hello",
      status: "todo",
      project: "foo",
      priority: nil,
      severity: nil,
      assigned_to: nil,
      requires_approval: nil,
      schedule: nil
    }
  end

  test "renders without a recurring tag when schedule is nil" do
    html = render_card(base_task())
    refute html =~ "gl-task-card__recurring"
    refute html =~ "↻"
  end

  test "renders the recurring tag with schedule text when set" do
    html = render_card(%{base_task() | schedule: "every monday at 9am"})
    assert html =~ "gl-task-card__recurring"
    assert html =~ "↻"
    assert html =~ "every monday at 9am"
  end

  test "blank schedule does not trigger the tag" do
    html = render_card(%{base_task() | schedule: ""})
    refute html =~ "gl-task-card__recurring"
  end

  test "whitespace-only schedule does not trigger the tag" do
    html = render_card(%{base_task() | schedule: "   "})
    refute html =~ "gl-task-card__recurring"
  end
end
