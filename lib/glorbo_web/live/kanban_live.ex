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

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.ProviderModel
  alias Glorbo.Repo
  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.TaskCard
  alias GlorboWeb.Components.TaskDetailForm

  @task_event_re ~r{\Aprojects/.+/tasks/.+\.md\z}
  @task_path_re ~r{\Aprojects/[a-z0-9-]+/tasks/[a-z0-9-]+\.md\z}

  @impl true
  def mount(%{"company" => slug}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    if Glorbo.Slug.valid?(slug) do
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
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:projects")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:agents:status")
      end

      {:ok,
       socket
       |> assign(:sidebar_active, :kanban)
       |> assign(:company_slug, slug)
       |> assign(:current_company, slug)
       |> assign(:project_filter, nil)
       |> assign(:goal_filter, nil)
       |> assign(:who_filter, nil)
       |> assign(:columns, group_by_column([]))
       |> assign(:new_task_open?, false)
       |> assign(:new_task_projects, list_projects(base, slug))
       |> assign(:assignee_options, list_assignees(base, slug))
       |> assign(:open_task, nil)
       |> assign(:new_task_form, default_new_task_form())
       |> assign(:new_task_model_options, [])
       |> assign(:task_search, "")
       |> assign(:return_to, nil)
       |> allow_upload(:new_task_attachments,
         accept: :any,
         max_entries: 8,
         max_file_size: 10_000_000
       )
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

    # `?goal=<slug>` filters tasks by their frontmatter `goal:` field
    # (PLAN P2-2). Not exclusive with `?project=` — directors can
    # combine both. Invalid slugs pass through as nil (no filter).
    goal_filter =
      case Map.get(params, "goal") do
        g when is_binary(g) and g != "" ->
          if Glorbo.Slug.valid?(g), do: g, else: nil

        _ ->
          nil
      end

    # `?who=<slug>` filters tasks by their `assigned_to:` agent
    # (#261). Composes with `?project=` and `?goal=`.
    who_filter =
      case Map.get(params, "who") do
        w when is_binary(w) and w != "" ->
          if Glorbo.Slug.valid?(w), do: w, else: nil

        _ ->
          nil
      end

    tasks =
      base
      |> load_tasks(slug)
      |> apply_project_filter(filter)
      |> apply_goal_filter(goal_filter)
      |> apply_who_filter(who_filter)

    title = build_kanban_title(slug, filter, goal_filter)

    # `?assignee=<slug>` opens the new-task drawer pre-filled with
    # this agent as the assignee — entry point from AgentLive's
    # "assign task" button (PLAN P1-3). `?new_task=1` opens the
    # drawer empty — used by the sidebar + new task button and the
    # command palette (`g n`). `?return_to=<path>` remembers where
    # cancel should navigate back to.
    {new_task_form, new_task_open?} = resolve_new_task_params(params, socket.assigns)

    # GEP-32 phase 4 follow-up — pre-fill the model <datalist> when
    # `?assignee=<slug>` pre-populated the assignee field, since the
    # `new_task_validate` path isn't triggered by a query-param
    # pre-fill.
    new_task_model_options =
      if new_task_form.assigned_to == socket.assigns.new_task_form.assigned_to do
        socket.assigns.new_task_model_options
      else
        model_options_for_assignee(
          base_dir(),
          socket.assigns.company_slug,
          new_task_form.assigned_to
        )
      end

    socket =
      socket
      |> assign(:page_title, title)
      |> assign(:project_filter, filter)
      |> assign(:goal_filter, goal_filter)
      |> assign(:who_filter, who_filter)
      |> assign(:columns, group_by_column(tasks))
      |> assign(:new_task_form, new_task_form)
      |> assign(:new_task_open?, new_task_open?)
      |> assign(:new_task_model_options, new_task_model_options)
      |> assign(:return_to, Map.get(params, "return_to"))

    # Deep-link: `?task=projects/<proj>/tasks/<id>.md` opens the task
    # detail overlay on mount. Falls through silently if the path is
    # malformed or the file is missing so a stale bookmark doesn't
    # crash the page. If `?task=` is absent, make sure any previously-
    # open task is cleared (covers browser-back after close).
    socket =
      case Map.get(params, "task") do
        task_path when is_binary(task_path) and task_path != "" ->
          maybe_open_task_from_param(socket, slug, task_path)

        _ ->
          assign(socket, :open_task, nil)
      end

    {:noreply, socket}
  end

  # Deep-link helper: materialise the same `:open_task` assign shape
  # as the click-driven `handle_event("open_task", ...)` path so the
  # existing overlay form works identically.
  defp maybe_open_task_from_param(socket, company, task_path) do
    with {:ok, abs} <- resolve_task_path(task_path, company),
         {:ok, task} <-
           Glorbo.TaskDefinition.parse_file(abs, base: base_dir(), company: company) do
      prompt = String.trim(task.prompt_body || "")
      comments = load_task_comments(abs)

      detail = %{
        task_path: task_path,
        task_id: task.task_id,
        title: task.title || "",
        status: task.status || "todo",
        assigned_to: task.assigned_to || "",
        priority: if(task.priority, do: Atom.to_string(task.priority), else: ""),
        severity: if(task.severity, do: Atom.to_string(task.severity), else: ""),
        requires_approval: if(task.requires_approval == :director, do: "director", else: ""),
        denial_reason: task.denial_reason || "",
        done_when: task.done_when || "",
        body: prompt,
        comments: comments,
        attachments: list_task_attachments(company, task.project, task.task_id)
      }

      assign(socket, :open_task, detail)
    else
      _ -> socket
    end
  end

  defp build_task_params(socket, path) do
    base = [task: path]

    case socket.assigns[:project_filter] do
      nil -> base
      "" -> base
      filter -> [project: filter] ++ base
    end
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel_path)

    cond do
      Regex.match?(@task_event_re, rel_path) ->
        base = base_dir()
        slug = socket.assigns.company_slug

        tasks =
          base
          |> load_tasks(slug)
          |> apply_project_filter(socket.assigns.project_filter)
          |> apply_goal_filter(socket.assigns.goal_filter)
          |> apply_who_filter(socket.assigns.who_filter)
          |> apply_search_filter(socket.assigns.task_search)

        socket =
          socket
          |> assign(:columns, group_by_column(tasks))
          |> assign(:new_task_projects, list_projects(base, slug))
          |> assign(:assignee_options, list_assignees(base, slug))
          |> maybe_refresh_open_task(rel_path)

        {:noreply, socket}

      # New project scaffold drops `projects/<slug>/project.md` —
      # refresh the project list so the Kanban create-task dialog's
      # "project" dropdown sees it without a page reload.
      String.starts_with?(rel_path, "projects/") and String.ends_with?(rel_path, "/project.md") ->
        base = base_dir()
        slug = socket.assigns.company_slug
        {:noreply, assign(socket, :new_task_projects, list_projects(base, slug))}

      true ->
        {:noreply, socket}
    end
  end

  # Agent busy/idle transition — touch the socket so the sidebar
  # re-renders with the fresh pill color. We don't store the status
  # in assigns because the sidebar recomputes it from Registry on
  # every render.
  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, assign(socket, :_agent_status_tick, System.unique_integer([:positive]))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # If the currently-open task overlay's source file was touched
  # (e.g. an agent appended a task comment), re-materialise the detail
  # so new comments + status changes appear without closing/reopening.
  defp maybe_refresh_open_task(%{assigns: %{open_task: nil}} = socket, _rel_path), do: socket

  defp maybe_refresh_open_task(%{assigns: %{open_task: %{task_path: path}}} = socket, rel_path) do
    # GEP-30 D8: the sibling `.comments.md` thread is a separate
    # file, so watcher events land under a different rel_path. Refresh
    # the overlay when either the task file itself or its thread
    # sibling changes.
    comments_rel = Glorbo.TaskComments.path_for(path)

    if rel_path == path or rel_path == comments_rel do
      maybe_open_task_from_param(socket, socket.assigns.company_slug, path)
    else
      socket
    end
  end

  defp maybe_refresh_open_task(socket, _rel_path), do: socket

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("open_task", %{"path" => path}, socket) do
    # Validate up-front so an explicit click on a bad path produces a
    # visible flash, then push_patch so the URL carries the open task
    # as `?task=...` (shareable / bookmarkable). `handle_params/3`
    # does the actual detail materialisation. Deep-link arrivals with
    # a bad path silently fail-closed in the handle_params branch so
    # stale bookmarks don't crash the page.
    case resolve_task_path(path, socket.assigns.company_slug) do
      {:ok, _abs} ->
        params = build_task_params(socket, path)

        {:noreply,
         push_patch(socket,
           to: ~p"/companies/#{socket.assigns.company_slug}/kanban?#{params}"
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Invalid task path.")}
    end
  end

  def handle_event("close_task", _params, socket) do
    # Clear ?task= from the URL so bookmarks + browser-back behave
    # as expected. Preserve the project filter if set.
    params =
      case socket.assigns[:project_filter] do
        nil -> []
        "" -> []
        filter -> [project: filter]
      end

    path =
      case params do
        [] -> ~p"/companies/#{socket.assigns.company_slug}/kanban"
        _ -> ~p"/companies/#{socket.assigns.company_slug}/kanban?#{params}"
      end

    {:noreply, socket |> assign(:open_task, nil) |> push_patch(to: path)}
  end

  def handle_event("search_task", %{"q" => q}, socket) do
    base = base_dir()

    tasks =
      base
      |> load_tasks(socket.assigns.company_slug)
      |> apply_project_filter(socket.assigns.project_filter)
      |> apply_goal_filter(socket.assigns.goal_filter)
      |> apply_who_filter(socket.assigns.who_filter)
      |> apply_search_filter(q)

    {:noreply,
     socket
     |> assign(:task_search, q)
     |> assign(:columns, group_by_column(tasks))}
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

  def handle_event("delete_task", %{"path" => path}, socket) do
    company = socket.assigns.company_slug

    case Glorbo.Actions.Tasks.archive_to_history(company, path,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, _} ->
        tasks =
          base_dir()
          |> load_tasks(company)
          |> apply_project_filter(socket.assigns.project_filter)
          |> apply_goal_filter(socket.assigns.goal_filter)
          |> apply_who_filter(socket.assigns.who_filter)
          |> apply_search_filter(socket.assigns.task_search)

        {:noreply,
         socket
         |> assign(:columns, group_by_column(tasks))
         |> assign(:open_task, nil)
         |> put_flash(:info, "Task moved to history.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete task.")}
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
          "severity" => Map.get(params, "severity", ""),
          "requires_approval" => Map.get(params, "requires_approval", ""),
          # GEP-40 — `done_when` is the agent-facing definition of
          # done. Empty string clears the field via
          # `TaskDefinition.write_frontmatter/2`'s "drop empty keys"
          # rule, matching the rest of the form's clear semantics.
          "done_when" => Map.get(params, "done_when", "") |> String.trim()
        }

        prompt = Map.get(params, "body", "") |> String.trim()
        # GEP-30 D8: comments live in the sibling `.comments.md` file,
        # not inline. Save writes the prompt only — the thread stays
        # untouched.
        body = prompt

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
            prompt
          )

          # Reload everything — filter-aware refresh.
          tasks =
            base_dir()
            |> load_tasks(socket.assigns.company_slug)
            |> apply_project_filter(socket.assigns.project_filter)
            |> apply_goal_filter(socket.assigns.goal_filter)
            |> apply_who_filter(socket.assigns.who_filter)
            |> apply_search_filter(socket.assigns.task_search)

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
    socket =
      socket
      |> assign(:new_task_open?, false)
      |> assign(:new_task_form, default_new_task_form())

    case socket.assigns[:return_to] do
      path when is_binary(path) and path != "" ->
        # Only honor same-origin paths — never navigate to an
        # external URL supplied via query string. The leading
        # "/" check alone is not enough: protocol-relative URLs
        # like "//evil.com/foo" also start with "/" and the browser
        # resolves them to https://evil.com. Reject any path that
        # begins with "//" or "/\" (Windows-style backslash).
        if same_origin_path?(path),
          do: {:noreply, push_navigate(socket, to: path)},
          else: {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  # `phx-change` on the form keeps upload entries in sync AND
  # persists form values on the socket — otherwise a re-render
  # triggered by an upload chunk would wipe the text inputs (they
  # aren't value-bound to avoid overwriting the user's typing on
  # every keystroke).
  def handle_event("new_task_validate", params, socket) do
    form = %{
      project: Map.get(params, "project", socket.assigns.new_task_form.project),
      title: Map.get(params, "title", socket.assigns.new_task_form.title),
      assigned_to: Map.get(params, "assigned_to", socket.assigns.new_task_form.assigned_to),
      model: Map.get(params, "model", socket.assigns.new_task_form.model),
      priority: Map.get(params, "priority", socket.assigns.new_task_form.priority),
      severity: Map.get(params, "severity", socket.assigns.new_task_form.severity),
      description: Map.get(params, "description", socket.assigns.new_task_form.description)
    }

    # GEP-32 phase 4 follow-up — recompute the cached model list whenever
    # the assignee changes, so the <datalist> reflects the agent's
    # provider. No-op if the assignee didn't actually change.
    socket =
      if form.assigned_to == socket.assigns.new_task_form.assigned_to do
        socket
      else
        base = base_dir()

        assign(
          socket,
          :new_task_model_options,
          model_options_for_assignee(base, socket.assigns.company_slug, form.assigned_to)
        )
      end

    {:noreply, assign(socket, :new_task_form, form)}
  end

  def handle_event("new_task_cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :new_task_attachments, ref)}
  end

  def handle_event("new_task_create", params, socket) do
    base = base_dir()
    company = socket.assigns.company_slug

    projects = socket.assigns.new_task_projects

    # GEP-36 — task creation flows through `Glorbo.Actions.Tasks.create/4`.
    # LV keeps the upload consumption + render bookkeeping; the
    # filesystem write + audit emit live in core.
    #
    # Pre-reserve the task id via `Tasks.next_task_id/3` so uploads can
    # land under the correct `attachments/<task_id>/` directory before
    # the task file itself is written (the body links into that
    # directory).
    with :ok <- validate_project(Map.get(params, "project", ""), projects),
         :ok <- pre_validate_title(Map.get(params, "title", "")),
         project = Map.fetch!(params, "project"),
         {:ok, task_id} <- Glorbo.Actions.Tasks.next_task_id(base, company, project),
         attachments <- consume_new_task_uploads(socket, base, company, project, task_id),
         {:ok, _result} <-
           Glorbo.Actions.Tasks.create(company, project, params,
             actor: "director",
             base: base,
             task_id: task_id,
             attachments: attachments
           ) do
      # If the user assigned the task, drop an inbox notification so
      # the wake pipeline picks it up (same pattern as kanban save).
      maybe_notify_assignee(
        "",
        Map.get(params, "assigned_to", "") |> String.trim(),
        company,
        task_id,
        String.trim(Map.get(params, "title", "")),
        build_body(params, attachments)
      )

      tasks =
        base
        |> load_tasks(company)
        |> apply_project_filter(socket.assigns.project_filter)
        |> apply_goal_filter(socket.assigns.goal_filter)
        |> apply_who_filter(socket.assigns.who_filter)
        |> apply_search_filter(socket.assigns.task_search)

      summary =
        if attachments == [] do
          "Created #{task_id} in #{project}."
        else
          "Created #{task_id} in #{project} with #{length(attachments)} attachment(s)."
        end

      {:noreply,
       socket
       |> assign(:columns, group_by_column(tasks))
       |> assign(:new_task_open?, false)
       |> assign(:new_task_form, default_new_task_form())
       |> put_flash(:info, summary)}
    else
      {:error, :invalid_project} ->
        {:noreply, put_flash(socket, :error, "Pick a project.")}

      {:error, :invalid_title} ->
        {:noreply, put_flash(socket, :error, "Title can't be empty.")}

      {:error, {:invalid_slug, kind, _slug}} ->
        {:noreply, put_flash(socket, :error, "Invalid #{kind} identifier.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not create task.")}
    end
  end

  def handle_event("kanban:move", %{"task_path" => task_path, "to" => to}, socket) do
    with {:ok, status} <- column_to_status(to),
         {:ok, abs_path} <- resolve_task_path(task_path, socket.assigns.company_slug),
         :ok <- refuse_if_bypasses_approval_gate(abs_path, status),
         :ok <- Glorbo.TaskDefinition.write(abs_path, %{status: status}) do
      base = base_dir()

      tasks =
        base
        |> load_tasks(socket.assigns.company_slug)
        |> apply_project_filter(socket.assigns.project_filter)
        |> apply_goal_filter(socket.assigns.goal_filter)
        |> apply_who_filter(socket.assigns.who_filter)
        |> apply_search_filter(socket.assigns.task_search)

      {:noreply, assign(socket, :columns, group_by_column(tasks))}
    else
      {:error, :approval_gate_bypass} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This task requires director approval — approve it via the Inbox before moving to done."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not move task.")}
    end
  end

  # A task with `requires_approval: director` in its frontmatter
  # must NOT skip the approval workflow by being dragged straight to
  # done. Opencode round-3 flagged: `column_to_status("done") →
  # {:ok, "done"}` was written unconditionally, so drag-to-done
  # bypassed the gate. Refuse the move unless the task has already
  # been approved (status == "approved").
  defp refuse_if_bypasses_approval_gate(abs_path, target_status)
       when target_status in ["done", "in-progress"] do
    case File.read(abs_path) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, fm, _body} ->
            requires? = to_string(Map.get(fm, "requires_approval", "")) == "director"
            approved? = to_string(Map.get(fm, "status", "")) == "approved"

            if requires? and not approved? do
              {:error, :approval_gate_bypass}
            else
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp refuse_if_bypasses_approval_gate(_abs, _status), do: :ok

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
          <form phx-change="search_task" class="gl-kanban__search">
            <input
              type="search"
              name="q"
              value={@task_search}
              class="gl-input"
              placeholder="search title/assignee…"
              aria-label="Search tasks"
            />
          </form>
          <button type="button" class="gl-btn" phx-click="new_task">+ new task</button>
        </div>
      </header>

      <div
        :if={@project_filter || @goal_filter || @who_filter}
        class="gl-kanban__filters"
        aria-label="Active filters"
      >
        <span class="gl-kanban__filters-label">filters:</span>
        <.link
          :if={@project_filter}
          navigate={
            kanban_path_without(@company_slug, @project_filter, @goal_filter, @who_filter,
              drop: :project
            )
          }
          class="gl-chip gl-chip--filter"
          title={"Clear project filter · " <> @project_filter}
        >
          <span class="gl-chip__label">project</span>
          <span class="gl-chip__value">{@project_filter}</span>
          <span class="gl-chip__close" aria-hidden="true">×</span>
        </.link>
        <.link
          :if={@goal_filter}
          navigate={
            kanban_path_without(@company_slug, @project_filter, @goal_filter, @who_filter,
              drop: :goal
            )
          }
          class="gl-chip gl-chip--filter"
          title={"Clear goal filter · " <> @goal_filter}
        >
          <span class="gl-chip__label">goal</span>
          <span class="gl-chip__value">{@goal_filter}</span>
          <span class="gl-chip__close" aria-hidden="true">×</span>
        </.link>
        <.link
          :if={@who_filter}
          navigate={
            kanban_path_without(@company_slug, @project_filter, @goal_filter, @who_filter, drop: :who)
          }
          class="gl-chip gl-chip--filter"
          title={"Clear assignee filter · " <> @who_filter}
        >
          <span class="gl-chip__label">assignee</span>
          <span class="gl-chip__value">{@who_filter}</span>
          <span class="gl-chip__close" aria-hidden="true">×</span>
        </.link>
        <.link
          navigate={~p"/companies/#{@company_slug}/kanban"}
          class="gl-kanban__filters-clear"
          title="Clear all filters"
        >
          clear all
        </.link>
      </div>

      <p class="gl-banner gl-banner--muted">
        Drag a card to move between lanes. Status writes back to the task's <code>status:</code>
        frontmatter.
      </p>

      <%!--
        New-task right-side drawer (.design/20-kanban-new-task-drawer.png):
        title/description/assignee/priority/severity + file uploads.
        Attachments are uploaded to
        `projects/<proj>/attachments/<task_id>/<filename>`. Slides in
        from the right, leaving the kanban board visible on the left.
      --%>
      <div
        :if={@new_task_open?}
        class="gl-shelf-scrim"
        phx-click-away="new_task_cancel"
      >
        <form
          phx-submit="new_task_create"
          phx-change="new_task_validate"
          phx-window-keydown="new_task_cancel"
          phx-key="Escape"
          class="gl-new-task-drawer"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-new-task-title"
        >
          <header class="gl-new-task-drawer__header">
            <div id="gl-new-task-title" class="gl-new-task-drawer__title">
              <strong>+ new task</strong>
              <span class="gl-muted gl-new-task-drawer__status">DRAFT</span>
            </div>
            <button
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="new_task_cancel"
              aria-label="Close"
              title="esc"
            >
              esc close
            </button>
          </header>

          <div class="gl-new-task-drawer__body gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">project</span>
              <select
                name="project"
                class="gl-input"
                required
                disabled={@new_task_projects == []}
              >
                <option :if={@new_task_projects == []} value="">(no projects)</option>
                <option :for={p <- @new_task_projects} value={p}>{p}</option>
              </select>
            </label>

            <label class="gl-form__row">
              <span class="gl-form__label">title</span>
              <input
                type="text"
                name="title"
                class="gl-input"
                value={@new_task_form.title}
                required
                maxlength="200"
                autofocus
                placeholder="Short task title…"
              />
            </label>

            <label class="gl-form__row">
              <span class="gl-form__label">assigned to</span>
              <input
                type="text"
                name="assigned_to"
                class="gl-input"
                value={@new_task_form.assigned_to}
                list="gl-new-task-assignees"
                placeholder="(nobody yet)"
              />
            </label>
            <datalist id="gl-new-task-assignees">
              <option :for={a <- @assignee_options} value={a}></option>
            </datalist>

            <label class="gl-form__row">
              <span class="gl-form__label">model</span>
              <input
                type="text"
                name="model"
                class="gl-input"
                value={@new_task_form.model}
                list="gl-new-task-model-options"
                placeholder="(agent default)"
              />
            </label>
            <datalist id="gl-new-task-model-options">
              <option :for={m <- @new_task_model_options} value={m}></option>
            </datalist>

            <label class="gl-form__row">
              <span class="gl-form__label">priority</span>
              <select name="priority" class="gl-input">
                <option value="" selected={@new_task_form.priority == ""}>—</option>
                <option value="low" selected={@new_task_form.priority == "low"}>low</option>
                <option value="medium" selected={@new_task_form.priority == "medium"}>medium</option>
                <option value="high" selected={@new_task_form.priority == "high"}>high</option>
              </select>
            </label>

            <label class="gl-form__row">
              <span class="gl-form__label">severity</span>
              <select name="severity" class="gl-input">
                <option value="" selected={@new_task_form.severity == ""}>—</option>
                <option value="info" selected={@new_task_form.severity == "info"}>info</option>
                <option value="minor" selected={@new_task_form.severity == "minor"}>minor</option>
                <option value="major" selected={@new_task_form.severity == "major"}>major</option>
                <option value="critical" selected={@new_task_form.severity == "critical"}>
                  critical
                </option>
              </select>
            </label>

            <label class="gl-form__row gl-form__row--stretch">
              <span class="gl-form__label">description</span>
              <textarea
                name="description"
                rows="6"
                class="gl-input gl-company-md-form__body"
                placeholder="Markdown supported."
              >{@new_task_form.description}</textarea>
            </label>

            <label class="gl-form__row gl-form__row--stretch">
              <span class="gl-form__label">attachments</span>
              <div class="gl-new-task-form__uploads">
                <.live_file_input upload={@uploads.new_task_attachments} class="gl-input" />
                <p class="gl-muted gl-new-task-form__hint">
                  Up to 8 files, 10 MB each. Stored under <code>projects/&lt;project&gt;/attachments/&lt;task-id&gt;/</code>.
                </p>
                <ul :if={@uploads.new_task_attachments.entries != []} class="gl-upload-list">
                  <li
                    :for={entry <- @uploads.new_task_attachments.entries}
                    class="gl-upload-list__row"
                  >
                    <span class="gl-upload-list__name">{entry.client_name}</span>
                    <span class="gl-muted gl-upload-list__size">
                      {Float.round(entry.client_size / 1024, 1)} KB
                    </span>
                    <button
                      type="button"
                      class="gl-btn gl-btn--sm"
                      phx-click="new_task_cancel_upload"
                      phx-value-ref={entry.ref}
                    >
                      remove
                    </button>
                    <p
                      :for={err <- upload_errors(@uploads.new_task_attachments, entry)}
                      class="gl-form__error"
                    >
                      {upload_error_message(err)}
                    </p>
                  </li>
                </ul>
                <p :for={err <- upload_errors(@uploads.new_task_attachments)} class="gl-form__error">
                  {upload_error_message(err)}
                </p>
              </div>
            </label>
          </div>

          <footer class="gl-new-task-drawer__footer">
            <span class="gl-muted gl-new-task-drawer__hotkeys">
              <kbd>⌘</kbd><kbd>↵</kbd> create · <kbd>esc</kbd> discard
            </span>
            <span class="gl-panel__spacer"></span>
            <button type="button" class="gl-btn" phx-click="new_task_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">+ create task</button>
          </footer>
        </form>
      </div>

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
        class="gl-shelf-scrim"
        phx-click-away="close_task"
        phx-window-keydown="close_task"
        phx-key="Escape"
      >
        <div class="gl-task-detail gl-task-detail--shelf">
          <header class="gl-panel__header">
            <span class="gl-muted">task/</span>
            <span class="gl-panel__title">{@open_task.task_id}</span>
            <span class="gl-panel__spacer"></span>
            <.link
              navigate={~p"/companies/#{@company_slug}/tasks/#{@open_task.task_id}"}
              class="gl-btn gl-btn--sm gl-btn--ghost"
              title="Open the full task page (same as JIRA's issue detail)"
            >
              open task page →
            </.link>
            <button
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="close_task"
              aria-label="Close"
            >
              close
            </button>
          </header>

          <TaskDetailForm.task_detail_form
            task={@open_task}
            company_slug={@company_slug}
            assignee_options={@assignee_options}
          />

          <%!--
          Sibling form inside the overlay — can't be nested inside the
          save form (HTML forbids nested <form>), so the outer
          .gl-task-detail wrapper is a div and each form is a child.
        --%>
          <form
            phx-submit="comment_task"
            phx-hook="ResetOnSubmit"
            id="gl-task-comment-form"
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
        </div>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  # Decide the drawer's initial state based on query params:
  # - `?assignee=<slug>` pre-fills the assigned-to field and opens.
  # - `?new_task=1` opens empty (sidebar button, command palette).
  # - neither: preserve whatever the current assigns say.
  defp resolve_new_task_params(params, assigns) do
    case Map.get(params, "assignee") do
      slug when is_binary(slug) and slug != "" ->
        if Glorbo.Slug.valid?(slug) do
          form = Map.put(assigns.new_task_form, :assigned_to, slug)
          {form, true}
        else
          {assigns.new_task_form, assigns.new_task_open?}
        end

      _ ->
        open? = Map.get(params, "new_task") in ["1", "true"]
        {assigns.new_task_form, open? or assigns.new_task_open?}
    end
  end

  defp apply_project_filter(tasks, nil), do: tasks

  defp apply_project_filter(tasks, project) when is_binary(project) do
    Enum.filter(tasks, fn t -> t.project == project end)
  end

  defp apply_goal_filter(tasks, nil), do: tasks

  defp apply_goal_filter(tasks, goal) when is_binary(goal) do
    Enum.filter(tasks, fn t -> Map.get(t, :goal) == goal end)
  end

  # #261 — filter by assigned_to agent slug. Separate from the
  # existing `?assignee=` query param which pre-fills the
  # new-task modal; this one narrows the *displayed* list.
  defp apply_who_filter(tasks, nil), do: tasks

  defp apply_who_filter(tasks, who) when is_binary(who) do
    Enum.filter(tasks, fn t -> to_string(Map.get(t, :assigned_to) || "") == who end)
  end

  defp build_kanban_title(slug, nil, nil), do: "Kanban — #{slug} — Glorbo"

  defp build_kanban_title(slug, project, nil), do: "Kanban · #{project} — #{slug} — Glorbo"

  defp build_kanban_title(slug, nil, goal), do: "Kanban · goal:#{goal} — #{slug} — Glorbo"

  defp build_kanban_title(slug, project, goal),
    do: "Kanban · #{project} / goal:#{goal} — #{slug} — Glorbo"

  # #275 — build the kanban URL with one filter removed. Used by
  # the chip bar so each chip's × link drops only that filter,
  # preserving others. Empty/nil filters are omitted from the
  # querystring; if nothing is left, returns the bare kanban path.
  defp kanban_path_without(slug, project, goal, who, drop: field) do
    project = if field == :project, do: nil, else: project
    goal = if field == :goal, do: nil, else: goal
    who = if field == :who, do: nil, else: who

    query =
      [project: project, goal: goal, who: who]
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)

    if query == [] do
      ~p"/companies/#{slug}/kanban"
    else
      ~p"/companies/#{slug}/kanban?#{query}"
    end
  end

  # GEP-30 D8: the task comment thread lives in a sibling
  # `<task>.comments.md` file. Wrap the `Glorbo.TaskComments.read`
  # helper so the open-task overlay gets an empty list on any IO
  # failure rather than crashing.
  defp load_task_comments(abs_task_path) do
    comments_path = Glorbo.TaskComments.path_for(abs_task_path)

    case Glorbo.TaskComments.read(comments_path) do
      {:ok, entries} -> entries
      _ -> []
    end
  end

  # threatmodel M17: the original implementation used a wildcard
  # `companies/*/` segment which enumerated attachments from every
  # tenant sharing a project slug + task id, leaking cross-company
  # metadata (filenames + sizes). Scope to the caller's company.
  defp list_task_attachments(company, project, task_id)
       when is_binary(company) and is_binary(project) and is_binary(task_id) do
    base = base_dir()

    dir =
      Path.join([
        base,
        "companies",
        company,
        "projects",
        project,
        "attachments",
        task_id
      ])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn name ->
          abs = Path.join(dir, name)

          %{
            name: name,
            size:
              case File.stat(abs) do
                {:ok, %File.Stat{size: s}} -> s
                _ -> 0
              end
          }
        end)

      _ ->
        []
    end
  end

  defp list_task_attachments(_, _, _), do: []

  defp apply_search_filter(tasks, nil), do: tasks
  defp apply_search_filter(tasks, ""), do: tasks

  defp apply_search_filter(tasks, q) when is_binary(q) do
    needle = String.downcase(q)

    Enum.filter(tasks, fn t ->
      title = String.downcase(t.title || "")
      assigned = String.downcase(t.assigned_to || "")
      task_id = String.downcase(t.task_id || "")

      String.contains?(title, needle) or
        String.contains?(assigned, needle) or
        String.contains?(task_id, needle)
    end)
  end

  defp columns(%{todo: t, in_progress: i, review: r, done: d}) do
    [
      {:todo, "todo", t},
      {:in_progress, "in progress", i},
      {:review, "review", r},
      {:done, "done", d}
    ]
  end

  defp real_directory?(parent, slug) do
    case File.lstat(Path.join(parent, slug)) do
      {:ok, %{type: :directory}} -> true
      _ -> false
    end
  end

  defp list_projects(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, slugs} ->
        # Threatmodel wave 5: slug-gate the enumeration AND lstat (not
        # File.dir?, which follows symlinks). An agent with project-
        # write access could otherwise plant a symlink
        # `projects/evil → /etc` that appears in the Kanban "new task"
        # dropdown, so that selecting it writes task files under the
        # target directory.
        slugs
        |> Enum.sort()
        |> Enum.filter(fn slug ->
          Glorbo.Slug.valid?(slug) and real_directory?(projects_dir, slug)
        end)

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
    # threatmodel [35]/[36]: `new_assignee` comes straight from the
    # LiveView form (or frontmatter). Without a slug check, values
    # like `../../companies/other/agents/ceo` escape the intended
    # `agents/<slug>` directory via `Path.join/1`, enabling cross-
    # company or arbitrary-path file writes under the Glorbo user.
    if Glorbo.Slug.valid?(new_assignee) do
      do_notify_assignee(new_assignee, company, task_id, title, body)
    else
      :ok
    end
  end

  defp maybe_notify_assignee(_prev, _new, _co, _id, _title, _body), do: :ok

  defp do_notify_assignee(new_assignee, company, task_id, title, body) do
    case Glorbo.Actions.Inbox.deliver_task_assignment(
           company,
           new_assignee,
           task_id,
           title,
           body,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, _} ->
        # Belt-and-braces: inotify → PubSub → Agent.Server is the canonical
        # wake path, but boot-race or dropped events leave tasks sitting in
        # inbox until the next heartbeat (observed 2026-04-19, >8 min
        # delay). Directly wake via Registry lookup; idempotent with the
        # fs-event path via the server's wake-queue.
        safe_wake_assignee(company, new_assignee)

      {:error, :agent_not_found} ->
        # No agent directory — silently skip. The task is still
        # re-assignable manually.
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "[kanban/#{company}] skipped assignee notify for #{new_assignee}: #{inspect(reason)}"
        )
    end

    :ok
  end

  defp safe_wake_assignee(company, slug) do
    case Registry.lookup(Glorbo.Agent.Registry, {:agent_server, company, slug}) do
      [{pid, _}] when is_pid(pid) ->
        try do
          Glorbo.Agent.Server.wake(pid, :inbox, nil)
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

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

  # GEP-32 phase 4 follow-up — when the new-task form has an assignee
  # pinned, populate the model <datalist> with the cached model IDs for
  # that agent's provider. Returns `[]` for the "director" synthetic
  # assignee, for unknown slugs, for CLI-provider agents (no cached
  # models), and for any lookup error — keeping the field optional and
  # free-text in those cases.
  @doc false
  def model_options_for_assignee(base, company, assigned_to)

  def model_options_for_assignee(_base, _company, nil), do: []
  def model_options_for_assignee(_base, _company, ""), do: []
  def model_options_for_assignee(_base, _company, "director"), do: []

  def model_options_for_assignee(base, company, assigned_to)
      when is_binary(base) and is_binary(company) and is_binary(assigned_to) do
    case lookup_agent_provider(base, company, assigned_to) do
      provider when is_binary(provider) and provider != "" ->
        import Ecto.Query, only: [from: 2]

        query =
          from pm in ProviderModel,
            where: pm.alias == ^provider,
            select: pm.model_id,
            order_by: [asc: pm.model_id]

        Repo.all(query)

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp lookup_agent_provider(base, company, slug) do
    ag_dir = Path.join([base, "companies", company, "agents", slug])
    agent_md = Glorbo.Agent.FileLayout.agent_md(ag_dir)

    case Glorbo.Agent.Parser.parse_file(agent_md) do
      {:ok, %{provider: p}} when is_binary(p) -> p
      _ -> nil
    end
  end

  defp validate_project(project, allowed) do
    if is_binary(project) and project != "" and project in allowed do
      :ok
    else
      {:error, :invalid_project}
    end
  end

  # Codex P2 (v0.8.0 pre-release): short-circuit title validation
  # before `consume_new_task_uploads/5` so an invalid-title form
  # doesn't leave an orphaned attachments dir + `attachment.upload`
  # audit rows behind. `Actions.Tasks.create/4` re-validates the
  # title as defense-in-depth, but by the time it runs the uploads
  # have already landed on disk.
  defp pre_validate_title(title) do
    trimmed = title |> to_string() |> String.trim()

    cond do
      trimmed == "" -> {:error, :invalid_title}
      byte_size(trimmed) > 200 -> {:error, :invalid_title}
      true -> :ok
    end
  end

  # Sink uploads into `projects/<p>/attachments/<task_id>/` via
  # `Glorbo.Actions.Attachments.ingest/6`. Entries that fail to
  # ingest come back as `nil` from the callback and are filtered
  # out — LiveView renders any upload_errors in the UI already.
  defp consume_new_task_uploads(socket, _base, company, project, task_id) do
    socket
    |> consume_uploaded_entries(:new_task_attachments, fn %{path: tmp}, entry ->
      case Glorbo.Actions.Attachments.ingest(
             company,
             project,
             task_id,
             tmp,
             entry.client_name,
             actor: "director",
             base: base_dir()
           ) do
        {:ok, rel_path} ->
          {:ok, rel_path}

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[kanban/#{company}] attachment ingest failed for #{entry.client_name}: #{inspect(reason)}"
          )

          {:ok, nil}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_body(params, attachments) do
    description = Map.get(params, "description", "") |> String.trim()

    attach_block =
      case attachments do
        [] ->
          ""

        list ->
          "\n\n## Attachments\n\n" <>
            Enum.map_join(list, "\n", fn rel -> "- [#{Path.basename(rel)}](../#{rel})" end) <>
            "\n"
      end

    if description == "" do
      Map.get(params, "title", "") |> String.trim()
    else
      description
    end <> attach_block
  end

  defp default_new_task_form do
    %{
      project: "",
      title: "",
      assigned_to: "",
      model: "",
      priority: "",
      severity: "",
      description: ""
    }
  end

  @doc false
  def upload_error_message(:too_large), do: "file too large (max 10 MB)"
  def upload_error_message(:too_many_files), do: "too many files (max 8)"
  def upload_error_message(:not_accepted), do: "file type not accepted"
  def upload_error_message(other), do: "upload error: #{inspect(other)}"

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
    abs = Path.join([base_dir(), "companies", company, rel])

    with true <- Regex.match?(@task_path_re, rel),
         :ok <- ensure_regular_file(abs) do
      {:ok, abs}
    else
      _ -> :error
    end
  end

  defp resolve_task_path(_, _), do: :error

  # Caller collapses the full `{:error, ...}` set to a bare `:error`
  # sentinel, so flatten AgentWritableFile's tagged-error return here.
  defp ensure_regular_file(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_regular(path) do
      :ok -> :ok
      {:error, _} -> :error
    end
  end

  # True iff the path is unambiguously same-origin: starts with
  # "/" but NOT "//" (protocol-relative — browser navigates to
  # the host after the slashes) and NOT "/\\" (some browsers
  # treat it as protocol-relative on legacy paths).
  defp same_origin_path?("/"), do: true
  defp same_origin_path?("//" <> _), do: false
  defp same_origin_path?("/\\" <> _), do: false
  defp same_origin_path?("/" <> _), do: true
  defp same_origin_path?(_), do: false

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
      review:
        Enum.filter(
          tasks,
          &(&1.status in ["pending", "pending-approval", "approved", "denied"])
        ),
      done: Enum.filter(tasks, &(&1.status == "done"))
    }
  end
end
