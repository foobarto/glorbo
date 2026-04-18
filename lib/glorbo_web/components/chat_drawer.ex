defmodule GlorboWeb.Components.ChatDrawer do
  @moduledoc """
  Persistent chat drawer docked to the bottom of the viewport.

  Always renders when a company is focused (has `current_company`).
  Tails `#general` for that company — swap-to-another-channel is a
  follow-up (#TBD). Shows a disabled placeholder when no company is
  focused (companies list / providers / health).

  ## Features

  - Drag the 4px top handle to resize (persisted to
    `localStorage['glorbo.chatdrawer.height']`).
  - Click the header to minimize (collapses to just the header bar,
    persisted to `localStorage['glorbo.chatdrawer.minimized']`).
  - Compose form posts to `GlorboWeb.Actions.post_message/4`.
  - Realtime updates via PubSub on `company:<co>:channels:general`.

  ## Assigns (driven by the parent LiveView)

  - `:current_company` — company slug or nil.
  - `:chat_drawer_messages` — list of `%{author, timestamp, body_html}`
    parsed from `channels/general.md`.

  Parents that want the drawer to show fresh messages subscribe to
  the PubSub topic + re-assign on `:file_event`. See
  `GlorboWeb.Components.ChatDrawer.State` for the shared LV
  implementation.
  """
  use Phoenix.Component

  attr :current_company, :string, default: nil
  attr :messages, :list, default: []

  def chat_drawer(assigns) do
    ~H"""
    <section
      id="gl-chat-drawer"
      class="gl-chat-drawer"
      phx-hook="ChatDrawer"
      data-no-company={is_nil(@current_company) && "1"}
    >
      <div class="gl-chat-drawer__handle" aria-label="Resize chat" role="separator" tabindex="0">
      </div>
      <header class="gl-chat-drawer__header">
        <div class="gl-chat-drawer__title">
          <span class="gl-chat-drawer__glyph" aria-hidden="true">◫</span>
          <%= if @current_company do %>
            <strong>#general</strong>
            <span class="gl-muted">· {@current_company}</span>
          <% else %>
            <strong>chat</strong>
            <span class="gl-muted">· pick a company to chat</span>
          <% end %>
        </div>
        <button
          type="button"
          class="gl-chat-drawer__toggle"
          id="gl-chat-drawer-toggle"
          aria-label="Minimize chat drawer"
        >
          <span class="gl-chat-drawer__toggle-glyph" aria-hidden="true">▾</span>
        </button>
      </header>
      <div class="gl-chat-drawer__body">
        <div :if={@current_company == nil} class="gl-chat-drawer__empty">
          <p class="gl-muted">
            Open a company from the sidebar to tail its <code>#general</code> channel here.
          </p>
        </div>

        <div :if={@current_company != nil and @messages == []} class="gl-chat-drawer__empty">
          <p class="gl-muted">
            No messages in <code>#general</code> yet. Say hi 👋
          </p>
        </div>

        <ol :if={@messages != []} class="gl-chat-drawer__messages" id="gl-chat-drawer-messages">
          <li
            :for={m <- @messages}
            class={[
              "gl-chat-drawer__message",
              director?(m.author) && "gl-chat-drawer__message--director"
            ]}
          >
            <div class="gl-chat-drawer__meta">
              <span class="gl-chat-drawer__author">{m.author}</span>
              <time class="gl-chat-drawer__ts">{short_ts(m.timestamp)}</time>
            </div>
            <div class="gl-chat-drawer__body-text">{Phoenix.HTML.raw(m.body_html)}</div>
          </li>
        </ol>

        <form
          :if={@current_company != nil}
          phx-submit="chat_drawer_post"
          class="gl-chat-drawer__compose"
        >
          <input
            type="text"
            name="body"
            id="gl-chat-drawer-input"
            maxlength="10240"
            class="gl-chat-drawer__input"
            placeholder="Message #general as Director…"
            autocomplete="off"
          />
          <button type="submit" class="gl-btn gl-btn--sm gl-btn--primary">send ↵</button>
        </form>
      </div>
    </section>
    """
  end

  defp director?(author), do: String.downcase(author || "") == "director"

  # Short form: "14:32" for same-day, "Apr 18 · 14:32" otherwise. The
  # drawer is space-constrained so we prefer terse.
  defp short_ts(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _} ->
        now = DateTime.utc_now()
        same_day? = Date.compare(DateTime.to_date(dt), DateTime.to_date(now)) == :eq

        if same_day? do
          String.slice(DateTime.to_iso8601(dt), 11..15)
        else
          String.slice(DateTime.to_iso8601(dt), 5..15)
        end

      _ ->
        raw
    end
  end

  defp short_ts(other), do: to_string(other)
end
