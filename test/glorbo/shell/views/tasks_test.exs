defmodule Glorbo.Shell.Views.TasksTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Tasks
  alias TermUI.Event.Key

  defp sample_rows do
    [
      %{
        task_id: "t-1",
        project: "demo",
        title: "Todo One",
        status: "todo",
        assignee: "ceo",
        lane: :todo
      },
      %{
        task_id: "t-2",
        project: "demo",
        title: "Todo Two",
        status: "todo",
        assignee: nil,
        lane: :todo
      },
      %{
        task_id: "t-3",
        project: "demo",
        title: "Active",
        status: "in-progress",
        assignee: "engineer",
        lane: :in_progress
      },
      %{
        task_id: "t-4",
        project: "demo",
        title: "Review",
        status: "pending-approval",
        assignee: "engineer",
        lane: :review
      },
      %{
        task_id: "t-5",
        project: "demo",
        title: "Done",
        status: "done",
        assignee: nil,
        lane: :done
      }
    ]
  end

  describe "init/1" do
    test "with explicit :rows opt, sets rows in canonical lane order; cursor 0" do
      state = Tasks.init(rows: sample_rows())
      assert length(state.rows) == 5
      # Sort-by-lane is idempotent on already-ordered input.
      assert Enum.map(state.rows, & &1.task_id) == ["t-1", "t-2", "t-3", "t-4", "t-5"]
      assert state.cursor == 0
    end

    test "rearranges rows into canonical lane order on init" do
      shuffled = Enum.reverse(sample_rows())
      state = Tasks.init(rows: shuffled)
      # Shuffled input → init must group + flatten into canonical order.
      assert Enum.map(state.rows, & &1.task_id) == ["t-2", "t-1", "t-3", "t-4", "t-5"]
    end

    test "with :loader_fn, calls it with (base, company)" do
      ref = make_ref()
      Process.put({:fn_called, ref}, false)

      loader_fn = fn _b, _c ->
        Process.put({:fn_called, ref}, true)
        sample_rows()
      end

      state = Tasks.init(base: "/tmp/glorbo", company: "acme", loader_fn: loader_fn)
      assert Process.get({:fn_called, ref}) == true
      assert length(state.rows) == 5
    end

    test "no opts → empty list" do
      state = Tasks.init([])
      assert state.rows == []
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Tasks.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Tasks.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Tasks.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Tasks.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Tasks.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Tasks.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Tasks.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at last row" do
      state = %{
        rows: sample_rows(),
        cursor: 4,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Tasks.update(:cursor_down, state)
      assert state.cursor == 4
    end

    test ":cursor_up clamps at 0" do
      state = %{
        rows: sample_rows(),
        cursor: 0,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Tasks.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn with sort + reclamp" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        if n == 0, do: sample_rows(), else: Enum.take(sample_rows(), 1)
      end

      state = Tasks.init(base: "/tmp", company: "acme", loader_fn: loader_fn)
      state = %{state | cursor: 4}

      {state, []} = Tasks.update(:refresh, state)
      assert length(state.rows) == 1
      assert state.cursor == 0
    end

    test ":refresh without :base/:company is a no-op" do
      state = Tasks.init(rows: sample_rows())
      {state, []} = Tasks.update(:refresh, state)
      assert length(state.rows) == 5
    end

    test "unmapped msg → :noreply" do
      assert Tasks.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty rows render the bootstrap-hint placeholder" do
      view = Tasks.view(%{rows: [], cursor: 0})
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content =~ "No tasks yet"
    end

    test "renders four lane headers with counts; OTHER omitted when empty" do
      state = Tasks.init(rows: sample_rows())
      rendered = render_to_strings(Tasks.view(state))

      assert Enum.any?(rendered, &String.contains?(&1, "▾ TODO (2)"))
      assert Enum.any?(rendered, &String.contains?(&1, "▾ IN PROGRESS (1)"))
      assert Enum.any?(rendered, &String.contains?(&1, "▾ REVIEW (1)"))
      assert Enum.any?(rendered, &String.contains?(&1, "▾ DONE (1)"))
      # OTHER lane is always rendered as a header even when empty —
      # gives the Director a "no surprise tasks" signal.
      assert Enum.any?(rendered, &String.contains?(&1, "▾ OTHER (0)"))
    end

    test "renders one indented row per task with assignee bracket when set" do
      state = Tasks.init(rows: sample_rows())
      rendered = render_to_strings(Tasks.view(state))

      assert Enum.any?(rendered, &String.contains?(&1, "  > t-1 — Todo One [ceo]"))
      # t-2 has no assignee — no bracket.
      assert Enum.any?(rendered, &String.contains?(&1, "    t-2 — Todo Two"))
      refute Enum.any?(rendered, &(String.contains?(&1, "t-2") and String.contains?(&1, "[")))
      assert Enum.any?(rendered, &String.contains?(&1, "    t-3 — Active [engineer]"))
    end

    test "cursor moves across lane boundaries (flat row index)" do
      # Cursor 3 should be on t-4 (review lane).
      state = %{Tasks.init(rows: sample_rows()) | cursor: 3}
      rendered = render_to_strings(Tasks.view(state))

      assert Enum.any?(rendered, &String.contains?(&1, "  > t-4 — Review"))
      # t-1 is no longer the cursor row.
      assert Enum.any?(rendered, &String.contains?(&1, "    t-1 — Todo One"))
    end
  end

  defp render_to_strings(%TermUI.Component.RenderNode{type: :text, content: content}),
    do: [content]

  defp render_to_strings(%TermUI.Component.RenderNode{children: children})
       when is_list(children) do
    Enum.flat_map(children, &render_to_strings/1)
  end

  defp render_to_strings(%TermUI.Component.RenderNode{}), do: []
  defp render_to_strings(_), do: []
end
