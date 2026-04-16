defmodule GlorboWeb.Components.Icon do
  @moduledoc """
  Nine-glyph inline-SVG icon set (D-03, 04-UI-SPEC §Iconography).

  `check`, `x`, `play`, `pause`, `user`, `folder`, `message`, `lightning`,
  `pulse`. Every glyph renders with `viewBox="0 0 16 16"`, `stroke-width="1.5"`,
  `stroke="currentColor"`, `fill="none"` (except lightning which is
  geometrically filled).

  Usage:

      <.icon name="folder" />
      <.icon name="check" label="Approve" />

  * `aria-hidden="true"` by default (decorative).
  * When `label` is set, `role="img"` and `<title>` are emitted for screen
    readers (04-UI-SPEC Accessibility table).
  * Unknown glyphs render as empty `<svg/>` with `data-icon-missing="true"`
    — a development hint rather than a crash.
  """
  use Phoenix.Component

  attr :name, :string, required: true
  attr :class, :string, default: "gl-icon"
  attr :label, :string, default: nil

  def icon(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 16 16"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      stroke-width="1.5"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden={if @label, do: "false", else: "true"}
      role={if @label, do: "img", else: "presentation"}
      data-icon-missing={missing?(@name)}
    >
      <title :if={@label}>{@label}</title>
      {glyph(@name)}
    </svg>
    """
  end

  defp glyph("check"),
    do: Phoenix.HTML.raw(~s(<polyline points="3,8.5 6.5,12 13,4.5"/>))

  defp glyph("x"),
    do:
      Phoenix.HTML.raw(
        ~s(<line x1="3" y1="3" x2="13" y2="13"/><line x1="13" y1="3" x2="3" y2="13"/>)
      )

  defp glyph("play"),
    do: Phoenix.HTML.raw(~s(<polygon points="4,3 4,13 13,8" fill="currentColor"/>))

  defp glyph("pause"),
    do:
      Phoenix.HTML.raw(
        ~s(<rect x="4" y="3" width="3" height="10" fill="currentColor"/><rect x="9" y="3" width="3" height="10" fill="currentColor"/>)
      )

  defp glyph("user"),
    do:
      Phoenix.HTML.raw(
        ~s(<circle cx="8" cy="5" r="3"/><path d="M2,14 C3,11 5,10 8,10 C11,10 13,11 14,14"/>)
      )

  defp glyph("folder"),
    do: Phoenix.HTML.raw(~s(<path d="M1.5,4.5 L6.5,4.5 L8,6 L14.5,6 L14.5,13 L1.5,13 Z"/>))

  defp glyph("message"),
    do: Phoenix.HTML.raw(~s(<path d="M2,3 L14,3 L14,11 L6,11 L3,14 L3,11 L2,11 Z"/>))

  defp glyph("lightning"),
    do:
      Phoenix.HTML.raw(
        ~s(<polygon points="9,1 3,9 7,9 5,15 13,6 9,6 11,1" fill="currentColor" stroke="none"/>)
      )

  defp glyph("pulse"),
    do: Phoenix.HTML.raw(~s(<polyline points="1,8 4,8 6,3 10,13 12,8 15,8"/>))

  defp glyph(_), do: Phoenix.HTML.raw("")

  defp missing?(name) do
    case name do
      n when n in ~w(check x play pause user folder message lightning pulse) -> nil
      _ -> "true"
    end
  end
end
