defmodule GlorboWeb.Components.ChannelMessage do
  @moduledoc """
  A single message row inside `ChannelLive` (UI-SPEC §Copy for ChannelLive).

  Meta row: `{author} · {relative-timestamp}` in label-size muted
  text. The raw ISO string stays available through the `<time
  datetime=>` attribute and as the `title` tooltip, so the exact
  instant is one hover away. The visible label uses
  `GlorboWeb.TimeFormat.relative/1` so Directors see "2 min ago",
  "yesterday", "2026-04-15" rather than
  `2026-04-17T10:30:00Z` (TODO.md P1).

  Body: the pre-rendered HTML (from `GlorboWeb.Markdown.render/2`) —
  the caller is responsible for sanitization; this component
  interpolates the `{:safe, _}` tuple verbatim.
  """
  use Phoenix.Component

  alias GlorboWeb.TimeFormat

  attr :message, :map, required: true

  def channel_message(assigns) do
    ~H"""
    <article class="gl-channel-message">
      <header class="gl-channel-message__meta">
        <span>{@message.author}</span>
        <span>·</span>
        <time
          class="gl-tabular"
          datetime={TimeFormat.iso(@message.timestamp)}
          title={TimeFormat.iso(@message.timestamp)}
        >
          {TimeFormat.relative(@message.timestamp)}
        </time>
      </header>
      <div class="gl-channel-message__body">{@message.body_html}</div>
    </article>
    """
  end
end
