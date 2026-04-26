defmodule Glorbo.Shell.Views.Inbox do
  @moduledoc """
  GEP-37 Phase 2 — the TUI Inbox view.

  Drop-in (read-only) parity with the LV inbox's approvals tab:
  lists `awaiting-approval-*` sentinels for the active company,
  cursor navigation up/down (arrows + j/k), `q` to quit. Action
  handlers (approve / deny / archive) land in Phase 2b alongside
  the wave-31 Gate carve-out.

  Implements `TermUI.Elm`. State shape:

      %{
        approvals: [Inbox.Data.approval_row()],
        cursor:    non_neg_integer()
      }

  ## Boot path

  Production callers pass `base: "..."` + `company: "..."` to
  `init/1`; Phase 2 reads from disk via
  `Glorbo.Shell.Views.Inbox.Data.load_approvals/2`. Tests pass
  pre-built `approvals: [...]` opts directly so the view can be
  exercised without a fixture filesystem.
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Inbox.Data
  alias TermUI.Event.Key

  @typedoc "Inbox view state."
  @type state :: %{
          approvals: [Data.approval_row()],
          cursor: non_neg_integer()
        }

  @impl TermUI.Elm
  def init(opts) do
    approvals =
      cond do
        Keyword.has_key?(opts, :approvals) ->
          Keyword.fetch!(opts, :approvals)

        Keyword.has_key?(opts, :base) and Keyword.has_key?(opts, :company) ->
          Data.load_approvals(Keyword.fetch!(opts, :base), Keyword.fetch!(opts, :company))

        true ->
          []
      end

    %{approvals: approvals, cursor: 0}
  end

  @impl TermUI.Elm
  def event_to_msg(%Key{key: :up}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :down}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "j"}, _state), do: {:msg, :cursor_down}
  def event_to_msg(%Key{key: :char, char: "k"}, _state), do: {:msg, :cursor_up}
  def event_to_msg(%Key{key: :char, char: "q"}, _state), do: {:msg, :quit}
  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update(:cursor_down, state) do
    last = max(0, length(state.approvals) - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  def update(:cursor_up, state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  def update({:approvals_changed, list}, state) do
    {%{state | approvals: list, cursor: clamp_cursor(state.cursor, length(list))}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.approvals == [] do
      text("Inbox empty — no pending approvals.")
    else
      lines = render_approval_lines(state)
      stack(:vertical, lines)
    end
  end

  # ----------------------------------------------------------------

  defp render_approval_lines(%{approvals: approvals, cursor: cursor}) do
    approvals
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      assignee = row.assignee || "unassigned"
      text("#{prefix}#{row.task_id} — #{row.title} [#{assignee}]")
    end)
  end

  defp clamp_cursor(_cursor, 0), do: 0

  defp clamp_cursor(cursor, len) when cursor >= len, do: len - 1

  defp clamp_cursor(cursor, _len), do: cursor
end
