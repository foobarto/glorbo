defmodule Glorbo.Shell.Views.ChatTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Chat
  alias TermUI.Event.Key

  defp sample_messages do
    [
      %{ts: "2026-04-26T10:00:00Z", author: "director", body: "Hello, team."},
      %{ts: "2026-04-26T10:01:30Z", author: "engineer", body: "Working on it.\nMore detail."},
      %{ts: "2026-04-26T10:02:00Z", author: "ceo", body: ""}
    ]
  end

  describe "init/1" do
    test "with explicit :messages opt, sets list and cursor 0; default channel" do
      state = Chat.init(messages: sample_messages())
      assert length(state.messages) == 3
      assert state.cursor == 0
      assert state.channel == "general"
    end

    test "respects :channel opt" do
      state = Chat.init(messages: [], channel: "incidents")
      assert state.channel == "incidents"
    end

    test "with :loader_fn opt, calls it with (base, company, channel)" do
      ref = make_ref()
      Process.put({:fn_called, ref}, nil)

      loader_fn = fn base, co, ch ->
        Process.put({:fn_called, ref}, {base, co, ch})
        sample_messages()
      end

      state =
        Chat.init(
          base: "/tmp/glorbo",
          company: "acme",
          channel: "incidents",
          loader_fn: loader_fn
        )

      assert Process.get({:fn_called, ref}) == {"/tmp/glorbo", "acme", "incidents"}
      assert length(state.messages) == 3
    end

    test "no opts → empty list" do
      state = Chat.init([])
      assert state.messages == []
      assert state.channel == "general"
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Chat.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Chat.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Chat.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Chat.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Chat.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Chat.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Chat.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at last row" do
      state = %{
        messages: sample_messages(),
        cursor: 2,
        base: nil,
        company: nil,
        channel: "general",
        loader_fn: fn _, _, _ -> [] end
      }

      {state, []} = Chat.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      state = %{
        messages: sample_messages(),
        cursor: 0,
        base: nil,
        company: nil,
        channel: "general",
        loader_fn: fn _, _, _ -> [] end
      }

      {state, []} = Chat.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn with current channel and reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c, ch ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        # Capture the channel arg for assertion below.
        Process.put({:loader_channel, ref}, ch)
        if n == 0, do: sample_messages(), else: Enum.take(sample_messages(), 1)
      end

      state =
        Chat.init(
          base: "/tmp",
          company: "acme",
          channel: "incidents",
          loader_fn: loader_fn
        )

      state = %{state | cursor: 2}

      {state, []} = Chat.update(:refresh, state)
      assert length(state.messages) == 1
      assert state.cursor == 0
      assert Process.get({:loader_channel, ref}) == "incidents"
    end

    test ":refresh without :base/:company is a no-op" do
      state = Chat.init(messages: sample_messages())
      {state, []} = Chat.update(:refresh, state)
      assert state.messages == sample_messages()
    end

    test "unmapped msg → :noreply" do
      assert Chat.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "header line shows the active channel name" do
      state = Chat.init(messages: [], channel: "incidents")
      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "#incidents"))
    end

    test "empty list renders the per-channel empty-state placeholder" do
      state = Chat.init(messages: [], channel: "general")
      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "No messages in #general."))
    end

    test "non-empty renders one line per message; multi-line bodies collapsed to first line" do
      state = Chat.init(messages: sample_messages())
      rendered = render_to_strings(Chat.view(state))

      assert Enum.any?(
               rendered,
               &String.contains?(&1, "> [2026-04-26T10:00] director: Hello, team.")
             )

      # engineer's body spans two lines; only the first should appear.
      assert Enum.any?(
               rendered,
               &String.contains?(&1, "  [2026-04-26T10:01] engineer: Working on it.")
             )

      refute Enum.any?(rendered, &String.contains?(&1, "More detail"))
      # Empty body renders cleanly with a trailing colon-space.
      assert Enum.any?(rendered, &String.contains?(&1, "  [2026-04-26T10:02] ceo: "))
    end

    test "cursor at index 1 prefixes the second message" do
      state = %{messages: sample_messages(), cursor: 1, channel: "general"}
      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  [2026-04-26T10:00] director"))
      assert Enum.any?(rendered, &String.contains?(&1, "> [2026-04-26T10:01] engineer"))
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
