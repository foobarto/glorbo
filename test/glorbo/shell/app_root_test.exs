defmodule Glorbo.Shell.AppRootTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.AppRoot
  alias TermUI.Event.Key

  defp init_state(opts \\ []) do
    AppRoot.init(Keyword.merge([approvals: []], opts))
  end

  describe "init/1" do
    test "starts in :idle chord, :approvals view, with Inbox sub-state, help closed" do
      state = init_state()
      assert state.chord == :idle
      assert state.view == :approvals
      assert state.chord_hint == nil
      assert state.help_open == false
      assert is_map(state.sub_state)
      assert state.sub_state.approvals == []
    end

    test "forwards opts to the initial sub-view's init/1" do
      sample = [%{task_id: "t-1", task_path: "x", title: "X", assignee: "ceo"}]
      state = init_state(approvals: sample)
      assert state.sub_state.approvals == sample
    end

    test "respects :initial_view opt to start in a non-default view" do
      checks = [%{name: "ok", pass: true, detail: "fine", severity: :blocker}]

      state =
        AppRoot.init(
          initial_view: :health,
          checks_fn: fn -> checks end
        )

      assert state.view == :health
      assert state.sub_state.checks == checks
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

    test "{:chord_select, \"h\"} routes to :health (Phase 3b)" do
      checks = [%{name: "x", pass: true, detail: "ok", severity: :blocker}]

      # Inject a checks_fn into init opts that flows through to the
      # health view's init when the chord swap fires.
      state = AppRoot.init(approvals: [], checks_fn: fn -> checks end)
      state = %{state | chord: :c_c}

      {state, []} = AppRoot.update({:chord_select, "h"}, state)
      assert state.chord == :idle
      assert state.view == :health
      assert state.chord_hint == nil
      # AppRoot bootstrapped a fresh Health sub_state — no checks
      # carry forward through the swap (Health init re-reads).
      assert is_map(state.sub_state)
      assert Map.has_key?(state.sub_state, :checks)
    end

    test "{:chord_select, \"o\"} routes to :overview (Phase 3c)" do
      state = AppRoot.init(approvals: [], companies: [])
      state = %{state | chord: :c_c}

      {state, []} = AppRoot.update({:chord_select, "o"}, state)
      assert state.chord == :idle
      assert state.view == :overview
      assert state.chord_hint == nil
    end

    test "{:chord_select, \"t\"} routes to :tasks (Phase 3g — last D10 letter)" do
      state = AppRoot.init(approvals: [], rows: [])
      state = %{state | chord: :c_c}

      {state, []} = AppRoot.update({:chord_select, "t"}, state)
      assert state.chord == :idle
      assert state.view == :tasks
      assert state.chord_hint == nil
    end

    test "view swap forwards :base + :company opts to the new view's init" do
      state =
        AppRoot.init(
          approvals: [],
          base: "/tmp/glorbo-base",
          company: "acme",
          checks_fn: fn -> [] end
        )

      state = %{state | chord: :c_c}
      {state, []} = AppRoot.update({:chord_select, "h"}, state)

      # Health's init/1 doesn't need :base/:company yet but the
      # forwarding layer must still pass them through without
      # crashing. State should carry forward via Inbox.sub_state's
      # :base + :company.
      assert state.view == :health
      # No assertion on Health's state contents — the contract is
      # that the forward_opts didn't crash + the sub_state is a map.
      assert is_map(state.sub_state)
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
    test "no chord active → renders the active view body + idle discovery footer" do
      state = init_state()
      rendered = render_to_strings(AppRoot.view(state))
      # Body still carries the Inbox empty-state placeholder.
      assert Enum.any?(rendered, &String.contains?(&1, "Inbox empty"))
      # Plus a one-line footer pointing at the help overlay + chord prefix.
      assert Enum.any?(rendered, &String.contains?(&1, "? help"))
      assert Enum.any?(rendered, &String.contains?(&1, "C-c o/t/a/c/p/h/u"))
    end

    test ":c_c chord active → appends the chord-hint footer (idle footer suppressed)" do
      state = %{init_state() | chord: :c_c}
      rendered = render_to_strings(AppRoot.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "(C-c …)"))
      assert Enum.any?(rendered, &String.contains?(&1, "o/t/a/c/p/h/u"))
      # Idle footer is suppressed while the chord is active to avoid
      # visual noise.
      refute Enum.any?(rendered, &String.contains?(&1, "? help"))
    end

    test "chord_hint set → appended as a `[chord]` line (idle footer suppressed)" do
      state = %{init_state() | chord_hint: "unknown chord: C-c z"}
      rendered = render_to_strings(AppRoot.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "[chord] unknown chord: C-c z"))
      refute Enum.any?(rendered, &String.contains?(&1, "? help"))
    end
  end

  describe "Phase 3a-revisit — help overlay" do
    test "`?` in idle mode opens the help overlay" do
      assert AppRoot.event_to_msg(%Key{key: :char, char: "?"}, %{chord: :idle, help_open: false}) ==
               {:msg, :help_open}
    end

    test "Esc and `?` while help is open both close it" do
      open = %{help_open: true}
      assert AppRoot.event_to_msg(%Key{key: :escape}, open) == {:msg, :help_close}
      assert AppRoot.event_to_msg(%Key{key: :char, char: "?"}, open) == {:msg, :help_close}
    end

    test "all other keys are absorbed while help is open (no leak to view or chord)" do
      open = %{help_open: true}
      assert AppRoot.event_to_msg(%Key{key: :char, char: "j"}, open) == :ignore
      assert AppRoot.event_to_msg(%Key{key: :down}, open) == :ignore

      assert AppRoot.event_to_msg(%Key{key: :char, char: "c", modifiers: [:ctrl]}, open) ==
               :ignore
    end

    test ":help_open / :help_close flip the boolean" do
      state = init_state()
      {state, []} = AppRoot.update(:help_open, state)
      assert state.help_open == true

      {state, []} = AppRoot.update(:help_close, state)
      assert state.help_open == false
    end

    test "view in help mode renders the keymap reference (not the active sub-view)" do
      state = %{init_state() | help_open: true}
      rendered = render_to_strings(AppRoot.view(state))

      assert Enum.any?(rendered, &String.contains?(&1, "Glorbo Shell — Help"))
      assert Enum.any?(rendered, &String.contains?(&1, "C-c o   Overview"))
      assert Enum.any?(rendered, &String.contains?(&1, "C-c u   aUdit"))
      # List-nav primer.
      assert Enum.any?(rendered, &String.contains?(&1, "j / ↓"))
      # Per-view bindings exposed.
      assert Enum.any?(rendered, &String.contains?(&1, "i       open composer"))
      assert Enum.any?(rendered, &String.contains?(&1, "p       previous month"))
      # Inbox empty-state placeholder is NOT rendered while help is open.
      refute Enum.any?(rendered, &String.contains?(&1, "Inbox empty"))
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

  defp render_to_strings(other) when is_list(other),
    do: Enum.flat_map(other, &render_to_strings/1)

  defp render_to_strings(_), do: []
end
