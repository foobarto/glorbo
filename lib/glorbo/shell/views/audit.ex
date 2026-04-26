defmodule Glorbo.Shell.Views.Audit do
  @moduledoc """
  GEP-37 Phase 3e + 3e-revisit — read-only TUI Audit view.

  Renders the JSONL audit tail for a chosen month bucket
  (last 100 by default). Each row: `[<ts>] <actor> <action>
  <target>`. Phase 3e shipped current-month-only; Phase
  3e-revisit (this version) adds older-page navigation via
  `p` (previous month) / `n` (next month, only when not at
  the latest bucket). The header line shows the active
  month + a hint if more pages exist.

  Cursor navigation via arrows + `j`/`k`; `r` reloads the
  active bucket; `q` quits. The Phase-3f live-tail EventBus
  subscription (PubSub → AppRoot routing) is still future
  work — structurally awkward in pure Elm and the bounded
  reload is fine for v1.

  Implements `TermUI.Elm`. State shape:

      %{
        entries:           [Audit.Data.entry_row()],
        cursor:            non_neg_integer(),
        year_month:        String.t(),
        available_months:  [String.t()],   # newest-first
        company:           String.t() | nil,
        base:              Path.t() | nil,
        loader_fn:         function(),     # (b, c, ym) -> [row]
        list_months_fn:    function()      # (b, c)     -> [ym]
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Audit.Data
  alias Glorbo.Shell.Views.Common
  alias TermUI.Event.Key

  @impl TermUI.Elm
  def init(opts) do
    loader_fn =
      Keyword.get(opts, :loader_fn, fn b, c, ym ->
        Data.load_tail(b, c, year_month: ym)
      end)

    list_months_fn = Keyword.get(opts, :list_months_fn, &Data.list_year_months/2)
    base = Keyword.get(opts, :base)
    company = Keyword.get(opts, :company)

    available_months =
      if is_binary(base) and is_binary(company),
        do: list_months_fn.(base, company),
        else: [current_year_month()]

    year_month = Keyword.get(opts, :year_month, hd(available_months))

    entries =
      cond do
        Keyword.has_key?(opts, :entries) -> Keyword.fetch!(opts, :entries)
        is_binary(base) and is_binary(company) -> loader_fn.(base, company, year_month)
        true -> []
      end

    %{
      entries: entries,
      cursor: 0,
      year_month: year_month,
      available_months: available_months,
      base: base,
      company: company,
      loader_fn: loader_fn,
      list_months_fn: list_months_fn
    }
  end

  @impl TermUI.Elm
  # `p`/`n` for older/newer page first; everything else falls through.
  def event_to_msg(%Key{key: :char, char: "p"}, _state), do: {:msg, :prev_month}
  def event_to_msg(%Key{key: :char, char: "n"}, _state), do: {:msg, :next_month}
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.entries))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    if is_binary(state.base) and is_binary(state.company) do
      months = state.list_months_fn.(state.base, state.company)
      ym = if state.year_month in months, do: state.year_month, else: hd(months)
      refreshed = state.loader_fn.(state.base, state.company, ym)
      new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))

      {%{
         state
         | entries: refreshed,
           available_months: months,
           year_month: ym,
           cursor: new_cursor
       }, []}
    else
      {state, []}
    end
  end

  def update(:prev_month, state), do: change_month(state, +1)
  def update(:next_month, state), do: change_month(state, -1)

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    header = text(header_line(state))

    body =
      if state.entries == [] do
        text("No audit entries for #{state.year_month}.")
      else
        stack(:vertical, render_entry_lines(state))
      end

    stack(:vertical, [header, body])
  end

  # ----------------------------------------------------------------

  # Shift the active month by `delta` indices in
  # `available_months` (which is newest-first, so +1 goes back
  # in time, -1 goes forward). Clamped at the boundaries; a
  # no-op at the edges. Triggers a fresh loader_fn call only
  # if the index actually moved.
  defp change_month(state, delta) do
    months = state.available_months
    cur_idx = Enum.find_index(months, &(&1 == state.year_month)) || 0
    last = max(length(months) - 1, 0)
    new_idx = cur_idx |> Kernel.+(delta) |> max(0) |> min(last)

    if new_idx == cur_idx do
      {state, []}
    else
      ym = Enum.at(months, new_idx)

      refreshed =
        if is_binary(state.base) and is_binary(state.company),
          do: state.loader_fn.(state.base, state.company, ym),
          else: []

      {%{state | year_month: ym, entries: refreshed, cursor: 0}, []}
    end
  end

  defp header_line(state) do
    months = state.available_months
    cur_idx = Enum.find_index(months, &(&1 == state.year_month)) || 0
    older = if cur_idx < length(months) - 1, do: " (p older)", else: ""
    newer = if cur_idx > 0, do: " (n newer)", else: ""
    "Audit — #{state.year_month}#{older}#{newer}"
  end

  defp render_entry_lines(%{entries: entries, cursor: cursor}) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      target = if row.target == "", do: "", else: " " <> row.target
      text("#{prefix}[#{format_ts(row.ts)}] #{row.actor} #{row.action}#{target}")
    end)
  end

  # Trim ISO 8601 timestamps to the date+time portion (16 chars,
  # `YYYY-MM-DDTHH:MM`) so each line stays narrow. Anything we
  # can't recognise is rendered as-is.
  defp format_ts(ts) when is_binary(ts) and byte_size(ts) >= 16,
    do: String.slice(ts, 0, 16)

  defp format_ts(ts), do: ts

  defp current_year_month do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.to_string()
    |> String.slice(0, 7)
  end
end
