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
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
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
       |> assign(:archives, list_archive_segments(base, co, ch))
       |> assign(:open_archive, nil)
       |> assign(:open_archive_messages, [])
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

    {:noreply,
     socket
     |> assign(:messages, load_messages(path, socket.assigns.company_slug))
     |> assign(
       :archives,
       list_archive_segments(
         socket.assigns.base,
         socket.assigns.company_slug,
         socket.assigns.channel
       )
     )}
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, assign(socket, :_agent_status_tick, System.unique_integer([:positive]))}
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

        content =
          """
          ---
          kind: channel-log/v1
          channel: #{normalized}
          ---
          # ##{normalized}

          """

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

  # Archive names are generated by rotator as ISO-derived strings (only
  # digits + `-`), so reject anything else at the boundary to prevent
  # path-traversal via handcrafted phx-value-name payloads.
  @archive_name_regex ~r/\A[0-9a-zA-Z][-0-9a-zA-Z]{0,63}\z/

  def handle_event("open_archive", %{"name" => name}, socket) do
    if Regex.match?(@archive_name_regex, name) do
      path =
        archive_segment_path(
          socket.assigns.base,
          socket.assigns.company_slug,
          socket.assigns.channel,
          name
        )

      if File.exists?(path) do
        {:noreply,
         socket
         |> assign(:open_archive, name)
         |> assign(:open_archive_messages, load_messages(path, socket.assigns.company_slug))}
      else
        {:noreply, put_flash(socket, :error, "Archive segment not found.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Invalid archive segment name.")}
    end
  end

  def handle_event("close_archive", _, socket) do
    {:noreply, socket |> assign(:open_archive, nil) |> assign(:open_archive_messages, [])}
  end

  def handle_event("archive_channel", _params, socket) do
    channel = socket.assigns.channel
    company = socket.assigns.company_slug
    base = socket.assigns.base

    if archivable?(channel) do
      do_archive(base, company, channel, socket)
    else
      {:noreply,
       put_flash(socket, :error, "Can't archive ##{channel} — it's a canonical channel.")}
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
        # Belt-and-braces: inotify → PubSub can miss under load (esp. on
        # first write to a newly-created channel). Reload directly.
        path =
          channel_path(socket.assigns.base, socket.assigns.company_slug, socket.assigns.channel)

        {:noreply,
         socket
         |> assign(:compose_body, "")
         |> assign(:messages, load_messages(path, socket.assigns.company_slug))}

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
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">{channel_heading(@channel)}</h1>
        <div :if={archivable?(@channel)} class="gl-channel__actions">
          <button
            type="button"
            class="gl-btn gl-btn--sm gl-btn--ghost"
            phx-click="archive_channel"
            data-confirm={"Archive ##{@channel}? The markdown file moves to channels/.archive/; you can restore it by moving the file back."}
          >
            ⎘ archive
          </button>
        </div>
      </header>

      <div :if={Phoenix.Flash.get(@flash, :error)} class="gl-banner gl-banner--muted" role="alert">
        {Phoenix.Flash.get(@flash, :error)}
      </div>

      <div class="gl-channel__layout">
        <aside class="gl-channel__rail" aria-label="Chat">
          <h2 class="gl-panel__header">/chat</h2>
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
              pattern="[a-z0-9][-a-z0-9]*"
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
                {d.agent}
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

          <details :if={@archives != []} class="gl-channel__archives">
            <summary class="gl-channel__archives-summary">
              <span class="gl-channel__archives-glyph" aria-hidden="true">🗂</span>
              {length(@archives)} archived segment{if length(@archives) == 1, do: "", else: "s"} — click to browse
            </summary>
            <ul class="gl-channel__archives-list">
              <li :for={a <- @archives} class="gl-channel__archives-row">
                <button
                  type="button"
                  class="gl-btn gl-btn--ghost gl-btn--sm"
                  phx-click="open_archive"
                  phx-value-name={a.name}
                  aria-expanded={to_string(@open_archive == a.name)}
                >
                  {a.label}
                </button>
                <span class="gl-muted gl-channel__archives-meta">
                  {a.size_h} · {a.message_count} msgs
                </span>
              </li>
            </ul>
            <div :if={@open_archive} class="gl-channel__archives-viewer">
              <header class="gl-channel__archives-viewer-head">
                <strong>{@open_archive}</strong>
                <button
                  type="button"
                  class="gl-btn gl-btn--sm gl-btn--ghost"
                  phx-click="close_archive"
                >
                  close ×
                </button>
              </header>
              <div class="gl-channel__messages gl-channel__messages--archive">
                <ChannelMessage.channel_message
                  :for={m <- @open_archive_messages}
                  message={m}
                />
              </div>
            </div>
          </details>

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
              <span class="gl-compose__prompt-user">director</span><span class="gl-compose__prompt-dim">@</span><span class="gl-compose__prompt-co">{@company_slug}</span><span class="gl-compose__prompt-dim">:</span><span class="gl-compose__prompt-channel">#{@channel}</span><span class="gl-compose__prompt-dim">$</span>
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
          <div class="gl-compose__hint" aria-hidden="true">
            <kbd>@</kbd> mention · <kbd>/</kbd> slash · <kbd>⏎</kbd> send · <kbd>⇧⏎</kbd> newline
          </div>
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

  # #238 UI — list rotated segments under channels/archive/<channel>/.
  # Newest-first so directors see recent history on top.
  defp list_archive_segments(base, company, channel) do
    dir = Path.join([base, "companies", company, "channels", "archive", channel])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort(:desc)
        |> Enum.map(&summarise_archive(dir, &1))

      _ ->
        []
    end
  end

  defp summarise_archive(dir, filename) do
    path = Path.join(dir, filename)
    name = Path.basename(filename, ".md")

    {size_bytes, count} =
      case File.read(path) do
        {:ok, content} ->
          {byte_size(content), count_headers(content)}

        _ ->
          {0, 0}
      end

    %{
      name: name,
      label: humanise_archive_label(name),
      size_h: humanise_bytes(size_bytes),
      message_count: count
    }
  end

  @archive_header_regex ~r/^## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/m

  defp count_headers(content),
    do: Regex.scan(@archive_header_regex, content) |> length()

  # Archive filenames look like `2026-04-21-10-00-00Z.md`
  # (ts with `T` / `:` / `.` replaced by `-`). We display the
  # original-ish ISO8601 form for readability.
  defp humanise_archive_label(name) do
    case Regex.run(~r/\A(\d{4}-\d{2}-\d{2})-(\d{2})-(\d{2})-(\d{2})/, name) do
      [_, date, hh, mm, ss] -> "#{date} #{hh}:#{mm}:#{ss}Z"
      _ -> name
    end
  end

  defp humanise_bytes(n) when n < 1024, do: "#{n} B"
  defp humanise_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp humanise_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  defp archive_segment_path(base, company, channel, name) do
    Path.join([
      base,
      "companies",
      company,
      "channels",
      "archive",
      channel,
      "#{name}.md"
    ])
  end

  defp channel_link_class(candidate, current) when candidate == current,
    do: "gl-channel-list__link gl-channel-list__link--active"

  defp channel_link_class(_, _), do: "gl-channel-list__link"

  # `general` is the Director's catch-all + the chat drawer's backing
  # channel. DM channels (`dm-director--<agent>`) are owned by their
  # threads and should also not be archived from this UI.
  defp archivable?("general"), do: false

  defp archivable?(slug) when is_binary(slug) do
    not String.starts_with?(slug, "dm-director--")
  end

  defp archivable?(_), do: false

  defp do_archive(base, company, channel, socket) do
    src = channel_path(base, company, channel)
    archive_dir = Path.join([base, "companies", company, "channels", ".archive"])
    dst = Path.join(archive_dir, "#{channel}.md")

    with :ok <- File.mkdir_p(archive_dir),
         :ok <- File.rename(src, dst) do
      {:noreply,
       socket
       |> put_flash(:info, "Archived ##{channel}. Moved to channels/.archive/#{channel}.md.")
       |> push_navigate(to: ~p"/companies/#{company}/channels/general")}
    else
      {:error, reason} ->
        Logger.warning("archive_channel failed",
          company: company,
          channel: channel,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Could not archive channel.")}
    end
  end

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
        |> Enum.reject(&String.starts_with?(&1, "."))
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

  defp channel_heading("dm-director--" <> agent), do: "DM · #{agent}"
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
