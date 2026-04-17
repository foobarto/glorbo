defmodule GlorboWeb.Components.StatCard do
  @moduledoc """
  Overview stat card — label / big value (with optional unit) /
  sub-text / sparkline (mockup: overview.jsx:38-62).

  ## Attrs

    * `:label` — uppercase strip text
    * `:value` — the big number
    * `:unit`  — optional denominator (e.g. `/ 6`, `/ $420`)
    * `:sub`   — contextual sub-line in muted tone
    * `:spark` — list of numbers for the sparkline (defaults to `[]`)
    * `:spark_color` — CSS color for the sparkline
    * `:tone`  — `:default | :accent | :amber | :rose` — drives the
      accent bar on the card (top border or similar).
  """
  use Phoenix.Component

  alias GlorboWeb.Components.Spark

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :unit, :string, default: nil
  attr :sub, :string, default: nil
  attr :spark, :list, default: []
  attr :spark_color, :string, default: "var(--gl-accent-dim)"
  attr :tone, :atom, default: :default, values: [:default, :accent, :amber, :rose]

  def stat_card(assigns) do
    ~H"""
    <div class={["gl-stat-card", "gl-stat-card--" <> Atom.to_string(@tone)]}>
      <div class="gl-stat-card__label">{@label}</div>
      <div class="gl-stat-card__value">
        {@value}
        <span :if={@unit} class="gl-stat-card__unit">{@unit}</span>
      </div>
      <div :if={@sub} class="gl-stat-card__sub">{@sub}</div>
      <div class="gl-stat-card__spark">
        <Spark.spark data={@spark} color={@spark_color} />
      </div>
    </div>
    """
  end
end
