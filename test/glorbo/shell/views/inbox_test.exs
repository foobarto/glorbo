defmodule Glorbo.Shell.Views.InboxTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Inbox
  alias TermUI.Event.Key

  defp sample_approvals do
    [
      %{
        task_id: "task-a",
        task_path: "projects/demo/tasks/task-a.md",
        title: "Alpha",
        assignee: "engineer"
      },
      %{
        task_id: "task-b",
        task_path: "projects/demo/tasks/task-b.md",
        title: "Bravo",
        assignee: "ceo"
      },
      %{task_id: "task-c", task_path: nil, title: "task-c", assignee: nil}
    ]
  end

  describe "init/1" do
    test "with explicit :approvals opt, sets that list and cursor 0" do
      state = Inbox.init(approvals: sample_approvals())
      assert length(state.approvals) == 3
      assert state.cursor == 0
    end

    test "with no opts and no base/company, returns empty state" do
      assert Inbox.init([]) == %{approvals: [], cursor: 0}
    end
  end

  describe "event_to_msg/2" do
    test "down arrow → :cursor_down" do
      assert Inbox.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
    end

    test "up arrow → :cursor_up" do
      assert Inbox.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
    end

    test "j/k → cursor down/up" do
      assert Inbox.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Inbox.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "q → :quit" do
      assert Inbox.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped key → :ignore" do
      assert Inbox.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down advances within bounds" do
      state = Inbox.init(approvals: sample_approvals())
      {state, []} = Inbox.update(:cursor_down, state)
      assert state.cursor == 1
      {state, []} = Inbox.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_down clamps at the last row" do
      state = %{approvals: sample_approvals(), cursor: 2}
      {state, []} = Inbox.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_down on empty list stays at 0" do
      state = %{approvals: [], cursor: 0}
      {state, []} = Inbox.update(:cursor_down, state)
      assert state.cursor == 0
    end

    test ":cursor_up clamps at 0" do
      state = %{approvals: sample_approvals(), cursor: 0}
      {state, []} = Inbox.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test "{:approvals_changed, list} replaces list and reclamps cursor" do
      state = %{approvals: sample_approvals(), cursor: 2}
      shrunken = Enum.take(sample_approvals(), 2)

      {state, []} = Inbox.update({:approvals_changed, shrunken}, state)
      assert state.approvals == shrunken
      # cursor was 2 (third row), now max valid is 1 (second row)
      assert state.cursor == 1
    end

    test "{:approvals_changed, []} resets cursor to 0" do
      state = %{approvals: sample_approvals(), cursor: 2}
      {state, []} = Inbox.update({:approvals_changed, []}, state)
      assert state.approvals == []
      assert state.cursor == 0
    end

    test "unmapped msg → :noreply" do
      assert Inbox.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty state renders the empty-state placeholder" do
      view = Inbox.view(%{approvals: [], cursor: 0})
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content == "Inbox empty — no pending approvals."
    end

    test "non-empty renders one line per approval, cursor row prefixed `> `" do
      state = Inbox.init(approvals: sample_approvals())
      view = Inbox.view(state)
      # term_ui's stack/2 returns a RenderNode; bypass its internal shape and
      # assert by stringifying — tests are about content, not framework wire.
      rendered = render_to_strings(view)
      assert Enum.any?(rendered, &String.contains?(&1, "> task-a — Alpha [engineer]"))
      assert Enum.any?(rendered, &String.contains?(&1, "  task-b — Bravo [ceo]"))
      assert Enum.any?(rendered, &String.contains?(&1, "  task-c — task-c [unassigned]"))
    end

    test "cursor at index 1 prefixes the second row" do
      state = %{approvals: sample_approvals(), cursor: 1}
      rendered = render_to_strings(Inbox.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  task-a — Alpha [engineer]"))
      assert Enum.any?(rendered, &String.contains?(&1, "> task-b — Bravo [ceo]"))
    end
  end

  # ----------------------------------------------------------------
  # Helpers — flatten the term_ui render tree into a list of strings.
  # ----------------------------------------------------------------

  defp render_to_strings(%TermUI.Component.RenderNode{type: :text, content: content}),
    do: [content]

  defp render_to_strings(%TermUI.Component.RenderNode{children: children})
       when is_list(children) do
    Enum.flat_map(children, &render_to_strings/1)
  end

  defp render_to_strings(%TermUI.Component.RenderNode{}), do: []

  defp render_to_strings({:text, content}), do: [content]

  defp render_to_strings(other) when is_list(other),
    do: Enum.flat_map(other, &render_to_strings/1)

  defp render_to_strings(_), do: []
end
