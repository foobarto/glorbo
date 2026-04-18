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

      {:ok,
       socket
       |> assign(:sidebar_active, :kanban)
       |> assign(:company_slug, slug)
       |> assign(:current_company, slug)
       |> assign(:project_filter, nil)
       |> assign(:columns, group_by_column([]))
       |> assign(:new_task_open?, false)
       |> assign(:new_task_projects, list_projects(base, slug))
       |> assign(:assignee_options, list_assignees(base, slug))
       |> assign(:open_task, nil)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company \"#{slug}\" not found.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    base = base_dir()
    slug = socket.assigns.company_slug
    projects = socket.assigns.new_task_projects

    filter =
      case Map.get(params, "project") do
        p when is_binary(p) and p != "" ->
          if p in projects, do: p, else: nil

        _ ->
          nil
      end

    tasks =
      base
      |> load_tasks(slug)
      |> apply_project_filter(filter)

    title =
      if filter,
        do: "Kanban · #{filter} — #{slug} — Glorbo",
        else: "Kanban — #{slug} — Glorbo"

    {:noreply,
     socket
     |> assign(:page_title, title)
     |> assign(:project_filter, filter)
     |> assign(:columns, group_by_column(tasks))}
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    if Regex.match?(@task_path_re, rel_path) do
      base = base_dir()

      tasks =
        base
        |> load_tasks(socket.assigns.company_slug)
        |> apply_project_filter(socket.assigns.project_filter)

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
        case Glorbo.TaskDefinition.parse_file(abs,
               base: base_dir(),
               company: socket.assigns.company_slug
             ) do
          {:ok, task} ->
            detail = %{
              task_path: path,
              task_id: task.task_id,
              title: task.title || "",
              status: task.status || "todo",
              assigned_to: task.assigned_to || "",
              priority: if(task.priority, do: Atom.to_string(task.priority), else: ""),
              requires_approval:
                if(task.requires_approval == :director, do: "director", else: ""),
              body: String.trim(task.prompt_body || "")
            }

            {:noreply, assign(socket, :open_task, detail)}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not parse task.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task path.")}
    end
  end

  def handle_event("close_task", _params, socket) do
    {:noreply, assign(socket, :open_task, nil)}
  end

  def handle_event("comment_task", %{"comment" => comment}, socket) do
    task = socket.assigns.open_task
    trimmed = String.trim(comment)

    cond do
      is_nil(task) ->
        {:noreply, socket}

      trimmed == "" ->
        {:noreply, put_flash(socket, :error, "Comment is empty.")}

      true ->
        case GlorboWeb.Actions.post_task_comment(
               socket.assigns.company_slug,
               task.task_path,
               trimmed
             ) do
          :ok ->
            # Re-open the task so the refreshed body (with the new comment
            # appended) is visible in the detail form.
            handle_event("open_task", %{"path" => task.task_path}, socket)

          _ ->
            {:noreply, put_flash(socket, :error, "Could not post comment.")}
        end
    end
  end

  def handle_event("save_task", params, socket) do
    task = socket.assigns.open_task

    case resolve_task_path(task.task_path, socket.assigns.company_slug) do
      {:ok, abs} ->
        fm = %{
          "title" => Map.get(params, "title", "") |> String.trim(),
          "status" => Map.get(params, "status", task.status),
          "assigned_to" => Map.get(params, "assigned_to", "") |> String.trim(),
          "priority" => Map.get(params, "priority", ""),
          "requires_approval" => Map.get(params, "requires_approval", "")
        }

        body = Map.get(params, "body", "") |> String.trim()

        with :ok <- Glorbo.TaskDefinition.write_frontmatter(abs, fm),
             :ok <- Glorbo.TaskDefinition.write_body(abs, body) do
          # Task #126 — when assigned_to changed to a real agent (or was
          # set for the first time), drop a notification into that
          # agent's inbox so the wake pipeline picks it up. Skips when
          # the field is empty, matches "director" (not an agent), or
          # the target dir doesn't exist.
          maybe_notify_assignee(
            Map.get(task, :assigned_to, ""),
            fm["assigned_to"],
            socket.assigns.company_slug,
            task.task_id,
            fm["title"],
            body
          )

          # Reload everything — filter-aware refresh.
          tasks =
            base_dir()
            |> load_tasks(socket.assigns.company_slug)
            |> apply_project_filter(socket.assigns.project_filter)

          {:noreply,
           socket
           |> assign(:columns, group_by_column(tasks))
           |> assign(:open_task, nil)
           |> put_flash(:info, "Saved #{task.task_id}.")}
        else
          _ -> {:noreply, put_flash(socket, :error, "Could not save task.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task path.")}
    end
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
      rel_path = "projects/#{project}/tasks/#{task_id}.md"
      emit_task_create_audit(company, rel_path, String.trim(title))

      tasks =
        base
        |> load_tasks(company)
        |> apply_project_filter(socket.assigns.project_filter)

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

      tasks =
        base
        |> load_tasks(socket.assigns.company_slug)
        |> apply_project_filter(socket.assigns.project_filter)

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
        <h1 class="gl-heading gl-heading--display">
          Kanban — {@company_slug}<span
            :if={@project_filter}
            class="gl-muted"
          >· {@project_filter}</span>
        </h1>
        <div class="gl-kanban__actions">
          <.link
            :if={@project_filter}
            navigate={~p"/companies/#{@company_slug}/projects/#{@project_filter}"}
            class="gl-btn gl-btn--sm"
          >
            ⚙ {@project_filter} config
          </.link>
          <.link
            :if={@project_filter}
            navigate={~p"/companies/#{@company_slug}/kanban"}
            class="gl-btn gl-btn--sm"
          >
            × all projects
          </.link>
          <button type="button" class="gl-btn" phx-click="new_task">+ new task</button>
        </div>
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

      <form
        :if={@open_task}
        phx-submit="save_task"
        phx-window-keydown="close_task"
        phx-key="Escape"
        class="gl-task-detail"
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

        <div class="gl-task-detail__fields">
          <label class="gl-task-detail__field">
            <span class="gl-muted">title</span>
            <input type="text" name="title" value={@open_task.title} class="gl-input" required />
          </label>

          <label class="gl-task-detail__field">
            <span class="gl-muted">status</span>
            <select name="status" class="gl-input">
              <option value="todo" selected={@open_task.status == "todo"}>todo</option>
              <option value="in-progress" selected={@open_task.status == "in-progress"}>
                in-progress
              </option>
              <option value="done" selected={@open_task.status == "done"}>done</option>
              <option value="pending" selected={@open_task.status == "pending"}>pending</option>
              <option value="approved" selected={@open_task.status == "approved"}>approved</option>
              <option value="denied" selected={@open_task.status == "denied"}>denied</option>
            </select>
          </label>

          <label class="gl-task-detail__field">
            <span class="gl-muted">assigned_to</span>
            <input
              type="text"
              name="assigned_to"
              value={@open_task.assigned_to}
              list="gl-assignee-options"
              class="gl-input"
              autocomplete="off"
            />
            <datalist id="gl-assignee-options">
              <option :for={slug <- @assignee_options} value={slug}></option>
            </datalist>
          </label>

          <label class="gl-task-detail__field">
            <span class="gl-muted">priority</span>
            <select name="priority" class="gl-input">
              <option value="" selected={@open_task.priority == ""}>—</option>
              <option value="low" selected={@open_task.priority == "low"}>low</option>
              <option value="medium" selected={@open_task.priority == "medium"}>medium</option>
              <option value="high" selected={@open_task.priority == "high"}>high</option>
            </select>
          </label>

          <label class="gl-task-detail__field gl-task-detail__field--check">
            <input
              type="checkbox"
              name="requires_approval"
              value="director"
              checked={@open_task.requires_approval == "director"}
            />
            <span>requires Director approval</span>
          </label>

          <label class="gl-task-detail__field gl-task-detail__field--body">
            <span class="gl-muted">body</span>
            <textarea name="body" rows="8" class="gl-input">{@open_task.body}</textarea>
          </label>
        </div>

        <footer class="gl-task-detail__footer">
          <span class="gl-muted gl-task-detail__path">
            ~/.glorbo/companies/{@company_slug}/{@open_task.task_path}
          </span>
          <div class="gl-task-detail__actions">
            <button type="button" class="gl-btn" phx-click="close_task">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">save</button>
          </div>
        </footer>
      </form>

      <form
        :if={@open_task}
        phx-submit="comment_task"
        class="gl-task-comment"
      >
        <span class="gl-compose__prompt" aria-hidden="true">
          director@{@open_task.task_id} ▸
        </span>
        <input
          type="text"
          name="comment"
          class="gl-compose__input"
          placeholder="Add a comment… @mention to ping another agent"
          maxlength="10240"
          autocomplete="off"
        />
        <button type="submit" class="gl-btn gl-btn--sm gl-btn--primary">send ↵</button>
      </form>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  defp apply_project_filter(tasks, nil), do: tasks

  defp apply_project_filter(tasks, project) when is_binary(project) do
    Enum.filter(tasks, fn t -> t.project == project end)
  end

  defp columns(%{todo: t, in_progress: i, review: r, done: d}) do
    [
      {:todo, "todo", t},
      {:in_progress, "in progress", i},
      {:review, "review", r},
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

  # Options for the `assigned_to` datalist: every agent slug under
  # companies/<co>/agents/ plus "director" (the human operator — not a
  # real agent dir, but a valid assignment target per task #116).
  # Task #126 — when the Director reassigns a task to an agent, drop a
  # notification into that agent's inbox. inotify → PubSub → Agent.Server
  # wakes the agent with the task as context. No-op if:
  #
  #   - assignee unchanged (avoids duplicate wakes on re-save)
  #   - new assignee is empty or "director" (Director isn't an agent)
  #   - agent dir doesn't exist
  defp maybe_notify_assignee(prev, new, _co, _id, _title, _body)
       when new == prev or new == "" or new == "director" do
    :ok
  end

  defp maybe_notify_assignee(_prev, new_assignee, company, task_id, title, body)
       when is_binary(new_assignee) do
    agent_dir = Path.join([base_dir(), "companies", company, "agents", new_assignee])

    if File.dir?(agent_dir) do
      inbox_dir = Path.join([agent_dir, "inbox"])
      File.mkdir_p!(inbox_dir)

      ts = System.system_time(:millisecond)
      path = Path.join(inbox_dir, "#{ts}-task-#{task_id}.md")

      content = """
      ---
      from: director
      task_id: "#{task_id}"
      kind: task_assignment
      delivered_at: "#{DateTime.to_iso8601(DateTime.utc_now())}"
      ---

      # New task assigned: #{title}

      #{body}
      """

      File.write!(path, content)
    end

    :ok
  end

  defp maybe_notify_assignee(_prev, _new, _co, _id, _title, _body), do: :ok

  defp list_assignees(base, company) do
    agents_dir = Path.join([base, "companies", company, "agents"])

    slugs =
      case File.ls(agents_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
          |> Enum.sort()

        _ ->
          []
      end

    ["director" | slugs]
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

  # GEP-13: task filenames are `<project-slug>-<NN>.md`. Legacy `t-NN.md`
  # files are still counted when picking the next number so a mixed
  # directory (during the soft-migration window) doesn't collide.
  defp next_task_id(base, company, project) do
    tasks_dir = Path.join([base, "companies", company, "projects", project, "tasks"])
    File.mkdir_p!(tasks_dir)

    legacy_re = ~r/\At-(\d+)\.md\z/
    prefixed_re = ~r/\A#{Regex.escape(project)}-(\d+)\.md\z/

    max_n =
      case File.ls(tasks_dir) do
        {:ok, files} ->
          files
          |> Enum.map(fn f ->
            Regex.run(prefixed_re, f) || Regex.run(legacy_re, f)
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn [_, n] -> String.to_integer(n) end)
          |> Enum.max(fn -> 0 end)

        _ ->
          0
      end

    next = max_n + 1

    n_str =
      if next <= 99,
        do: String.pad_leading(Integer.to_string(next), 2, "0"),
        else: Integer.to_string(next)

    {:ok, "#{project}-#{n_str}"}
  end

  # Resolve the company's AuditLog via-tuple (same shape Actions uses),
  # fall back silently if the audit server isn't registered — new-task
  # creation must not fail just because audit is unavailable.
  defp emit_task_create_audit(company, rel_path, title) do
    via =
      case Registry.lookup(Glorbo.Agent.Registry, {:company_child, company, :audit_log}) do
        [{_pid, _}] ->
          {:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :audit_log}}}

        _ ->
          Glorbo.Company.AuditLog
      end

    try do
      Glorbo.Company.AuditLog.append(via, %{
        company: company,
        actor: "director",
        action: "task.create",
        target: rel_path,
        title: title
      })
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    :ok
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
  defp column_key_to_status(:review), do: "pending"
  defp column_key_to_status(:done), do: "done"

  # Drag-target column name → canonical task status. `review` accepts
  # drops as `pending` (the neutral approval-gate state); existing
  # `approved`/`denied` tasks stay in the same lane until the Director
  # explicitly edits the status on the detail overlay.
  defp column_to_status("todo"), do: {:ok, "todo"}
  defp column_to_status("in-progress"), do: {:ok, "in-progress"}
  defp column_to_status("pending"), do: {:ok, "pending"}
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

  # Default four-lane layout. Keeps the status dropdown and board in
  # sync: every status the user can select lands in a visible lane.
  # `review` collects approval-gate states (pending/approved/denied)
  # so the Director sees at-a-glance which tasks are awaiting or
  # contested. Full PROJECT.md-configurable lanes land separately
  # (task #122 full scope).
  defp group_by_column(tasks) do
    %{
      todo: Enum.filter(tasks, &(&1.status == "todo")),
      in_progress: Enum.filter(tasks, &(&1.status == "in-progress")),
      review: Enum.filter(tasks, &(&1.status in ["pending", "approved", "denied"])),
      done: Enum.filter(tasks, &(&1.status == "done"))
    }
  end

  defp base_dir,
    do: Glorbo.Filesystem.Hierarchy.default_root()
end
