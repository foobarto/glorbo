defmodule GlorboWeb.GoalsLive do
  @moduledoc """
  Goals view — GET `/companies/:company/goals`
  (paperclip-ux-gaps §7).

  Reads `company.md` frontmatter `goals:` list and aggregates each
  goal's tasks (tasks whose `goal: <slug>` matches). For each goal
  shows: title, description, status, open task count, status
  breakdown, and a deep link to Kanban filtered by the goal slug.

  Tasks with no `goal:` frontmatter are grouped under an "(no goal)"
  pseudo-row at the bottom so the director sees unassigned work.
  Read-only — editing goals still happens by editing `company.md`
  from the sidebar file editor, which keeps `company.md` the source
  of truth.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.StatBreakdown

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not File.dir?(Path.join([base_dir(), "companies", co])) ->
        {:ok,
         socket
         |> put_flash(:error, "Company \"#{co}\" not found.")
         |> push_navigate(to: ~p"/companies")}

      true ->
        if connected?(socket),
          do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")

        {:ok, load_and_assign(socket, co)}
    end
  end

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    {:noreply, load_and_assign(socket, socket.assigns.company_slug)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-goals-page">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">{@company_slug} /</span> goals
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">
              <code>company.md</code>
              frontmatter <code>goals:</code>
              · referenced from task frontmatter <code>goal:</code>
            </span>
          </p>
        </div>
      </header>

      <p :if={@goals == [] and @unassigned_count == 0} class="gl-muted">
        No goals declared in <code>company.md</code>
        yet. Edit it from the sidebar to add <code>goals:</code>
        entries with <code>slug</code>, <code>title</code>, and optional <code>description</code>.
      </p>

      <div :if={@goals != [] or @unassigned_count > 0} class="gl-goals-list">
        <article :for={g <- @goals} class="gl-goal-card">
          <header class="gl-goal-card__head">
            <div>
              <strong>{g.title}</strong>
              <span class="gl-muted gl-goal-card__slug">· {g.slug}</span>
            </div>
            <div class="gl-goal-card__actions">
              <span class={["gl-badge", "gl-badge--" <> g.status]}>{g.status}</span>
              <.link
                navigate={~p"/companies/#{@company_slug}/kanban?goal=#{g.slug}"}
                class="gl-btn gl-btn--sm"
              >
                open in kanban →
              </.link>
            </div>
          </header>
          <p :if={g.description != ""} class="gl-goal-card__desc gl-muted">{g.description}</p>
          <div class="gl-goal-card__stats">
            <div>
              <span class="gl-muted">total</span>
              <strong>{g.task_count}</strong>
            </div>
            <div>
              <span class="gl-muted">open</span>
              <strong>{g.open_count}</strong>
            </div>
          </div>
          <StatBreakdown.stat_breakdown
            label="by status"
            buckets={g.breakdown}
          />
        </article>

        <article :if={@unassigned_count > 0} class="gl-goal-card gl-goal-card--unassigned">
          <header class="gl-goal-card__head">
            <div>
              <strong>(no goal)</strong>
              <span class="gl-muted gl-goal-card__slug">· tasks without a goal frontmatter</span>
            </div>
            <div class="gl-goal-card__actions">
              <.link
                navigate={~p"/companies/#{@company_slug}/kanban"}
                class="gl-btn gl-btn--sm"
              >
                open in kanban →
              </.link>
            </div>
          </header>
          <div class="gl-goal-card__stats">
            <div>
              <span class="gl-muted">total</span>
              <strong>{@unassigned_count}</strong>
            </div>
          </div>
          <StatBreakdown.stat_breakdown label="by status" buckets={@unassigned_breakdown} />
        </article>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Loaders
  # ---------------------------------------------------------------------------

  defp load_and_assign(socket, co) do
    co_path = Path.join([base_dir(), "companies", co])
    goals_raw = load_goals(co_path)
    tasks_fm = collect_task_frontmatters(co_path)

    {goals_with_stats, unassigned_fms} = attach_task_stats(goals_raw, tasks_fm)

    socket
    |> assign(:page_title, "#{co} · goals — Glorbo")
    |> assign(:sidebar_active, :goals)
    |> assign(:current_company, co)
    |> assign(:company_slug, co)
    |> assign(:goals, goals_with_stats)
    |> assign(:unassigned_count, length(unassigned_fms))
    |> assign(:unassigned_breakdown, status_breakdown(unassigned_fms))
    |> ChatDrawer.State.wire_drawer()
  end

  defp load_goals(co_path) do
    case File.read(Path.join(co_path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"goals" => goals}, _} when is_list(goals) ->
            goals |> Enum.map(&normalize_goal/1) |> Enum.reject(&is_nil/1)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp normalize_goal(%{} = g) do
    slug = to_string(Map.get(g, "slug", "") || "")

    if slug == "" do
      nil
    else
      %{
        slug: slug,
        title: to_string(Map.get(g, "title", slug)),
        description: to_string(Map.get(g, "description", "") || ""),
        status: to_string(Map.get(g, "status", "active") || "active")
      }
    end
  end

  defp normalize_goal(_), do: nil

  defp collect_task_frontmatters(co_path) do
    projects_dir = Path.join(co_path, "projects")

    case File.ls(projects_dir) do
      {:ok, projects} -> Enum.flat_map(projects, &collect_project_fms(projects_dir, &1))
      _ -> []
    end
  end

  defp collect_project_fms(projects_dir, project) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&read_fm(Path.join(tasks_dir, &1)))

      _ ->
        []
    end
  end

  defp read_fm(path) do
    with {:ok, content} <- File.read(path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      [fm]
    else
      _ -> []
    end
  end

  defp attach_task_stats(goals, tasks_fm) do
    {by_goal, unassigned} =
      Enum.reduce(tasks_fm, {%{}, []}, fn fm, {acc, unassigned} ->
        case fm["goal"] do
          nil -> {acc, [fm | unassigned]}
          "" -> {acc, [fm | unassigned]}
          g when is_binary(g) -> {Map.update(acc, g, [fm], &[fm | &1]), unassigned}
          _ -> {acc, [fm | unassigned]}
        end
      end)

    with_stats =
      Enum.map(goals, fn goal ->
        fms = Map.get(by_goal, goal.slug, [])

        Map.merge(goal, %{
          task_count: length(fms),
          open_count: Enum.count(fms, &(to_string(&1["status"] || "todo") != "done")),
          breakdown: status_breakdown(fms)
        })
      end)

    {with_stats, unassigned}
  end

  defp status_breakdown(fms) do
    known = ["todo", "in-progress", "pending", "approved", "denied", "done"]

    counts =
      Enum.reduce(fms, %{}, fn fm, acc ->
        key = to_string(fm["status"] || "todo")
        Map.update(acc, key, 1, &(&1 + 1))
      end)

    known
    |> Enum.map(fn k -> {k, Map.get(counts, k, 0)} end)
    |> Enum.filter(fn {_, c} -> c > 0 end)
  end
end
