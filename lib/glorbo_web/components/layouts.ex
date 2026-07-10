defmodule GlorboWeb.Layouts do
  @moduledoc """
  Application layouts.

  Two templates live under `layouts/`:

    * `root.html.heex` — HTML envelope (doctype, `<head>`, CSRF meta,
      `<.live_title>`, asset links). Rendered by the browser pipeline
      via `put_root_layout`.
    * `app.html.heex` — responsive dashboard shell. CSS-grid 260px
      sidebar + main pane on wide screens; narrow screens collapse the
      sidebar into a toggleable overlay. Rendered inside `root.html.heex`
      when an LV or controller specifies `{GlorboWeb.Layouts, :app}` as
      its layout.
  """
  use GlorboWeb, :html

  embed_templates "layouts/*"

  @doc """
  LiveView mount hook — seeds default assigns the `app.html.heex`
  layout expects. LVs may override `:current_company` / `:sidebar_health`
  in their own `mount/3`.
  """
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> Phoenix.Component.assign_new(:current_company, fn -> nil end)
      |> Phoenix.Component.assign_new(:sidebar_health, fn -> %{alerts: 0, crashed: 0} end)

    {:cont, socket}
  end
end
