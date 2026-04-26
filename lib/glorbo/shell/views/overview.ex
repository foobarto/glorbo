defmodule Glorbo.Shell.Views.Overview do
  @moduledoc """
  GEP-37 Phase 3c — read-only TUI Overview view.

  Cross-company snapshot. Lists every workspace under
  `<base>/companies/`, one row each, with light FS-only counts
  (agent count + alert count). Phase 3d will widen to the
  spend / in-progress / goals-progress columns the LV Overview
  carries; Phase 3c keeps the read path narrow so the suite
  stays Repo-free.

  Active company (the one passed via `glorbo shell <company>`)
  is highlighted with a `*` glyph in the leading column so the
  Director knows which workspace the chord-driven sibling views
  (Inbox / Health) act on.

  Implements `TermUI.Elm`. State shape:

      %{
        companies:       [Overview.Data.overview_row()],
        cursor:          non_neg_integer(),
        active_company:  String.t() | nil,
        base:            Path.t() | nil,
        loader_fn:       function()  # injected for tests
      }

  ## Boot path

  Production callers pass `base:` + `company:` (the active
  company). Tests pass `companies:` directly to skip the FS
  read.
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Common
  alias Glorbo.Shell.Views.Overview.Data

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_companies/1)
    base = Keyword.get(opts, :base)
    active = Keyword.get(opts, :company)

    companies =
      cond do
        Keyword.has_key?(opts, :companies) -> Keyword.fetch!(opts, :companies)
        is_binary(base) -> loader_fn.(base)
        true -> []
      end

    %{
      companies: companies,
      cursor: cursor_for_active(companies, active),
      active_company: active,
      base: base,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.companies))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base), do: state.loader_fn.(state.base), else: state.companies

    new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))
    {%{state | companies: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.companies == [] do
      text("No companies yet — `glorbo new company <slug>` to bootstrap one.")
    else
      stack(:vertical, render_company_lines(state))
    end
  end

  # ----------------------------------------------------------------

  defp render_company_lines(%{
         companies: companies,
         cursor: cursor,
         active_company: active
       }) do
    companies
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      cursor_glyph = if idx == cursor, do: "> ", else: "  "
      active_glyph = if row.slug == active, do: "*", else: " "
      spend = format_spend(row)

      text(
        "#{cursor_glyph}#{active_glyph} #{row.slug} (#{row.name}) — " <>
          "#{row.agent_count} agent#{plural(row.agent_count)}, " <>
          "#{row.alert_count} alert#{plural(row.alert_count)}" <>
          spend
      )
    end)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  # Phase 3c-revisit: spend column. Suppressed when zero so
  # quiet companies stay visually distinct from spending ones.
  # Map.get/3 keeps legacy Phase-3c row shapes (without
  # `:spend_cents`) renderable.
  defp format_spend(row) do
    case Map.get(row, :spend_cents, 0) do
      cents when is_integer(cents) and cents > 0 -> ", $#{format_cents(cents)} spent"
      _ -> ""
    end
  end

  defp format_cents(cents) when is_integer(cents) and cents >= 0 do
    dollars = div(cents, 100)
    pennies = rem(cents, 100)
    "#{dollars}.#{String.pad_leading(Integer.to_string(pennies), 2, "0")}"
  end

  # Cursor lands on the active-company row when present so the
  # Director's chord-target row is the highlighted one on first
  # paint. Otherwise cursor 0.
  defp cursor_for_active(_companies, nil), do: 0

  defp cursor_for_active(companies, active) when is_binary(active) do
    case Enum.find_index(companies, &(&1.slug == active)) do
      nil -> 0
      idx -> idx
    end
  end
end
