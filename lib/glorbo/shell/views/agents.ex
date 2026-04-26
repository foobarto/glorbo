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
  alias TermUI.Event.Key

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
  def event_to_msg(%Key{key: :up}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :down}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "j"}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "k"}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :char, char: "r"}, _state), do: {:msg, :refresh}
  def event_to_msg(%Key{key: :char, char: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:cursor_down, state) do
    last = max(0, length(state.agents) - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  def update(:cursor_up, state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  def update(:refresh, state) do
    refreshed =
      if is_binary(state.base) and is_binary(state.company),
        do: state.loader_fn.(state.base, state.company),
        else: state.agents

    new_cursor = clamp_cursor(state.cursor, length(refreshed))
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
      reports_to = if row.reports_to, do: " → #{row.reports_to}", else: ""

      text(
        "#{prefix}#{row.slug} [#{row.role}] " <>
          "#{provider_model} · #{row.network}" <>
          reports_to
      )
    end)
  end

  defp format_provider_model(provider, ""), do: provider
  defp format_provider_model(provider, model), do: "#{provider}/#{model}"

  defp clamp_cursor(_cursor, 0), do: 0
  defp clamp_cursor(cursor, len) when cursor >= len, do: len - 1
  defp clamp_cursor(cursor, _len), do: cursor
end
