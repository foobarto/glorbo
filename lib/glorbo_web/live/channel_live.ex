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
       |> assign(:channels, list_channels(base, co))
       |> assign(:dm_threads, list_dm_threads(base, co))
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
      <GlorboWeb.Components.CompanyTabs.company_tabs slug={@company_slug} active={:chat} />
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">{"##{@channel}"}</h1>
      </header>

      <div :if={Phoenix.Flash.get(@flash, :error)} class="gl-banner gl-banner--muted" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </div>

      <div class="gl-channel__layout">
        <aside class="gl-channel__rail" aria-label="Channels">
          <h2 class="gl-panel__header">/channels</h2>
          <ul class="gl-channel-list">
            <li :for={c <- @channels}>
              <.link
                navigate={~p"/companies/#{@company_slug}/channels/#{c}"}
                class={channel_link_class(c, @channel)}
              >
                {"#" <> c}
              </.link>
            </li>
          </ul>
          <h2 class="gl-panel__header">/dms</h2>
          <ul :if={@dm_threads != []} class="gl-channel-list">
            <li :for={d <- @dm_threads} class="gl-channel-list__item">
              <span class="gl-muted">{d.a} ↔ {d.b}</span>
              <span class="gl-muted gl-tabular">{d.count}</span>
            </li>
          </ul>
          <p :if={@dm_threads == []} class="gl-muted gl-empty__hint">
            No DM threads yet.
          </p>
        </aside>

        <div class="gl-channel__main">
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
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp channel_path(base, company, channel),
    do: Path.join([base, "companies", company, "channels", "#{channel}.md"])

  defp channel_link_class(candidate, current) when candidate == current,
    do: "gl-channel-list__link gl-channel-list__link--active"

  defp channel_link_class(_, _), do: "gl-channel-list__link"

  defp list_channels(base, company) do
    dir = Path.join([base, "companies", company, "channels"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.rootname/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp list_dm_threads(base, company) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, agents} ->
        agents
        |> Enum.flat_map(&dm_files_for_agent(agents_dir, &1))
        |> Enum.map(&canonical_pair/1)
        |> Enum.reduce(%{}, fn pair, acc -> Map.update(acc, pair, 1, &(&1 + 1)) end)
        |> Enum.map(fn {{a, b}, count} -> %{a: a, b: b, count: count} end)
        |> Enum.sort_by(& &1.a)

      _ ->
        []
    end
  end

  defp dm_files_for_agent(agents_dir, sender) do
    outbox = Path.join([agents_dir, sender, "outbox"])

    case File.ls(outbox) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&parse_dm_filename(&1, sender))

      _ ->
        []
    end
  end

  # Filename convention: `<ts>-<recipient>.md`. Anything that doesn't
  # match is treated as non-DM traffic and skipped.
  defp parse_dm_filename(filename, sender) do
    case Regex.run(~r/^[^-]+-(.+)\.md$/, filename) do
      [_, recipient] -> [{sender, recipient}]
      _ -> []
    end
  end

  defp canonical_pair({a, b}) when a <= b, do: {a, b}
  defp canonical_pair({a, b}), do: {b, a}

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
