defmodule GlorboWeb.Components.ChatDrawer.State do
  @moduledoc """
  Helpers for LVs that host the bottom-docked chat drawer.

  Each LV already tracks `:current_company`. Add this to `mount/3`
  to load the drawer + subscribe to the current channel's file-events:

      {:ok, socket
           |> assign(:current_company, slug)
           |> ChatDrawer.State.wire_drawer()}

  Then in `handle_info({:file_event, rel, _}, socket)`, route the
  drawer's rel paths through `maybe_refresh_drawer/2`:

      def handle_info({:file_event, rel, _} = msg, socket) do
        socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel)
        ...
      end

  And wire the compose form:

      def handle_event("chat_drawer_post", %{"body" => body}, socket),
        do: ChatDrawer.State.post(socket, body)

  Channel switching (`chat_drawer_channel`) is handled centrally by the
  `on_mount/4` hook below — wired once on the dashboard `live_session`,
  so no per-LV `handle_event` clause is needed (and the 19 hosts can't
  drift). The drawer tails one channel at a time, defaulting to
  `#general`; the selector swaps it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Glorbo.ChannelLog
  alias Glorbo.Filesystem.AgentWritableFile

  @default_channel "general"

  # `channels/<name>.md` is agent-influenced (any agent with chat write
  # appends to it) and grows without bound. The drawer renders only the
  # last ~200 messages, so reading the whole file just to throw most of
  # it away is an O(file bytes) regex + markdown DoS on every
  # company-page mount + channel file_event. Read only the last 256 KiB
  # tail before scanning — far more than 200 messages of real chat, but
  # a hard ceiling on parse/render work.
  @tail_bytes 262_144

  # Parsed via `Glorbo.ChannelLog` (see ChannelLive).

  @doc "The channel the drawer is currently tailing (defaults to #general)."
  def current_channel(socket), do: socket.assigns[:chat_drawer_channel] || @default_channel

  @doc """
  Subscribe to the current channel's PubSub topic + load initial
  messages + the channel list for the selector. Call this from
  `mount/3` after `:current_company` is assigned.
  """
  def wire_drawer(socket, opts \\ []) do
    base = Keyword.get(opts, :base, GlorboWeb.LiveHelpers.base_dir())
    co = socket.assigns[:current_company]
    channel = current_channel(socket)

    if Phoenix.LiveView.connected?(socket) and is_binary(co) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, channel_topic(co, channel))
    end

    socket
    |> assign(:chat_drawer_base, base)
    |> assign(:chat_drawer_channel, channel)
    |> assign(:chat_drawer_channels, list_channels(base, co))
    |> assign(:chat_drawer_messages, load_messages(base, co, channel))
  end

  @doc """
  If the file_event relative path is the current channel's file, reload
  drawer messages. Otherwise pass through unchanged.
  """
  def maybe_refresh_drawer(socket, rel) when is_binary(rel) do
    if rel == "channels/#{current_channel(socket)}.md" do
      base = socket.assigns[:chat_drawer_base] || GlorboWeb.LiveHelpers.base_dir()
      co = socket.assigns[:current_company]
      assign(socket, :chat_drawer_messages, load_messages(base, co, current_channel(socket)))
    else
      socket
    end
  end

  def maybe_refresh_drawer(socket, _), do: socket

  @doc "Handle the drawer's compose submission — posts to the current channel."
  def post(%{assigns: %{current_company: co}} = socket, body) when is_binary(co) do
    trimmed = String.trim(body || "")
    channel = current_channel(socket)

    if trimmed == "" do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Message is empty.")}
    else
      case Glorbo.Actions.post_message(co, channel, trimmed, actor: "director") do
        :ok ->
          # Belt-and-braces: inotify → PubSub can miss the event under
          # load or on first write to a newly-created channel. Reload
          # directly so the user always sees their own message without
          # a page reload.
          base = socket.assigns[:chat_drawer_base] || GlorboWeb.LiveHelpers.base_dir()
          {:noreply, assign(socket, :chat_drawer_messages, load_messages(base, co, channel))}

        {:error, :body_too_large} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Message exceeds 10 KB.")}

        {:error, _reason} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not post message.")}
      end
    end
  end

  def post(socket, _body), do: {:noreply, socket}

  @doc """
  Switch the drawer to another channel: validate it against the
  company's real channels (rejects path traversal / unknown names),
  swap the PubSub subscription, and reload. A no-op if the company is
  unset, the name is invalid, or it's already the current channel —
  which also makes the localStorage restore-on-nav safe across
  companies (a channel that doesn't exist here is simply ignored).
  """
  def switch_channel(%{assigns: %{current_company: co}} = socket, channel)
      when is_binary(co) and is_binary(channel) do
    current = current_channel(socket)
    base = socket.assigns[:chat_drawer_base] || GlorboWeb.LiveHelpers.base_dir()

    cond do
      channel == current ->
        socket

      not valid_channel?(base, co, channel) ->
        socket

      true ->
        # Subscribe to the new channel, but do NOT unsubscribe from the
        # old one (codex #75): PubSub subscriptions are per-PROCESS, and
        # the drawer shares its LiveView process with the host page. On
        # `ChannelLive`, the page already subscribes to its own
        # `company:<co>:channels:<ch>`; unsubscribing here would drop the
        # page's realtime updates too. `maybe_refresh_drawer/2` ignores
        # events for any channel other than the current one, so a leftover
        # subscription only delivers harmlessly-ignored messages (and the
        # whole set is torn down when the LiveView process exits on nav).
        if Phoenix.LiveView.connected?(socket) do
          Phoenix.PubSub.subscribe(Glorbo.PubSub, channel_topic(co, channel))
        end

        socket
        |> assign(:chat_drawer_channel, channel)
        |> assign(:chat_drawer_messages, load_messages(base, co, channel))
    end
  end

  def switch_channel(socket, _channel), do: socket

  @doc """
  `on_mount` hook (wired once on the dashboard `live_session`) that
  attaches a `handle_event` interceptor for `chat_drawer_channel`, so
  the selector works on every page without a per-LV clause.
  """
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :chat_drawer_channel, :handle_event, &handle_event/3)}
  end

  defp handle_event("chat_drawer_channel", %{"channel" => channel}, socket) do
    {:halt, switch_channel(socket, channel)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ---------------------------------------------------------------------------

  defp channel_topic(co, channel), do: "company:#{co}:channels:#{channel}"

  defp valid_channel?(base, co, channel) do
    Glorbo.Slug.valid?(channel) and channel in list_channels(base, co)
  end

  # Public, non-DM channels for this company, for the selector. Mirrors
  # `GlorboWeb.ChannelLive.list_channels/2`.
  defp list_channels(_base, nil), do: []

  defp list_channels(base, co) when is_binary(co) do
    dir = Path.join([base, "companies", co, "channels"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.reject(&String.starts_with?(&1, "dm-director--"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp load_messages(_base, nil, _channel), do: []

  defp load_messages(base, co, channel) when is_binary(co) and is_binary(channel) do
    path = Path.join([base, "companies", co, "channels", "#{channel}.md"])

    # tail-read drops a leading partial message on truncation; the
    # @message_re anchor only matches from a `## <YYYY-MM-DD ts> | author`
    # header, so the partial is discarded by parse_messages.
    case AgentWritableFile.read_tail(path, @tail_bytes) do
      {:ok, content} -> parse_messages(content, co)
      _ -> []
    end
  end

  defp parse_messages(content, company) do
    content
    |> ChannelLog.parse_messages()
    |> Enum.map(fn msg ->
      %{
        author: msg.author,
        provenance: msg.provenance,
        timestamp: msg.timestamp,
        body_html: GlorboWeb.Markdown.render(msg.body, company: company)
      }
    end)
    |> Enum.take(-200)
  end
end
