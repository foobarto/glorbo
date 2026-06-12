defmodule GlorboWeb.Components.StatBreakdown do
  @moduledoc """
  Mini stacked-segment tile for CompanyLive (paperclip-ux-gaps §4).

  Renders a label, a total value, and a horizontal strip of coloured
  segments — each segment's width is proportional to its count.
  A legend under the strip names each non-zero bucket.

  Segment colours cycle through a six-token palette; the caller can
  supply an explicit `:color_for/1` function that takes the bucket
  key and returns a CSS var name (defaults to rotation).
  """
  use Phoenix.Component

  attr :label, :string, required: true
  attr :buckets, :list, required: true, doc: "list of {key, count}"
  attr :color_for, :any, default: nil

  def stat_breakdown(assigns) do
    total = assigns.buckets |> Enum.map(fn {_, c} -> c end) |> Enum.sum()

    segs =
      for {k, c} <- assigns.buckets, c > 0 do
        pct = if total > 0, do: Float.round(c / total * 100, 1), else: 0.0
        color = resolve_color(assigns[:color_for], k)
        {k, c, pct, color}
      end

    assigns =
      assigns
      |> assign(:total, total)
      |> assign(:segs, segs)

    ~H"""
    <div class="gl-stat-breakdown">
      <div class="gl-stat-breakdown__head">
        <span class="gl-muted">{@label}</span>
        <strong>{@total}</strong>
      </div>
      <div class="gl-stat-breakdown__bar" role="presentation">
        <span
          :for={{_k, _c, pct, color} <- @segs}
          class="gl-stat-breakdown__seg"
          style={"width: #{pct}%; background: #{color};"}
        ></span>
      </div>
      <ul class="gl-stat-breakdown__legend">
        <li :for={{k, c, _pct, color} <- @segs}>
          <span class="gl-stat-breakdown__dot" style={"background: #{color};"}></span>{k}
          <span class="gl-muted">{c}</span>
        </li>
      </ul>
      <p :if={@total == 0} class="gl-muted">—</p>
    </div>
    """
  end

  defp resolve_color(nil, key), do: default_color(key)
  defp resolve_color(fun, key) when is_function(fun, 1), do: fun.(key)

  @palette %{
    "todo" => "var(--gl-fg-muted)",
    "in-progress" => "var(--gl-cyan)",
    "pending" => "var(--gl-warning)",
    "approved" => "var(--gl-success)",
    "denied" => "var(--gl-danger)",
    "done" => "var(--gl-accent-dim)",
    "high" => "var(--gl-danger)",
    "medium" => "var(--gl-warning)",
    "low" => "var(--gl-cyan)",
    "none" => "var(--gl-fg-muted)",
    "other" => "var(--gl-violet)"
  }

  defp default_color(key) when is_binary(key),
    do: Map.get(@palette, key, "var(--gl-accent-dim)")

  defp default_color(_), do: "var(--gl-accent-dim)"
end
