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

    test "with :loader_fn opt, calls it with current month for the list" do
      ref = make_ref()
      Process.put({:fn_called, ref}, nil)

      loader_fn = fn _b, _c, ym ->
        Process.put({:fn_called, ref}, ym)
        sample_entries()
      end

      list_months_fn = fn _b, _c -> ["2026-04", "2026-03"] end

      state =
        Audit.init(
          base: "/tmp/glorbo",
          company: "acme",
          loader_fn: loader_fn,
          list_months_fn: list_months_fn
        )

      # Latest month from list_months_fn is what loader_fn sees.
      assert Process.get({:fn_called, ref}) == "2026-04"
      assert state.year_month == "2026-04"
      assert state.available_months == ["2026-04", "2026-03"]
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

    test "p → :prev_month, n → :next_month" do
      assert Audit.event_to_msg(%Key{key: :char, char: "p"}, %{}) == {:msg, :prev_month}
      assert Audit.event_to_msg(%Key{key: :char, char: "n"}, %{}) == {:msg, :next_month}
    end

    test "unmapped → :ignore" do
      assert Audit.event_to_msg(%Key{key: :char, char: "x"}, %{}) == :ignore
    end
  end

  describe "update/2" do
    defp seed_state(opts) do
      %{
        entries: Keyword.get(opts, :entries, sample_entries()),
        cursor: Keyword.get(opts, :cursor, 0),
        year_month: Keyword.get(opts, :year_month, "2026-04"),
        available_months: Keyword.get(opts, :months, ["2026-04", "2026-03", "2026-02"]),
        base: Keyword.get(opts, :base),
        company: Keyword.get(opts, :company),
        loader_fn: Keyword.get(opts, :loader_fn, fn _, _, _ -> [] end),
        list_months_fn: Keyword.get(opts, :list_months_fn, fn _, _ -> ["2026-04"] end)
      }
    end

    test ":cursor_down clamps at last row" do
      {state, []} = Audit.update(:cursor_down, seed_state(cursor: 2))
      assert state.cursor == 2
    end

    test ":cursor_up clamps at 0" do
      {state, []} = Audit.update(:cursor_up, seed_state(cursor: 0))
      assert state.cursor == 0
    end

    test ":refresh re-runs loader_fn for the active month + reclamps cursor" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, [])

      loader_fn = fn _b, _c, ym ->
        prior = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, prior ++ [ym])
        Enum.take(sample_entries(), 1)
      end

      state =
        seed_state(
          cursor: 2,
          base: "/tmp",
          company: "acme",
          loader_fn: loader_fn,
          list_months_fn: fn _, _ -> ["2026-04", "2026-03"] end
        )

      {state, []} = Audit.update(:refresh, state)
      assert length(state.entries) == 1
      assert state.cursor == 0
      assert Process.get({:fn_calls, ref}) == ["2026-04"]
    end

    test ":refresh without :base/:company is a no-op" do
      state = Audit.init(entries: sample_entries())
      {state, []} = Audit.update(:refresh, state)
      assert state.entries == sample_entries()
    end

    test ":prev_month moves to the next-older bucket and reloads" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, [])

      loader_fn = fn _b, _c, ym ->
        prior = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, prior ++ [ym])

        case ym do
          "2026-03" -> [hd(sample_entries())]
          _ -> sample_entries()
        end
      end

      state =
        seed_state(
          cursor: 2,
          base: "/tmp",
          company: "acme",
          year_month: "2026-04",
          months: ["2026-04", "2026-03", "2026-02"],
          loader_fn: loader_fn
        )

      {state, []} = Audit.update(:prev_month, state)

      assert state.year_month == "2026-03"
      assert length(state.entries) == 1
      assert state.cursor == 0
      assert Process.get({:fn_calls, ref}) == ["2026-03"]
    end

    test ":next_month moves to the next-newer bucket and reloads" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, [])

      loader_fn = fn _b, _c, ym ->
        prior = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, prior ++ [ym])
        sample_entries()
      end

      state =
        seed_state(
          base: "/tmp",
          company: "acme",
          year_month: "2026-03",
          months: ["2026-04", "2026-03"],
          loader_fn: loader_fn
        )

      {state, []} = Audit.update(:next_month, state)

      assert state.year_month == "2026-04"
      assert Process.get({:fn_calls, ref}) == ["2026-04"]
    end

    test ":prev_month at the oldest bucket is a no-op (doesn't reload)" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c, _ym ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        []
      end

      state =
        seed_state(
          base: "/tmp",
          company: "acme",
          year_month: "2026-02",
          months: ["2026-04", "2026-03", "2026-02"],
          loader_fn: loader_fn
        )

      {state, []} = Audit.update(:prev_month, state)

      assert state.year_month == "2026-02"
      assert Process.get({:fn_calls, ref}) == 0
    end

    test ":next_month at the newest bucket is a no-op" do
      ref = make_ref()
      Process.put({:fn_calls, ref}, 0)

      loader_fn = fn _b, _c, _ym ->
        n = Process.get({:fn_calls, ref})
        Process.put({:fn_calls, ref}, n + 1)
        []
      end

      state =
        seed_state(
          base: "/tmp",
          company: "acme",
          year_month: "2026-04",
          months: ["2026-04", "2026-03"],
          loader_fn: loader_fn
        )

      {state, []} = Audit.update(:next_month, state)

      assert state.year_month == "2026-04"
      assert Process.get({:fn_calls, ref}) == 0
    end

    test "unmapped msg → :noreply" do
      assert Audit.update(:bogus, %{}) == :noreply
    end
  end

  describe "view/1" do
    test "empty list renders an empty-state placeholder naming the month" do
      state = %{
        entries: [],
        cursor: 0,
        year_month: "2026-04",
        available_months: ["2026-04"]
      }

      rendered = render_to_strings(Audit.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "Audit — 2026-04"))
      assert Enum.any?(rendered, &String.contains?(&1, "No audit entries for 2026-04."))
    end

    test "header line shows older/newer hints when more pages exist" do
      state = %{
        entries: sample_entries(),
        cursor: 0,
        year_month: "2026-03",
        available_months: ["2026-04", "2026-03", "2026-02"]
      }

      rendered = render_to_strings(Audit.view(state))
      # Middle bucket: both directions available.
      header = Enum.find(rendered, &String.contains?(&1, "Audit — 2026-03"))
      assert String.contains?(header, "(p older)")
      assert String.contains?(header, "(n newer)")
    end

    test "header line omits hints at the bucket boundaries" do
      latest = %{
        entries: sample_entries(),
        cursor: 0,
        year_month: "2026-04",
        available_months: ["2026-04", "2026-03"]
      }

      rendered = render_to_strings(Audit.view(latest))
      header = Enum.find(rendered, &String.contains?(&1, "Audit — 2026-04"))
      assert String.contains?(header, "(p older)")
      refute String.contains?(header, "(n newer)")

      oldest = %{
        entries: sample_entries(),
        cursor: 0,
        year_month: "2026-03",
        available_months: ["2026-04", "2026-03"]
      }

      rendered = render_to_strings(Audit.view(oldest))
      header = Enum.find(rendered, &String.contains?(&1, "Audit — 2026-03"))
      refute String.contains?(header, "(p older)")
      assert String.contains?(header, "(n newer)")
    end

    test "non-empty renders [ts] actor action target with ts trimmed to 16 chars" do
      state = %{
        entries: sample_entries(),
        cursor: 0,
        year_month: "2026-04",
        available_months: ["2026-04"]
      }

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
      state = %{
        entries: sample_entries(),
        cursor: 1,
        year_month: "2026-04",
        available_months: ["2026-04"]
      }

      rendered = render_to_strings(Audit.view(state))
      assert Enum.any?(rendered, &String.contains?(&1, "  [2026-04-26T10:00] ceo"))
      assert Enum.any?(rendered, &String.contains?(&1, "> [2026-04-26T10:01] engineer"))
    end

    test "ts shorter than 16 chars renders as-is" do
      state = %{
        entries: [%{ts: "short", actor: "ceo", action: "x", target: ""}],
        cursor: 0,
        year_month: "2026-04",
        available_months: ["2026-04"]
      }

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
