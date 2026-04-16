defmodule GlorboWeb.Components.HealthDot do
  @moduledoc """
  8×8px filled-circle dot (04-UI-SPEC §Component Inventory).

  Variants map to semantic color tokens:
    * `:healthy` → `--gl-success`
    * `:warning` → `--gl-warning`
    * `:crashed` → `--gl-danger`
    * `:idle`    → `--gl-fg-muted`

  When `label` is set the dot becomes an accessible `img` element with
  the label read by screen readers; otherwise it's decorative.
  """
  use Phoenix.Component

  attr :status, :atom, default: :idle, values: [:healthy, :warning, :crashed, :idle]
  attr :label, :string, default: nil

  def health_dot(assigns) do
    ~H"""
    <span
      class={["gl-dot", "gl-dot--" <> Atom.to_string(@status)]}
      aria-label={@label}
      role={if @label, do: "img", else: "presentation"}
    />
    """
  end
end
