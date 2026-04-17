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
        |> stream(:stdout, [], limit: -1000)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:stdout")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:wake")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:budget")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")

        case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
          {:ok, pid} ->
            Process.monitor(pid)
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
  def handle_info({:stdout_line, _co, _ag, %{id: id, body: body}}, socket) do
    {:noreply, stream_insert(socket, :stdout, %{id: id, body: body}, at: -1, limit: -1000)}
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

  def handle_info({:file_event, _rel, _events}, socket), do: {:noreply, socket}

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
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(stdout sandbox inbox history) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  def handle_event("hover_perm", %{"perm" => perm}, socket) do
    {:noreply, assign(socket, :hovered_perm, perm)}
  end

  def handle_event("unhover_perm", _params, socket) do
    {:noreply, assign(socket, :hovered_perm, nil)}
  end

  def handle_event("wake", %{"reason" => reason}, socket) do
    base = base_dir()

    case GlorboWeb.Actions.wake_agent(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           reason,
           base: base
         ) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Woken. Writing state/wake-request.md…")}

      {:error, err} ->
        Logger.warning("wake_agent failed",
          company: socket.assigns.company_slug,
          agent: socket.assigns.agent_slug,
          reason: inspect(err)
        )

        {:noreply, put_flash(socket, :error, "Could not wake agent.")}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:streamer_pid], do: GlorboWeb.StdoutStreamer.stop(pid)
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
          <button type="button" class="gl-btn" disabled title="Pending P3 AGENT.md editor">
            ✎ edit AGENT.md
          </button>
          <button type="button" class="gl-btn" disabled title="Pending P3 messaging UI">
            ✉ send message
          </button>
          <button
            type="button"
            class="gl-btn gl-btn--deny"
            disabled
            title="Pending M3.5 stop sentinel"
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

          <section class="gl-panel gl-workspace-panel">
            <header class="gl-panel__header">
              <span>workspace/</span>
              <span class="gl-panel__hint">bind-mount view</span>
            </header>
            <div class="gl-panel__body gl-panel__body--flush">
              <div class="gl-filetree">
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">┌─ </span>/workspace
                  <span class="gl-mount-tag gl-mount-tag--rw">rw</span>
                </div>
                <div
                  :for={entry <- @detail.workspace_tree}
                  class="gl-filetree__node"
                  style={"padding-left: #{10 + entry.depth * 14}px"}
                >
                  <span class="gl-filetree__prefix">├─ </span>
                  <span class={
                    if entry.kind == :dir, do: "gl-filetree__dir", else: "gl-filetree__file"
                  }>
                    {entry.name}
                  </span>
                </div>
                <div :if={@detail.workspace_tree == []} class="gl-muted gl-filetree__node">
                  <span class="gl-filetree__prefix">└─ </span>(empty)
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
                <div :if={not @detail.inbox.latest} class="gl-muted">No inbox messages.</div>
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
                <div :if={not @detail.outbox.latest} class="gl-muted">No pending outbox.</div>
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
    </section>
    """
  end

  defp wake_button(assigns) do
    ~H"""
    <button
      type="button"
      class="gl-btn gl-btn--primary"
      phx-click="wake"
      phx-value-reason=""
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
        used_str: dp2(used),
        cap_str: dp0(cap),
        pct: pct,
        cls: cls
      },
      workspace_tree: walk_workspace(ag_dir),
      not_mounted: not_mounted_list(base, co, ag),
      inbox: load_inbox_preview(ag_dir),
      outbox: load_outbox_preview(ag_dir),
      sandbox: build_sandbox_preview(spec, co, ag)
    }
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

  defp walk_workspace(ag_dir) do
    path = Path.join(ag_dir, "workspace")

    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.map(fn e ->
          full = Path.join(path, e)
          %{name: e, kind: if(File.dir?(full), do: :dir, else: :file), depth: 0}
        end)

      _ ->
        []
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

  defp current_year_month do
    now = DateTime.utc_now()
    "#{now.year}-#{String.pad_leading(Integer.to_string(now.month), 2, "0")}"
  end

  defp dp2(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp dp2(_), do: "0.00"

  defp dp0(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 0)
  defp dp0(_), do: "0"

  defp base_dir, do: Glorbo.Filesystem.Hierarchy.default_root()

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
end
