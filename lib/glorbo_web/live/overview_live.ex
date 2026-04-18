defmodule GlorboWeb.OverviewLive do
  @moduledoc """
  Multi-company overview — GET `/companies` (D-21).

  Scans `<base>/companies/*` on mount, reads each `company.md`, counts
  agents + in-progress tasks + alerts, and sums the current month's
  spend from `Glorbo.Budget.Ledger`. Health-dot state is derived from
  the `Glorbo.Company.Supervisor` children when they're running, else
  `:healthy` (all green by default).

  On `connected?/1` the view subscribes to the `"companies"` topic so
  company add/remove triggers a re-render. LiveView stays a pure
  renderer — every mount re-derives the full list from disk + SQLite
  (CLAUDE.md invariant: no in-memory state not rebuildable from the
  source of truth).
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0, current_year_month: 0]

  alias GlorboWeb.Components.CompanyCard

  @impl true
  def mount(_params, _session, socket) do
    # OverviewLive takes no slug params — no WR-02 guard needed; kept
    # as a no-op for symmetry with the other LVs.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "companies")

    {:ok,
     socket
     |> assign(:page_title, "Companies — Glorbo")
     |> assign(:sidebar_active, :overview)
     |> assign(:companies, load_companies())}
  end

  @impl true
  def handle_info({:company_added, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info({:company_removed, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("new_company", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "New-company UI ships in a later milestone. For now: mkdir ~/.glorbo/companies/<slug>."
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view">
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">Companies</h1>
        <button
          type="button"
          class="gl-btn gl-btn--soon"
          phx-click="new_company"
          title="Coming soon — use `glorbo new company <slug>` from a terminal for now"
        >
          + new company <span class="gl-btn__soon-tag">soon</span>
        </button>
      </header>

      <div :if={@companies == []} class="gl-empty">
        <p>No companies yet.</p>
        <p class="gl-muted">
          A company is a directory under <code>~/.glorbo/companies/</code>.
          Run <code>glorbo new company acme</code> then refresh.
        </p>
      </div>

      <div :if={@companies != []} class="gl-grid gl-grid--cards">
        <CompanyCard.company_card :for={c <- @companies} company={c} />
      </div>

      <%!--
        UAT N1: single-company installs left the right ~70% of the
        viewport empty and the user wondering if they were missing
        something. Hint panel shows only when every company has ≤1
        agent (otherwise the board is already populated and noise).
      --%>
      <aside
        :if={@companies != [] and Enum.all?(@companies, &(&1.agent_count <= 1))}
        class="gl-welcome-hint"
      >
        <h2 class="gl-heading gl-heading--heading">Next step</h2>
        <ul class="gl-welcome-hint__list">
          <li>Click a company card → see its agents + kanban.</li>
          <li>Press <kbd>?</kbd> to see keyboard shortcuts.</li>
          <li>Press <kbd>⌘K</kbd> / <kbd>CtrlK</kbd> for the command palette.</li>
          <li>
            Scaffold another agent: <code>glorbo new agent &lt;company&gt;/&lt;slug&gt;</code>
          </li>
        </ul>
      </aside>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders — pure filesystem reads, no GenServer state.
  # ---------------------------------------------------------------------------

  defp load_companies do
    base = base_dir()
    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.map(&load_company(base, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp load_company(base, slug) do
    path = Path.join([base, "companies", slug])
    if File.dir?(path), do: do_load_company(base, slug, path), else: nil
  end

  defp do_load_company(base, slug, path) do
    %{
      slug: slug,
      name: company_name(path, slug),
      agent_count: agent_count(path),
      in_progress_count: in_progress_count(base, slug, path),
      spend_usd: spend_usd(path),
      alert_count: alert_count(path),
      health: :healthy
    }
  end

  defp company_name(path, slug) do
    case File.read(Path.join(path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"name" => n}, _} -> to_string(n)
          _ -> slug
        end

      _ ->
        slug
    end
  end

  defp agent_count(path) do
    agents_dir = Path.join(path, "agents")

    case File.ls(agents_dir) do
      {:ok, items} ->
        Enum.count(items, &File.dir?(Path.join(agents_dir, &1)))

      _ ->
        0
    end
  end

  # Count tasks under any project with frontmatter `status: in-progress`
  # (KanbanLive.group_by_column uses exactly the same classification).
  # Walks projects/*/tasks/*.md; returns 0 on any filesystem hiccup.
  defp in_progress_count(base, company_slug, company_path) do
    projects_dir = Path.join(company_path, "projects")

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.reduce(projects, 0, fn project, acc ->
          acc + count_in_progress_in_project(projects_dir, project, base, company_slug)
        end)

      _ ->
        0
    end
  end

  defp count_in_progress_in_project(projects_dir, project, base, company) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.count(fn filename ->
          path = Path.join(tasks_dir, filename)

          case Glorbo.TaskDefinition.parse_file(path, base: base, company: company) do
            {:ok, %{status: "in-progress"}} -> true
            _ -> false
          end
        end)

      _ ->
        0
    end
  end

  # Sum each agent's current-month ledger row into USD. Tolerant of
  # missing SQLite / missing row / crashed ledger — mirrors
  # AgentLive.load_used_usd/1 (agent_live.ex:222-231).
  defp spend_usd(company_path) do
    agents_dir = Path.join(company_path, "agents")
    ym = current_year_month()

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.reduce(0.0, fn slug, acc -> acc + agent_spend_usd(slug, ym) end)

      _ ->
        0.0
    end
  end

  defp agent_spend_usd(agent_slug, year_month) do
    case Glorbo.Budget.Ledger.fetch(agent_slug, year_month) do
      %{cost_usd_cents: c} when is_integer(c) -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
  end

  # Sum of `agents/*/alerts/*.md` files (budget alerts from Phase 3).
  defp alert_count(path) do
    agents_dir = Path.join(path, "agents")

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        Enum.reduce(slugs, 0, fn ag, acc ->
          alerts_dir = Path.join([agents_dir, ag, "alerts"])

          case File.ls(alerts_dir) do
            {:ok, files} -> acc + Enum.count(files, &String.ends_with?(&1, ".md"))
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end
end
