defmodule Glorbo.Shell.AppRoot do
  @moduledoc """
  GEP-37 Phase 3a — top-level shell view + chord-prefix dispatcher.

  Wraps the per-view `TermUI.Elm` modules (Phase 2/2b/2c shipped
  the Inbox; Phase 3b adds Health, Overview, etc.) and owns the
  Emacs-style `C-c <letter>` chord that flips between them per
  GEP-37 D10's keybinding table:

      | C-c o | Overview            |
      | C-c t | Tasks               |
      | C-c a | Agents              |
      | C-c c | Chat                |
      | C-c p | Approvals (Inbox)   |
      | C-c h | Health              |
      | C-c u | aUdit               |

  Phase 3a (this version) ships the chord scaffold + Inbox routing
  only. Pressing `C-c p` re-renders the Inbox; every other letter
  surfaces a "view not yet implemented in Phase 3a" footer line.
  Phase 3b adds the second view and validates the chord-driven swap
  by actually transitioning the rendered surface.

  ## State shape

      %{
        view:          atom(),      # currently :approvals
        sub_state:     map(),       # the active view's state
        chord:         :idle | :c_c # chord-prefix tracker
      }

  ## How chords work

  `event_to_msg/2` in `:c_c` chord mode interprets the next single
  keystroke as a view-switch letter. Esc cancels back to `:idle`.
  Any other key in `:c_c` mode also returns to `:idle` and is
  ignored — Emacs convention is that an unknown chord suffix is
  a no-op.

  In `:idle` mode, `Ctrl+c` (term_ui delivers as
  `%Key{key: :char, char: "c", modifiers: [:ctrl]}`) flips into
  `:c_c`. Everything else delegates to the active view.
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Inbox
  alias TermUI.Event.Key

  @typedoc "Active view identifier. Phase 3a only Inbox; Phase 3b adds the rest."
  @type view :: :approvals

  @typedoc "Chord-prefix tracker."
  @type chord :: :idle | :c_c

  @typedoc "AppRoot state."
  @type state :: %{
          view: view(),
          sub_state: map(),
          chord: chord(),
          chord_hint: String.t() | nil
        }

  @views_phase_3a [:approvals]

  @impl TermUI.Elm
  def init(opts) do
    sub_state = Inbox.init(opts)
    %{view: :approvals, sub_state: sub_state, chord: :idle, chord_hint: nil}
  end

  @impl TermUI.Elm
  # Chord mode — the next keystroke is a view-switch letter.
  def event_to_msg(%Key{key: :escape}, %{chord: :c_c}), do: {:msg, :chord_cancel}

  def event_to_msg(%Key{key: :char, char: ch}, %{chord: :c_c})
      when is_binary(ch) and byte_size(ch) > 0,
      do: {:msg, {:chord_select, ch}}

  def event_to_msg(_event, %{chord: :c_c}), do: {:msg, :chord_cancel}

  # Idle mode — Ctrl+c starts a chord; everything else delegates.
  def event_to_msg(%Key{key: :char, char: "c", modifiers: mods}, _state) do
    if :ctrl in mods, do: {:msg, :chord_start_c_c}, else: :propagate
  end

  def event_to_msg(_event, _state), do: :propagate

  @impl TermUI.Elm
  def update(:chord_start_c_c, state) do
    {%{state | chord: :c_c, chord_hint: nil}, []}
  end

  def update(:chord_cancel, state) do
    {%{state | chord: :idle, chord_hint: nil}, []}
  end

  def update({:chord_select, ch}, state) do
    case Map.get(view_letter_map(), ch) do
      nil ->
        {%{state | chord: :idle, chord_hint: "unknown chord: C-c #{ch}"}, []}

      view when view in @views_phase_3a ->
        {%{state | chord: :idle, view: view, chord_hint: nil}, []}

      view ->
        {%{state | chord: :idle, chord_hint: "view '#{view}' not yet implemented (Phase 3b+)"}, []}
    end
  end

  def update(msg, state) do
    # Delegate any non-chord message to the active view module.
    active = view_module(state.view)

    case active.update(msg, state.sub_state) do
      :noreply ->
        :noreply

      {new_sub, cmds} ->
        {%{state | sub_state: new_sub}, cmds}
    end
  end

  @impl TermUI.Elm
  def view(state) do
    active = view_module(state.view)
    body = active.view(state.sub_state)
    append_chord_hint(body, state)
  end

  # ----------------------------------------------------------------

  # Chord-letter → view-atom routing per GEP-37 D10. Phase 3a
  # routes only `p` (approvals); the others are reserved + report
  # "not implemented" via the hint slot. Phase 3b widens the
  # implemented set, gradually emptying the not-implemented branch.
  defp view_letter_map do
    %{
      "o" => :overview,
      "t" => :tasks,
      "a" => :agents,
      "c" => :chat,
      "p" => :approvals,
      "h" => :health,
      "u" => :audit
    }
  end

  defp view_module(:approvals), do: Inbox
  # Phase 3b adds: defp view_module(:health), do: Health, etc.
  defp view_module(_), do: Inbox

  defp append_chord_hint(body, %{chord: :c_c}) do
    stack(:vertical, [body, text("(C-c …) — pick a view: o/t/a/c/p/h/u, Esc to cancel")])
  end

  defp append_chord_hint(body, %{chord_hint: nil}), do: body

  defp append_chord_hint(body, %{chord_hint: hint}) when is_binary(hint) do
    stack(:vertical, [body, text("[chord] #{hint}")])
  end
end
