defmodule GlorboWeb.CompanyLive do
  @moduledoc """
  Per-company dashboard — GET `/companies/:company` (D-22, M2 rewrite).

  Matches the mockup at abc.zip/screenshots/04.png. Five regions:

    1. **View header** — `{company} / overview`, path breadcrumb,
       quote line, actions (reindex / backup / + new agent).
    2. **Stat row** — 4 cards: agents running, open tasks, budget burn,
       invocations 24h. Each with a sparkline.
    3. **Agents roster** — table with status/agent/activity/provider/
       net/budget/last-wake columns; click row → agent detail.
    4. **Audit tail** — last 8 events from current-month JSONL.
    5. **Bottom row** — projects burn bars + providers runtime summary.

  ## Rebuild cadence

  Most data is derived at mount + on PubSub events. `last_wake`, the
  invocations histogram, and budget-burn sparkline all need time-
  series data the app doesn't currently cache; for M2 we substitute
  reasonable proxies (last audit `agent.wake` per slug, hour-bucketed
  audit counts) and leave the door open for a real metrics store in
  a follow-up.

  404 path preserved: unknown company → flash + push_navigate to
  `/companies`.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers,
    only: [
      base_dir: 0,
      current_year_month: 0,
      budget_classify: 2,
      two_dp: 1,
      zero_dp: 1
    ]

  alias Glorbo.Budget.Ledger
  alias Glorbo.CLI.Registry, as: CLIRegistry
  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.Filesystem.Frontmatter
  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.{StatCard, StatusPill}

  @impl true
  def mount(%{"company" => slug}, _session, socket) do
    if GlorboWeb.Slug.valid?(slug) do
      mount_valid(slug, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid company identifier.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  defp mount_valid(slug, socket) do
    base = base_dir()
    co_path = Path.join([base, "companies", slug])

    if File.dir?(co_path) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:agents")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:agents:status")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:approvals")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:projects")
      end

      data = load_company_data(base, slug, co_path)

      {:ok,
       socket
       |> assign(:page_title, "#{data.company_name} — Glorbo")
       |> assign(:sidebar_active, :overview)
       |> assign(:current_company, slug)
       |> assign(:company_slug, slug)
       |> assign(:company_name, data.company_name)
       |> assign(:company, data)
       |> assign(:edit_company_md, nil)
       |> assign(:new_agent_open?, false)
       |> assign(:new_project_open?, false)
       |> assign(:provider_options, provider_options())
       |> ChatDrawer.State.wire_drawer()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company \"#{slug}\" not found.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # `?modal=new_agent` / `?modal=new_project` opens the matching
    # modal on mount. Used by the sidebar's "+" section-label buttons
    # which don't have a direct phx-click path into CompanyLive.
    socket =
      case Map.get(params, "modal") do
        "new_agent" -> assign(socket, :new_agent_open?, true)
        "new_project" -> assign(socket, :new_project_open?, true)
        _ -> socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel_path)
    base = base_dir()
    slug = socket.assigns.company_slug
    co_path = Path.join([base, "companies", slug])
    data = load_company_data(base, slug, co_path)
    {:noreply, assign(socket, :company, data)}
  end

  def handle_info({:agent_status, _slug, _status}, socket) do
    # The agent grid's pill_status is snapshotted at build time (see
    # build_agent_row → agent_pill_status → agent_runtime_status). For
    # the pills to re-derive we have to rebuild the agents list. Other
    # company data (audit tail, budget, projects) is stable for the
    # duration of a dispatch flip, so we only refresh `agents` +
    # dependent stats — cheaper than the full load_company_data.
    base = GlorboWeb.LiveHelpers.base_dir()
    slug = socket.assigns.company_slug
    co_path = Path.join([base, "companies", slug])
    agents = load_agents(base, slug, co_path)

    company =
      socket.assigns[:company]
      |> Map.put(:agents, agents)
      |> Map.put(:agents_alive, Enum.count(agents, &(&1.pill_status == :alive)))
      |> Map.put(:agents_idle, Enum.count(agents, &(&1.pill_status == :idle)))
      |> Map.put(:agents_warn, Enum.count(agents, &(&1.pill_status == :warn)))
      |> Map.put(:agents_crashed, Enum.count(agents, &(&1.pill_status == :stop)))

    {:noreply, assign(socket, :company, company)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-overview">
      <header class="gl-view__header gl-overview__header">
        <div>
          <h1 class="gl-heading gl-heading--display">
            {@company_name} <span class="gl-muted">/ overview</span>
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">~/.glorbo/companies/</span>{@company_slug}<span class="gl-muted">/company.md</span>
          </p>
          <p class="gl-overview__quote">
            // Company status at a glance: agents, projects, budget, activity.
          </p>
        </div>
        <div class="gl-overview__actions">
          <button
            type="button"
            class="gl-btn"
            phx-click="edit_company_md"
            title="Edit company.md frontmatter + body"
          >
            ✎ edit company.md
          </button>
          <button
            type="button"
            class="gl-btn"
            phx-click="reindex"
            phx-disable-with="↻ reindexing…"
            title="Rebuild SQLite index from filesystem (companies/*, agents/*, tasks/*)"
          >
            ↻ reindex
          </button>
          <button
            type="button"
            class="gl-btn"
            phx-click="backup"
            phx-disable-with="⇩ archiving…"
            title="Create ~/.glorbo/backups/YYYY-MM-DD.tar.zst snapshot (live)"
            data-confirm="Create a backup archive now? This reads the live WAL while agents run — safe for snapshots but not for byte-exact restore testing."
          >
            ⇩ backup
          </button>
          <button
            type="button"
            class="gl-btn"
            phx-click="new_project"
          >
            + new project
          </button>
          <button
            type="button"
            class="gl-btn gl-btn--primary"
            phx-click="new_agent"
          >
            + new agent
          </button>
        </div>
      </header>

      <div class="gl-overview__stats">
        <StatCard.stat_card
          label="agents running"
          value={@company.agents_alive}
          unit={"/ #{@company.agents_total}"}
          sub={"#{@company.agents_idle} idle · #{@company.agents_crashed} crashed · #{@company.agents_warn} warn"}
          spark={@company.sparks.agents}
          tone={:accent}
        />
        <StatCard.stat_card
          label="open tasks"
          value={@company.open_tasks}
          sub={"#{@company.tasks_approval} awaiting approval · #{@company.tasks_review} in progress"}
          spark={@company.sparks.tasks}
          spark_color="var(--gl-cyan)"
        />
        <StatCard.stat_card
          label="budget · this month"
          value={"$" <> two_dp(@company.budget_used)}
          unit={"/ $" <> zero_dp(@company.budget_cap)}
          sub={"#{@company.budget_pct}% used"}
          spark={@company.sparks.budget}
          spark_color={
            if @company.budget_pct > 80, do: "var(--gl-amber)", else: "var(--gl-accent-dim)"
          }
          tone={if @company.budget_pct > 80, do: :amber, else: :accent}
        />
        <StatCard.stat_card
          label="invocations · 24h"
          value={@company.invocations_24h}
          sub="from agent.complete audit events"
          spark={@company.sparks.invocations}
          spark_color="var(--gl-violet)"
        />
      </div>

      <div class="gl-overview__main gl-overview__main--with-org">
        <section class="gl-panel gl-overview__roster">
          <header class="gl-panel__header">
            <span>agents/</span>
            <span class="gl-panel__title">roster</span>
            <span class="gl-panel__hint">click row → agent detail</span>
          </header>
          <div class="gl-panel__body gl-panel__body--flush">
            <table class="gl-agent-table">
              <thead>
                <tr>
                  <th>status</th>
                  <th>agent</th>
                  <th>activity</th>
                  <th>provider</th>
                  <th>net</th>
                  <th>budget</th>
                  <th>last wake</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={a <- @company.agents}
                  phx-click="open_agent"
                  phx-value-slug={a.slug}
                  phx-keydown="open_agent"
                  phx-key="Enter"
                  role="link"
                  tabindex="0"
                  aria-label={"Open agent #{a.slug}"}
                  class="gl-agent-table__row"
                >
                  <td><StatusPill.status_pill status={a.pill_status} label={a.pill_label} /></td>
                  <td>
                    <div class="gl-agent-table__name">{a.slug}</div>
                    <div class="gl-agent-table__role gl-muted">{a.role}</div>
                  </td>
                  <td class="gl-muted gl-agent-table__activity">{a.activity}</td>
                  <td>
                    <div>{a.provider}</div>
                    <div class="gl-muted gl-agent-table__model">{a.model}</div>
                  </td>
                  <td>
                    <span class="gl-badge">{a.network}</span>
                  </td>
                  <td>
                    <div :if={a.budget_tracked?} class="gl-budget-bar">
                      <span
                        class={[
                          "gl-budget-bar__fill",
                          a.budget_cls && "gl-budget-bar__fill--" <> a.budget_cls
                        ]}
                        style={"width: #{a.budget_pct}%;"}
                      />
                      <span class="gl-muted gl-agent-table__budget-text">
                        ${two_dp(a.budget_used)}/${zero_dp(a.budget_cap)}
                      </span>
                    </div>
                    <span :if={not a.budget_tracked?} class="gl-muted">untracked</span>
                  </td>
                  <td class="gl-muted">{a.last_wake}</td>
                </tr>
                <tr :if={@company.agents == []}>
                  <td colspan="7" class="gl-empty gl-empty--inline">
                    No agents yet. Scaffold one with <code>glorbo new agent {@company_slug}/&lt;name&gt;</code>.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="gl-panel gl-overview__org">
          <header class="gl-panel__header">
            <span>org/</span>
            <span class="gl-panel__title">chart</span>
            <span class="gl-panel__hint">reports_to</span>
          </header>
          <div class="gl-panel__body gl-panel__body--flush">
            <pre class="gl-orgchart"><span class="gl-orgchart__line"><span class="gl-orgchart__director">director</span> <span class="gl-muted">(human · you)</span></span><span :for={row <- @company.org_chart} class="gl-orgchart__line"><span class="gl-orgchart__prefix"> {row.prefix}</span><span class="gl-orgchart__name">{row.agent.slug}</span>  <span class="gl-muted">{row.agent.role}</span>  <span class={["gl-orgchart__state", "gl-orgchart__state--" <> Atom.to_string(row.agent.pill_status)]}>{org_state_glyph(row.agent.pill_status)} {row.agent.pill_label}</span></span>
            </pre>
            <p
              :if={@company.org_chart == []}
              class="gl-muted gl-panel__body gl-panel__body--flush gl-org-empty"
            >
              No agents — hire one to start the chart.
            </p>
          </div>
        </section>
      </div>

      <div class="gl-overview__bottom">
        <section class="gl-panel gl-overview__audit-tail">
          <header class="gl-panel__header">
            <span>audit.tail</span>
            <.link
              navigate={"/companies/#{@company_slug}/audit"}
              class="gl-panel__hint gl-overview__audit-link"
            >
              full log →
            </.link>
          </header>
          <div class="gl-panel__body gl-panel__body--flush">
            <ol class="gl-activity">
              <li :for={e <- @company.audit_tail} class="gl-activity__row">
                <time class="gl-activity__ts gl-tabular" datetime={e.ts}>{e.ts_short}</time>
                <div class="gl-activity__body">
                  <span class="gl-activity__actor">{e.actor}</span>
                  <span class="gl-muted">·</span>
                  <span>{e.action}</span>
                  <span class="gl-muted">·</span>
                  <span>{e.target_short}</span>
                </div>
              </li>
              <li :if={@company.audit_tail == []} class="gl-activity__row gl-muted">
                No audit events this month.
              </li>
            </ol>
          </div>
        </section>

        <div class="gl-overview__side">
          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>projects/</span>
              <span class="gl-panel__hint">{length(@company.projects)} projects</span>
            </header>
            <div class="gl-panel__body">
              <ul class="gl-bar-list">
                <li :for={p <- @company.projects} class="gl-bar-row">
                  <div class="gl-bar-row__label">
                    <div>{p.slug}</div>
                    <div class="gl-muted gl-bar-row__sub">{p.task_count} tasks</div>
                  </div>
                  <div class="gl-bar-row__track">
                    <span
                      class={["gl-bar-row__fill", p.burn_cls && "gl-bar-row__fill--" <> p.burn_cls]}
                      style={"width: #{p.burn_pct}%;"}
                    />
                  </div>
                  <div class="gl-bar-row__val gl-tabular">{p.burn_pct}%</div>
                </li>
                <li :if={@company.projects == []} class="gl-muted">No projects.</li>
              </ul>
            </div>
          </section>

          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>providers/</span>
              <span class="gl-panel__title">runtime</span>
              <.link navigate={~p"/providers"} class="gl-panel__hint gl-overview__audit-link">
                registry →
              </.link>
            </header>
            <div class="gl-panel__body">
              <ul class="gl-bar-list">
                <li :for={p <- @company.provider_summary} class="gl-bar-row gl-bar-row--provider">
                  <div class="gl-bar-row__label">
                    <div>{p.name}</div>
                    <div class="gl-muted gl-bar-row__sub">
                      {p.agent_count} agent{if p.agent_count == 1, do: "", else: "s"}{if p.version,
                        do: " · " <> p.version,
                        else: ""}
                    </div>
                  </div>
                  <StatusPill.status_pill status={p.pill} label={p.pill_label} />
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>

      <%!-- company.md edit modal (opens via `edit_company_md` event) --%>
      <div :if={@edit_company_md} class="gl-modal-scrim" phx-click-away="cancel_company_md">
        <form
          phx-submit="save_company_md"
          phx-window-keydown="cancel_company_md"
          phx-key="Escape"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-company-md-title"
        >
          <header class="gl-modal__header">
            <div id="gl-company-md-title">
              <span class="gl-muted">companies/{@company_slug}/</span><strong>company.md</strong>
            </div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="cancel_company_md"
              aria-label="Close"
            >
              ✕
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">name</span>
              <input
                type="text"
                name="name"
                value={@edit_company_md.name}
                maxlength="200"
                class="gl-input"
                required
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">description</span>
              <input
                type="text"
                name="description"
                value={@edit_company_md.description}
                maxlength="500"
                class="gl-input"
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">icon</span>
              <input
                type="text"
                name="icon"
                value={@edit_company_md.icon}
                maxlength="100"
                class="gl-input"
                placeholder="fa-building"
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">monthly budget (USD)</span>
              <input
                type="number"
                name="monthly_usd"
                value={@edit_company_md.monthly_usd}
                min="0"
                step="0.01"
                class="gl-input"
                placeholder="100.00"
              />
            </label>
            <label class="gl-form__row gl-form__row--stretch">
              <span class="gl-form__label">body (markdown)</span>
              <textarea name="body" rows="10" class="gl-input gl-company-md-form__body">{@edit_company_md.body}</textarea>
            </label>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="cancel_company_md">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">save</button>
          </footer>
        </form>
      </div>

      <div :if={@new_agent_open?} class="gl-modal-scrim" phx-click-away="new_agent_cancel">
        <form
          phx-submit="new_agent_create"
          phx-window-keydown="new_agent_cancel"
          phx-key="Escape"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-new-agent-title"
        >
          <header class="gl-modal__header">
            <div id="gl-new-agent-title">
              <strong>+ new agent</strong>
              <span class="gl-muted">· {@company_slug}</span>
            </div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="new_agent_cancel"
              aria-label="Close"
            >
              ✕
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">slug</span>
              <input
                type="text"
                name="slug"
                class="gl-input"
                required
                maxlength="64"
                pattern="[a-z][a-z0-9_-]*"
                title="Lowercase letter start, then letters / digits / dashes / underscores"
                placeholder="engineer"
                autocomplete="off"
                autofocus
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">role</span>
              <input
                type="text"
                name="role"
                class="gl-input"
                maxlength="200"
                placeholder="Software Engineer"
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">provider</span>
              <select name="provider" class="gl-input">
                <option value="">(default: claude-code)</option>
                <option :for={p <- @provider_options} value={p}>{p}</option>
              </select>
            </label>
            <p class="gl-muted" style="font-size: 11px;">
              Creates <code>agents/&lt;slug&gt;/</code>
              with <code>AGENT.md</code>, <code>inbox/</code>, <code>outbox/</code>, <code>workspace/</code>. Edit
              <code>AGENT.md</code>
              afterward to refine
              permissions and heartbeat.
            </p>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="new_agent_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">create</button>
          </footer>
        </form>
      </div>

      <div :if={@new_project_open?} class="gl-modal-scrim" phx-click-away="new_project_cancel">
        <form
          phx-submit="new_project_create"
          phx-window-keydown="new_project_cancel"
          phx-key="Escape"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-new-project-title"
        >
          <header class="gl-modal__header">
            <div id="gl-new-project-title">
              <strong>+ new project</strong>
              <span class="gl-muted">· {@company_slug}</span>
            </div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="new_project_cancel"
              aria-label="Close"
            >
              ✕
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">slug</span>
              <input
                type="text"
                name="slug"
                class="gl-input"
                required
                maxlength="64"
                pattern="[a-z0-9][a-z0-9-]*"
                title="Lowercase letters / digits / dashes"
                placeholder="website-redesign"
                autocomplete="off"
                autofocus
              />
            </label>
            <p class="gl-muted" style="font-size: 11px;">
              Creates <code>projects/&lt;slug&gt;/</code>
              with <code>project.md</code>, <code>tasks/</code>, <code>attachments/</code>, and
              <code>history/</code>
              scaffolding. Add tasks via <strong>+ new task</strong>
              on the Kanban board.
            </p>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="new_project_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">create</button>
          </footer>
        </form>
      </div>
    </section>
    """
  end

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("edit_company_md", _params, socket) do
    base = base_dir()
    slug = socket.assigns.company_slug
    co_path = Path.join([base, "companies", slug])
    form = load_company_md_form(co_path, slug)
    {:noreply, assign(socket, :edit_company_md, form)}
  end

  def handle_event("cancel_company_md", _params, socket) do
    {:noreply, assign(socket, :edit_company_md, nil)}
  end

  def handle_event("save_company_md", params, socket) do
    base = base_dir()
    slug = socket.assigns.company_slug
    co_path = Path.join([base, "companies", slug])

    case write_company_md(co_path, params) do
      :ok ->
        data = load_company_data(base, slug, co_path)

        {:noreply,
         socket
         |> assign(:edit_company_md, nil)
         |> assign(:company, data)
         |> assign(:company_name, data.company_name)
         |> put_flash(:info, "Saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  def handle_event("open_agent", %{"slug" => slug}, socket) do
    company = socket.assigns.company_slug
    {:noreply, push_navigate(socket, to: ~p"/companies/#{company}/agents/#{slug}")}
  end

  def handle_event("reindex", _params, socket) do
    {:ok, %{indexed: i, skipped: s, deleted: d}} =
      Glorbo.Filesystem.Reindex.run(base: base_dir())

    {:noreply, put_flash(socket, :info, "reindex ok — indexed=#{i} skipped=#{s} deleted=#{d}")}
  end

  def handle_event("backup", _params, socket) do
    case Glorbo.Backup.run(base: base_dir(), force_live: true) do
      {:ok, path} ->
        {:noreply, put_flash(socket, :info, "backup ok — #{Path.basename(path)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "backup failed: #{inspect(reason)}")}
    end
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply, assign(socket, :new_agent_open?, true)}
  end

  def handle_event("new_agent_cancel", _params, socket) do
    {:noreply, assign(socket, :new_agent_open?, false)}
  end

  def handle_event("new_agent_create", params, socket) do
    slug = Map.get(params, "slug", "") |> String.trim()
    role = Map.get(params, "role", "") |> String.trim()
    provider = Map.get(params, "provider", "") |> String.trim()

    argv =
      ["#{socket.assigns.company_slug}/#{slug}"]
      |> append_if_nonempty(["--role", role])
      |> append_if_nonempty(["--provider", provider])

    case Glorbo.CLI.Scaffold.Agent.run(argv) do
      {:new_agent, 0, msg} ->
        base = base_dir()
        co_path = Path.join([base, "companies", socket.assigns.company_slug])
        data = load_company_data(base, socket.assigns.company_slug, co_path)

        flash_msg =
          if String.contains?(msg, "already exists"),
            do: "Agent #{slug} already exists — no change.",
            else: "Created agent: #{slug}"

        {:noreply,
         socket
         |> assign(:new_agent_open?, false)
         |> assign(:company, data)
         |> put_flash(:info, flash_msg)}

      {:new_agent, _nonzero, msg} ->
        {:noreply, put_flash(socket, :error, String.trim(msg))}
    end
  end

  def handle_event("new_project", _params, socket) do
    {:noreply, assign(socket, :new_project_open?, true)}
  end

  def handle_event("new_project_cancel", _params, socket) do
    {:noreply, assign(socket, :new_project_open?, false)}
  end

  def handle_event("new_project_create", params, socket) do
    slug = Map.get(params, "slug", "") |> String.trim()
    argv = ["#{socket.assigns.company_slug}/#{slug}"]

    case Glorbo.CLI.Scaffold.Project.run(argv) do
      {:new_project, 0, msg} ->
        base = base_dir()
        co_path = Path.join([base, "companies", socket.assigns.company_slug])
        data = load_company_data(base, socket.assigns.company_slug, co_path)

        flash_msg =
          if String.contains?(msg, "already exists"),
            do: "Project #{slug} already exists — no change.",
            else: "Created project: #{slug}"

        {:noreply,
         socket
         |> assign(:new_project_open?, false)
         |> assign(:company, data)
         |> put_flash(:info, flash_msg)}

      {:new_project, _nonzero, msg} ->
        {:noreply, put_flash(socket, :error, String.trim(msg))}
    end
  end

  defp append_if_nonempty(argv, [_flag, ""]), do: argv
  defp append_if_nonempty(argv, extra), do: argv ++ extra

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_company_data(base, slug, co_path) do
    agents = load_agents(base, slug, co_path)
    audit = load_audit_tail(co_path, 8)
    {tasks, projects_stats} = load_projects_and_tasks(co_path)
    budget = load_company_budget(co_path, agents)
    providers_summary = build_provider_summary(agents)
    # UAT4: sparks now read from the same audit lines `load_audit_tail`
    # already fetched (reuse, no extra I/O) and from agent + task
    # data. No more synthetic placeholders.
    all_audit_lines = audit[:all_lines] || []
    sparks = build_sparks(all_audit_lines, tasks, agents)

    %{
      company_name: company_name(co_path, slug),
      agents: agents,
      agents_alive: Enum.count(agents, &(&1.pill_status == :alive)),
      agents_idle: Enum.count(agents, &(&1.pill_status == :idle)),
      agents_warn: Enum.count(agents, &(&1.pill_status == :warn)),
      agents_crashed: Enum.count(agents, &(&1.pill_status == :stop)),
      agents_total: length(agents),
      open_tasks: Enum.count(tasks, &(&1.status != "done")),
      # UAT4: align with how Kanban's "review" column writes status.
      # column_key_to_status(:review) → "pending", and the /approvals
      # queue resolves approved/denied via Gate. So "awaiting approval"
      # covers anything sitting in the review lane: pending,
      # pending-approval (legacy), approved, denied (terminal but
      # still visible until the Gate moves them).
      tasks_approval:
        Enum.count(tasks, &(&1.status in ["pending", "pending-approval", "approved", "denied"])),
      tasks_review: Enum.count(tasks, &(&1.status == "in-progress")),
      budget_used: budget.used,
      budget_cap: budget.cap,
      budget_pct: budget.pct,
      invocations_24h: audit.invocations_24h,
      audit_tail: audit.tail,
      projects: projects_stats,
      provider_summary: providers_summary,
      sparks: sparks,
      org_chart: build_org_chart(agents)
    }
  end

  # Render agents as a nested tree keyed by `reports_to`. Agents with
  # no reports_to (or a reports_to pointing at an unknown slug) become
  # top-level children of the director. Output is a flat list of
  # `%{depth, prefix, agent}` rows so the HEEX template just maps
  # them — no recursion in the view.
  defp build_org_chart(agents) do
    agent_map = Map.new(agents, &{&1.slug, &1})
    children_map = build_children_map(agents, agent_map)
    roots = find_org_roots(agents, agent_map)

    Enum.flat_map(Enum.sort_by(roots, & &1.slug), fn root ->
      walk_org_tree(root, children_map, 0, [])
    end)
  end

  defp build_children_map(agents, agent_map) do
    Enum.reduce(agents, %{}, fn agent, acc ->
      parent =
        if agent.reports_to && Map.has_key?(agent_map, agent.reports_to),
          do: agent.reports_to

      Map.update(acc, parent, [agent], &[agent | &1])
    end)
  end

  # Roots are agents whose reports_to is nil or points at a non-existent slug.
  defp find_org_roots(agents, agent_map) do
    Enum.filter(agents, fn a ->
      a.reports_to == nil or not Map.has_key?(agent_map, a.reports_to)
    end)
  end

  # Recursive tree walker — yields one row per agent with ASCII tree
  # prefix. `ancestors_last?` is a list of booleans marking whether
  # each ancestor was its parent's last sibling; used to draw the
  # correct `│  ` vs `   ` continuation columns.
  defp walk_org_tree(agent, children_map, depth, ancestors_last?) do
    kids = children_map |> Map.get(agent.slug, []) |> Enum.sort_by(& &1.slug)
    last_count = max(length(kids) - 1, 0)

    row = %{
      depth: depth,
      prefix: org_prefix(ancestors_last?, depth == 0),
      agent: agent
    }

    rest =
      kids
      |> Enum.with_index()
      |> Enum.flat_map(fn {kid, idx} ->
        last? = idx == last_count
        walk_org_tree(kid, children_map, depth + 1, ancestors_last? ++ [last?])
      end)

    [row | rest]
  end

  defp org_prefix(_ancestors_last?, true), do: ""

  defp org_prefix(ancestors_last?, false) do
    last_idx = length(ancestors_last?) - 1

    ancestors_last?
    |> Enum.with_index()
    |> Enum.map_join("", fn
      {true, ^last_idx} -> "└─ "
      {false, ^last_idx} -> "├─ "
      {true, _} -> "   "
      {false, _} -> "│  "
    end)
  end

  defp company_name(co_path, slug) do
    case File.read(Path.join(co_path, "company.md")) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, %{"name" => n}, _} -> to_string(n)
          _ -> slug
        end

      _ ->
        slug
    end
  end

  # For each agent directory, load agent.md and derive: status pill,
  # activity (one-liner from the most recent inbox task file if any),
  # budget (Ledger.fetch), last_wake (most recent agent.wake audit).
  defp load_agents(base, slug, co_path) do
    agents_dir = Path.join(co_path, "agents")
    ym = current_year_month()
    audit_map = audit_last_wakes(co_path, ym)

    case File.ls(agents_dir) do
      {:ok, ags} ->
        ags
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        # Hide the `.archive/` sibling — retired agents live there and
        # don't belong in the active roster.
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&build_agent_row(&1, base, slug, agents_dir, audit_map, ym))

      _ ->
        []
    end
  end

  defp build_agent_row(agent_slug, _base, _company_slug, agents_dir, audit_map, year_month) do
    agent_path = Path.join(agents_dir, agent_slug)
    agent_md = Glorbo.Agent.FileLayout.agent_md(agent_path)

    meta = parse_agent_md(agent_md)

    used = agent_used_usd(agent_slug, year_month)
    cap = (meta[:budget_monthly_usd] || 0.0) * 1.0

    {pct, cls} = budget_classify(used, cap)
    tracked? = cap > 0

    %{
      slug: agent_slug,
      name: meta[:name] || agent_slug,
      role: meta[:role] || "—",
      activity: activity_hint(agent_path, meta),
      provider: meta[:provider] || "—",
      model: meta[:model] || "",
      network: meta[:network] || "none",
      reports_to: meta[:reports_to],
      budget_used: used,
      budget_cap: cap,
      budget_pct: pct,
      budget_cls: cls,
      budget_tracked?: tracked?,
      last_wake: Map.get(audit_map, agent_slug, "—"),
      pill_status: agent_pill_status(meta, pct, tracked?, agent_slug),
      pill_label: agent_pill_label(meta, pct, tracked?, agent_slug)
    }
  end

  defp parse_agent_md(path) do
    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      %{
        name: to_string(meta["name"] || ""),
        role: to_string(meta["role"] || ""),
        provider: to_string(meta["provider"] || ""),
        model: to_string(meta["model"] || ""),
        network: to_string(meta["network"] || ""),
        reports_to: meta["reports_to"] && to_string(meta["reports_to"]),
        budget_monthly_usd: budget_cents_to_dollars(meta["budget"])
      }
    else
      _ -> %{}
    end
  end

  defp budget_cents_to_dollars(%{"monthly_usd" => n}) when is_number(n), do: n * 1.0
  defp budget_cents_to_dollars(_), do: 0.0

  defp agent_used_usd(agent_slug, year_month) do
    case Ledger.fetch(agent_slug, year_month) do
      %{cost_usd_cents: c} when is_integer(c) -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
  end

  # Whether the agent's Agent.Server is running. Budget warnings win
  # over alive/idle because they're actionable.
  #
  # UAT4: the previous version documented "check the Registry" but
  # never actually did — so the agents-running stat was stuck at 0
  # even after `glorbo up` started the full supervision tree.
  defp agent_pill_status(_meta, pct, tracked?, _slug) when tracked? and pct > 90, do: :warn

  defp agent_pill_status(_meta, _pct, _tracked?, slug) do
    # Match sidebar semantics: :alive only for actively busy dispatch;
    # registered-but-quiet is :idle, non-zero exit is :stop.
    agent_runtime_status(slug)
  end

  defp agent_pill_label(_meta, pct, tracked?, _slug) when tracked? and pct > 90,
    do: "budget #{pct}%"

  defp agent_pill_label(_meta, _pct, _tracked?, slug) do
    case agent_runtime_status(slug) do
      :alive -> "alive"
      :stop -> "stop"
      _ -> "idle"
    end
  end

  # Lookup is by slug across all companies because the LV is already
  # scoped to a company via the URL — we could pipe company through
  # and match `{:agent_server, company, slug}` if this ever needs
  # cross-company disambiguation. Today the Registry's uniqueness
  # guarantees safety for a single company/agent pair.
  # Richer pill state: :alive when actively dispatching, :stop on
  # non-zero exit, :idle when registered-but-quiet or no server.
  # Matches GlorboWeb.Components.Sidebar.live_status/2.
  defp agent_runtime_status(slug) do
    case Registry.match(Glorbo.Agent.Registry, {:agent_server, :_, slug}, :_) do
      [{pid, _} | _] when is_pid(pid) ->
        try do
          classify_runtime_status(Glorbo.Agent.Server.status(pid))
        rescue
          _ -> :idle
        catch
          :exit, _ -> :idle
        end

      _ ->
        :idle
    end
  rescue
    _ -> :idle
  end

  defp classify_runtime_status(%{state: :busy}), do: :alive
  defp classify_runtime_status(%{last_exit_status: s}) when is_integer(s) and s != 0, do: :stop
  defp classify_runtime_status(%{last_exit_status: "stopped_by_director"}), do: :stop
  defp classify_runtime_status(%{last_exit_status: {:crashed, _}}), do: :stop
  defp classify_runtime_status(_), do: :idle

  # Quick first-line hint from agent's newest inbox file, else fall
  # back to role. Keeps the column readable without re-rendering
  # every file on every event.
  defp activity_hint(agent_path, meta) do
    inbox = Path.join(agent_path, "inbox")

    case File.ls(inbox) do
      {:ok, files} ->
        md = Enum.filter(files, &String.ends_with?(&1, ".md"))

        case Enum.sort(md) |> List.last() do
          nil -> meta[:role] || "—"
          f -> read_first_line(Path.join(inbox, f)) || meta[:role] || "—"
        end

      _ ->
        meta[:role] || "—"
    end
  end

  defp read_first_line(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", parts: 2)
        |> List.first()
        |> case do
          nil -> nil
          s -> String.slice(s, 0, 80)
        end

      _ ->
        nil
    end
  end

  # Scan audit/YYYY-MM.jsonl for agent.wake events; for each agent
  # remember the newest. Hot path on every overview re-render; capped
  # at a cheap line count.
  defp audit_last_wakes(co_path, year_month) do
    path = Path.join([co_path, "audit", "#{year_month}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.reduce(%{}, fn line, acc ->
          case Jason.decode(line) do
            {:ok, %{"action" => "agent.dispatch", "actor" => _, "agent" => slug, "ts" => ts}} ->
              Map.put_new(acc, slug, relative_from_iso(ts))

            {:ok, %{"action" => "agent.wake", "actor" => slug, "ts" => ts}} ->
              Map.put_new(acc, slug, relative_from_iso(ts))

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp relative_from_iso(iso) when is_binary(iso) do
    GlorboWeb.TimeFormat.relative(iso)
  end

  defp relative_from_iso(_), do: "—"

  # Collect audit tail (last N events) + 24h invocation count.
  # UAT4: also include the previous month's file when the current one
  # is early-in-the-month so the 24h window doesn't drop events from
  # the day before a rollover.
  defp load_audit_tail(co_path, n) do
    current_ym = current_year_month()
    paths = [previous_year_month_file(co_path, current_ym), audit_path(co_path, current_ym)]

    lines =
      paths
      |> Enum.flat_map(&read_audit_lines/1)

    if lines == [] do
      %{tail: [], invocations_24h: 0, all_lines: []}
    else
      invocations_24h = count_invocations_24h(lines)

      tail =
        lines
        |> Enum.reverse()
        |> Enum.take(n)
        |> Enum.map(&decorate_audit_row/1)

      %{tail: tail, invocations_24h: invocations_24h, all_lines: lines}
    end
  end

  defp audit_path(co_path, ym), do: Path.join([co_path, "audit", "#{ym}.jsonl"])

  defp previous_year_month_file(co_path, current_ym) do
    [year, month] = current_ym |> String.split("-") |> Enum.map(&String.to_integer/1)

    {py, pm} =
      if month == 1, do: {year - 1, 12}, else: {year, month - 1}

    prev_ym = "#{py}-#{String.pad_leading(Integer.to_string(pm), 2, "0")}"
    audit_path(co_path, prev_ym)
  end

  defp read_audit_lines(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode/1)
        |> Enum.flat_map(fn
          {:ok, m} when is_map(m) -> [m]
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp count_invocations_24h(lines) do
    cutoff = DateTime.add(DateTime.utc_now(), -60 * 60 * 24, :second)

    Enum.count(lines, fn
      %{"action" => "agent.complete", "ts" => ts} ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp decorate_audit_row(e) do
    ts = to_string(e["ts"] || "")

    %{
      ts: ts,
      ts_short: short_ts(ts),
      actor: to_string(e["actor"] || "system"),
      action: to_string(e["action"] || "—"),
      target_short: target_short(e["target"])
    }
  end

  defp short_ts(ts) when is_binary(ts) and byte_size(ts) >= 19, do: String.slice(ts, 11, 8)
  defp short_ts(_), do: "—"

  defp target_short(nil), do: ""

  defp target_short(t) when is_binary(t) do
    t |> String.split("/") |> List.last() |> to_string()
  end

  defp target_short(t), do: inspect(t)

  # Walk projects/*/tasks/*.md once, returning both the task list (for
  # overall stat computations) and per-project stats (task count +
  # "burn": percentage of tasks not-done).
  defp load_projects_and_tasks(co_path) do
    projects_dir = Path.join(co_path, "projects")

    case File.ls(projects_dir) do
      {:ok, projects} ->
        projects = Enum.filter(projects, &File.dir?(Path.join(projects_dir, &1)))

        all_tasks =
          Enum.flat_map(projects, fn p ->
            load_project_tasks(Path.join(projects_dir, p))
          end)

        stats =
          Enum.map(projects, fn p ->
            tasks = load_project_tasks(Path.join(projects_dir, p))
            build_project_stats(p, tasks)
          end)

        {all_tasks, stats}

      _ ->
        {[], []}
    end
  end

  defp load_project_tasks(project_dir) do
    tasks_dir = Path.join(project_dir, "tasks")

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&parse_task(Path.join(tasks_dir, &1)))

      _ ->
        []
    end
  end

  defp parse_task(path) do
    case File.read(path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _} -> [%{status: to_string(meta["status"] || "")}]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp build_project_stats(slug, tasks) do
    count = length(tasks)
    done = Enum.count(tasks, &(&1.status == "done"))
    burn = if count > 0, do: div(done * 100, count), else: 0

    cls =
      cond do
        burn > 85 -> "accent"
        burn > 60 -> "amber"
        true -> nil
      end

    %{slug: slug, task_count: count, burn_pct: burn, burn_cls: cls}
  end

  defp load_company_budget(co_path, agents) do
    used = Enum.reduce(agents, 0.0, fn a, acc -> acc + a.budget_used end)
    cap_from_agents = Enum.reduce(agents, 0.0, fn a, acc -> acc + a.budget_cap end)
    cap_from_company = parse_company_budget_cap(co_path)
    cap = if cap_from_company > 0, do: cap_from_company, else: cap_from_agents

    pct = if cap > 0, do: round(used / cap * 100), else: 0

    %{used: used, cap: cap, pct: pct}
  end

  defp parse_company_budget_cap(co_path) do
    with {:ok, content} <- File.read(Path.join(co_path, "company.md")),
         {:ok, meta, _} <- Frontmatter.parse(content) do
      case meta["budget"] do
        %{"monthly_usd" => n} when is_number(n) -> n * 1.0
        _ -> 0.0
      end
    else
      _ -> 0.0
    end
  end

  # Group roster by provider; cross-reference CLI.Registry to show
  # routable/untracked/not-installed status per provider.
  defp build_provider_summary(agents) do
    by_provider = Enum.frequencies_by(agents, & &1.provider)

    by_provider
    |> Enum.sort_by(fn {name, _count} -> name end)
    |> Enum.map(fn {name, count} -> provider_summary_row(name, count) end)
  end

  defp provider_summary_row(name, count) do
    provider = safe_registry_get(name)

    {pill, pill_label} =
      case provider && Provider.status(provider) do
        :routable -> {:alive, "routable"}
        :installed_untracked -> {:info, "untracked"}
        :not_installed -> {:stop, "not installed"}
        _ -> {:idle, "unknown"}
      end

    %{
      name: name,
      agent_count: count,
      version: provider && provider.version,
      pill: pill,
      pill_label: pill_label
    }
  end

  defp safe_registry_get(name) do
    CLIRegistry.get(name)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # Sparklines — hour-bucket audit events into 30 bars (last 30h).
  # UAT4: was returning synthetic pseudo-random patterns; now reads
  # from the same audit.jsonl we already loaded for the tail +
  # 24h-invocation count. All four sparks share the same hourly
  # grid; zero-counts render as empty bars.
  defp build_sparks(audit_lines, _tasks, agents) do
    now = DateTime.utc_now()
    # 30 buckets, one per hour, oldest-first (left) → newest (right).
    bucket_starts =
      for i <- 29..0//-1, do: DateTime.add(now, -i * 3600, :second)

    %{
      # Agents are a roster snapshot, not a time series — show
      # running agents across the 30 buckets (flat line) so the
      # spark area isn't empty.
      agents: List.duplicate(Enum.count(agents, &(&1.pill_status == :alive)), 30),
      tasks: histogram(audit_lines, "task.create", bucket_starts),
      budget: bucket_dollars(audit_lines, bucket_starts),
      invocations: histogram(audit_lines, "agent.complete", bucket_starts)
    }
  end

  # Count audit lines with the given action, bucketed by hour.
  defp histogram(lines, action, bucket_starts) do
    Enum.map(bucket_starts, fn bucket_start ->
      bucket_end = DateTime.add(bucket_start, 3600, :second)

      Enum.count(lines, fn
        %{"action" => ^action, "ts" => ts} ->
          within_bucket?(ts, bucket_start, bucket_end)

        _ ->
          false
      end)
    end)
  end

  # Sum agent.complete cost_usd_cents per bucket → dollars spent per
  # hour. Falls back to token counts if cost isn't on the line.
  defp bucket_dollars(lines, bucket_starts) do
    Enum.map(bucket_starts, fn bucket_start ->
      bucket_end = DateTime.add(bucket_start, 3600, :second)

      lines
      |> Enum.filter(fn
        %{"action" => "agent.complete", "ts" => ts} ->
          within_bucket?(ts, bucket_start, bucket_end)

        _ ->
          false
      end)
      |> Enum.reduce(0, fn %{"detail" => d}, acc ->
        case d do
          %{"cost_usd_cents" => c} when is_integer(c) -> acc + c
          _ -> acc
        end
      end)
      # cents → dollars for the spark y-axis
      |> Kernel./(100)
    end)
  end

  defp within_bucket?(ts, bucket_start, bucket_end) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        DateTime.compare(dt, bucket_start) != :lt and
          DateTime.compare(dt, bucket_end) == :lt

      _ ->
        false
    end
  end

  defp within_bucket?(_, _, _), do: false

  defp org_state_glyph(:alive), do: "●"
  defp org_state_glyph(:warn), do: "⚠"
  defp org_state_glyph(:stop), do: "✕"
  defp org_state_glyph(_), do: "○"

  # ---------------------------------------------------------------------------
  # company.md editor (form state + atomic write)
  # ---------------------------------------------------------------------------

  defp load_company_md_form(co_path, slug) do
    path = Path.join(co_path, "company.md")

    {meta, body} =
      case File.read(path) do
        {:ok, content} ->
          case Frontmatter.parse(content) do
            {:ok, m, b} -> {m, b}
            _ -> {%{}, ""}
          end

        _ ->
          {%{}, ""}
      end

    monthly =
      case meta["budget"] do
        %{"monthly_usd" => n} when is_number(n) -> to_string(n)
        _ -> ""
      end

    %{
      name: to_string(meta["name"] || slug),
      description: to_string(meta["description"] || ""),
      icon: to_string(meta["icon"] || ""),
      monthly_usd: monthly,
      body: body || ""
    }
  end

  defp write_company_md(co_path, params) do
    name = params |> Map.get("name", "") |> String.trim()
    description = params |> Map.get("description", "") |> String.trim()
    icon = params |> Map.get("icon", "") |> String.trim()
    monthly_raw = params |> Map.get("monthly_usd", "") |> String.trim()
    body = params |> Map.get("body", "") |> String.trim_trailing()

    if name == "" do
      {:error, :name_required}
    else
      monthly = parse_monthly(monthly_raw)

      yaml =
        render_company_yaml(%{
          name: name,
          description: description,
          icon: icon,
          monthly_usd: monthly
        })

      content = "---\n" <> yaml <> "---\n\n" <> body <> "\n"

      path = Path.join(co_path, "company.md")
      tmp = path <> ".tmp"

      with :ok <- File.write(tmp, content),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, _} = err -> err
      end
    end
  end

  defp parse_monthly(""), do: nil

  defp parse_monthly(raw) do
    case Float.parse(raw) do
      {n, _} when n >= 0 -> n
      _ -> nil
    end
  end

  # Build YAML frontmatter deterministically. We control every
  # string, so quoting is hand-rolled rather than dragging in a YAML
  # encoder — same pattern as TaskDefinition.write_frontmatter.
  defp render_company_yaml(%{name: name, description: desc, icon: icon, monthly_usd: monthly}) do
    lines =
      [
        {"name", name},
        {"description", desc},
        {"icon", icon}
      ]
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Enum.map(fn {k, v} -> "#{k}: #{yaml_string(v)}\n" end)

    budget_block =
      case monthly do
        nil -> ""
        n -> "budget:\n  monthly_usd: #{Float.round(n * 1.0, 2)}\n"
      end

    Enum.join(lines) <> budget_block
  end

  defp yaml_string(s) do
    if String.contains?(s, [":", "#", "[", "]", "\"", "'", "\n"]) do
      ~s("#{String.replace(s, "\"", "\\\"")}")
    else
      s
    end
  end

  # Providers declared in the registry. Falls back to the bundled
  # builtins if the registry hasn't been started yet (e.g. tests that
  # don't boot the full app).
  defp provider_options do
    CLIRegistry.list()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  rescue
    _ -> ~w(claude-code codex gemini-cli hermes opencode pi)
  end
end
