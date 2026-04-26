defmodule Glorbo.Shell.Views.Tasks do
  @moduledoc """
  GEP-37 Phase 3g — read-only TUI Tasks view (kanban-style).

  Renders all tasks across all projects, grouped into the
  four canonical lanes (TODO / IN PROGRESS / REVIEW / DONE)
  + a fifth `OTHER` catch-all. Each lane gets a header line
  `▾ <LANE> (<count>)` followed by one indented row per
  task: `<task_id> — <title> [<assignee>]`.

  Cursor navigates the *flat* sequence of task rows (lane
  headers are skipped). j/k + arrows move one task at a
  time across lane boundaries. `r` reloads; `q` quits.
  Phase 3h adds Tab/Shift-Tab to jump between lane heads.

  Implements `TermUI.Elm`. State shape:

      %{
        rows:        [Tasks.Data.task_row()],
        cursor:      non_neg_integer(),
        company:     String.t() | nil,
        base:        Path.t() | nil,
        loader_fn:   function()  # injected for tests
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Tasks.Data
  alias TermUI.Event.Key

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_tasks/2)
    base = Keyword.get(opts, :base)
    company = Keyword.get(opts, :company)

    rows =
      cond do
        Keyword.has_key?(opts, :rows) -> Keyword.fetch!(opts, :rows)
        is_binary(base) and is_binary(company) -> loader_fn.(base, company)
        true -> []
      end
      |> sort_by_lane()

    %{
      rows: rows,
      cursor: 0,
      base: base,
      company: company,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  def event_to_msg(%Key{key: :up}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :down}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "j"}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "k"}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :char, char: "r"}, _state), do: {:msg, :refresh}
  def event_to_msg(%Key{key: :char, char: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:cursor_down, state) do
    last = max(0, length(state.rows) - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  def update(:cursor_up, state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company) |> sort_by_lane(),
        else: state.rows

    new_cursor = clamp_cursor(state.cursor, length(refreshed))
    {%{state | rows: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.rows == [] do
      text("No tasks yet — `glorbo new task <project> <title>` to scaffold one.")
    else
      stack(:vertical, render_lanes(state))
    end
  end

  # ----------------------------------------------------------------

  # Render each lane as a header line followed by its tasks.
  # Cursor index is over the flat `rows` list; we walk the lanes
  # in the same order Data.group_by_lane returns and use a running
  # offset to know which absolute index each row is at.
  defp render_lanes(%{rows: rows, cursor: cursor}) do
    {lines, _} =
      rows
      |> Data.group_by_lane()
      |> Enum.reduce({[], 0}, fn {lane, lane_rows}, {acc, offset} ->
        header = text("▾ #{Data.lane_label(lane)} (#{length(lane_rows)})")
        body_lines = render_lane_rows(lane_rows, offset, cursor)
        {acc ++ [header | body_lines], offset + length(lane_rows)}
      end)

    lines
  end

  defp render_lane_rows([], _offset, _cursor), do: []

  defp render_lane_rows(rows, offset, cursor) do
    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      absolute_idx = offset + idx
      prefix = if absolute_idx == cursor, do: "  > ", else: "    "
      assignee = if row.assignee, do: " [#{row.assignee}]", else: ""
      text("#{prefix}#{row.task_id} — #{row.title}#{assignee}")
    end)
  end

  defp clamp_cursor(_cursor, 0), do: 0
  defp clamp_cursor(cursor, len) when cursor >= len, do: len - 1
  defp clamp_cursor(cursor, _len), do: cursor

  # Sort rows by lane in canonical order so the cursor index over
  # `rows` lines up with the rendered (lane-grouped) display.
  # Stable within each lane via the list's existing alphabetical
  # order from Data.load_tasks (project + filename sort).
  defp sort_by_lane(rows) do
    rows |> Data.group_by_lane() |> Enum.flat_map(fn {_lane, items} -> items end)
  end
end
