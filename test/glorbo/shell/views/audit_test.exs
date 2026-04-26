defmodule Glorbo.Shell.Views.AuditTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Audit
  alias TermUI.Event.Key

  defp sample_entries do
    [
      %{
        ts: "2026-04-26T10:00:00Z",
        actor: "ceo",
        action: "task.create",
        target: "projects/x/tasks/t-01.md"
      },
      %{
        ts: "2026-04-26T10:01:30Z",
        actor: "engineer",
        action: "approval.requested",
        target: "projects/x/tasks/t-01.md"
      },
      %{ts: "2026-04-26T10:02:00Z", actor: "director", action: "approval.granted", target: ""}
    ]
  end

  describe "init/1" do
    test "with explicit :entries opt, sets list and cursor 0" do
      state = Audit.init(entries: sample_entries())
      assert length(state.entries) == 3
      assert state.cursor == 0
    end

    test "with :loader_fn opt, calls it for the list" do
      ref = make_ref()
      Process.put({:fn_called, ref}, false)

      loader_fn = fn _b, _c ->
        Process.put({:fn_called, ref}, true)
        sample_entries()
      end

      state = Audit.init(base: "/tmp/glorbo", company: "acme", loader_fn: loader_fn)
      assert Process.get({:fn_called, ref}) == true
      assert length(state.entries) == 3
    end

    test "no opts → empty list" do
      state = Audit.init([])
      assert state.entries == []
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Audit.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Audit.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Audit.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Audit.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Audit.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Audit.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Audit.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at last row" do
      state = %{
        entries: sample_entries(),
        cursor: 2,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Audit.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      state = %{
        entries: sample_entries(),
        cursor: 0,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Audit.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn and reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        if n == 0, do: sample_entries(), else: Enum.take(sample_entries(), 1)
      end

      state = Audit.init(base: "/tmp", company: "acme", loader_fn: loader_fn)
      state = %{state | cursor: 2}

      {state, []} = Audit.update(:refresh, state)
      assert length(state.entries) == 1
      assert state.cursor == 0
    end

    test ":refresh without :base/:company is a no-op" do
      state = Audit.init(entries: sample_entries())
      {state, []} = Audit.update(:refresh, state)
      assert state.entries == sample_entries()
    end

    test "unmapped msg → :noreply" do
      assert Audit.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty list renders the empty-state placeholder" do
      view = Audit.view(%{entries: [], cursor: 0})
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content == "No audit entries this month."
    end

    test "non-empty renders [ts] actor action target with ts trimmed to 16 chars" do
      state = Audit.init(entries: sample_entries())
      rendered = render_to_strings(Audit.view(state))

      # ts trimmed to YYYY-MM-DDTHH:MM (16 chars).
      assert Enum.any?(
               rendered,
               &String.contains?(
                 &1,
                 "> [2026-04-26T10:00] ceo task.create projects/x/tasks/t-01.md"
               )
             )

      assert Enum.any?(
               rendered,
               &String.contains?(
                 &1,
                 "  [2026-04-26T10:01] engineer approval.requested projects/x/tasks/t-01.md"
               )
             )

      # Empty target → no trailing space-target.
      assert Enum.any?(
               rendered,
               &String.contains?(&1, "  [2026-04-26T10:02] director approval.granted")
             )

      # Sanity: no trailing space when target is empty.
      director_line = Enum.find(rendered, &String.contains?(&1, "approval.granted"))
      refute String.ends_with?(director_line, " ")
    end

    test "cursor at index 1 prefixes the second row" do
      state = %{entries: sample_entries(), cursor: 1}
      rendered = render_to_strings(Audit.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  [2026-04-26T10:00] ceo"))
      assert Enum.any?(rendered, &String.contains?(&1, "> [2026-04-26T10:01] engineer"))
    end

    test "ts shorter than 16 chars renders as-is" do
      state = Audit.init(entries: [%{ts: "short", actor: "ceo", action: "x", target: ""}])
      rendered = render_to_strings(Audit.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "[short]"))
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
