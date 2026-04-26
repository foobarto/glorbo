defmodule Glorbo.Shell.Views.AgentsTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Agents
  alias TermUI.Event.Key

  defp sample_agents do
    [
      %{
        slug: "ceo",
        name: "CEO",
        role: "Strategist",
        provider: "ollama",
        model: "qwen3:8b",
        network: "outgoing",
        reports_to: nil
      },
      %{
        slug: "engineer",
        name: "engineer",
        role: "—",
        provider: "openai",
        model: "gpt-4o",
        network: "loopback",
        reports_to: "ceo"
      },
      %{
        slug: "minimal",
        name: "minimal",
        role: "—",
        provider: "—",
        model: "",
        network: "loopback",
        reports_to: nil
      }
    ]
  end

  describe "init/1" do
    test "with explicit :agents opt, sets list and cursor 0" do
      state = Agents.init(agents: sample_agents())
      assert length(state.agents) == 3
      assert state.cursor == 0
    end

    test "with :loader_fn opt, calls it for the list" do
      ref = make_ref()
      Process.put({:fn_called, ref}, false)

      loader_fn = fn _base, _co ->
        Process.put({:fn_called, ref}, true)
        sample_agents()
      end

      state = Agents.init(base: "/tmp/glorbo-base", company: "acme", loader_fn: loader_fn)
      assert Process.get({:fn_called, ref}) == true
      assert length(state.agents) == 3
    end

    test "no opts → empty list" do
      state = Agents.init([])
      assert state.agents == []
    end
  end

  describe "event_to_msg/2" do
    test "j/k + arrows → cursor down/up" do
      assert Agents.event_to_msg(%Key{key: :down}, %{}) == {:msg, :cursor_down}
      assert Agents.event_to_msg(%Key{key: :up}, %{}) == {:msg, :cursor_up}
      assert Agents.event_to_msg(%Key{key: :char, char: "j"}, %{}) == {:msg, :cursor_down}
      assert Agents.event_to_msg(%Key{key: :char, char: "k"}, %{}) == {:msg, :cursor_up}
    end

    test "r → :refresh, q → :quit" do
      assert Agents.event_to_msg(%Key{key: :char, char: "r"}, %{}) == {:msg, :refresh}
      assert Agents.event_to_msg(%Key{key: :char, char: "q"}, %{}) == {:msg, :quit}
    end

    test "unmapped → :ignore" do
      assert Agents.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    test ":cursor_down clamps at last row" do
      state = %{
        agents: sample_agents(),
        cursor: 2,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Agents.update(:cursor_down, state)
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      state = %{
        agents: sample_agents(),
        cursor: 0,
        base: nil,
        company: nil,
        loader_fn: fn _, _ -> [] end
      }

      {state, []} = Agents.update(:cursor_up, state)
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn and reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        if n == 0, do: sample_agents(), else: Enum.take(sample_agents(), 1)
      end

      state = Agents.init(base: "/tmp", company: "acme", loader_fn: loader_fn)
      state = %{state | cursor: 2}

      {state, []} = Agents.update(:refresh, state)
      assert length(state.agents) == 1
      assert state.cursor == 0
    end

    test ":refresh without :base/:company is a no-op" do
      state = Agents.init(agents: sample_agents())
      {state, []} = Agents.update(:refresh, state)
      assert state.agents == sample_agents()
    end

    test "unmapped msg → :noreply" do
      assert Agents.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty state renders the bootstrap-hint placeholder" do
      view = Agents.view(%{agents: [], cursor: 0})
      assert %TermUI.Component.RenderNode{type: :text, content: content} = view
      assert content == "No agents yet — `glorbo new agent <slug>` to scaffold one."
    end

    test "non-empty renders provider/model joined; missing model omitted" do
      state = Agents.init(agents: sample_agents())
      rendered = render_to_strings(Agents.view(state))

      assert Enum.any?(
               rendered,
               &String.contains?(&1, "> ceo [Strategist] ollama/qwen3:8b · outgoing")
             )

      assert Enum.any?(
               rendered,
               &String.contains?(&1, "  engineer [—] openai/gpt-4o · loopback → ceo")
             )

      # `minimal` has empty model + provider="—" → just `—` (no slash).
      assert Enum.any?(rendered, &String.contains?(&1, "  minimal [—] — · loopback"))
    end

    test "reports_to is appended only when set" do
      state = Agents.init(agents: sample_agents())
      rendered = render_to_strings(Agents.view(state))

      ceo_line = Enum.find(rendered, &String.starts_with?(&1, "> ceo "))
      engineer_line = Enum.find(rendered, &String.starts_with?(&1, "  engineer "))

      # ceo has no reports_to → no `→` in its line.
      refute String.contains?(ceo_line, "→")
      # engineer reports_to ceo → trailing `→ ceo`.
      assert String.contains?(engineer_line, "→ ceo")
    end

    test "cursor at index 1 prefixes the second row" do
      state = %{agents: sample_agents(), cursor: 1}
      rendered = render_to_strings(Agents.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  ceo"))
      assert Enum.any?(rendered, &String.contains?(&1, "> engineer"))
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
