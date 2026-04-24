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
      peer_review_required: false,
      peer_review_verdict: nil,
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

  # GEP-41 Round N-2 — peer-review pill visibility.
  describe "peer-review pill (GEP-41)" do
    test "shows ⧗ peer-review when peer_review_required and no verdict" do
      html = render_card(%{base_task() | peer_review_required: true})
      assert html =~ "⧗ peer-review"
      assert html =~ "gl-task-card__peer-review-tag"
    end

    test "hides the pill once a verdict is recorded" do
      html =
        render_card(%{
          base_task()
          | peer_review_required: true,
            peer_review_verdict: "approve"
        })

      refute html =~ "⧗ peer-review"

      html2 =
        render_card(%{
          base_task()
          | peer_review_required: true,
            peer_review_verdict: "block"
        })

      refute html2 =~ "⧗ peer-review"
    end

    test "does not show when peer_review_required is false" do
      html = render_card(base_task())
      refute html =~ "⧗ peer-review"
    end

    test "coexists with the ⚠ gated approval pill" do
      html =
        render_card(%{
          base_task()
          | peer_review_required: true,
            requires_approval: :director,
            status: "pending"
        })

      assert html =~ "⚠ gated"
      assert html =~ "⧗ peer-review"
    end
  end
end
