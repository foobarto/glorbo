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
  import GlorboWeb.LiveHelpers, only: [base_dir: 0]
  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.ChannelMessage

  # Splits `## <iso8601-ts> | <author>\n<body>` entries. Body may contain
  # markdown sub-headers (`## Sub-heading`) which we DON'T want to treat
  # as message boundaries — so the lookahead and the header anchor both
  # require an ISO date (YYYY-MM-DD) prefix before the `|` separator.
  # Named captures return alphabetically: [author, body, ts].
  @message_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*\n(?<body>.*?)(?=\n## \d{4}-|\z)/ms

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
       |> assign(:sidebar_active, :chat)
       |> assign(:current_company, co)
       |> assign(:company_slug, co)
       |> assign(:channel, ch)
       |> assign(:base, base)
       |> assign(:compose_body, "")
       |> assign(:channels, list_channels(base, co))
       |> assign(:dm_threads, list_dm_threads(base, co))
       |> assign(:messages, load_messages(path, co))
       |> assign(:new_channel_slug, "")
       |> ChatDrawer.State.wire_drawer()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Channel \"#{ch}\" not found in #{co}.")
       |> push_navigate(to: ~p"/companies/#{co}")}
    end
  end

  @impl true
  def handle_info({:file_event, rel, _events}, socket) do
    socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel)
    path = channel_path(socket.assigns.base, socket.assigns.company_slug, socket.assigns.channel)

    {:noreply, assign(socket, :messages, load_messages(path, socket.assigns.company_slug))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("create_channel", %{"slug" => slug}, socket) do
    normalized = String.trim(slug || "")

    cond do
      not GlorboWeb.Slug.valid?(normalized) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Channel name must be lowercase letters / digits / dashes (starts with a letter or digit)."
         )}

      File.exists?(channel_path(socket.assigns.base, socket.assigns.company_slug, normalized)) ->
        {:noreply, put_flash(socket, :error, "Channel ##{normalized} already exists.")}

      true ->
        path = channel_path(socket.assigns.base, socket.assigns.company_slug, normalized)
        content = "# #" <> normalized <> "\n\n"

        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(path, content) do
          {:noreply,
           socket
           |> assign(:new_channel_slug, "")
           |> push_navigate(
             to: ~p"/companies/#{socket.assigns.company_slug}/channels/#{normalized}"
           )}
        else
          {:error, reason} ->
            Logger.warning("create_channel failed",
              company: socket.assigns.company_slug,
              channel: normalized,
              reason: inspect(reason)
            )

            {:noreply, put_flash(socket, :error, "Could not create channel.")}
        end
    end
  end

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
    <section class="gl-view gl-view--tall gl-channel">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">{channel_heading(@channel)}</h1>
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
          <form phx-submit="create_channel" class="gl-channel-create">
            <input
              type="text"
              name="slug"
              value={@new_channel_slug}
              class="gl-input gl-input--sm"
              maxlength="64"
              pattern="[a-z0-9][a-z0-9-]*"
              title="Lowercase letters, digits, and dashes"
              placeholder="+ new channel"
              aria-label="New channel name"
              autocomplete="off"
            />
          </form>
          <h2 class="gl-panel__header">/dms</h2>
          <ul :if={@dm_threads != []} class="gl-channel-list">
            <li :for={d <- @dm_threads}>
              <.link
                navigate={~p"/companies/#{@company_slug}/dms/#{d.agent}"}
                class={[
                  "gl-channel-list__link",
                  dm_counterparty(@channel) == d.agent && "gl-channel-list__link--active",
                  not d.started && "gl-channel-list__link--faded"
                ]}
              >
                director ↔ {d.agent}
              </.link>
            </li>
          </ul>
          <p :if={@dm_threads == []} class="gl-muted gl-empty__hint">
            No agents yet.
          </p>
        </aside>

        <div class="gl-channel__main">
          <div :if={@messages == []} class="gl-empty">
            <p>{empty_state(@channel)}</p>
          </div>

          <div
            :if={@messages != []}
            class="gl-channel__messages"
            id="gl-channel-messages"
            phx-hook="TailPin"
          >
            <ChannelMessage.channel_message :for={m <- @messages} message={m} />
          </div>

          <form phx-submit="post" class="gl-compose">
            <span class="gl-compose__prompt" aria-hidden="true">
              director@{@channel} ▸
            </span>
            <textarea
              name="body"
              maxlength="10240"
              class="gl-compose__input"
              placeholder={compose_placeholder(@channel)}
              rows="1"
              id="gl-compose-input"
              phx-hook="SubmitOnEnter"
            >{@compose_body}</textarea>
            <button type="submit" class="gl-btn gl-btn--sm gl-btn--primary">send ↵</button>
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
        # Hide Director-side DM channels from the public list — they
        # have their own rail below.
        |> Enum.reject(&String.starts_with?(&1, "dm-director--"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  # DM rail data: every agent on disk gets a row. `:started` indicates
  # whether a `channels/dm-director--<agent>.md` file already exists
  # (i.e. someone has posted into the thread), so the UI can fade
  # never-contacted agents.
  defp list_dm_threads(base, company) do
    agents_dir = Path.join([base, "companies", company, "agents"])
    channels_dir = Path.join([base, "companies", company, "channels"])

    case File.ls(agents_dir) do
      {:ok, agents} ->
        agents
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.map(fn slug ->
          %{
            agent: slug,
            started: File.exists?(Path.join(channels_dir, "dm-director--#{slug}.md"))
          }
        end)

      _ ->
        []
    end
  end

  defp dm_counterparty("dm-director--" <> agent), do: agent
  defp dm_counterparty(_), do: nil

  defp channel_heading("dm-director--" <> agent), do: "DM · director ↔ #{agent}"
  defp channel_heading(ch), do: "##{ch}"

  defp empty_state("dm-director--" <> agent), do: "No messages with #{agent} yet."
  defp empty_state(ch), do: "No messages in ##{ch} yet."

  defp compose_placeholder("dm-director--" <> agent),
    do: "Message #{agent} as Director…"

  defp compose_placeholder(ch), do: "Message ##{ch} as Director…"

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
end
