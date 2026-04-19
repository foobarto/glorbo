defmodule GlorboWeb.Components.ChatDrawer.State do
  @moduledoc """
  Helpers for LVs that host the bottom-docked chat drawer.

  Each LV already tracks `:current_company`. Add this to `mount/3`
  to load the drawer + subscribe to `#general` file-events:

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
  """

  import Phoenix.Component, only: [assign: 3]

  # Split channel messages `## <iso-ts> | <author>\n<body>` without
  # snagging markdown sub-headers inside message bodies — anchor on
  # the YYYY-MM-DD prefix of real timestamps. Matches
  # GlorboWeb.ChannelLive.@message_re.
  @message_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## \d{4}-|\z)/ms

  @doc """
  Subscribe to #general PubSub + load initial messages. Call this
  from `mount/3` after `:current_company` is assigned.
  """
  def wire_drawer(socket, opts \\ []) do
    base = Keyword.get(opts, :base, GlorboWeb.LiveHelpers.base_dir())
    co = socket.assigns[:current_company]

    if Phoenix.LiveView.connected?(socket) and is_binary(co) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels:general")
    end

    socket
    |> assign(:chat_drawer_base, base)
    |> assign(:chat_drawer_messages, load_messages(base, co))
  end

  @doc """
  If the file_event relative path is `channels/general.md`, reload
  drawer messages. Otherwise pass through unchanged.
  """
  def maybe_refresh_drawer(socket, rel) when is_binary(rel) do
    if rel == "channels/general.md" do
      base = socket.assigns[:chat_drawer_base] || GlorboWeb.LiveHelpers.base_dir()
      co = socket.assigns[:current_company]
      assign(socket, :chat_drawer_messages, load_messages(base, co))
    else
      socket
    end
  end

  def maybe_refresh_drawer(socket, _), do: socket

  @doc "Handle the drawer's compose submission."
  def post(%{assigns: %{current_company: co}} = socket, body) when is_binary(co) do
    trimmed = String.trim(body || "")

    if trimmed == "" do
      {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Message is empty.")}
    else
      case GlorboWeb.Actions.post_message(co, "general", trimmed) do
        :ok ->
          # Belt-and-braces: inotify → PubSub can miss the event under
          # load or on first write to a newly-created channel. Reload
          # directly so the user always sees their own message without
          # a page reload.
          base = socket.assigns[:chat_drawer_base] || GlorboWeb.LiveHelpers.base_dir()
          {:noreply, assign(socket, :chat_drawer_messages, load_messages(base, co))}

        {:error, :body_too_large} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Message exceeds 10 KB.")}

        {:error, _reason} ->
          {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Could not post message.")}
      end
    end
  end

  def post(socket, _body), do: {:noreply, socket}

  defp load_messages(_base, nil), do: []

  defp load_messages(base, co) when is_binary(co) do
    path = Path.join([base, "companies", co, "channels", "general.md"])

    case File.read(path) do
      {:ok, content} -> parse_messages(content, co)
      _ -> []
    end
  end

  defp parse_messages(content, company) do
    @message_re
    |> Regex.scan(content, capture: :all_names)
    |> Enum.map(fn [author, body, ts] ->
      %{
        author: String.trim(author),
        timestamp: String.trim(ts),
        body_html: GlorboWeb.Markdown.render(String.trim(body), company: company)
      }
    end)
    |> Enum.take(-200)
  end
end
