defmodule Glorbo.Shell.AppRootTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.AppRoot
  alias TermUI.Event.Key

  defp init_state(opts \\ []) do
    AppRoot.init(Keyword.merge([approvals: []], opts))
  end

  describe "init/1" do
    test "starts in :idle chord, :approvals view, with Inbox sub-state" do
      state = init_state()
      assert state.chord == :idle
      assert state.view == :approvals
      assert state.chord_hint == nil
      assert is_map(state.sub_state)
      assert state.sub_state.approvals == []
    end

    test "forwards opts to the initial sub-view's init/1" do
      sample = [%{task_id: "t-1", task_path: "x", title: "X", assignee: "ceo"}]
      state = init_state(approvals: sample)
      assert state.sub_state.approvals == sample
    end
  end

  describe "event_to_msg/2 — chord prefix" do
    test "Ctrl+c in :idle starts the C-c chord" do
      state = %{chord: :idle}

      assert AppRoot.event_to_msg(%Key{key: :char, char: "c", modifiers: [:ctrl]}, state) ==
               {:msg, :chord_start_c_c}
    end

    test "plain `c` in :idle is propagated (not absorbed)" do
      state = %{chord: :idle}

      assert AppRoot.event_to_msg(%Key{key: :char, char: "c", modifiers: []}, state) ==
               :propagate
    end

    test "single keystroke in :c_c mode → {:chord_select, ch}" do
      state = %{chord: :c_c}

      assert AppRoot.event_to_msg(%Key{key: :char, char: "p"}, state) ==
               {:msg, {:chord_select, "p"}}
    end

    test "Esc in :c_c mode cancels the chord" do
      state = %{chord: :c_c}
      assert AppRoot.event_to_msg(%Key{key: :escape}, state) == {:msg, :chord_cancel}
    end

    test "non-char/non-Esc keys in :c_c mode also cancel (Emacs convention)" do
      state = %{chord: :c_c}
      assert AppRoot.event_to_msg(%Key{key: :backspace}, state) == {:msg, :chord_cancel}
    end

    test "non-Ctrl+c events in :idle propagate to active view" do
      state = %{chord: :idle}
      assert AppRoot.event_to_msg(%Key{key: :down}, state) == :propagate
      assert AppRoot.event_to_msg(%Key{key: :char, char: "a"}, state) == :propagate
    end
  end

  describe "update/2 — chord lifecycle" do
    test ":chord_start_c_c flips chord to :c_c and clears hint" do
      state = %{init_state() | chord_hint: "old hint"}
      {state, []} = AppRoot.update(:chord_start_c_c, state)
      assert state.chord == :c_c
      assert state.chord_hint == nil
    end

    test ":chord_cancel returns to :idle and clears hint" do
      state = %{init_state() | chord: :c_c, chord_hint: "x"}
      {state, []} = AppRoot.update(:chord_cancel, state)
      assert state.chord == :idle
      assert state.chord_hint == nil
    end

    test "{:chord_select, \"p\"} routes to :approvals (the only Phase 3a view)" do
      state = %{init_state() | chord: :c_c}
      {state, []} = AppRoot.update({:chord_select, "p"}, state)
      assert state.chord == :idle
      assert state.view == :approvals
      assert state.chord_hint == nil
    end

    test "{:chord_select, <unknown>} surfaces an `unknown chord` hint" do
      state = %{init_state() | chord: :c_c}
      {state, []} = AppRoot.update({:chord_select, "z"}, state)
      assert state.chord == :idle
      assert state.chord_hint == "unknown chord: C-c z"
    end

    test "{:chord_select, <not-yet-implemented>} surfaces a Phase 3b+ hint" do
      state = %{init_state() | chord: :c_c}
      {state, []} = AppRoot.update({:chord_select, "h"}, state)
      assert state.chord == :idle
      assert state.chord_hint =~ "Phase 3b+"
      assert state.chord_hint =~ "health"
      # The :approvals view stays selected — failed switch is a no-op.
      assert state.view == :approvals
    end
  end

  describe "update/2 — sub-view delegation" do
    test "non-chord messages delegate to the active view's update" do
      sample = [%{task_id: "t-1", task_path: "x", title: "X", assignee: "ceo"}]
      state = init_state(approvals: sample)
      # :cursor_down is an Inbox message; AppRoot delegates it.
      {state, []} = AppRoot.update(:cursor_down, state)
      # Single-row list, cursor stays at 0 (clamped) but the call must
      # not crash — and the sub_state must be the updated one.
      assert state.sub_state.cursor == 0
    end

    test "delegated :noreply propagates back" do
      state = init_state()
      assert AppRoot.update(:bogus_phase_3a_unknown, state) == :noreply
    end
  end

  describe "view/1" do
    test "no chord active → renders the active view's body unchanged" do
      state = init_state()
      view = AppRoot.view(state)
      # Body is the Inbox empty-state placeholder.
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content =~ "Inbox empty"
    end

    test ":c_c chord active → appends the chord-hint footer" do
      state = %{init_state() | chord: :c_c}
      rendered = render_to_strings(AppRoot.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "(C-c …)"))
      assert Enum.any?(rendered, &String.contains?(&1, "o/t/a/c/p/h/u"))
    end

    test "chord_hint set → appended as a `[chord]` line" do
      state = %{init_state() | chord_hint: "unknown chord: C-c z"}
      rendered = render_to_strings(AppRoot.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "[chord] unknown chord: C-c z"))
    end
  end

  defp render_to_strings(%TermUI.Component.RenderNode{type: :text, content: content}),
    do: [content]

  defp render_to_strings(%TermUI.Component.RenderNode{children: children})
       when is_list(children) do
    Enum.flat_map(children, &render_to_strings/1)
  end

  defp render_to_strings(%TermUI.Component.RenderNode{}), do: []
  defp render_to_strings({:text, content}), do: [content]
  defp render_to_strings(other) when is_list(other), do: Enum.flat_map(other, &render_to_strings/1)
  defp render_to_strings(_), do: []
end
