defmodule Glorbo.Shell.Views.Agents do
  @moduledoc """
  GEP-37 Phase 3d — read-only TUI Agents view.

  Per-company roster of agents. One line per agent:
  `<slug> [<role>] <provider>/<model> · <network>`.
  Cursor navigation via arrows + j/k; `r` reloads from disk;
  `q` quits.

  Phase 3d ships FS-only reads — no budget tracking, no
  last-wake hint, no pill status. Phase 3e widens to those
  Repo-backed columns. Empty-state placeholder when the
  company has no bootable agents.

  Implements `TermUI.Elm`. State shape:

      %{
        agents:     [Agents.Data.agent_row()],
        cursor:     non_neg_integer(),
        company:    String.t() | nil,
        base:       Path.t() | nil,
        loader_fn:  function()  # injected for tests
      }
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Agents.Data
  alias Glorbo.Shell.Views.Common

  @impl TermUI.Elm
  def init(opts) do
    loader_fn = Keyword.get(opts, :loader_fn, &Data.load_agents/2)
    base = Keyword.get(opts, :base)
    company = Keyword.get(opts, :company)

    agents =
      cond do
        Keyword.has_key?(opts, :agents) -> Keyword.fetch!(opts, :agents)
        is_binary(base) and is_binary(company) -> loader_fn.(base, company)
        true -> []
      end

    %{
      agents: agents,
      cursor: 0,
      base: base,
      company: company,
      loader_fn: loader_fn
    }
  end

  @impl TermUI.Elm
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.agents))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company),
        else: state.agents

    new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))
    {%{state | agents: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.agents == [] do
      text("No agents yet — `glorbo new agent <slug>` to scaffold one.")
    else
      stack(:vertical, render_agent_lines(state))
    end
  end

  # ----------------------------------------------------------------

  defp render_agent_lines(%{agents: agents, cursor: cursor}) do
    agents
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      provider_model = format_provider_model(row.provider, row.model)
      budget = format_budget(row)
      reports_to = if row.reports_to, do: " → #{row.reports_to}", else: ""

      text(
        "#{prefix}#{row.slug} [#{row.role}] " <>
          "#{provider_model} · #{row.network}" <>
          budget <>
          reports_to
      )
    end)
  end

  defp format_provider_model(provider, ""), do: provider
  defp format_provider_model(provider, model), do: "#{provider}/#{model}"

  # Phase 3d-revisit: budget column. Shows nothing when no cap is
  # declared (matches the LV's "tracked? = cap > 0" gate); shows
  # `$used.dd/$cap.dd` otherwise. `budget_used_cents` defaults to
  # 0 when state shape is missing the field — keeps the legacy
  # Phase-3d row shape (without budget cents) renderable.
  defp format_budget(row) do
    cap = Map.get(row, :budget_cap_cents)
    used = Map.get(row, :budget_used_cents, 0)

    if is_integer(cap) and cap > 0 do
      " · $#{format_cents(used)}/$#{format_cents(cap)}"
    else
      ""
    end
  end

  defp format_cents(cents) when is_integer(cents) and cents >= 0 do
    dollars = div(cents, 100)
    pennies = rem(cents, 100)
    "#{dollars}.#{String.pad_leading(Integer.to_string(pennies), 2, "0")}"
  end
end
