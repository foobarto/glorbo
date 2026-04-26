defmodule Glorbo.Shell.Views.Health do
  @moduledoc """
  GEP-37 Phase 3b — read-only TUI Health view.

  Mirrors the surface of `glorbo doctor` (without the JSON
  formatter): one line per check, each tagged with a pass/fail
  glyph and severity, cursor-navigable for inspection. Phase 3b
  ships read-only; Phase 3c adds expand-on-Enter for the `detail`
  field + live re-poll.

  Implements `TermUI.Elm`. State shape:

      %{
        checks:     [Glorbo.Doctor.check()],
        cursor:     non_neg_integer(),
        checks_fn:  function()  # injected for tests
      }

  ## Boot path

  Production callers pass `[]` (or omit) to `init/1` and the view
  reads `Glorbo.Doctor.run_checks/0` synchronously on init. Tests
  pass `:checks` directly OR `:checks_fn` returning a list, so the
  suite never actually runs the system probes (bwrap shell-out,
  disk_space stat, etc.).
  """

  use TermUI.Elm

  alias Glorbo.Shell.Views.Common

  @typedoc "Health view state."
  @type state :: %{
          checks: [map()],
          cursor: non_neg_integer(),
          checks_fn: (-> [map()])
        }

  @impl TermUI.Elm
  def init(opts) do
    checks_fn = Keyword.get(opts, :checks_fn, &Glorbo.Doctor.run_checks/0)

    checks =
      if Keyword.has_key?(opts, :checks),
        do: Keyword.fetch!(opts, :checks),
        else: checks_fn.()

    %{checks: checks, cursor: 0, checks_fn: checks_fn}
  end

  @impl TermUI.Elm
  def event_to_msg(event, _state), do: Common.cursor_nav_event(event)

  @impl TermUI.Elm
  def update(:cursor_down, state), do: Common.cursor_down(state, length(state.checks))
  def update(:cursor_up, state), do: Common.cursor_up(state)

  def update(:refresh, state) do
    refreshed = state.checks_fn.()
    new_cursor = Common.clamp_cursor(state.cursor, length(refreshed))
    {%{state | checks: refreshed, cursor: new_cursor}, []}
  end

  def update(_msg, _state), do: :noreply

  @impl TermUI.Elm
  def view(state) do
    if state.checks == [] do
      text("No health checks available.")
    else
      stack(:vertical, render_check_lines(state))
    end
  end

  # ----------------------------------------------------------------

  defp render_check_lines(%{checks: checks, cursor: cursor}) do
    checks
    |> Enum.with_index()
    |> Enum.map(fn {check, idx} ->
      prefix = if idx == cursor, do: "> ", else: "  "
      glyph = if check.pass, do: "✓", else: "✗"
      severity = check |> Map.get(:severity, :blocker) |> Atom.to_string()
      detail = format_detail(check)
      text("#{prefix}#{glyph} [#{severity}] #{check.name} — #{detail}")
    end)
  end

  defp format_detail(%{detail: detail}) when is_binary(detail), do: detail
  defp format_detail(_), do: ""
end
