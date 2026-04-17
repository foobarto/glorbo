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
       |> assign(:columns, group_by_column(tasks))
       |> assign(:new_task_open?, false)
       |> assign(:new_task_projects, list_projects(base, slug))
       |> assign(:open_task, nil)}
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
  def handle_event("open_task", %{"path" => path}, socket) do
    case resolve_task_path(path, socket.assigns.company_slug) do
      {:ok, abs} ->
        case File.read(abs) do
          {:ok, content} ->
            {fm, body} = split_frontmatter(content)

            detail = %{
              task_path: path,
              task_id: task_id_from_path(path),
              frontmatter: fm,
              body: String.trim(body)
            }

            {:noreply, assign(socket, :open_task, detail)}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not read task.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task path.")}
    end
  end

  def handle_event("close_task", _params, socket) do
    {:noreply, assign(socket, :open_task, nil)}
  end

  def handle_event("new_task", _params, socket) do
    {:noreply, assign(socket, :new_task_open?, true)}
  end

  def handle_event("new_task_cancel", _params, socket) do
    {:noreply, assign(socket, :new_task_open?, false)}
  end

  def handle_event(
        "new_task_create",
        %{"project" => project, "title" => title},
        socket
      ) do
    base = base_dir()
    company = socket.assigns.company_slug

    with :ok <- validate_project(project, socket.assigns.new_task_projects),
         :ok <- validate_title(title),
         {:ok, task_id} <- next_task_id(base, company, project),
         :ok <- write_new_task(base, company, project, task_id, title) do
      tasks = load_tasks(base, company)

      {:noreply,
       socket
       |> assign(:columns, group_by_column(tasks))
       |> assign(:new_task_open?, false)
       |> put_flash(:info, "Created #{task_id} in #{project}.")}
    else
      {:error, :invalid_project} ->
        {:noreply, put_flash(socket, :error, "Pick a project.")}

      {:error, :invalid_title} ->
        {:noreply, put_flash(socket, :error, "Title can't be empty.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not create task.")}
    end
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

      <form
        :if={@new_task_open?}
        phx-submit="new_task_create"
        class="gl-new-task-form"
        aria-label="Create new task"
      >
        <label class="gl-sr-only" for="new-task-project">Project</label>
        <select
          id="new-task-project"
          name="project"
          class="gl-input"
          required
          disabled={@new_task_projects == []}
        >
          <option :if={@new_task_projects == []} value="">(no projects)</option>
          <option :for={p <- @new_task_projects} value={p}>{p}</option>
        </select>
        <label class="gl-sr-only" for="new-task-title">Title</label>
        <input
          id="new-task-title"
          type="text"
          name="title"
          class="gl-input"
          placeholder="Task title…"
          required
          maxlength="200"
          autofocus
        />
        <button type="submit" class="gl-btn gl-btn--primary">Create</button>
        <button
          type="button"
          class="gl-btn"
          phx-click="new_task_cancel"
        >
          Cancel
        </button>
      </form>

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

      <div
        :if={@open_task}
        class="gl-task-detail"
        phx-click-away="close_task"
        phx-window-keydown="close_task"
        phx-key="Escape"
      >
        <header class="gl-panel__header">
          <span class="gl-muted">task/</span>
          <span class="gl-panel__title">{@open_task.task_id}</span>
          <span class="gl-panel__spacer"></span>
          <button
            type="button"
            class="gl-btn gl-btn--sm"
            phx-click="close_task"
            aria-label="Close"
          >
            close
          </button>
        </header>
        <pre class="gl-task-detail__frontmatter"><code>{@open_task.frontmatter}</code></pre>
        <div :if={@open_task.body != ""} class="gl-task-detail__body">
          <pre><code>{@open_task.body}</code></pre>
        </div>
        <p class="gl-muted gl-task-detail__path">
          ~/.glorbo/companies/{@company_slug}/{@open_task.task_path}
        </p>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defp task_id_from_path(path) when is_binary(path) do
    path |> Path.basename() |> Path.rootname()
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [fm, body] -> {String.trim(fm), body}
      _ -> {"", "---\n" <> rest}
    end
  end

  defp split_frontmatter(content), do: {"", content}

  defp columns(%{todo: t, in_progress: i, done: d}) do
    [
      {:todo, "todo", t},
      {:in_progress, "in progress", i},
      {:done, "done", d}
    ]
  end

  defp list_projects(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(projects_dir, &1)))

      _ ->
        []
    end
  end

  defp validate_project(project, allowed) do
    if is_binary(project) and project != "" and project in allowed do
      :ok
    else
      {:error, :invalid_project}
    end
  end

  defp validate_title(title) when is_binary(title) do
    trimmed = String.trim(title)

    if trimmed != "" and byte_size(trimmed) <= 200,
      do: :ok,
      else: {:error, :invalid_title}
  end

  defp validate_title(_), do: {:error, :invalid_title}

  defp next_task_id(base, company, project) do
    tasks_dir = Path.join([base, "companies", company, "projects", project, "tasks"])
    File.mkdir_p!(tasks_dir)

    max_n =
      case File.ls(tasks_dir) do
        {:ok, files} ->
          files
          |> Enum.map(&Regex.run(~r/\At-(\d+)\.md\z/, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn [_, n] -> String.to_integer(n) end)
          |> Enum.max(fn -> 0 end)

        _ ->
          0
      end

    {:ok, "t-" <> String.pad_leading(Integer.to_string(max_n + 1), 2, "0")}
  end

  defp write_new_task(base, company, project, task_id, title) do
    trimmed = String.trim(title)
    escaped = trimmed |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))

    body = """
    ---
    title: "#{escaped}"
    status: todo
    ---

    #{trimmed}
    """

    path = Path.join([base, "companies", company, "projects", project, "tasks", "#{task_id}.md"])
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, body, [:sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
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
