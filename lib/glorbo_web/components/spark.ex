defmodule GlorboWeb.Components.Spark do
  @moduledoc """
  Tiny SVG sparkline — horizontal bar chart at ~30 samples wide,
  terminal-TUI aesthetic (mockup: abc.zip shell.jsx:124-137).

  Data is a list of non-negative numbers. The bar chart fills its
  container height, with each bar scaled to `value / max`. Opacity
  also scales with the ratio so the strip reads as a fade rather
  than a hard-edged chart — mimics the CLI `pixelated` look.

  ## Attrs

    * `:data` — list of numbers (defaults to `[]`, renders nothing)
    * `:color` — CSS color token or var (defaults to `var(--gl-accent-dim)`)
    * `:label` — optional aria-label for screen readers; if given the
      SVG becomes `role="img"`, otherwise `role="presentation"`.
  """
  use Phoenix.Component

  attr :data, :list, default: []
  attr :color, :string, default: "var(--gl-accent-dim)"
  attr :label, :string, default: nil

  def spark(assigns) do
    bars = normalize(assigns[:data])
    assigns = assign(assigns, :bars, bars)

    ~H"""
    <div
      :if={@bars != []}
      class="gl-spark"
      role={if @label, do: "img", else: "presentation"}
      aria-label={@label}
    >
      <span
        :for={{ratio, idx} <- Enum.with_index(@bars)}
        class="gl-spark__bar"
        style={"height: #{Float.round(ratio * 100, 1)}%; background: #{@color}; opacity: #{Float.round(0.35 + 0.65 * ratio, 2)};"}
        data-idx={idx}
      ></span>
    </div>
    """
  end

  # Scale each value to 0.0..1.0 based on the list's max. Empty list
  # or all-zeros → empty list (component renders nothing).
  defp normalize([]), do: []

  defp normalize(values) when is_list(values) do
    max =
      values
      |> Enum.filter(&is_number/1)
      |> Enum.max(fn -> 0 end)

    if max > 0 do
      Enum.map(values, fn
        n when is_number(n) and n >= 0 -> n / max
        _ -> 0.0
      end)
    else
      []
    end
  end
end
