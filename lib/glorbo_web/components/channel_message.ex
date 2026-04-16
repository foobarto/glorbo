defmodule GlorboWeb.Components.ChannelMessage do
  @moduledoc """
  A single message row inside `ChannelLive` (UI-SPEC §Copy for ChannelLive).

  Meta row: `{author} · {timestamp}` in label-size muted text.
  Body: the pre-rendered HTML (from `GlorboWeb.Markdown.render/2`) —
  the caller is responsible for sanitization; this component interpolates
  the `{:safe, _}` tuple verbatim.
  """
  use Phoenix.Component

  attr :message, :map, required: true

  def channel_message(assigns) do
    ~H"""
    <article class="gl-channel-message">
      <header class="gl-channel-message__meta">
        <span>{@message.author}</span>
        <span>·</span>
        <span class="gl-tabular">{@message.timestamp}</span>
      </header>
      <div class="gl-channel-message__body">{@message.body_html}</div>
    </article>
    """
  end
end
