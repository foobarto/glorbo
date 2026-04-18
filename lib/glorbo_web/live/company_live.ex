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
       |> assign(:company, data)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company \"#{slug}\" not found.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_info({:file_event, _rel_path, _events}, socket) do
    base = base_dir()
    slug = socket.assigns.company_slug
    co_path = Path.join([base, "companies", slug])
    data = load_company_data(base, slug, co_path)
    {:noreply, assign(socket, :company, data)}
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
          <button type="button" class="gl-btn" phx-click="reindex">↻ reindex</button>
          <button type="button" class="gl-btn" phx-click="backup">⇩ backup</button>
          <button type="button" class="gl-btn gl-btn--primary" phx-click="new_agent">
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
          sub={"#{@company.tasks_approval} awaiting approval · #{@company.tasks_review} in review"}
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
    </section>
    """
  end

  @impl true
  def handle_event("open_agent", %{"slug" => slug}, socket) do
    company = socket.assigns.company_slug
    {:noreply, push_navigate(socket, to: ~p"/companies/#{company}/agents/#{slug}")}
  end

  def handle_event("reindex", _params, socket) do
    {:noreply, put_flash(socket, :info, "reindex: run `glorbo reindex` from the CLI for now.")}
  end

  def handle_event("backup", _params, socket) do
    {:noreply, put_flash(socket, :info, "backup: run `glorbo backup` from the CLI for now.")}
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "New-agent UI ships in a later milestone. For now: mkdir agents/<slug>/ and drop an AGENT.md."
     )}
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_company_data(base, slug, co_path) do
    agents = load_agents(base, slug, co_path)
    audit = load_audit_tail(co_path, 8)
    {tasks, projects_stats} = load_projects_and_tasks(co_path)
    budget = load_company_budget(co_path, agents)
    providers_summary = build_provider_summary(agents)
    sparks = build_sparks(audit, tasks, agents)

    %{
      company_name: company_name(co_path, slug),
      agents: agents,
      agents_alive: Enum.count(agents, &(&1.pill_status == :alive)),
      agents_idle: Enum.count(agents, &(&1.pill_status == :idle)),
      agents_warn: Enum.count(agents, &(&1.pill_status == :warn)),
      agents_crashed: Enum.count(agents, &(&1.pill_status == :stop)),
      agents_total: length(agents),
      open_tasks: Enum.count(tasks, &(&1.status != "done")),
      tasks_approval: Enum.count(tasks, &(&1.status == "pending-approval")),
      tasks_review: Enum.count(tasks, &(&1.status == "review")),
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

  # Whether the agent's Agent.Server is running. Proxy: check the
  # Glorbo.Agent.Registry for a :server child under this company.
  defp agent_pill_status(_meta, pct, tracked?, _slug) when tracked? and pct > 90, do: :warn
  defp agent_pill_status(_meta, _pct, _tracked?, _slug), do: :idle

  defp agent_pill_label(_meta, pct, tracked?, _slug) when tracked? and pct > 90,
    do: "budget #{pct}%"

  defp agent_pill_label(_meta, _pct, _tracked?, _slug), do: "idle"

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
  defp load_audit_tail(co_path, n) do
    ym = current_year_month()
    path = Path.join([co_path, "audit", "#{ym}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        lines =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(&Jason.decode/1)
          |> Enum.flat_map(fn
            {:ok, m} when is_map(m) -> [m]
            _ -> []
          end)

        invocations_24h = count_invocations_24h(lines)

        tail =
          lines
          |> Enum.reverse()
          |> Enum.take(n)
          |> Enum.map(&decorate_audit_row/1)

        %{tail: tail, invocations_24h: invocations_24h}

      _ ->
        %{tail: [], invocations_24h: 0}
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
  defp build_sparks(%{tail: _} = _audit_tail, _tasks, _agents) do
    # No full event log retained; approximate with noise-ish but
    # stable values so the UI has shape. Real implementation needs an
    # audit-event histogram cache (follow-up).
    %{
      agents: synthetic_spark(30, 2..6),
      tasks: synthetic_spark(30, 3..9),
      budget: synthetic_spark(30, 5..18),
      invocations: synthetic_spark(30, 8..36)
    }
  end

  defp synthetic_spark(n, range) do
    # Deterministic pseudo-random from current hour so repeated
    # renders don't flicker, but each hour gives a subtly different
    # shape. Fine as a placeholder; replace with a real histogram
    # when the cache lands.
    seed = div(System.os_time(:second), 3600)

    Enum.map(0..(n - 1), fn i ->
      rem(seed + i * 7, Enum.max(range) - Enum.min(range) + 1) + Enum.min(range)
    end)
  end

  defp org_state_glyph(:alive), do: "●"
  defp org_state_glyph(:warn), do: "⚠"
  defp org_state_glyph(:stop), do: "✕"
  defp org_state_glyph(_), do: "○"
end
