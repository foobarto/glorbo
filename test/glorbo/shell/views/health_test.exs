defmodule Glorbo.Shell.Views.HealthTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Health
  alias TermUI.Event.Key

  defp sample_checks do
    [
      %{name: "linux_kernel", pass: true, detail: "Linux 6.17", severity: :blocker},
      %{name: "bwrap", pass: true, detail: "bwrap 0.10.0", severity: :blocker},
      %{name: "pasta", pass: false, detail: "passt missing", severity: :warning}
    ]
  end

  describe "init/1" do
    test "with explicit :checks opt, sets list and cursor 0" do
      state = Health.init(checks: sample_checks())
      assert length(state.checks) == 3
      assert state.cursor == 0
    end

    test "with :checks_fn opt, calls it for the checks list" do
      ref = make_ref()
      Process.put({:fn_called, ref}, false)

      checks_fn = fn ->
        Process.put({:fn_called, ref}, true)
        sample_checks()
      end

      state = Health.init(checks_fn: checks_fn)
      assert Process.get({:fn_called, ref}) == true
      assert length(state.checks) == 3
    end

    test "no opts → calls Doctor.run_checks/0 (real-system path)" do
      # Sanity guard — Doctor.run_checks/0 returns a list and the
      # view doesn't crash on the real return shape. We don't assert
      # on the contents (host-dependent).
      state = Health.init([])
      assert is_list(state.checks)
      assert state.cursor == 0
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Health.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Health.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Health.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Health.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Health.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Health.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Health.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at the last row" do
      state = %{checks: sample_checks(), cursor: 2, checks_fn: fn -> [] end}
      {state, []} = Health.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      state = %{checks: sample_checks(), cursor: 0, checks_fn: fn -> [] end}
      {state, []} = Health.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs checks_fn and reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      checks_fn = fn ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        # 2nd call returns a shorter list to test reclamping.
        if n == 0, do: sample_checks(), else: Enum.take(sample_checks(), 1)
      end

      state = Health.init(checks_fn: checks_fn)
      state = %{state | cursor: 2}

      {state, []} = Health.update(:refresh, state)
      assert length(state.checks) == 1
      assert state.cursor == 0
      assert Process.get({:fn_calls, ref}) == 2
    end

    test "unmapped msg → :noreply" do
      assert Health.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty checks list renders the empty-state placeholder" do
      view = Health.view(%{checks: [], cursor: 0})
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content == "No health checks available."
    end

    test "non-empty renders one line per check with glyph + severity" do
      state = Health.init(checks: sample_checks())
      rendered = render_to_strings(Health.view(state))

      assert Enum.any?(
               rendered,
               &String.contains?(&1, "> ✓ [blocker] linux_kernel — Linux 6.17")
             )

      assert Enum.any?(rendered, &String.contains?(&1, "  ✓ [blocker] bwrap — bwrap 0.10.0"))
      assert Enum.any?(rendered, &String.contains?(&1, "  ✗ [warning] pasta — passt missing"))
    end

    test "cursor at index 1 prefixes the second row" do
      state = %{checks: sample_checks(), cursor: 1, checks_fn: fn -> [] end}
      rendered = render_to_strings(Health.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  ✓ [blocker] linux_kernel"))
      assert Enum.any?(rendered, &String.contains?(&1, "> ✓ [blocker] bwrap"))
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
