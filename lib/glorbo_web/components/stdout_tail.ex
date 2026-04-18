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

  attr :empty_hint, :string,
    default:
      "No output yet. This agent hasn't been invoked — click \"wake now\" above, or wait for the next heartbeat tick."

  def stdout_tail(assigns) do
    ~H"""
    <div class="gl-stdout-tail" id="stdout-tail-wrap">
      <div id="stdout-tail" phx-update="stream">
        <div
          :for={{dom_id, line} <- @stream}
          id={dom_id}
          class={[
            "gl-stdout-tail__line",
            line_kind_class(Map.get(line, :kind))
          ]}
        >
          <%= case Map.get(line, :kind) do %>
            <% :header -> %>
              <span class="gl-stdout-tail__marker">dispatch</span>
              <time class="gl-stdout-tail__ts gl-muted">{Map.get(line, :ts, "")}</time>
            <% :exit -> %>
              <span class="gl-stdout-tail__marker">exit</span>
              <span class={[
                "gl-stdout-tail__exit-code",
                exit_code_class(Map.get(line, :exit_code))
              ]}>
                {Map.get(line, :exit_code, "?")}
              </span>
            <% _ -> %>
              {line.body}
          <% end %>
        </div>
      </div>
      <div class="gl-stdout-tail__empty gl-muted" id="stdout-tail-empty">
        {@empty_hint}
      </div>
    </div>
    """
  end

  defp line_kind_class(:header), do: "gl-stdout-tail__line--header"
  defp line_kind_class(:exit), do: "gl-stdout-tail__line--exit"
  defp line_kind_class(_), do: nil

  defp exit_code_class("0"), do: "gl-stdout-tail__exit-code--ok"
  defp exit_code_class(_), do: "gl-stdout-tail__exit-code--err"
end
