defmodule GlorboWeb.ChannelLive do
  @moduledoc """
  Per-channel chat view — GET `/companies/:company/channels/:channel` (D-25).

  Parses `channels/<channel>.md` by splitting on `## ` headers (the
  shape Elixir writes via `GlorboWeb.Actions.post_message/4` — Elixir
  is the sole writer per UI-03). Each message has author + ISO
  timestamp + body; the body flows through `GlorboWeb.Markdown.render/2`
  (mention pre-pass + earmark + sanitizer).

  Real-time propagation (UI-02): on `connected?/1` subscribes to
  `company:<co>:channels:<slug>`. Any file-event triggers a full
  re-read (the file is append-only, tail reads are cheap). No
  optimistic append (04-RESEARCH Pitfall 3 — the inotify path's
  ~200 ms round-trip is the only render source).

  Compose form: `phx-submit="post"` calls `GlorboWeb.Actions.post_message/4`,
  which performs its own slug + body validation and writes the file.
  The LiveView clears the compose textarea on success; error tuples
  surface via flash.
  """
  use GlorboWeb, :live_view
  require Logger
  alias GlorboWeb.Components.ChannelMessage

  # Splits `## <ts> | <author>\n<body>` entries. `body` captures until
  # the next `## ` header or EOF. Named captures return alphabetically:
  # [author, body, ts].
  @message_re ~r/^## (?<ts>[^|]+?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## |\z)/ms

  @impl true
  def mount(%{"company" => co, "channel" => ch}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not GlorboWeb.Slug.valid?(ch) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid channel identifier.")
         |> push_navigate(to: ~p"/companies/#{co}")}

      true ->
        mount_valid(co, ch, socket)
    end
  end

  defp mount_valid(co, ch, socket) do
    base = base_dir()
    path = channel_path(base, co, ch)

    if File.exists?(path) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:channels:#{ch}")
      end

      {:ok,
       socket
       |> assign(:page_title, "#{ch} — #{co} — Glorbo")
       |> assign(:current_company, co)
       |> assign(:company_slug, co)
       |> assign(:channel, ch)
       |> assign(:base, base)
       |> assign(:compose_body, "")
       |> assign(:messages, load_messages(path, co))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Channel \"#{ch}\" not found in #{co}.")
       |> push_navigate(to: ~p"/companies/#{co}")}
    end
  end

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    path = channel_path(socket.assigns.base, socket.assigns.company_slug, socket.assigns.channel)

    {:noreply, assign(socket, :messages, load_messages(path, socket.assigns.company_slug))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("post", %{"body" => body}, socket) do
    trimmed = String.trim(body)

    case GlorboWeb.Actions.post_message(
           socket.assigns.company_slug,
           socket.assigns.channel,
           trimmed,
           base: socket.assigns.base
         ) do
      :ok ->
        {:noreply, assign(socket, :compose_body, "")}

      {:error, :empty_body} ->
        {:noreply, put_flash(socket, :error, "Message is empty.")}

      {:error, :body_too_large} ->
        {:noreply, put_flash(socket, :error, "Message exceeds 10 KB.")}

      {:error, reason} ->
        # WR-08: never leak raw atoms (`:enoent`, `:eacces`, …) to the UI.
        # Log the underlying reason for operators; show a generic flash.
        Logger.warning("post_message failed",
          company: socket.assigns.company_slug,
          channel: socket.assigns.channel,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Could not post message.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-channel">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">{"##{@channel}"}</h1>
      </header>

      <div :if={Phoenix.Flash.get(@flash, :error)} class="gl-banner gl-banner--muted" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </div>

      <div :if={@messages == []} class="gl-empty">
        <p>{"No messages in ##{@channel} yet."}</p>
      </div>

      <div :if={@messages != []} class="gl-channel__messages">
        <ChannelMessage.channel_message :for={m <- @messages} message={m} />
      </div>

      <form phx-submit="post" class="gl-compose">
        <textarea
          name="body"
          maxlength="10240"
          class="gl-input"
          placeholder={"Message ##{@channel} as Director…"}
        >{@compose_body}</textarea>
        <div class="gl-compose__actions">
          <button type="submit" class="gl-btn gl-btn--primary">Send</button>
        </div>
      </form>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp channel_path(base, company, channel),
    do: Path.join([base, "companies", company, "channels", "#{channel}.md"])

  defp load_messages(path, company) do
    case File.read(path) do
      {:ok, content} -> parse_messages(content, company)
      _ -> []
    end
  end

  defp parse_messages(content, company) do
    # `capture: :all_names` returns each match as a list of values in
    # alphabetical order of the named-capture keys: [author, body, ts].
    @message_re
    |> Regex.scan(content, capture: :all_names)
    |> Enum.map(fn [author, body, ts] ->
      %{
        author: String.trim(author),
        timestamp: String.trim(ts),
        body_html: GlorboWeb.Markdown.render(String.trim(body), company: company)
      }
    end)
  end

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
