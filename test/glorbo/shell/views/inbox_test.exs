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
      state = Inbox.init([])
      assert state.approvals == []
      assert state.cursor == 0
      assert state.company == nil
      assert state.base == nil
      assert state.last_action == nil
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

    test "a → :approve, d → :deny (Phase 2b)" do
      assert Inbox.event_to_msg(%Key{key: :char, char: "a"}, %{}) == {:msg, :approve}
      assert Inbox.event_to_msg(%Key{key: :char, char: "d"}, %{}) == {:msg, :deny}
    end

    test "unmapped key → :ignore" do
      assert Inbox.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "Phase 2b — :approve / :deny actions" do
    defp init_with_actions(approvals, opts \\ []) do
      action_calls = make_ref()
      Process.put({:action_calls, action_calls}, [])

      approve_fn = fn co, tp, decision, kw ->
        prior = Process.get({:action_calls, action_calls})
        Process.put({:action_calls, action_calls}, prior ++ [{co, tp, decision, kw}])
        Keyword.get(opts, :approve_result, :ok)
      end

      loader_fn = fn _base, _company -> Keyword.get(opts, :refreshed, []) end

      state =
        Inbox.init(
          approvals: approvals,
          company: "acme",
          base: "/tmp/glorbo_test_base",
          approve_fn: approve_fn,
          loader_fn: loader_fn
        )

      {state, fn -> Process.get({:action_calls, action_calls}) end}
    end

    test ":approve calls set_approval(:approved) and refreshes the list" do
      {state, calls} = init_with_actions(sample_approvals(), refreshed: [])

      {state, []} = Inbox.update(:approve, state)

      assert calls.() == [
               {"acme", "projects/demo/tasks/task-a.md", :approved,
                [base: "/tmp/glorbo_test_base", actor: "director"]}
             ]

      assert state.approvals == []
      assert state.last_action == {:ok, :approved, nil}
    end

    test ":deny opens the deny-reason prompt; Enter submits with the buffer as denial_reason" do
      {state, calls} = init_with_actions(sample_approvals(), refreshed: [])

      # Step 1 — :deny enters prompt mode, no API call yet.
      {state, []} = Inbox.update(:deny, state)
      assert state.mode == {:deny_prompt, ""}
      assert calls.() == []

      # Step 2 — type "out of scope" via :deny_prompt_input msgs.
      {state, []} = Inbox.update({:deny_prompt_input, "o"}, state)
      {state, []} = Inbox.update({:deny_prompt_input, "u"}, state)
      {state, []} = Inbox.update({:deny_prompt_input, "t"}, state)
      assert state.mode == {:deny_prompt, "out"}

      # Step 3 — Enter submits set_approval with denial_reason: "out".
      {state, []} = Inbox.update(:deny_prompt_submit, state)

      [{co, tp, decision, opts}] = calls.()
      assert co == "acme"
      assert tp == "projects/demo/tasks/task-a.md"
      assert decision == :denied
      assert Keyword.get(opts, :base) == "/tmp/glorbo_test_base"
      assert Keyword.get(opts, :actor) == "director"
      assert Keyword.get(opts, :denial_reason) == "out"

      assert state.last_action == {:ok, :denied, nil}
      assert state.mode == :list
    end

    test ":approve at cursor 1 targets the second row" do
      {state, calls} = init_with_actions(sample_approvals())
      state = %{state | cursor: 1}

      {_state, []} = Inbox.update(:approve, state)

      assert [{_, "projects/demo/tasks/task-b.md", :approved, _}] = calls.()
    end

    test ":approve on a sentinel-without-task row records :no_actionable_row" do
      {state, calls} = init_with_actions(sample_approvals())
      # Cursor at index 2 — task-c has task_path: nil
      state = %{state | cursor: 2}

      {state, []} = Inbox.update(:approve, state)

      assert calls.() == []
      assert state.last_action == {:error, :approved, :no_actionable_row}
    end

    test ":approve when set_approval returns {:error, reason}" do
      {state, _calls} = init_with_actions(sample_approvals(), approve_result: {:error, :enoent})

      {state, []} = Inbox.update(:approve, state)

      assert state.last_action == {:error, :approved, :enoent}
      # Approvals list is NOT refreshed on error.
      assert state.approvals == sample_approvals()
    end

    test ":approve on empty approvals list is a no-op" do
      {state, calls} = init_with_actions([])

      {state, []} = Inbox.update(:approve, state)

      assert calls.() == []
      assert state.last_action == {:error, :approved, :no_actionable_row}
    end

    test ":approve refreshes cursor to clamp within new bounds" do
      original = sample_approvals()
      shrunken = Enum.take(original, 1)
      {state, _calls} = init_with_actions(original, refreshed: shrunken)
      # Cursor at index 1 (task-b — has valid task_path); after refresh
      # the new list has only 1 row so the cursor must clamp to 0.
      state = %{state | cursor: 1}

      {state, []} = Inbox.update(:approve, state)

      assert state.approvals == shrunken
      assert state.cursor == 0
    end
  end

  describe "Phase 2c — deny-reason prompt modal" do
    test "Esc cancels the prompt without calling set_approval" do
      action_calls = make_ref()
      Process.put({:action_calls, action_calls}, [])

      approve_fn = fn co, tp, dec, kw ->
        Process.put({:action_calls, action_calls}, [{co, tp, dec, kw}])
        :ok
      end

      state =
        Inbox.init(
          approvals: sample_approvals(),
          company: "acme",
          base: "/tmp/glorbo_test_base",
          approve_fn: approve_fn,
          loader_fn: fn _, _ -> [] end
        )

      {state, []} = Inbox.update(:deny, state)
      {state, []} = Inbox.update({:deny_prompt_input, "x"}, state)
      assert state.mode == {:deny_prompt, "x"}

      {state, []} = Inbox.update(:deny_prompt_cancel, state)
      assert state.mode == :list
      assert Process.get({:action_calls, action_calls}) == []
      assert state.last_action == nil
    end

    test "backspace drops the last character of the buffer" do
      state = %{
        approvals: sample_approvals(),
        cursor: 0,
        mode: {:deny_prompt, "abc"},
        company: "acme",
        base: "/tmp",
        last_action: nil,
        approve_fn: fn _, _, _, _ -> :ok end,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Inbox.update(:deny_prompt_backspace, state)
      assert state.mode == {:deny_prompt, "ab"}
    end

    test "backspace on empty buffer is a no-op" do
      state = %{
        approvals: sample_approvals(),
        cursor: 0,
        mode: {:deny_prompt, ""},
        company: "acme",
        base: "/tmp",
        last_action: nil,
        approve_fn: fn _, _, _, _ -> :ok end,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Inbox.update(:deny_prompt_backspace, state)
      assert state.mode == {:deny_prompt, ""}
    end

    test "Enter on empty buffer submits with denial_reason: nil" do
      action_calls = make_ref()
      Process.put({:action_calls, action_calls}, [])

      approve_fn = fn co, tp, dec, kw ->
        Process.put({:action_calls, action_calls}, [{co, tp, dec, kw}])
        :ok
      end

      state =
        Inbox.init(
          approvals: sample_approvals(),
          company: "acme",
          base: "/tmp",
          approve_fn: approve_fn,
          loader_fn: fn _, _ -> [] end
        )
        |> Map.put(:mode, {:deny_prompt, ""})

      {state, []} = Inbox.update(:deny_prompt_submit, state)

      [{_, _, :denied, opts}] = Process.get({:action_calls, action_calls})
      refute Keyword.has_key?(opts, :denial_reason)
      assert state.mode == :list
    end

    test "event_to_msg in deny_prompt mode routes to prompt actions" do
      state = %{mode: {:deny_prompt, "abc"}}

      assert Inbox.event_to_msg(%Key{key: :enter}, state) == {:msg, :deny_prompt_submit}
      assert Inbox.event_to_msg(%Key{key: :escape}, state) == {:msg, :deny_prompt_cancel}
      assert Inbox.event_to_msg(%Key{key: :backspace}, state) == {:msg, :deny_prompt_backspace}

      assert Inbox.event_to_msg(%Key{key: :char, char: "x"}, state) ==
               {:msg, {:deny_prompt_input, "x"}}

      # Arrow keys are ignored — they don't leak to list-mode handlers.
      assert Inbox.event_to_msg(%Key{key: :up}, state) == :ignore
    end

    test "view/1 in deny_prompt mode appends the prompt overlay" do
      state =
        Inbox.init(approvals: sample_approvals())
        |> Map.put(:mode, {:deny_prompt, "out of scope"})

      rendered = render_to_strings(Inbox.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "Deny reason"))
      assert Enum.any?(rendered, &String.contains?(&1, "> out of scope_"))
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
