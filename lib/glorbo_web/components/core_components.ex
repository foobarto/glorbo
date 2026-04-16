defmodule GlorboWeb.CoreComponents do
  @moduledoc """
  Core UI components.

  Re-exports the nine-glyph `<.icon>` component from
  `GlorboWeb.Components.Icon` so templates can write `<.icon name="..."/>`
  without an explicit alias. All other dashboard components live in their
  own `GlorboWeb.Components.*` modules and are referenced via
  `<GlorboWeb.Components.X.y>` in HEEx.
  """
  use Phoenix.Component

  attr :name, :string, required: true
  attr :class, :string, default: "gl-icon"
  attr :label, :string, default: nil

  def icon(assigns), do: GlorboWeb.Components.Icon.icon(assigns)
end
