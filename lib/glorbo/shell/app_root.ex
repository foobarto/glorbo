defmodule Glorbo.Shell.AppRoot do
  @moduledoc """
  GEP-37 Phase 3a + 3a-revisit — top-level shell view +
  chord-prefix dispatcher + help overlay.

  Wraps the per-view `TermUI.Elm` modules and owns the
  Emacs-style `C-c <letter>` chord that flips between them
  per GEP-37 D10's keybinding table:

      | C-c o | Overview            |
      | C-c t | Tasks               |
      | C-c a | Agents              |
      | C-c c | Chat                |
      | C-c p | Approvals (Inbox)   |
      | C-c h | Health              |
      | C-c u | aUdit               |

  Phase 3a-revisit (this version) adds a `?`-toggled help
  overlay listing every chord, list-nav binding, and
  view-specific modal trigger in one place — discoverable
  without leaving the shell.

  ## State shape

      %{
        view:       atom(),         # currently :approvals
        sub_state:  map(),          # the active view's state
        chord:      :idle | :c_c,   # chord-prefix tracker
        chord_hint: String.t() | nil,
        help_open:  boolean()
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

  alias Glorbo.Shell.Views.{Agents, Audit, Chat, Health, Inbox, Overview, Tasks}
  alias TermUI.Event.Key

  @typedoc "Active view identifier. All GEP-37 D10 chord targets implemented."
  @type view :: :approvals | :health | :overview | :agents | :audit | :chat | :tasks

  @typedoc "Chord-prefix tracker."
  @type chord :: :idle | :c_c

  @typedoc "AppRoot state."
  @type state :: %{
          view: view(),
          sub_state: map(),
          chord: chord(),
          chord_hint: String.t() | nil,
          help_open: boolean()
        }

  # Implemented views — chord letters mapped here actually swap.
  # Letters in `view_letter_map/0` but NOT in this list surface a
  # "view not yet implemented" hint instead of switching.
  @views_implemented [:approvals, :health, :overview, :agents, :audit, :chat, :tasks]

  @impl TermUI.Elm
  def init(opts) do
    # Initial view defaults to :approvals (the existing Phase 2c
    # contract); callers can pass `:initial_view` to start
    # elsewhere. The opts pass through to the chosen view's
    # init/1 so per-view setup (`:base`, `:company`, mocks) keeps
    # working.
    initial_view = Keyword.get(opts, :initial_view, :approvals)
    sub_state = view_module(initial_view).init(opts)

    %{
      view: initial_view,
      sub_state: sub_state,
      chord: :idle,
      chord_hint: nil,
      help_open: false
    }
  end

  @impl TermUI.Elm
  # Help overlay absorbs every keystroke; only `?` and Esc dismiss
  # it. Sits above the chord-mode arms so an open help panel can't
  # be navigated through.
  def event_to_msg(%Key{key: :escape}, %{help_open: true}), do: {:msg, :help_close}
  def event_to_msg(%Key{key: :char, char: "?"}, %{help_open: true}), do: {:msg, :help_close}
  def event_to_msg(_event, %{help_open: true}), do: :ignore

  # Chord mode — the next keystroke is a view-switch letter.
  def event_to_msg(%Key{key: :escape}, %{chord: :c_c}), do: {:msg, :chord_cancel}

  def event_to_msg(%Key{key: :char, char: ch}, %{chord: :c_c})
      when is_binary(ch) and byte_size(ch) > 0,
      do: {:msg, {:chord_select, ch}}

  def event_to_msg(_event, %{chord: :c_c}), do: {:msg, :chord_cancel}

  # Idle mode — Ctrl+c starts a chord; `?` opens the help overlay;
  # everything else delegates.
  def event_to_msg(%Key{key: :char, char: "c", modifiers: mods}, _state) do
    if :ctrl in mods, do: {:msg, :chord_start_c_c}, else: :propagate
  end

  def event_to_msg(%Key{key: :char, char: "?"}, _state), do: {:msg, :help_open}

  def event_to_msg(_event, _state), do: :propagate

  @impl TermUI.Elm
  def update(:help_open, state), do: {%{state | help_open: true}, []}
  def update(:help_close, state), do: {%{state | help_open: false}, []}

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

      view when view in @views_implemented ->
        # Phase 3b: chord-driven view swap. Spin up the target
        # view's `init/1` with a fresh state. Carries forward the
        # current sub_state's company/base if present so the new
        # view boots with the same workspace context.
        opts = forward_opts(state.sub_state)
        new_sub = view_module(view).init(opts)
        {%{state | chord: :idle, view: view, sub_state: new_sub, chord_hint: nil}, []}

      view ->
        {%{state | chord: :idle, chord_hint: "view '#{view}' not yet implemented (Phase 3+)"}, []}
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
    if state.help_open do
      help_overlay()
    else
      active = view_module(state.view)
      body = active.view(state.sub_state)
      append_chord_hint(body, state)
    end
  end

  # Static keymap reference. Rendered as a stack of text lines so
  # the existing render_to_strings test helper can flatten it.
  # Mirrors the chord-prefix table in `view_letter_map/0` plus the
  # per-view bindings each view module already documents.
  defp help_overlay do
    stack(:vertical, [
      text("Glorbo Shell — Help (? or Esc to close)"),
      text(""),
      text("View switcher (chord prefix):"),
      text("  C-c o   Overview"),
      text("  C-c t   Tasks"),
      text("  C-c a   Agents"),
      text("  C-c c   Chat"),
      text("  C-c p   Approvals (Inbox)"),
      text("  C-c h   Health"),
      text("  C-c u   aUdit"),
      text(""),
      text("List navigation (every view):"),
      text("  j / ↓   cursor down"),
      text("  k / ↑   cursor up"),
      text("  r       refresh"),
      text("  q       quit"),
      text(""),
      text("Inbox (Approvals):"),
      text("  a       approve highlighted"),
      text("  d       deny → opens reason prompt"),
      text("  Enter   submit deny reason"),
      text("  Esc     cancel deny prompt"),
      text(""),
      text("Chat:"),
      text("  i       open composer modal"),
      text("  s       open channel switcher modal"),
      text("  /switch <ch>   slash: swap channel"),
      text("  /help          slash: list commands"),
      text("  /cancel        slash: silent exit"),
      text(""),
      text("Audit:"),
      text("  p       previous month"),
      text("  n       next month")
    ])
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
  defp view_module(:health), do: Health
  defp view_module(:overview), do: Overview
  defp view_module(:agents), do: Agents
  defp view_module(:audit), do: Audit
  defp view_module(:chat), do: Chat
  defp view_module(:tasks), do: Tasks
  # Every chord letter in `view_letter_map/0` now routes to a
  # real view (post-Phase-3g). Phase 3+ revisits views for the
  # heavier columns + composer + live-tail wire-ups.
  # The fallback is :approvals because that's the boot view; an
  # unimplemented view never reaches `view_module/1` (the
  # `chord_select` arm filters via `@views_implemented`).
  defp view_module(_), do: Inbox

  # Carry forward the sub_state's `:base` + `:company` when swapping
  # views so the next one boots with the same workspace context.
  # Tests that bypass the company/base path (passing `:approvals`
  # directly to Inbox) get an empty opts list, which the new view's
  # init/1 still tolerates.
  defp forward_opts(sub_state) do
    sub_state
    |> Map.take([:base, :company])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into([])
  end

  defp append_chord_hint(body, %{chord: :c_c}) do
    stack(:vertical, [body, text("(C-c …) — pick a view: o/t/a/c/p/h/u, Esc to cancel")])
  end

  defp append_chord_hint(body, %{chord_hint: hint}) when is_binary(hint) do
    stack(:vertical, [body, text("[chord] #{hint}")])
  end

  # Idle mode with no recent chord error: show a one-line discovery
  # footer so the chord prefix + help overlay are reachable without
  # reading docs. Pre-Phase-3a-revisit the shell rendered the active
  # view body alone, which left `?` and `C-c` invisible to a fresh user.
  defp append_chord_hint(body, _state) do
    stack(:vertical, [body, text("(? help · C-c o/t/a/c/p/h/u to switch view · q quit)")])
  end
end
