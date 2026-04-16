defmodule GlorboWeb.Components.StdoutTail do
  @moduledoc """
  Rolling stdout tail (D-15, 04-UI-SPEC §StdoutTail).

  Consumes a LiveView stream (`stream/4` with `limit: -1000`) and
  renders each line as a `<div>` inside a `phx-update="stream"`
  container. Line-numbering + autoscroll pinning are CSS concerns
  owned by 04-03's `app.css`; this component is pure DOM plumbing.

  Props:

    * `:stream` — required, the LiveView stream assign
      (`@streams.stdout`).
    * `:paused` — boolean, defaults to `false`.
  """
  use Phoenix.Component

  attr :stream, :any, required: true
  attr :paused, :boolean, default: false

  def stdout_tail(assigns) do
    ~H"""
    <div class="gl-stdout-tail" id="stdout-tail" phx-update="stream">
      <div
        :for={{dom_id, line} <- @stream}
        id={dom_id}
        class="gl-stdout-tail__line"
      >
        {line.body}
      </div>
    </div>
    """
  end
end
