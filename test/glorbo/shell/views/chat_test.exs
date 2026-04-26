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

  describe "Phase 3f-revisit — composer modal" do
    defp init_with_composer(opts \\ []) do
      action_calls = make_ref()
      Process.put({:post_calls, action_calls}, [])

      post_fn = fn co, ch, body, kw ->
        prior = Process.get({:post_calls, action_calls})
        Process.put({:post_calls, action_calls}, prior ++ [{co, ch, body, kw}])
        Keyword.get(opts, :post_result, :ok)
      end

      loader_fn = fn _b, _c, _ch -> Keyword.get(opts, :refreshed, sample_messages()) end

      state =
        Chat.init(
          messages: sample_messages(),
          channel: "general",
          company: "acme",
          base: "/tmp/glorbo",
          post_fn: post_fn,
          loader_fn: loader_fn
        )

      {state, fn -> Process.get({:post_calls, action_calls}) end}
    end

    test "`i` opens the composer modal" do
      assert Chat.event_to_msg(%Key{key: :char, char: "i"}, %{mode: :list}) ==
               {:msg, :compose_open}

      {state, _} = init_with_composer()
      {state, []} = Chat.update(:compose_open, state)
      assert state.mode == {:compose, ""}
    end

    test "compose mode routes Enter/Esc/backspace/chars to prompt actions" do
      state = %{mode: {:compose, "abc"}}

      assert Chat.event_to_msg(%Key{key: :enter}, state) == {:msg, :compose_submit}
      assert Chat.event_to_msg(%Key{key: :escape}, state) == {:msg, :compose_cancel}
      assert Chat.event_to_msg(%Key{key: :backspace}, state) == {:msg, :compose_backspace}

      assert Chat.event_to_msg(%Key{key: :char, char: "x"}, state) ==
               {:msg, {:compose_input, "x"}}

      # `j`/`k` are valid input chars while composing — they go into the
      # buffer rather than moving the cursor. Non-char nav keys (arrows)
      # are absorbed silently.
      assert Chat.event_to_msg(%Key{key: :char, char: "j"}, state) ==
               {:msg, {:compose_input, "j"}}

      assert Chat.event_to_msg(%Key{key: :down}, state) == :ignore
    end

    test "typing accumulates into the buffer; backspace drops the last char" do
      {state, _calls} = init_with_composer()
      {state, []} = Chat.update(:compose_open, state)
      {state, []} = Chat.update({:compose_input, "h"}, state)
      {state, []} = Chat.update({:compose_input, "i"}, state)
      assert state.mode == {:compose, "hi"}

      {state, []} = Chat.update(:compose_backspace, state)
      assert state.mode == {:compose, "h"}

      # Backspace on empty buffer is a no-op.
      state = %{state | mode: {:compose, ""}}
      {state, []} = Chat.update(:compose_backspace, state)
      assert state.mode == {:compose, ""}
    end

    test "Enter on non-empty buffer calls post_fn and refreshes messages" do
      {state, calls} = init_with_composer(refreshed: [hd(sample_messages())])
      state = %{state | mode: {:compose, "Hello world"}}

      {state, []} = Chat.update(:compose_submit, state)

      assert calls.() == [
               {"acme", "general", "Hello world", [base: "/tmp/glorbo"]}
             ]

      assert state.last_action == {:ok, :post, nil}
      assert state.mode == :list
      assert length(state.messages) == 1
    end

    test "Enter on empty buffer is a silent cancel (no post_fn call)" do
      {state, calls} = init_with_composer()
      state = %{state | mode: {:compose, ""}}

      {state, []} = Chat.update(:compose_submit, state)

      assert calls.() == []
      assert state.mode == :list
      # No last_action — silent cancel.
      assert state.last_action == nil
    end

    test "Esc cancels without calling post_fn" do
      {state, calls} = init_with_composer()
      state = %{state | mode: {:compose, "draft"}}

      {state, []} = Chat.update(:compose_cancel, state)

      assert calls.() == []
      assert state.mode == :list
    end

    test "post_fn returning {:error, reason} surfaces in last_action and skips refresh" do
      {state, _calls} = init_with_composer(post_result: {:error, :enoent})
      state = %{state | mode: {:compose, "test"}}

      {state, []} = Chat.update(:compose_submit, state)

      assert state.last_action == {:error, :post, :enoent}
      assert state.mode == :list
      # Messages unchanged (no refresh on error).
      assert state.messages == sample_messages()
    end

    test "post without :company / :base records :no_company error" do
      state = Chat.init(messages: [], channel: "general")
      state = %{state | mode: {:compose, "x"}}

      {state, []} = Chat.update(:compose_submit, state)

      assert state.last_action == {:error, :post, :no_company}
      assert state.mode == :list
    end

    test "view in compose mode appends the composer overlay" do
      state = %{
        messages: [],
        channel: "general",
        cursor: 0,
        mode: {:compose, "draft text"},
        last_action: nil
      }

      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "Compose (Enter to send"))
      assert Enum.any?(rendered, &String.contains?(&1, "> draft text_"))
    end

    test "view appends `✓ posted` after a successful post" do
      state = %{
        messages: sample_messages(),
        channel: "general",
        cursor: 0,
        mode: :list,
        last_action: {:ok, :post, nil}
      }

      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "✓ posted"))
    end

    test "view appends `✗ post failed` after a failed post" do
      state = %{
        messages: [],
        channel: "general",
        cursor: 0,
        mode: :list,
        last_action: {:error, :post, :enoent}
      }

      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "✗ post failed"))
      assert Enum.any?(rendered, &String.contains?(&1, ":enoent"))
    end
  end

  describe "Phase 3f-revisit-2 — channel switcher modal" do
    defp init_with_switcher(channels, opts \\ []) do
      list_channels_fn = fn _b, _c -> channels end

      loader_calls = make_ref()
      Process.put({:load_calls, loader_calls}, [])

      loader_fn = fn _b, _c, ch ->
        prior = Process.get({:load_calls, loader_calls})
        Process.put({:load_calls, loader_calls}, prior ++ [ch])
        Keyword.get(opts, :messages, sample_messages())
      end

      state =
        Chat.init(
          messages: sample_messages(),
          channel: "general",
          base: "/tmp/glorbo",
          company: "acme",
          list_channels_fn: list_channels_fn,
          loader_fn: loader_fn
        )

      {state, fn -> Process.get({:load_calls, loader_calls}) end}
    end

    test "`s` opens the switcher modal and loads channels with cursor on current" do
      assert Chat.event_to_msg(%Key{key: :char, char: "s"}, %{mode: :list}) ==
               {:msg, :switch_open}

      {state, _calls} = init_with_switcher(["alerts", "general", "incidents"])
      {state, []} = Chat.update(:switch_open, state)
      assert {:switch, %{channels: ["alerts", "general", "incidents"], cursor: 1}} = state.mode
    end

    test "switch mode routes j/k/arrows/Enter/Esc; absorbs everything else" do
      state = %{mode: {:switch, %{channels: ["a", "b"], cursor: 0}}}

      assert Chat.event_to_msg(%Key{key: :down}, state) == {:msg, :switch_cursor_down}
      assert Chat.event_to_msg(%Key{key: :up}, state) == {:msg, :switch_cursor_up}
      assert Chat.event_to_msg(%Key{key: :char, char: "j"}, state) == {:msg, :switch_cursor_down}
      assert Chat.event_to_msg(%Key{key: :char, char: "k"}, state) == {:msg, :switch_cursor_up}
      assert Chat.event_to_msg(%Key{key: :enter}, state) == {:msg, :switch_select}
      assert Chat.event_to_msg(%Key{key: :escape}, state) == {:msg, :switch_cancel}

      # Random keys absorbed (no leak into list-mode handler).
      assert Chat.event_to_msg(%Key{key: :char, char: "x"}, state) == :ignore
      assert Chat.event_to_msg(%Key{key: :char, char: "i"}, state) == :ignore
    end

    test ":switch_cursor_down/up clamp at list boundaries" do
      state = %{mode: {:switch, %{channels: ["a", "b", "c"], cursor: 2}}}
      {state, []} = Chat.update(:switch_cursor_down, state)
      assert {:switch, %{cursor: 2}} = state.mode

      state = %{mode: {:switch, %{channels: ["a", "b", "c"], cursor: 0}}}
      {state, []} = Chat.update(:switch_cursor_up, state)
      assert {:switch, %{cursor: 0}} = state.mode
    end

    test ":switch_select sets channel, reloads via loader_fn, exits modal" do
      {state, calls} = init_with_switcher(["alerts", "general", "incidents"])
      {state, []} = Chat.update(:switch_open, state)
      # Move cursor to "incidents".
      {state, []} = Chat.update(:switch_cursor_down, state)
      {state, []} = Chat.update(:switch_cursor_down, state)
      {state, []} = Chat.update(:switch_select, state)

      assert state.channel == "incidents"
      assert state.mode == :list
      assert state.cursor == 0
      # init's auto-load saw "general"; switch_select reloaded "incidents".
      assert calls.() == ["incidents"]
    end

    test ":switch_cancel exits without touching channel" do
      {state, calls} = init_with_switcher(["alerts", "general"])
      {state, []} = Chat.update(:switch_open, state)
      {state, []} = Chat.update(:switch_cursor_down, state)
      {state, []} = Chat.update(:switch_cancel, state)

      assert state.channel == "general"
      assert state.mode == :list
      # No load call happened on cancel.
      assert calls.() == []
    end

    test ":switch_open with no :base/:company is a no-op" do
      state = Chat.init(messages: sample_messages(), channel: "general")
      {state, []} = Chat.update(:switch_open, state)
      assert state.mode == :list
    end

    test ":switch_open with empty channel list still enters mode (Esc to leave)" do
      {state, _calls} = init_with_switcher([])
      {state, []} = Chat.update(:switch_open, state)
      assert {:switch, %{channels: [], cursor: 0}} = state.mode
    end

    test "view in switch mode renders the channel list with `>` on cursor row" do
      state = %{
        messages: sample_messages(),
        channel: "general",
        cursor: 0,
        mode: {:switch, %{channels: ["alerts", "general", "incidents"], cursor: 2}},
        last_action: nil
      }

      rendered = render_to_strings(Chat.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "Switch channel"))
      assert Enum.any?(rendered, &String.contains?(&1, "  #alerts"))
      assert Enum.any?(rendered, &String.contains?(&1, "  #general"))
      assert Enum.any?(rendered, &String.contains?(&1, "> #incidents"))
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
