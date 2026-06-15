defmodule GlorboWeb.Components.ChatDrawer do
  @moduledoc """
  Quake-console chat drawer docked to the bottom of the viewport
  (GEP-30). Minimized by default on every page — a single-row summary
  bar (company:#general · unread count). Toggle with `Ctrl+`` (or
  whatever keybind the user stored under `glorbo.chatdrawer.toggle_key`
  in localStorage) to slide up the full transcript + composer.

  Always renders when a company is focused (has `current_company`).
  Tails one channel at a time (default `#general`); the header
  `<select>` swaps it — the `chat_drawer_channel` event is handled
  centrally by `ChatDrawer.State`'s `on_mount` hook, and the choice is
  persisted to `localStorage` so it survives the per-navigation
  re-mount. Shows a disabled placeholder when no company is focused
  (companies list / providers / health).

  ## Features

  - Minimized by default (thin header bar). The `ChatDrawer` hook
    slides it up when the user presses the configured toggle key.
  - Drag the 4px top handle to resize (persisted to
    `localStorage['glorbo.chatdrawer.height']`).
  - Click the header or press the keybind to toggle minimize
    (persisted to `localStorage['glorbo.chatdrawer.minimized']`).
  - Compose renders as an IRC-style prompt
    `director@<co>:#general$ <input>`.
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
  attr :current_channel, :string, default: "general"
  attr :channels, :list, default: []
  attr :messages, :list, default: []

  def chat_drawer(assigns) do
    ~H"""
    <section
      id="gl-chat-drawer"
      class="gl-chat-drawer gl-chat-drawer--minimized"
      phx-hook="ChatDrawer"
      data-no-company={is_nil(@current_company) && "1"}
      data-channel={@current_channel}
    >
      <div class="gl-chat-drawer__handle" aria-label="Resize chat" role="separator" tabindex="0">
      </div>
      <header class="gl-chat-drawer__header">
        <div class="gl-chat-drawer__title">
          <span class="gl-chat-drawer__glyph" aria-hidden="true">^</span>
          <%= if @current_company do %>
            <span class="gl-chat-drawer__co">{@current_company}</span><span class="gl-chat-drawer__sep">:</span>
            <%= if length(@channels) > 1 do %>
              <form
                id="gl-chat-drawer-channel-form"
                phx-change="chat_drawer_channel"
                class="gl-chat-drawer__channel-form"
              >
                <select
                  name="channel"
                  class="gl-chat-drawer__channel-select"
                  aria-label="Switch channel"
                ><option :for={ch <- @channels} value={ch} selected={ch == @current_channel}>
                  {"#" <> ch}
                </option></select>
              </form>
            <% else %>
              <span class="gl-chat-drawer__channel">{"#" <> @current_channel}</span>
            <% end %>
          <% else %>
            <strong>chat</strong>
            <span class="gl-muted">· pick a company to chat</span>
          <% end %>
        </div>
        <div class="gl-chat-drawer__hint">
          <kbd class="gl-chat-drawer__kbd">Ctrl+`</kbd>
          <span class="gl-chat-drawer__hint-label">toggle</span>
          <button
            type="button"
            class="gl-chat-drawer__toggle"
            id="gl-chat-drawer-toggle"
            aria-label="Toggle chat drawer"
          >
            <span class="gl-chat-drawer__toggle-glyph" aria-hidden="true">▴</span>
          </button>
        </div>
      </header>
      <div class="gl-chat-drawer__body">
        <div :if={@current_company == nil} class="gl-chat-drawer__empty">
          <p class="gl-muted">
            Open a company from the sidebar to tail its <code>#general</code> channel here.
          </p>
        </div>

        <div :if={@current_company != nil and @messages == []} class="gl-chat-drawer__empty">
          <p class="gl-muted">
            No messages in <code>{"#" <> @current_channel}</code> yet. Say hi 👋
          </p>
        </div>

        <ol
          :if={@messages != []}
          class="gl-chat-drawer__messages"
          id="gl-chat-drawer-messages"
          phx-hook="TailPin"
        >
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
          phx-hook="ResetOnSubmit"
          id="gl-chat-drawer-form"
          class="gl-chat-drawer__compose"
        >
          <span class="gl-chat-drawer__prompt" aria-hidden="true">
            <span class="gl-chat-drawer__prompt-user">director</span><span class="gl-chat-drawer__prompt-dim">@</span><span class="gl-chat-drawer__prompt-co">{@current_company}</span><span class="gl-chat-drawer__prompt-dim">:</span><span class="gl-chat-drawer__prompt-channel">{"#" <>
              @current_channel}</span><span class="gl-chat-drawer__prompt-dim">$</span>
          </span>
          <input
            type="text"
            name="body"
            id="gl-chat-drawer-input"
            phx-hook="MentionAutocomplete"
            maxlength="10240"
            class="gl-chat-drawer__input"
            placeholder=""
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
