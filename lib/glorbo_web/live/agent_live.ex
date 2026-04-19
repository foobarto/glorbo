defmodule GlorboWeb.AgentLive do
  @moduledoc """
  Agent detail view — GET `/companies/:company/agents/:agent` (M3 rewrite).

  Matches the mockup (abc.zip views/agent.jsx) — a three-column layout
  that treats this as the signature view of the dashboard.

  ## Columns

  **Left** — identity card + workspace file tree. Tree walks
  `agents/<slug>/workspace/` and annotates each entry with its
  bind-mount class (`rw` / `ro` / hidden). Under the walk, a
  "NOT MOUNTED" list makes the kernel-guard invariant visible:
  sibling agents, other companies, and so on.

  **Center** — three tabs over the same dataset: stdout (streaming),
  sandbox argv (mount-argv generated from the agent's permissions),
  inbox/outbox (last message pair).

  **Right** — config `<dl>`, budget meter with 80% threshold line,
  permissions list where each row is tagged `mount` or `router`
  depending on whether `PermissionMapper` emits a bwrap flag.

  ## Stdout streaming

  Same as before: `GlorboWeb.StdoutStreamer` on the DynamicSupervisor,
  monitored; crash → re-spawn without killing the LV.

  ## Actions

  Header action row: edit AGENT.md (disabled), send message
  (disabled), stop (disabled pending M3.5 server-side sentinel),
  wake now (wired via `GlorboWeb.Actions.wake_agent/3`).
  """
  use GlorboWeb, :live_view
  require Logger

  import GlorboWeb.LiveHelpers,
    only: [base_dir: 0, current_year_month: 0, two_dp: 1, zero_dp: 1]

  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.{StatusPill, StdoutTail}

  @impl true
  def mount(%{"company" => co, "agent" => ag}, _session, socket) do
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not GlorboWeb.Slug.valid?(ag) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid agent identifier.")
         |> push_navigate(to: ~p"/companies/#{co}")}

      true ->
        mount_valid(co, ag, socket)
    end
  end

  defp mount_valid(co, ag, socket) do
    base = base_dir()
    ag_dir = Path.join([base, "companies", co, "agents", ag])

    if File.dir?(ag_dir) do
      detail = load_agent_detail(base, co, ag)

      history = load_history(base, co, ag)

      socket =
        socket
        |> assign(:page_title, "#{detail.name} — #{co} — Glorbo")
        |> assign(:current_company, co)
        |> assign(:company_slug, co)
        |> assign(:agent_slug, ag)
        |> assign(:detail, detail)
        |> assign(:tab, :stdout)
        |> assign(:hovered_perm, nil)
        |> assign(:streamer_pid, nil)
        |> assign(:history, history)
        |> assign(:open_file, nil)
        |> assign(:wake_open?, false)
        |> stream(:stdout, [], limit: -1000)
        |> ChatDrawer.State.wire_drawer()

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:stdout")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:wake")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:budget")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")

        case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
          {:ok, pid} ->
            Process.monitor(pid)
            # Backfill the local stream from the streamer's rolling
            # buffer (task #141) — singleton streamers only replay at
            # their init, so late-subscribing mounts need this call
            # to see recent history.
            socket = backfill_stdout(socket, pid)
            {:ok, assign(socket, :streamer_pid, pid)}

          _ ->
            {:ok, socket}
        end
      else
        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Agent \"#{ag}\" not found in #{co}.")
       |> push_navigate(to: ~p"/companies/#{co}")}
    end
  end

  @impl true
  def handle_info({:stdout_line, _co, _ag, %{id: _id} = payload}, socket) do
    # Forward the full payload — it carries `kind` + optional `ts`/`exit_code`
    # for the dispatch-card rendering in Components.StdoutTail (task #135).
    {:noreply, stream_insert(socket, :stdout, payload, at: -1, limit: -1000)}
  end

  # Realtime history: append audit records that concern this agent.
  def handle_info({:audit_append, record}, socket) when is_map(record) do
    if audit_for_this_agent?(record, socket.assigns.agent_slug) do
      row = to_history_row(stringify_keys(record))
      new_history = Enum.take([row | socket.assigns.history], 200)
      {:noreply, assign(socket, :history, new_history)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:file_event, rel, _events}, socket) do
    {:noreply, ChatDrawer.State.maybe_refresh_drawer(socket, rel)}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %{assigns: %{streamer_pid: pid}} = socket
      ) do
    base = base_dir()
    co = socket.assigns.company_slug
    ag = socket.assigns.agent_slug

    case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
      {:ok, new_pid} ->
        Process.monitor(new_pid)
        {:noreply, assign(socket, :streamer_pid, new_pid)}

      _ ->
        {:noreply, assign(socket, :streamer_pid, nil)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(stdout sandbox inbox history) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("hover_perm", %{"perm" => perm}, socket) do
    {:noreply, assign(socket, :hovered_perm, perm)}
  end

  def handle_event("unhover_perm", _params, socket) do
    {:noreply, assign(socket, :hovered_perm, nil)}
  end

  def handle_event("wake_prompt", _params, socket) do
    {:noreply, assign(socket, :wake_open?, true)}
  end

  def handle_event("wake_cancel", _params, socket) do
    {:noreply, assign(socket, :wake_open?, false)}
  end

  def handle_event("wake", params, socket) do
    reason = Map.get(params, "reason", "")
    base = base_dir()

    case GlorboWeb.Actions.wake_agent(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           reason,
           base: base
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:wake_open?, false)
         |> put_flash(:info, "Woken. Writing state/wake-request.md…")}

      {:error, err} ->
        Logger.warning("wake_agent failed",
          company: socket.assigns.company_slug,
          agent: socket.assigns.agent_slug,
          reason: inspect(err)
        )

        {:noreply,
         socket
         |> assign(:wake_open?, false)
         |> put_flash(:error, "Could not wake agent.")}
    end
  end

  def handle_event("stop", _params, socket) do
    case find_agent_server(socket.assigns.agent_slug) do
      nil ->
        {:noreply, put_flash(socket, :info, "Agent is not running.")}

      pid ->
        case Glorbo.Agent.Server.stop_inflight(pid) do
          :ok -> {:noreply, put_flash(socket, :info, "Stopped in-flight dispatch.")}
          :idle -> {:noreply, put_flash(socket, :info, "Agent is idle — nothing to stop.")}
        end
    end
  rescue
    _ -> {:noreply, put_flash(socket, :error, "Could not stop agent.")}
  end

  # task #117 — click a file in the workspace tree to open an editor.
  # `path` is the workspace-relative path so the UI never leaks
  # absolute paths, and the server re-anchors against the known
  # workspace dir (defence in depth against traversal).
  @workspace_edit_max_bytes 512 * 1024

  def handle_event("open_file", %{"path" => rel}, socket) do
    case read_workspace_file(socket, rel) do
      {:ok, content} ->
        {:noreply, assign(socket, :open_file, %{rel: rel, content: content, error: nil})}

      {:error, :too_large} ->
        {:noreply, put_flash(socket, :error, "File is larger than 512 KB — edit on disk.")}

      {:error, :binary} ->
        {:noreply, put_flash(socket, :error, "Binary file — won't open in the editor.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "File no longer exists.")}

      {:error, :invalid_path} ->
        {:noreply, put_flash(socket, :error, "Invalid path.")}
    end
  end

  def handle_event("close_file", _params, socket) do
    {:noreply, assign(socket, :open_file, nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    case socket.assigns.open_file do
      %{rel: rel} ->
        case write_workspace_file(socket, rel, content) do
          :ok ->
            {:noreply,
             socket
             |> assign(:detail, refresh_files(socket))
             |> assign(:open_file, nil)
             |> put_flash(:info, "Saved #{rel}.")}

          {:error, reason} ->
            {:noreply,
             assign(socket, :open_file, %{
               socket.assigns.open_file
               | error: "save failed: #{inspect(reason)}"
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Task #143 — create an empty file under the agent dir and open the
  # editor on it. Refuses to overwrite an existing file.
  def handle_event("create_file", %{"path" => rel}, socket) do
    with {:ok, abs_path} <- resolve_workspace_path(socket, rel),
         false <- File.exists?(abs_path),
         :ok <- File.mkdir_p(Path.dirname(abs_path)),
         :ok <- File.write(abs_path, "") do
      {:noreply,
       socket
       |> assign(:detail, refresh_files(socket))
       |> assign(:open_file, %{rel: rel, content: "", error: nil})
       |> put_flash(:info, "Created #{rel}.")}
    else
      true ->
        {:noreply, put_flash(socket, :error, "File already exists.")}

      {:error, :invalid_path} ->
        {:noreply, put_flash(socket, :error, "Invalid path.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}.")}
    end
  end

  # Task #143 — soft-delete: move to history/deleted/<ts>-<basename>
  # so the Director can recover. AGENT.md and stdout.log are refused
  # outright (AGENT.md is the agent's identity; stdout.log is runtime
  # state). Other contract files deleted = agent simply falls back to
  # whatever AGENT.md says (SOUL.md / HEARTBEAT.md / etc).
  def handle_event("delete_file", %{"path" => rel}, socket) do
    if rel in ["AGENT.md", "stdout.log"] do
      {:noreply, put_flash(socket, :error, "#{rel} is load-bearing; delete refused.")}
    else
      case soft_delete(socket, rel) do
        :ok ->
          {:noreply,
           socket
           |> assign(:detail, refresh_files(socket))
           |> put_flash(:info, "Moved #{rel} to history/deleted/.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}.")}
      end
    end
  end

  defp soft_delete(socket, rel) do
    with {:ok, abs_path} <- resolve_workspace_path(socket, rel),
         true <- File.exists?(abs_path) do
      ts = System.system_time(:millisecond)
      trash_dir = Path.join([agent_dir(socket), "history", "deleted"])
      File.mkdir_p!(trash_dir)
      dst = Path.join(trash_dir, "#{ts}-#{Path.basename(rel)}")
      File.rename(abs_path, dst)
    else
      false -> {:error, :not_found}
      err -> err
    end
  end

  defp refresh_files(socket) do
    ag_dir = agent_dir(socket)

    %{
      socket.assigns.detail
      | files: scan_agent_files(ag_dir),
        workspace_tree: walk_workspace(ag_dir)
    }
  end

  defp read_workspace_file(socket, rel) do
    with {:ok, abs_path} <- resolve_workspace_path(socket, rel),
         {:ok, %File.Stat{size: size}} <- File.stat(abs_path),
         :ok <- check_size(size),
         {:ok, bytes} <- File.read(abs_path),
         :ok <- check_binary(bytes) do
      {:ok, bytes}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} when reason in [:too_large, :binary, :invalid_path] -> {:error, reason}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp write_workspace_file(socket, rel, content) do
    with {:ok, abs_path} <- resolve_workspace_path(socket, rel) do
      File.write(abs_path, content)
    end
  end

  # Widened from workspace-only to full agent dir for task #143. The
  # UI now manages contract files (AGENT.md/SOUL.md/HEARTBEAT.md) +
  # their sibling dirs, not just workspace/. Traversal guard stays
  # strict — expanded path must live under the agent's own dir.
  defp resolve_workspace_path(socket, rel) do
    root = agent_dir(socket)
    candidate = Path.expand(Path.join(root, rel))

    if String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      {:error, :invalid_path}
    end
  end

  defp check_size(size) when size <= @workspace_edit_max_bytes, do: :ok
  defp check_size(_), do: {:error, :too_large}

  defp check_binary(bytes) do
    # Crude but effective — files with NUL bytes in the first 4 KiB are
    # treated as binary and refused in the editor. Plain text + UTF-8
    # markdown/JSON/YAML sail through.
    head = binary_part(bytes, 0, min(byte_size(bytes), 4096))
    if String.contains?(head, <<0>>), do: {:error, :binary}, else: :ok
  end

  # Task #141 — streamer is a singleton per agent; late-subscribing
  # LVs miss the init-time replay broadcast. We GenServer.call the
  # streamer for its rolling `recent` buffer and stream_insert each
  # payload locally so this LV sees the same history.
  defp backfill_stdout(socket, pid) do
    try do
      GlorboWeb.StdoutStreamer.backfill(pid)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
    |> Enum.reduce(socket, fn payload, acc ->
      stream_insert(acc, :stdout, payload, at: -1, limit: -1000)
    end)
  end

  defp agent_dir(socket) do
    Path.join([
      base_dir(),
      "companies",
      socket.assigns.company_slug,
      "agents",
      socket.assigns.agent_slug
    ])
  end

  @impl true
  def terminate(_reason, _socket) do
    # Don't stop the StdoutStreamer — it's a singleton per {company,
    # agent} shared by every open AgentLive (#134). Lingering after
    # the last tab closes is fine: the poll loop is cheap, and the
    # next mount reuses the pid. Streamer supervisor restarts on crash.
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-agent-detail">
      <header class="gl-view__header gl-agent-detail__header">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">agents /</span> {@agent_slug}
            <StatusPill.status_pill status={@detail.pill_status} label={@detail.pill_label} />
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">~/.glorbo/companies/{@company_slug}/agents/</span>{@agent_slug}<span class="gl-muted">/AGENT.md</span>
          </p>
        </div>
        <div class="gl-overview__actions">
          <button
            type="button"
            class="gl-btn"
            phx-click="open_file"
            phx-value-path="AGENT.md"
            title="Open AGENT.md in the in-browser editor"
          >
            ✎ edit AGENT.md
          </button>
          <.link
            navigate={~p"/companies/#{@company_slug}/dms/#{@agent_slug}"}
            class="gl-btn"
            title="Open Director ↔ #{@agent_slug} DM"
          >
            ✉ send message
          </.link>
          <button
            type="button"
            class="gl-btn gl-btn--deny"
            phx-click="stop"
            data-confirm="Kill the in-flight dispatch task? Agent stays registered; only the current invocation is terminated."
            title="Kill the current dispatch Task (no-op if agent is idle)"
          >
            ⏻ stop
          </button>
          <.wake_button />
        </div>
      </header>

      <div class="gl-agent-detail__grid">
        <%!-- LEFT COLUMN --%>
        <div class="gl-agent-detail__col">
          <section class="gl-panel gl-agent-identity">
            <header class="gl-panel__header">
              <span>identity</span>
              <span class="gl-panel__hint">{@detail.role}</span>
            </header>
            <div class="gl-panel__body">
              <div class="gl-agent-identity__avatar">
                {String.slice(@agent_slug, 0, 2) |> String.upcase()}
                <span class={[
                  "gl-agent-identity__dot",
                  "gl-agent-identity__dot--" <> Atom.to_string(@detail.pill_status)
                ]}>
                </span>
              </div>
              <div class="gl-agent-identity__name">{@detail.name}</div>
              <div class="gl-muted gl-agent-identity__reports">
                reports to <span class="gl-tabular">{@detail.reports_to || "(director)"}</span>
              </div>
            </div>
          </section>

          <%!-- task #118 — render SOUL.md if the agent has one --%>
          <section :if={@detail.soul} class="gl-panel gl-agent-soul">
            <header class="gl-panel__header">
              <span>soul</span>
              <span class="gl-panel__hint">SOUL.md</span>
            </header>
            <div class="gl-panel__body gl-agent-soul__body">
              {@detail.soul}
            </div>
          </section>

          <%!-- Task #143 — agent dir file manager (contracts + subdirs) --%>
          <section class="gl-panel gl-agent-files">
            <header class="gl-panel__header">
              <span>files</span>
              <span class="gl-panel__hint">agents/{@agent_slug}/</span>
            </header>
            <div class="gl-panel__body gl-panel__body--flush">
              <div class="gl-filetree">
                <div class="gl-filetree__section">contract files</div>

                <div
                  :for={row <- @detail.files.contracts}
                  class={[
                    "gl-filetree__node",
                    not row.exists? && "gl-filetree__node--missing"
                  ]}
                >
                  <span class="gl-filetree__prefix">├─ </span>
                  <button
                    :if={row.exists?}
                    type="button"
                    class="gl-filetree__file gl-filetree__file--clickable"
                    phx-click="open_file"
                    phx-value-path={row.rel}
                  >
                    {row.name}
                  </button>
                  <span :if={not row.exists?} class="gl-filetree__file gl-muted">
                    {row.name}
                  </span>
                  <span
                    :if={not row.exists?}
                    class="gl-filetree__action gl-muted"
                    phx-click="create_file"
                    phx-value-path={row.rel}
                  >
                    + create
                  </span>
                  <span
                    :if={row.exists? and row.name not in ["AGENT.md", "stdout.log"]}
                    class="gl-filetree__action gl-muted"
                    phx-click="delete_file"
                    phx-value-path={row.rel}
                    data-confirm={"Delete #{row.name}?"}
                  >
                    × delete
                  </span>
                </div>

                <div class="gl-filetree__section">directories</div>

                <div
                  :for={row <- @detail.files.subdirs}
                  class="gl-filetree__node"
                >
                  <span class="gl-filetree__prefix">├─ </span>
                  <span class="gl-filetree__dir">{row.name}/</span>
                  <span class="gl-filetree__count gl-muted">{row.count}</span>
                </div>

                <%!-- Bind-mount view (preserved from pre-#143) --%>
                <div class="gl-filetree__section">sandbox view</div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">├─ </span>/workspace
                  <span class="gl-mount-tag gl-mount-tag--rw">rw</span>
                </div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">├─ </span>/inbox
                  <span class="gl-mount-tag gl-mount-tag--ro">ro</span>
                </div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">└─ </span>/outbox
                  <span class="gl-mount-tag gl-mount-tag--rw">rw</span>
                </div>

                <div class="gl-filetree__section">
                  not mounted — invisible by construction
                </div>
                <div
                  :for={entry <- @detail.not_mounted}
                  class="gl-filetree__node gl-filetree__node--hidden"
                >
                  <span class="gl-filetree__prefix">✕ </span>{entry}
                </div>
              </div>
            </div>
          </section>
        </div>

        <%!-- CENTER COLUMN --%>
        <div class="gl-agent-detail__col gl-agent-detail__col--center">
          <section class="gl-panel gl-agent-detail__center-panel">
            <header class="gl-panel__header">
              <span>sandboxed</span>
              <span class="gl-panel__title">invocation</span>
              <div class="gl-agent-detail__tabs">
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :stdout && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="stdout"
                >
                  stdout
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :sandbox && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="sandbox"
                >
                  sandbox argv
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :inbox && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="inbox"
                >
                  inbox/outbox
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :history && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="history"
                >
                  history
                </button>
              </div>
            </header>

            <div :if={@tab == :stdout} class="gl-panel__body gl-panel__body--flush gl-stdout-wrap">
              <StdoutTail.stdout_tail stream={@streams.stdout} />
            </div>

            <div :if={@tab == :sandbox} class="gl-panel__body gl-sandbox">
              <p class="gl-muted gl-sandbox__hint">
                Generated per-wake by <code>Glorbo.Sandbox.PermissionMapper</code>.
                Hover a permission on the right to highlight its mount.
              </p>
              <pre class="gl-sandbox__argv"><span class="gl-sandbox__cmd">bwrap</span><span class="gl-sandbox__section">── BASE SANDBOX ──</span><span :for={flag <- @detail.sandbox.base} class="gl-sandbox__line"><span class="gl-sandbox__flag">  {flag}</span></span><span class="gl-sandbox__section">── SELF — this agent's private areas ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.workspace_path} /workspace</span></span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.outbox_path} /outbox</span></span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --ro-bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.inbox_path} /inbox</span></span><span class="gl-sandbox__section">── FROM permissions: (one mount per rule) ──</span><span :for={line <- @detail.sandbox.perm_lines} class={["gl-sandbox__line", @hovered_perm == line.perm && "gl-sandbox__line--hl"]}><span :if={line.flag} class="gl-sandbox__flag">  {line.flag}</span><span :if={line.arg}> <span class="gl-sandbox__arg">{line.arg}</span></span><span :if={line.comment} class="gl-sandbox__comment">  {line.comment}</span></span><span class="gl-sandbox__section">── NETWORK ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  {@detail.sandbox.network_flag}</span><span :if={@detail.sandbox.network_comment} class="gl-sandbox__comment">  {@detail.sandbox.network_comment}</span></span><span class="gl-sandbox__section">── EXEC ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__cmd">  {@detail.sandbox.exec_cmd}</span> <span class="gl-sandbox__arg">--model {@detail.model}</span></span>
              </pre>
            </div>

            <div :if={@tab == :inbox} class="gl-panel__body">
              <div class="gl-io-section">
                <div class="gl-io-section__label">── inbox/ · {@detail.inbox.count} unread ──</div>
                <div :if={@detail.inbox.latest} class="gl-io-card">
                  <div class="gl-muted gl-io-card__meta">
                    {@detail.inbox.latest.meta}
                  </div>
                  <div class="gl-io-card__title">{@detail.inbox.latest.title}</div>
                  <div class="gl-io-card__body">{@detail.inbox.latest.preview}</div>
                </div>
                <div :if={is_nil(@detail.inbox.latest)} class="gl-muted">No inbox messages.</div>
              </div>
              <div class="gl-io-section">
                <div class="gl-io-section__label">── outbox/ · pending route ──</div>
                <div :if={@detail.outbox.latest} class="gl-io-card">
                  <div class="gl-muted gl-io-card__meta">
                    {@detail.outbox.latest.meta}
                  </div>
                  <div class="gl-io-card__title">{@detail.outbox.latest.title}</div>
                  <div class="gl-io-card__body">{@detail.outbox.latest.preview}</div>
                </div>
                <div :if={is_nil(@detail.outbox.latest)} class="gl-muted">No pending outbox.</div>
              </div>
            </div>

            <div :if={@tab == :history} class="gl-panel__body gl-agent-history">
              <div :if={@history == []} class="gl-muted">
                No activity yet. Heartbeat ticks, director wakes, and dispatch
                events will appear here.
              </div>
              <ul :if={@history != []} class="gl-agent-history__list">
                <li
                  :for={row <- @history}
                  class={["gl-agent-history__row", "gl-agent-history__row--" <> row.kind]}
                >
                  <span class="gl-agent-history__ts gl-muted">{row.ts_short}</span>
                  <span class={["gl-agent-history__action", "gl-action--" <> row.class]}>
                    {row.action}
                  </span>
                  <span :if={row.detail} class="gl-agent-history__detail gl-muted">
                    {row.detail}
                  </span>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <%!-- RIGHT COLUMN --%>
        <div class="gl-agent-detail__col">
          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>config</span>
              <span class="gl-panel__hint">AGENT.md</span>
            </header>
            <div class="gl-panel__body">
              <dl class="gl-kv">
                <dt>provider</dt>
                <dd class="gl-accent">{@detail.provider}</dd>
                <dt>model</dt>
                <dd>{@detail.model}</dd>
                <dt>reports_to</dt>
                <dd>{@detail.reports_to || "(director)"}</dd>
                <dt>heartbeat</dt>
                <dd>{@detail.heartbeat || "—"}</dd>
                <dt>network</dt>
                <dd><span class="gl-badge">{@detail.network}</span></dd>
                <dt>skills</dt>
                <dd>{Enum.join(@detail.skills, ", ")}</dd>
              </dl>
            </div>
          </section>

          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>budget</span>
              <StatusPill.status_pill
                status={if @detail.budget.tracked?, do: :alive, else: :info}
                label={if @detail.budget.tracked?, do: "tracked", else: "untracked"}
              />
            </header>
            <div class="gl-panel__body">
              <div :if={@detail.budget.tracked?}>
                <div class="gl-budget-figure">
                  <span class="gl-budget-figure__used">${@detail.budget.used_str}</span>
                  <span class="gl-muted">/ ${@detail.budget.cap_str} this month</span>
                </div>
                <div class={["gl-meter", @detail.budget.cls && "gl-meter--" <> @detail.budget.cls]}>
                  <div class="gl-meter__fill" style={"width: #{@detail.budget.pct}%;"}></div>
                  <div class="gl-meter__threshold" style="left: 80%;"></div>
                </div>
                <div class="gl-muted gl-budget-sub">
                  {@detail.budget.pct}% used · alert at 80% · {if @detail.budget.pct > 80,
                    do: "ALERT FIRED",
                    else: "no alerts"}
                </div>
              </div>
              <p :if={not @detail.budget.tracked?} class="gl-muted gl-budget-untracked">
                Provider <span class="gl-accent">{@detail.provider}</span>
                has <code>usage_parser = "none"</code>. Agent opted in via
                <code>allow_untracked_budget: true</code>
                in AGENT.md.
              </p>
            </div>
          </section>

          <section class="gl-panel gl-agent-detail__perms">
            <header class="gl-panel__header">
              <span>permissions</span>
              <span class="gl-panel__hint">hover → highlights mount</span>
            </header>
            <div class="gl-panel__body gl-panel__body--flush">
              <ul class="gl-perms">
                <li
                  :for={p <- @detail.permissions}
                  class={["gl-perm", @hovered_perm == p.raw && "gl-perm--hl"]}
                  phx-mouseenter="hover_perm"
                  phx-value-perm={p.raw}
                  phx-mouseleave="unhover_perm"
                  phx-click="tab"
                  phx-value-tab="sandbox"
                >
                  <code class="gl-perm__token">
                    <span>{p.resource}</span>
                    <span class="gl-muted">:</span>
                    <span class="gl-perm__action">{p.action}</span>
                    <span class="gl-muted">:</span>
                    <span class="gl-perm__scope">{p.scope}</span>
                  </code>
                  <span class={["gl-perm__tag", "gl-perm__tag--" <> p.kind]}>{p.kind}</span>
                </li>
                <li :if={@detail.permissions == []} class="gl-muted gl-perm gl-perm--empty">
                  No permissions — sandboxed to workspace only.
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>

      <%!-- task #117 — workspace file editor overlay --%>
      <div :if={@open_file} class="gl-modal-scrim" phx-click="close_file">
        <div class="gl-modal gl-file-editor" phx-click-away="close_file">
          <form phx-submit="save_file" onclick="event.stopPropagation()">
            <header class="gl-modal__header">
              <span class="gl-muted">workspace/</span>{@open_file.rel}
              <button
                type="button"
                class="gl-btn gl-btn--ghost gl-modal__close"
                phx-click="close_file"
              >
                ×
              </button>
            </header>
            <div :if={@open_file.error} class="gl-flash gl-flash--error">{@open_file.error}</div>
            <textarea
              name="content"
              rows="20"
              class="gl-input gl-file-editor__textarea"
            >{@open_file.content}</textarea>
            <footer class="gl-modal__footer">
              <button type="button" class="gl-btn gl-btn--ghost" phx-click="close_file">
                cancel
              </button>
              <button type="submit" class="gl-btn">save</button>
            </footer>
          </form>
        </div>
      </div>

      <div :if={@wake_open?} class="gl-modal-scrim" phx-click-away="wake_cancel">
        <form
          phx-submit="wake"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-wake-title"
        >
          <header class="gl-modal__header">
            <div id="gl-wake-title"><strong>↻ wake {@agent_slug}</strong></div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="wake_cancel"
              aria-label="Close"
            >
              ✕
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">REASON</span>
              <textarea
                name="reason"
                rows="3"
                class="gl-input"
                maxlength="1024"
                placeholder="Optional — e.g. 'check the new claude-code version' or 'roadmap changed'"
                autofocus
              ></textarea>
            </label>
            <p class="gl-muted" style="font-size: 11px;">
              Writes <code>agents/{@agent_slug}/state/wake-request.md</code>.
              The agent's next invocation sees the reason as part of the wake prompt.
            </p>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="wake_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">wake</button>
          </footer>
        </form>
      </div>
    </section>
    """
  end

  defp wake_button(assigns) do
    ~H"""
    <button
      type="button"
      class="gl-btn gl-btn--primary"
      phx-click="wake_prompt"
    >
      ↻ wake now
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_agent_detail(base, co, ag) do
    ag_dir = Path.join([base, "companies", co, "agents", ag])
    agent_md = Glorbo.Agent.FileLayout.agent_md(ag_dir)

    spec =
      case Glorbo.Agent.Parser.parse_file(agent_md) do
        {:ok, s} -> s
        _ -> nil
      end

    used = load_used_usd(ag)
    cap = spec_cap(spec)
    {pct, cls, tracked?} = classify_budget(used, cap)

    %{
      name: agent_name(spec, ag),
      role: (spec && spec.role) || "agent",
      provider: (spec && spec.provider) || "unknown",
      model: (spec && spec.model) || "",
      reports_to: spec && spec.reports_to,
      heartbeat: spec && spec.heartbeat,
      network: (spec && to_string(spec.network)) || "none",
      skills: (spec && spec.skills) || [],
      permissions: classify_permissions(spec),
      pill_status: agent_pill_status(pct, tracked?),
      pill_label: agent_pill_label(pct, tracked?),
      budget: %{
        tracked?: tracked?,
        used_str: two_dp(used),
        cap_str: zero_dp(cap),
        pct: pct,
        cls: cls
      },
      workspace_tree: walk_workspace(ag_dir),
      not_mounted: not_mounted_list(base, co, ag),
      inbox: load_inbox_preview(ag_dir),
      outbox: load_outbox_preview(ag_dir),
      sandbox: build_sandbox_preview(spec, co, ag),
      soul: load_soul(ag_dir),
      files: scan_agent_files(ag_dir)
    }
  end

  # task #118 — if the agent has a SOUL.md file, render its body on
  # the identity column. We strip frontmatter since the frontmatter
  # fields (`role:`) duplicate identity data already on display.
  defp load_soul(ag_dir) do
    path = Path.join(ag_dir, "SOUL.md")

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         stripped <- strip_frontmatter(content),
         trimmed <- String.trim(stripped),
         true <- trimmed != "" do
      trimmed
    else
      _ -> nil
    end
  end

  defp agent_name(nil, ag), do: String.capitalize(ag)
  defp agent_name(spec, _ag), do: spec.slug |> to_string() |> String.capitalize()

  defp spec_cap(nil), do: 0.0
  defp spec_cap(%{budget_usd_cents_month: nil}), do: 0.0
  defp spec_cap(%{budget_usd_cents_month: c}), do: c / 100.0

  defp classify_budget(used, cap) when cap > 0 do
    pct = min(round(used / cap * 100), 100)

    cls =
      cond do
        pct > 90 -> "rose"
        pct > 80 -> "amber"
        true -> nil
      end

    {pct, cls, true}
  end

  defp classify_budget(_, _), do: {0, nil, false}

  defp agent_pill_status(pct, true) when pct > 90, do: :warn
  defp agent_pill_status(_pct, _tracked?), do: :idle

  defp agent_pill_label(pct, true) when pct > 90, do: "budget #{pct}%"
  defp agent_pill_label(_pct, _tracked?), do: "idle"

  # Permissions displayed as resource/action/scope triples + a `:kind`
  # tag — `mount` if PermissionMapper emits any bwrap flag,
  # `router` if it's application-layer only (agents:message, tasks:*,
  # chat:write, budget:read, tools:execute). Used on the right column.
  defp classify_permissions(nil), do: []

  defp classify_permissions(%{permissions: perms}) do
    Enum.map(perms, &permission_row/1)
  end

  defp permission_row({r, a, s}) do
    raw = "#{r}:#{a}:#{s}"
    kind = if filesystem_permission?(r, a), do: "mount", else: "router"
    %{raw: raw, resource: r, action: a, scope: s, kind: kind}
  end

  # Keep in sync with Glorbo.Sandbox.PermissionMapper. Conservative:
  # only report `mount` when the mapper is known to emit flags; tweak
  # when new mount-emitting permissions are added.
  defp filesystem_permission?("projects", _), do: true
  defp filesystem_permission?("chat", "read"), do: true
  defp filesystem_permission?(_, _), do: false

  # Walk the agent's workspace dir up to @workspace_tree_depth levels
  # deep. Skip dotfiles + known ephemeral caches. For files, include a
  # relative path (relative to the workspace root) so the UI can open
  # them for editing (task #117).
  @workspace_tree_depth 3
  @workspace_skip_dirs ~w(.cache .glorbo-claude .glorbo-skills node_modules .git)

  defp walk_workspace(ag_dir) do
    root = Path.join(ag_dir, "workspace")

    if File.dir?(root) do
      # Paths emitted are relative to the AGENT dir now (task #143
      # widened resolve_workspace_path from workspace-only to
      # agent-root). E.g. "workspace/notes.md" not "notes.md".
      walk_workspace_dir(ag_dir, root, 0)
    else
      []
    end
  end

  defp walk_workspace_dir(_ag_dir, _path, depth) when depth >= @workspace_tree_depth, do: []

  defp walk_workspace_dir(ag_dir, path, depth) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @workspace_skip_dirs))
        |> Enum.sort()
        |> Enum.flat_map(fn e ->
          full = Path.join(path, e)

          cond do
            File.dir?(full) ->
              [%{name: e, kind: :dir, depth: depth, rel: Path.relative_to(full, ag_dir)}] ++
                walk_workspace_dir(ag_dir, full, depth + 1)

            File.regular?(full) ->
              [%{name: e, kind: :file, depth: depth, rel: Path.relative_to(full, ag_dir)}]

            true ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # Task #143 — scan the whole agent dir (not just workspace/) and
  # return a structured listing the UI can render as a file manager.
  # Output shape:
  #
  #   %{
  #     contracts: [%{name, rel, role: :contract, exists?}],
  #     subdirs:   [%{name, rel, role: :dir, count}],
  #     scratch:   [%{name, rel, role: :file}]
  #   }
  #
  # `rel` is always relative to the agent dir (e.g. "AGENT.md",
  # "workspace/notes.md", "inbox/mentions/5.md"). Contract files are
  # the named ones the runtime expects (GEP-15) regardless of
  # existence — the UI offers create when exists?=false.
  @contract_files ~w(AGENT.md HEARTBEAT.md SOUL.md stdout.log)
  @contract_subdirs ~w(inbox outbox history state workspace)

  defp scan_agent_files(ag_dir) do
    %{
      contracts: contract_rows(ag_dir),
      subdirs: subdir_rows(ag_dir)
    }
  end

  defp contract_rows(ag_dir) do
    Enum.map(@contract_files, fn name ->
      %{name: name, rel: name, role: :contract, exists?: File.regular?(Path.join(ag_dir, name))}
    end)
  end

  defp subdir_rows(ag_dir) do
    Enum.map(@contract_subdirs, fn name ->
      dir = Path.join(ag_dir, name)
      count = if File.dir?(dir), do: count_files(dir), else: 0
      %{name: name, rel: name, role: :dir, count: count}
    end)
  end

  defp count_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.count(&File.regular?/1)

      _ ->
        0
    end
  end

  defp not_mounted_list(base, co, ag) do
    co_path = Path.join([base, "companies", co])
    agents_path = Path.join(co_path, "agents")

    siblings =
      case File.ls(agents_path) do
        {:ok, xs} ->
          xs
          |> Enum.reject(&(&1 == ag))
          |> Enum.map(&"agents/#{&1}")

        _ ->
          []
      end

    other_cos =
      case File.ls(Path.join(base, "companies")) do
        {:ok, cs} ->
          cs
          |> Enum.reject(&(&1 == co))
          |> Enum.map(&"companies/#{&1}")

        _ ->
          []
      end

    (siblings ++ other_cos) |> Enum.take(6)
  end

  defp load_inbox_preview(ag_dir) do
    load_io_preview(Path.join(ag_dir, "inbox"))
  end

  defp load_outbox_preview(ag_dir) do
    load_io_preview(Path.join(ag_dir, "outbox"))
  end

  defp load_io_preview(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        md = Enum.filter(files, &String.ends_with?(&1, ".md"))

        case Enum.sort(md) |> List.last() do
          nil ->
            %{count: 0, latest: false}

          f ->
            %{count: length(md), latest: io_card_from_file(Path.join(dir, f))}
        end

      _ ->
        %{count: 0, latest: false}
    end
  end

  defp io_card_from_file(path) do
    case File.read(path) do
      {:ok, content} ->
        meta =
          case Glorbo.Filesystem.Frontmatter.parse(content) do
            {:ok, m, _} -> m
            _ -> %{}
          end

        body = strip_frontmatter(content)
        title = first_heading(body) || Path.basename(path, ".md")

        preview =
          body |> String.replace(~r/^#\s+.*\n/, "") |> String.trim() |> String.slice(0, 220)

        %{
          meta: "from: #{meta["from"] || "—"} · #{meta["ts"] || meta["delivered_at"] || "—"}",
          title: title,
          preview: preview
        }

      _ ->
        %{meta: "—", title: Path.basename(path), preview: ""}
    end
  end

  defp strip_frontmatter(content) do
    case String.split(content, ~r/\A---\s*\n/, parts: 2) do
      [_, rest] ->
        case String.split(rest, ~r/\n---\s*\n/, parts: 2) do
          [_, body] -> body
          _ -> content
        end

      _ ->
        content
    end
  end

  defp first_heading(body) do
    body
    |> String.split("\n")
    |> Enum.find(&(String.starts_with?(&1, "#") and String.length(&1) > 1))
    |> case do
      nil -> nil
      line -> line |> String.trim_leading("#") |> String.trim()
    end
  end

  defp build_sandbox_preview(spec, co, ag) do
    base = "companies/#{co}"

    perm_lines =
      (spec && spec.permissions)
      |> Kernel.||([])
      |> Enum.map(&permission_sandbox_line/1)

    network = (spec && to_string(spec.network)) || "none"
    {network_flag, network_comment} = network_line(network)

    %{
      base: [
        "--die-with-parent",
        "--unshare-user-try",
        "--unshare-ipc",
        "--unshare-pid",
        "--unshare-uts",
        "--unshare-cgroup-try",
        "--new-session",
        "--cap-drop ALL"
      ],
      workspace_path: "#{base}/agents/#{ag}/workspace",
      outbox_path: "#{base}/agents/#{ag}/outbox",
      inbox_path: "#{base}/agents/#{ag}/inbox",
      perm_lines: perm_lines,
      network_flag: network_flag,
      network_comment: network_comment,
      exec_cmd: provider_cmd((spec && spec.provider) || "claude-code")
    }
  end

  defp permission_sandbox_line({r, a, s}) do
    raw = "#{r}:#{a}:#{s}"
    co = "companies/acme"

    case {r, a, s} do
      {"projects", "read", "*"} ->
        %{flag: "--ro-bind", arg: "#{co}/projects /projects", comment: "← #{raw}", perm: raw}

      {"projects", "write", name} when name != "*" ->
        %{
          flag: "--bind",
          arg: "#{co}/projects/#{name} /projects/#{name}",
          comment: "← #{raw}",
          perm: raw
        }

      {"projects", "read", name} ->
        %{
          flag: "--ro-bind",
          arg: "#{co}/projects/#{name} /projects/#{name}",
          comment: "← #{raw}",
          perm: raw
        }

      {"chat", "read", "*"} ->
        %{flag: "--ro-bind", arg: "#{co}/channels /channels", comment: "← #{raw}", perm: raw}

      _ ->
        %{
          flag: nil,
          arg: nil,
          comment: "# #{raw}  (Elixir router-enforced, not a mount)",
          perm: raw
        }
    end
  end

  defp network_line("none"),
    do: {"--unshare-net", "# kernel netns shutdown — no egress possible"}

  defp network_line("api-only"),
    do: {"--setenv HTTPS_PROXY http://127.0.0.1:9443", "# allowlisted HTTPS CONNECT proxy"}

  defp network_line("open"),
    do: {"# host netns inherited", "# explicit opt-in"}

  defp network_line(other), do: {"# network: #{other}", ""}

  defp provider_cmd("claude-code"), do: "claude"
  defp provider_cmd("gemini-cli"), do: "gemini"
  defp provider_cmd("codex"), do: "codex"
  defp provider_cmd(other), do: other

  defp load_used_usd(agent_slug) do
    case Glorbo.Budget.Ledger.fetch(agent_slug, current_year_month()) do
      %{cost_usd_cents: c} -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
  end

  # ---------------------------------------------------------------------------
  # History panel (GEP-14-adjacent — shows heartbeat + dispatch + wake activity)
  # ---------------------------------------------------------------------------

  @history_cap 200

  defp load_history(base, co, ag) do
    path =
      Path.join([
        base,
        "companies",
        co,
        "audit",
        "#{current_year_month()}.jsonl"
      ])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        # Reverse first so the reduce picks up the newest rows and caps at
        # @history_cap without having to walk the whole file.
        |> Enum.reverse()
        |> Enum.reduce_while([], &collect_history_row(&1, &2, ag))
        # Reverse back: newest first (matches realtime-append semantics).
        |> Enum.reverse()

      _ ->
        []
    end
  end

  defp collect_history_row(_line, acc, _ag) when length(acc) >= @history_cap do
    {:halt, acc}
  end

  defp collect_history_row(line, acc, ag) do
    with {:ok, entry} <- Jason.decode(line),
         true <- audit_for_this_agent?(entry, ag) do
      {:cont, [to_history_row(entry) | acc]}
    else
      _ -> {:cont, acc}
    end
  end

  # An audit record concerns this agent if any of: actor == slug, target
  # starts with `agents/<slug>`, or detail has {agent: slug}.
  defp audit_for_this_agent?(entry, slug) when is_map(entry) and is_binary(slug) do
    e = stringify_keys(entry)

    actor = to_string(e["actor"] || "")
    target = to_string(e["target"] || "")
    detail_agent = get_in(e, ["detail", "agent"]) |> to_string()

    actor == slug or
      String.starts_with?(target, "agents/#{slug}") or
      detail_agent == slug
  end

  defp audit_for_this_agent?(_entry, _slug), do: false

  defp to_history_row(entry) do
    action = to_string(entry["action"] || "")

    %{
      ts_short: short_ts(entry["ts"]),
      action: action,
      class: action_class(action),
      kind: kind_for(action),
      detail: history_detail(entry)
    }
  end

  defp short_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        naive = DateTime.to_naive(dt)

        "#{naive.hour |> pad2()}:#{naive.minute |> pad2()}:#{naive.second |> pad2()}"

      _ ->
        ts
    end
  end

  defp short_ts(_), do: ""

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Map audit actions to the same CSS classes AuditEntry uses.
  defp action_class("agent.wake" <> _), do: "wake"
  defp action_class("agent.dispatch" <> _), do: "wake"
  defp action_class("agent.complete" <> _), do: "wake"
  defp action_class("agent.heartbeat_skipped"), do: "wake"
  defp action_class("agent.wake_request"), do: "wake"
  defp action_class("budget" <> _), do: "budget"
  defp action_class("approval" <> _), do: "approval"
  defp action_class(_), do: "default"

  defp kind_for("agent.heartbeat_skipped"), do: "skipped"
  defp kind_for("agent.complete"), do: "complete"
  defp kind_for("agent.dispatch"), do: "dispatch"
  defp kind_for("agent.wake" <> _), do: "wake"
  defp kind_for(_), do: "default"

  defp history_detail(entry) do
    # Prefer a targeted one-line summary based on the action.
    case {entry["action"], entry["detail"]} do
      {"agent.wake", d} when is_map(d) ->
        "trigger: #{d["trigger"] || "?"}"

      {"agent.heartbeat_skipped", d} when is_map(d) ->
        "reason: #{d["reason"] || "?"}"

      {"agent.dispatch", d} when is_map(d) ->
        "provider: #{d["provider"] || "?"} · model: #{d["model"] || "?"}"

      {"agent.complete", d} when is_map(d) ->
        "exit #{d["exit_status"] || "?"} · #{d["duration_ms"] || "?"}ms"

      {"agent.wake_request", d} when is_map(d) ->
        reason = d["reason"] || ""
        if reason == "", do: "director wake", else: "director: #{reason}"

      _ ->
        nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp find_agent_server(slug) do
    case Registry.match(Glorbo.Agent.Registry, {:agent_server, :_, slug}, :_) do
      [{pid, _} | _] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
