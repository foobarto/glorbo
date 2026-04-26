defmodule Glorbo.Shell.Views.OverviewTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Overview
  alias TermUI.Event.Key

  defp sample_companies do
    [
      %{slug: "acme", name: "Acme Co", agent_count: 3, alert_count: 0},
      %{slug: "beta", name: "Beta Labs", agent_count: 1, alert_count: 2},
      %{slug: "delta", name: "delta", agent_count: 0, alert_count: 0}
    ]
  end

  describe "init/1" do
    test "with explicit :companies opt, sets list and cursor 0" do
      state = Overview.init(companies: sample_companies())
      assert length(state.companies) == 3
      assert state.cursor == 0
    end

    test "cursor lands on the active-company row when present" do
      state = Overview.init(companies: sample_companies(), company: "beta")
      assert state.cursor == 1
      assert state.active_company == "beta"
    end

    test "cursor stays at 0 when active company isn't in the list" do
      state = Overview.init(companies: sample_companies(), company: "ghost")
      assert state.cursor == 0
      assert state.active_company == "ghost"
    end

    test "with no opts and no base, returns empty companies list" do
      state = Overview.init([])
      assert state.companies == []
      assert state.cursor == 0
    end

    test "with :loader_fn opt, calls it for the companies list" do
      ref = make_ref()
      Process.put({:fn_called, ref}, false)

      loader_fn = fn _base ->
        Process.put({:fn_called, ref}, true)
        sample_companies()
      end

      state = Overview.init(base: "/tmp/glorbo-base", loader_fn: loader_fn)
      assert Process.get({:fn_called, ref}) == true
      assert length(state.companies) == 3
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Overview.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Overview.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Overview.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Overview.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Overview.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Overview.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Overview.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at last row" do
      state = %{
        companies: sample_companies(),
        cursor: 2,
        active_company: nil,
        base: nil,
        loader_fn: fn _ -> [] end
      }

      {state, []} = Overview.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      state = %{
        companies: sample_companies(),
        cursor: 0,
        active_company: nil,
        base: nil,
        loader_fn: fn _ -> [] end
      }

      {state, []} = Overview.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn and reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _base ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        # Second call returns a shorter list.
        if n == 0, do: sample_companies(), else: Enum.take(sample_companies(), 1)
      end

      state = Overview.init(base: "/tmp/glorbo-base", loader_fn: loader_fn)
      state = %{state | cursor: 2}

      {state, []} = Overview.update(:refresh, state)
      assert length(state.companies) == 1
      assert state.cursor == 0
    end

    test ":refresh without :base is a no-op (test path with explicit companies)" do
      state = Overview.init(companies: sample_companies())
      {state, []} = Overview.update(:refresh, state)
      assert state.companies == sample_companies()
    end

    test "unmapped msg → :noreply" do
      assert Overview.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty list renders the bootstrap-hint placeholder" do
      view = Overview.view(%{companies: [], cursor: 0, active_company: nil})

      assert %TermUI.Component.RenderNode{type: :text, content: content} = view

      assert content ==
               "No companies yet — `glorbo new company <slug>` to bootstrap one."
    end

    test "non-empty renders one line per company with cursor + active glyphs" do
      state = Overview.init(companies: sample_companies(), company: "beta")
      rendered = render_to_strings(Overview.view(state))

      # acme is row 0; cursor is on row 1 (beta = active company).
      assert Enum.any?(rendered, &String.contains?(&1, "    acme (Acme Co) — 3 agents, 0 alerts"))

      assert Enum.any?(
               rendered,
               &String.contains?(&1, "> * beta (Beta Labs) — 1 agent, 2 alerts")
             )

      assert Enum.any?(rendered, &String.contains?(&1, "    delta (delta) — 0 agents, 0 alerts"))
    end

    test "active company gets the `*` glyph regardless of cursor row" do
      state = Overview.init(companies: sample_companies(), company: "delta")
      rendered = render_to_strings(Overview.view(state))

      # delta is row 2 — active + cursor both on it.
      assert Enum.any?(rendered, &String.contains?(&1, "> * delta"))
      # acme + beta have no active glyph.
      assert Enum.any?(rendered, &String.contains?(&1, "    acme"))
      assert Enum.any?(rendered, &String.contains?(&1, "    beta"))
    end

    test "Phase 3c-revisit: spend column rendered when spend_cents > 0" do
      companies = [
        %{slug: "acme", name: "Acme Co", agent_count: 3, alert_count: 0, spend_cents: 1801}
      ]

      state = Overview.init(companies: companies, company: "acme")
      [line | _] = render_to_strings(Overview.view(state))
      assert line == "> * acme (Acme Co) — 3 agents, 0 alerts, $18.01 spent"
    end

    test "Phase 3c-revisit: spend_cents=0 suppresses the spend column" do
      companies = [
        %{slug: "acme", name: "Acme", agent_count: 1, alert_count: 0, spend_cents: 0}
      ]

      state = Overview.init(companies: companies, company: "acme")
      [line | _] = render_to_strings(Overview.view(state))
      assert line == "> * acme (Acme) — 1 agent, 0 alerts"
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
