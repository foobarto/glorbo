defmodule GlorboWeb.KanbanLive do
  @moduledoc """
  Company kanban board — GET `/companies/:company/kanban` (D-23).

  Scans `<base>/companies/<co>/projects/*/tasks/*.md`, parses each via
  `Glorbo.TaskDefinition.parse_file/2`, and groups tasks into exactly
  three columns with lowercase labels matching frontmatter `status:`
  values: `todo`, `in progress`, `done`. Other status values are
  ignored (strict 3-column contract).

  On `connected?/1` the view subscribes to `"company:<co>:projects"`;
  any `projects/*/tasks/*.md` event triggers a full re-scan from disk
  (CLAUDE.md: no in-memory state not rebuildable). `handle_info/2`
  filters cross-company events by path prefix (T-04-11 mitigation —
  though subscribing to a company-scoped topic already enforces the
  boundary).

  Read-only in v0.0.1 — the Director edits task files with their own
  editor (D-23). A muted banner communicates this.
  """
  use GlorboWeb, :live_view

  alias GlorboWeb.Components.TaskCard

  @task_path_re ~r{\Aprojects/.+/tasks/.+\.md\z}

  @impl true
  def mount(%{"company" => slug}, _session, socket) do
    base = base_dir()
    co_path = Path.join([base, "companies", slug])

    if File.dir?(co_path) do
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:projects")

      tasks = load_tasks(base, slug)

      {:ok,
       socket
       |> assign(:page_title, "Kanban — #{slug} — Glorbo")
       |> assign(:company_slug, slug)
       |> assign(:columns, group_by_column(tasks))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company \"#{slug}\" not found.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    if Regex.match?(@task_path_re, rel_path) do
      base = base_dir()
      tasks = load_tasks(base, socket.assigns.company_slug)
      {:noreply, assign(socket, :columns, group_by_column(tasks))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-kanban">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">Kanban — {@company_slug}</h1>
      </header>

      <p class="gl-banner gl-banner--muted">
        Read-only view. Edit task files with your editor to change status.
      </p>

      <div class="gl-kanban__board">
        <section :for={{_key, label, tasks} <- columns(@columns)} class="gl-kanban__column">
          <header class="gl-kanban__column-header">
            <span class="gl-muted">{label}</span>
            <span class="gl-muted gl-tabular">{length(tasks)}</span>
          </header>
          <div :if={tasks == []} class="gl-kanban__empty">(empty)</div>
          <TaskCard.task_card
            :for={t <- tasks}
            task={t}
            company_slug={@company_slug}
          />
        </section>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defp columns(%{todo: t, in_progress: i, done: d}) do
    [
      {:todo, "todo", t},
      {:in_progress, "in progress", i},
      {:done, "done", d}
    ]
  end

  defp load_tasks(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.flat_map(projects, fn p ->
          tasks_dir = Path.join([projects_dir, p, "tasks"])

          case File.ls(tasks_dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.ends_with?(&1, ".md"))
              |> Enum.flat_map(fn f ->
                path = Path.join(tasks_dir, f)

                case Glorbo.TaskDefinition.parse_file(path, base: base, company: company) do
                  {:ok, task} -> [task]
                  _ -> []
                end
              end)

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp group_by_column(tasks) do
    %{
      todo: Enum.filter(tasks, &(&1.status in ["todo", "pending"])),
      in_progress: Enum.filter(tasks, &(&1.status == "in-progress")),
      done: Enum.filter(tasks, &(&1.status == "done"))
    }
  end

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
