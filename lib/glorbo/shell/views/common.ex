defmodule Glorbo.Shell.Views.Common do
  @moduledoc """
  GEP-37 Phase 3 housecleaning — shared helpers for cursor-list views.

  All seven Phase-3 views (Inbox, Overview, Agents, Audit, Chat,
  Health, Tasks) share the same cursor-navigation skeleton:
  arrow keys + `j`/`k` for cursor motion, `r` for refresh, `q`
  for quit, plus standard cursor-clamping update logic. This
  module pulls those identical arms into one place so future
  views (or revisits to existing ones) don't re-typo them.

  ## Usage pattern

  Each view's `event_to_msg/2` calls `cursor_nav_event/1` as its
  fall-through arm:

      def event_to_msg(event, _state) do
        # View-specific arms first (e.g. Inbox's `a`/`d` actions
        # or AppRoot's chord prefix); then fall through:
        Common.cursor_nav_event(event)
      end

  Each view's `update/2` calls `cursor_down/2` + `cursor_up/1` +
  `clamp_cursor/2` against its own list-field accessor:

      def update(:cursor_down, state),
        do: Common.cursor_down(state, length(state.rows))

      def update(:cursor_up, state),
        do: Common.cursor_up(state)
  """

  alias TermUI.Event.Key

  @typedoc "Common message tags that views all forward through."
  @type cursor_msg ::
          :cursor_up | :cursor_down | :refresh | :quit

  @doc """
  Standard cursor-list event mapping. Returns `{:msg, atom}` for
  the recognised navigation arms; `:ignore` for everything else
  so view-specific dispatchers can chain after this.
  """
  @spec cursor_nav_event(Key.t()) :: {:msg, cursor_msg()} | :ignore
  def cursor_nav_event(%Key{key: :up}), do: {:msg, :cursor_up}
  def cursor_nav_event(%Key{key: :down}), do: {:msg, :cursor_down}
  def cursor_nav_event(%Key{key: :char, char: "j"}), do: {:msg, :cursor_down}
  def cursor_nav_event(%Key{key: :char, char: "k"}), do: {:msg, :cursor_up}
  def cursor_nav_event(%Key{key: :char, char: "r"}), do: {:msg, :refresh}
  def cursor_nav_event(%Key{key: :char, char: "q"}), do: {:msg, :quit}
  def cursor_nav_event(_event), do: :ignore

  @doc """
  Move the cursor one step down, clamped at `len - 1` (or 0 when
  the list is empty). Returns the term_ui update tuple.
  """
  @spec cursor_down(map(), non_neg_integer()) :: {map(), []}
  def cursor_down(state, len) do
    last = max(0, len - 1)
    {%{state | cursor: min(state.cursor + 1, last)}, []}
  end

  @doc """
  Move the cursor one step up, clamped at 0. Returns the term_ui
  update tuple.
  """
  @spec cursor_up(map()) :: {map(), []}
  def cursor_up(state) do
    {%{state | cursor: max(state.cursor - 1, 0)}, []}
  end

  @doc """
  Clamp a cursor index against a new list length. Used by
  `:refresh` arms that re-fetch the list and need to reposition
  the cursor inside the new bounds.
  """
  @spec clamp_cursor(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def clamp_cursor(_cursor, 0), do: 0
  def clamp_cursor(cursor, len) when cursor >= len, do: len - 1
  def clamp_cursor(cursor, _len), do: cursor
end
