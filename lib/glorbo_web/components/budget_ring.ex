defmodule GlorboWeb.Components.BudgetRing do
  @moduledoc """
  SVG budget ring (04-UI-SPEC §BudgetRing math).

  Draws a background circle (`--gl-surface-raised`) and a foreground
  arc whose length is `used/cap` of the total circumference. Color
  thresholds (D-30 semantics):

    * `ratio < 0.5`  → `--gl-success`
    * `0.5 ≤ ratio < 0.9` → `--gl-warning`
    * `ratio ≥ 0.9` → `--gl-danger`
    * `cap == nil` → solid background ring only (no denominator)
    * `ratio > 1.0` → danger + `!` prefix on the center text

  Props:

    * `:used` — USD spent (float). Defaults to `0.0`.
    * `:cap` — USD cap (float) or `nil` for no-cap.
    * `:size` — CSS px (40 for mini, 96 for agent header).
  """
  use Phoenix.Component

  # 2π × 16 (the circle's radius)
  @circumference 100.53

  attr :used, :float, default: 0.0
  attr :cap, :any, default: nil
  attr :size, :integer, default: 40

  def budget_ring(assigns) do
    r = ratio(assigns[:used], assigns[:cap])
    over? = over_cap?(assigns[:used], assigns[:cap])

    assigns =
      assigns
      |> assign(:ratio, r)
      |> assign(:color, color(r))
      |> assign(:over_cap, over?)
      |> assign(:dasharray, "#{r * @circumference} #{@circumference}")

    ~H"""
    <svg class="gl-budget-ring" viewBox="0 0 36 36" width={@size} height={@size}>
      <circle cx="18" cy="18" r="16" stroke="var(--gl-surface-raised)"
              stroke-width="3" fill="none" />
      <circle :if={@cap} cx="18" cy="18" r="16"
              stroke={@color} stroke-width="3" fill="none"
              stroke-dasharray={@dasharray}
              transform="rotate(-90 18 18)" />
      <text x="18" y="20" text-anchor="middle" font-size="8" fill="var(--gl-fg)">
        {center_text(@used, @cap, @size, @over_cap)}
      </text>
    </svg>
    """
  end

  defp ratio(_used, nil), do: 0.0

  defp ratio(used, cap) when is_number(used) and is_number(cap) and cap > 0 do
    r = used / cap
    if r > 1.0, do: 1.0, else: r
  end

  defp ratio(_, _), do: 0.0

  defp over_cap?(used, cap) when is_number(used) and is_number(cap) and cap > 0,
    do: used / cap > 1.0

  defp over_cap?(_, _), do: false

  defp color(r) when r >= 0.9, do: "var(--gl-danger)"
  defp color(r) when r >= 0.5, do: "var(--gl-warning)"
  defp color(_), do: "var(--gl-success)"

  defp center_text(used, nil, _size, _over), do: "$" <> two_decimals(used)

  defp center_text(used, cap, size, over) do
    prefix = if over, do: "!", else: ""

    if size < 60 do
      prefix <> "$" <> zero_decimals(used)
    else
      prefix <> "$" <> two_decimals(used) <> "/" <> zero_decimals(cap)
    end
  end

  defp two_decimals(n) when is_number(n),
    do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  defp two_decimals(_), do: "0.00"

  defp zero_decimals(n) when is_number(n),
    do: :erlang.float_to_binary(n * 1.0, decimals: 0)

  defp zero_decimals(_), do: "0"
end
