defmodule GlorboWeb.Components.StatusPill do
  @moduledoc """
  Uniform status pill (M1 mockup alignment — abc.zip shell.jsx:157-160).

  Replaces ad-hoc badges scattered across the dashboard with a single
  dot-prefixed label tuple. Five semantic states map to the phosphor
  palette:

    - `:alive` — phosphor-green (agent running, provider routable)
    - `:idle`  — muted (agent at rest)
    - `:warn`  — amber (budget approaching cap, slow heartbeat, …)
    - `:stop`  — rose (crashed, rejected, not-installed)
    - `:info`  — cyan (neutral informational — "untracked budget",
      "no-cap", etc.)

  ## Usage

      <StatusPill.status_pill status={:alive}>alive</StatusPill.status_pill>
      <StatusPill.status_pill status={:warn} label="budget 92%" />

  If `label` is given it's used as the visible text; otherwise the
  inner block (slot) is rendered. Passing a string-shorthand is
  convenient for the common `alive/idle/warn/stop` case.
  """
  use Phoenix.Component

  attr :status, :atom, default: :idle, values: [:alive, :idle, :warn, :stop, :info]
  attr :label, :string, default: nil
  slot :inner_block

  def status_pill(assigns) do
    ~H"""
    <span class={["gl-pill", "gl-pill--" <> Atom.to_string(@status)]}>
      <span class="gl-pill__dot" aria-hidden="true"></span>
      <span>{@label || render_slot(@inner_block) || Atom.to_string(@status)}</span>
    </span>
    """
  end
end
