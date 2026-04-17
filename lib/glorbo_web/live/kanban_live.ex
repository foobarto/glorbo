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

  v0.0.3 adds drag-and-drop between lanes (M4.1): a `"kanban:move"`
  event carries `task_path` + target column name; the handler validates
  the status, rewrites frontmatter via `Glorbo.TaskDefinition.write/2`,
  and lets inotify re-fire the view. Writes still go through the
  filesystem — no in-memory mutations (CLAUDE.md: SQLite is derived).
  """
  use GlorboWeb, :live_view

  alias GlorboWeb.Components.TaskCard

  @task_path_re ~r{\Aprojects/.+/tasks/.+\.md\z}

  @impl true
  def mount(%{"company" => slug}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
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
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:projects")

      tasks = load_tasks(base, slug)

      {:ok,
       socket
       |> assign(:page_title, "Kanban — #{slug} — Glorbo")
       |> assign(:sidebar_active, :kanban)
       |> assign(:company_slug, slug)
       |> assign(:current_company, slug)
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
  def handle_event("new_task", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :info,
       "New-task UI ships in a later milestone. Drop a file in projects/<name>/tasks/ for now."
     )}
  end

  def handle_event("kanban:move", %{"task_path" => task_path, "to" => to}, socket) do
    with {:ok, status} <- column_to_status(to),
         {:ok, abs_path} <- resolve_task_path(task_path, socket.assigns.company_slug),
         :ok <- Glorbo.TaskDefinition.write(abs_path, %{status: status}) do
      base = base_dir()
      tasks = load_tasks(base, socket.assigns.company_slug)
      {:noreply, assign(socket, :columns, group_by_column(tasks))}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not move task.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-kanban">
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">Kanban — {@company_slug}</h1>
        <button type="button" class="gl-btn" phx-click="new_task">+ new task</button>
      </header>

      <p class="gl-banner gl-banner--muted">
        Drag a card to move between lanes. Status writes back to the task's <code>status:</code>
        frontmatter.
      </p>

      <div class="gl-kanban__board">
        <section
          :for={{key, label, tasks} <- columns(@columns)}
          id={"gl-kanban-col-" <> Atom.to_string(key)}
          class="gl-kanban__column"
          data-status={column_key_to_status(key)}
          phx-hook="KanbanLane"
        >
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

  defp column_key_to_status(:todo), do: "todo"
  defp column_key_to_status(:in_progress), do: "in-progress"
  defp column_key_to_status(:done), do: "done"

  defp column_to_status("todo"), do: {:ok, "todo"}
  defp column_to_status("in-progress"), do: {:ok, "in-progress"}
  defp column_to_status("done"), do: {:ok, "done"}
  defp column_to_status(_), do: :error

  defp resolve_task_path(rel, company) when is_binary(rel) do
    if String.starts_with?(rel, "projects/") and not String.contains?(rel, "..") do
      {:ok, Path.join([base_dir(), "companies", company, rel])}
    else
      :error
    end
  end

  defp resolve_task_path(_, _), do: :error

  defp load_tasks(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.flat_map(projects, &load_project_tasks(projects_dir, &1, base, company))

      _ ->
        []
    end
  end

  defp load_project_tasks(projects_dir, project, base, company) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&parse_task_file(tasks_dir, &1, base, company))

      _ ->
        []
    end
  end

  defp parse_task_file(tasks_dir, filename, base, company) do
    path = Path.join(tasks_dir, filename)

    case Glorbo.TaskDefinition.parse_file(path, base: base, company: company) do
      {:ok, task} -> [task]
      _ -> []
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
