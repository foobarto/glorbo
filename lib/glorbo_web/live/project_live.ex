defmodule GlorboWeb.ProjectLive do
  @moduledoc """
  Per-project detail + config view — GET
  `/companies/:company/projects/:project`.

  Reads `companies/<co>/projects/<proj>/project.md` (YAML frontmatter +
  markdown body) and renders:

    * **Header** — project name + icon from frontmatter; path crumb to
      the on-disk file.
    * **Stats** — task count, completion ratio, last updated.
    * **Config form** — editable `name`, `icon`, `description`.
      Submits to `save_project` which atomically rewrites
      `project.md`.
    * **Tasks list** — every `.md` under `projects/<proj>/tasks/` with
      status + assignee; clicking a row jumps to the kanban filtered
      to this project.

  Auto-creates `project.md` on first view if missing (zero-frontmatter
  stub). That way adding a project is still `mkdir projects/<slug>/`
  — the UI fills in the rest.
  """
  use GlorboWeb, :live_view

  @project_md_size_cap 64 * 1024

  @impl true
  def mount(%{"company" => co, "project" => proj}, _session, socket) do
    with :valid_co <- (GlorboWeb.Slug.valid?(co) && :valid_co) || :bad_slug,
         :valid_proj <- (GlorboWeb.Slug.valid?(proj) && :valid_proj) || :bad_slug,
         base <- base_dir(),
         co_dir <- Path.join([base, "companies", co]),
         proj_dir <- Path.join([co_dir, "projects", proj]),
         true <- File.dir?(co_dir) or {:no_company, co},
         true <- File.dir?(proj_dir) or {:no_project, proj} do
      if connected?(socket),
        do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")

      meta = ensure_and_load_meta(proj_dir)
      tasks = list_tasks(base, co, proj)

      {:ok,
       socket
       |> assign(:page_title, "#{meta.name || proj} — #{co} — Glorbo")
       |> assign(:sidebar_active, nil)
       |> assign(:current_company, co)
       |> assign(:company_slug, co)
       |> assign(:project_slug, proj)
       |> assign(:project_dir, proj_dir)
       |> assign(:meta, meta)
       |> assign(:tasks, tasks)
       |> assign(:edit_mode, false)}
    else
      :bad_slug ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid identifier.")
         |> push_navigate(to: ~p"/companies")}

      {:no_company, slug} ->
        {:ok,
         socket
         |> put_flash(:error, "Company \"#{slug}\" not found.")
         |> push_navigate(to: ~p"/companies")}

      {:no_project, slug} ->
        {:ok,
         socket
         |> put_flash(:error, "Project \"#{slug}\" not found.")
         |> push_navigate(to: ~p"/companies/#{co}")}
    end
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    cond do
      project_md_for_me?(rel_path, socket.assigns.project_slug) ->
        meta = ensure_and_load_meta(socket.assigns.project_dir)
        {:noreply, assign(socket, :meta, meta)}

      task_for_me?(rel_path, socket.assigns.project_slug) ->
        base = base_dir()
        tasks = list_tasks(base, socket.assigns.company_slug, socket.assigns.project_slug)
        {:noreply, assign(socket, :tasks, tasks)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, true)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :edit_mode, false)}
  end

  def handle_event("save_project", params, socket) do
    name = Map.get(params, "name", "") |> String.trim()
    icon_raw = Map.get(params, "icon", "") |> String.trim()
    description = Map.get(params, "description", "") |> String.trim()

    icon = normalize_icon(icon_raw)

    new_meta = %{
      name: if(name == "", do: socket.assigns.project_slug, else: name),
      icon: icon,
      description: description
    }

    case write_project_md(socket.assigns.project_dir, new_meta) do
      :ok ->
        {:noreply,
         socket
         |> assign(:meta, new_meta)
         |> assign(:edit_mode, false)
         |> put_flash(:info, "Saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-project">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <i
              :if={@meta.icon}
              class={["gl-project__icon", "fa-solid", @meta.icon]}
              aria-hidden="true"
            />
            {@meta.name || @project_slug}
            <span class="gl-muted">· {@project_slug}</span>
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">~/.glorbo/companies/{@company_slug}/projects/</span>{@project_slug}<span class="gl-muted">/project.md</span>
          </p>
        </div>
        <div class="gl-overview__actions">
          <.link
            navigate={~p"/companies/#{@company_slug}/kanban?project=#{@project_slug}"}
            class="gl-btn"
          >
            ▤ open kanban
          </.link>
          <button
            :if={not @edit_mode}
            type="button"
            class="gl-btn gl-btn--primary"
            phx-click="edit"
          >
            ✎ edit
          </button>
        </div>
      </header>

      <div class="gl-grid gl-grid--project">
        <%!-- STATS --%>
        <section class="gl-panel">
          <header class="gl-panel__header">
            <span>stats</span>
          </header>
          <div class="gl-panel__body">
            <dl class="gl-kv">
              <dt>tasks</dt>
              <dd>{length(@tasks)}</dd>
              <dt>done</dt>
              <dd>{Enum.count(@tasks, &(&1.status == "done"))}</dd>
              <dt>in progress</dt>
              <dd>{Enum.count(@tasks, &(&1.status == "in-progress"))}</dd>
              <dt>todo</dt>
              <dd>{Enum.count(@tasks, &(&1.status == "todo"))}</dd>
            </dl>
          </div>
        </section>

        <%!-- CONFIG --%>
        <section class="gl-panel">
          <header class="gl-panel__header">
            <span>config</span>
            <span class="gl-panel__hint">project.md</span>
          </header>

          <div :if={not @edit_mode} class="gl-panel__body">
            <dl class="gl-kv">
              <dt>name</dt>
              <dd>{@meta.name || @project_slug}</dd>
              <dt>icon</dt>
              <dd>
                <span :if={@meta.icon}>
                  <i class={["fa-solid", @meta.icon]} aria-hidden="true" /> {@meta.icon}
                </span>
                <span :if={is_nil(@meta.icon)} class="gl-muted">(default)</span>
              </dd>
              <dt>description</dt>
              <dd>
                <span :if={@meta.description && @meta.description != ""}>
                  {@meta.description}
                </span>
                <span :if={!@meta.description || @meta.description == ""} class="gl-muted">
                  (none)
                </span>
              </dd>
            </dl>
          </div>

          <form :if={@edit_mode} phx-submit="save_project" class="gl-panel__body gl-project__form">
            <label class="gl-form__row">
              <span class="gl-form__label">name</span>
              <input
                type="text"
                name="name"
                value={@meta.name || @project_slug}
                class="gl-input"
                placeholder={@project_slug}
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">
                icon <span class="gl-muted">(fa-name · see fontawesome.com/icons)</span>
              </span>
              <input
                type="text"
                name="icon"
                value={@meta.icon || ""}
                class="gl-input"
                placeholder="fa-rocket"
              />
            </label>
            <label class="gl-form__row">
              <span class="gl-form__label">description</span>
              <textarea name="description" class="gl-input" rows="4"><%= @meta.description || "" %></textarea>
            </label>
            <div class="gl-form__actions">
              <button type="submit" class="gl-btn gl-btn--primary">save</button>
              <button type="button" class="gl-btn" phx-click="cancel_edit">cancel</button>
            </div>
          </form>
        </section>

        <%!-- TASKS --%>
        <section class="gl-panel gl-project__tasks">
          <header class="gl-panel__header">
            <span>tasks</span>
            <.link
              navigate={~p"/companies/#{@company_slug}/kanban?project=#{@project_slug}"}
              class="gl-panel__hint"
            >
              kanban →
            </.link>
          </header>
          <div :if={@tasks == []} class="gl-panel__body gl-muted">No tasks yet.</div>
          <ul :if={@tasks != []} class="gl-panel__body gl-project__task-list">
            <li :for={t <- @tasks} class="gl-project__task-row">
              <span class={["gl-project__task-status", "gl-status--" <> to_string(t.status)]}>
                {t.status}
              </span>
              <span class="gl-project__task-id gl-muted">{t.id}</span>
              <span class="gl-project__task-title">{t.title || "(untitled)"}</span>
              <span :if={t.assigned_to} class="gl-project__task-assignee gl-muted">
                @{t.assigned_to}
              </span>
            </li>
          </ul>
        </section>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data
  # ---------------------------------------------------------------------------

  defp project_md_for_me?(rel_path, slug) do
    case Path.split(rel_path) do
      ["projects", ^slug, "project.md"] -> true
      _ -> false
    end
  end

  defp task_for_me?(rel_path, slug) do
    case Path.split(rel_path) do
      ["projects", ^slug, "tasks", _] -> true
      _ -> false
    end
  end

  defp ensure_and_load_meta(proj_dir) do
    path = Path.join(proj_dir, "project.md")

    unless File.exists?(path) do
      File.write!(path, "---\n---\n")
    end

    case File.read(path) do
      {:ok, content} -> parse_meta(content)
      _ -> %{name: nil, icon: nil, description: nil}
    end
  end

  # Minimal frontmatter scanner — full YAML is overkill when we only care
  # about 3 string fields.
  defp parse_meta(content) when byte_size(content) > @project_md_size_cap do
    %{name: nil, icon: nil, description: nil}
  end

  defp parse_meta(content) do
    {fm, body} = split_frontmatter(content)

    %{
      name: scan_field(fm, "name"),
      icon: fm |> scan_field("icon") |> normalize_icon(),
      description: scan_field(fm, "description") || first_paragraph(body)
    }
  end

  defp split_frontmatter(content) do
    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, body] -> {fm, body}
      _ -> {"", content}
    end
  end

  defp scan_field(fm, key) do
    case Regex.run(~r/^#{key}:\s*"?([^"\n]+?)"?\s*$/m, fm) do
      [_, v] -> String.trim(v)
      _ -> nil
    end
  end

  defp first_paragraph(body) do
    body
    |> to_string()
    |> String.split("\n\n", parts: 2)
    |> List.first()
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      p -> p
    end
  end

  @fa_icon_regex ~r/\A[a-z][a-z0-9-]{0,63}\z/
  defp normalize_icon(nil), do: nil
  defp normalize_icon(""), do: nil

  defp normalize_icon(raw) when is_binary(raw) do
    name = raw |> String.trim() |> String.downcase() |> String.replace_leading("fa-", "")
    if Regex.match?(@fa_icon_regex, name), do: "fa-#{name}", else: nil
  end

  defp normalize_icon(_), do: nil

  defp list_tasks(base, co, proj) do
    dir = Path.join([base, "companies", co, "projects", proj, "tasks"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(fn f ->
          path = Path.join(dir, f)
          load_task_row(path, Path.basename(f, ".md"))
        end)

      _ ->
        []
    end
  end

  defp load_task_row(path, id) do
    content = File.read!(path)
    {fm, _body} = split_frontmatter(content)

    %{
      id: id,
      title: scan_field(fm, "title"),
      status: scan_field(fm, "status") || "todo",
      assigned_to: scan_field(fm, "assigned_to")
    }
  rescue
    _ -> %{id: id, title: nil, status: "unknown", assigned_to: nil}
  end

  # ---------------------------------------------------------------------------
  # Write
  # ---------------------------------------------------------------------------

  defp write_project_md(proj_dir, meta) do
    path = Path.join(proj_dir, "project.md")

    body =
      case File.read(path) do
        {:ok, content} ->
          {_fm, body} = split_frontmatter(content)
          body
      end

    fm_lines =
      [
        {"name", meta.name},
        {"icon", meta.icon},
        {"description", meta.description}
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.map_join("\n", fn {k, v} -> ~s(#{k}: "#{escape(v)}") end)

    new_content = "---\n" <> fm_lines <> "\n---\n" <> (body || "")

    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, new_content, [:sync]),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err ->
        _ = File.rm(tmp)
        err
    end
  end

  defp escape(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> String.replace("\n", " ")
  end

  defp base_dir do
    Glorbo.Filesystem.Hierarchy.default_root()
  end
end
