defmodule Glorbo.Shell.Views.Audit do
  @moduledoc """
  GEP-37 Phase 3e — read-only TUI Audit view.

  Renders the current-month JSONL audit tail (last 100 by
  default). Each line: `[<ts>] <actor> <action> <target>`.
  Cursor navigation via arrows + j/k; `r` reloads (re-streams
  the file); `q` quits.

  Phase 3e ships read-only with a fixed window. Phase 3f
  adds the live-tail EventBus subscription + older-page
  navigation; the Phase-1 supervisor's EventBus already
  forwards `company:<co>:audit` PubSub broadcasts so wiring
  is mostly a Runtime → AppRoot message-routing question.

  Implements `TermUI.Elm`. State shape:

      %{
        entries:    [Audit.Data.entry_row()],
        cursor:     non_neg_integer(),
        company:    String.t() | nil,
        base:       Path.t() | nil,
        loader_fn:  function()  # injected for tests
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Audit.Data
  alias Glorbo.Shell.Views.Common

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_tail/2)
    base = Keyword.get(opts, :base)
    company = Keyword.get(opts, :company)

    entries =
      cond do
        Keyword.has_key?(opts, :entries) -> Keyword.fetch!(opts, :entries)
        is_binary(base) and is_binary(company) -> loader_fn.(base, company)
        true -> []
      end

    %{
      entries: entries,
      cursor: 0,
      base: base,
      company: company,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.entries))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company),
        else: state.entries

    new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))
    {%{state | entries: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.entries == [] do
      text("No audit entries this month.")
    else
      stack(:vertical, render_entry_lines(state))
    end
  end

  # ----------------------------------------------------------------

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
end
