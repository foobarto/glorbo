defmodule GlorboWeb.TaskLive do
  @moduledoc """
  Dedicated task-detail page — GET
  `/companies/:company/tasks/:task_id`.

  JIRA-style pattern: Kanban opens a task as a right-shelf overlay
  for quick triage; clicking "open task page →" navigates here for
  the full-screen experience. Same underlying data (the task's
  markdown file on disk); the two views differ only in layout.

  Derives the project slug from the task-id by convention
  (`<project>-<digits>`) — matches how the Linkifier resolves task
  references in channel messages. If the task file doesn't exist,
  redirects back to Kanban with a flash.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(%{"company" => co, "task_id" => task_id}, _session, socket) do
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not valid_task_id?(task_id) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid task identifier.")
         |> push_navigate(to: ~p"/companies/#{co}")}

      true ->
        mount_valid(co, task_id, socket)
    end
  end

  defp mount_valid(co, task_id, socket) do
    base = base_dir()
    co_path = Path.join([base, "companies", co])

    with true <- File.dir?(co_path),
         {:ok, project} <- derive_project(task_id),
         rel_path = "projects/#{project}/tasks/#{task_id}.md",
         abs_path = Path.join(co_path, rel_path),
         true <- File.regular?(abs_path),
         {:ok, task} <- Glorbo.TaskDefinition.parse_file(abs_path, base: base, company: co) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")
      end

      {:ok,
       socket
       |> assign(:page_title, "#{task.task_id} — #{co} — Glorbo")
       |> assign(:sidebar_active, :kanban)
       |> assign(:current_company, co)
       |> assign(:company_slug, co)
       |> assign(:task_id, task_id)
       |> assign(:rel_path, rel_path)
       |> assign(:project, project)
       |> assign(:task, to_detail(task))
       |> ChatDrawer.State.wire_drawer()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Task \"#{task_id}\" not found.")
         |> push_navigate(to: ~p"/companies/#{co}/kanban")}
    end
  end

  @impl true
  def handle_info({:file_event, rel, _events}, socket) do
    socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel)

    if rel == socket.assigns.rel_path do
      base = base_dir()
      abs = Path.join([base, "companies", socket.assigns.company_slug, rel])

      case Glorbo.TaskDefinition.parse_file(abs,
             base: base,
             company: socket.assigns.company_slug
           ) do
        {:ok, task} -> {:noreply, assign(socket, :task, to_detail(task))}
        _ -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("comment_task", %{"comment" => comment}, socket) do
    trimmed = String.trim(comment)

    if trimmed == "" do
      {:noreply, put_flash(socket, :error, "Comment is empty.")}
    else
      case GlorboWeb.Actions.post_task_comment(
             socket.assigns.company_slug,
             socket.assigns.rel_path,
             trimmed,
             base: base_dir()
           ) do
        :ok -> {:noreply, socket}
        {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
      end
    end
  end

  defp format_error(:empty_body), do: "Comment is empty."
  defp format_error(:body_too_large), do: "Comment exceeds 10 KB."
  defp format_error(reason), do: "Could not post comment: #{inspect(reason)}"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Derive the project slug from a task-id of the form `<project>-<digits>`.
  # The project may itself contain dashes (e.g. `web-redesign-42` →
  # project `web-redesign`, number `42`).
  defp derive_project(task_id) do
    case Regex.run(~r/\A([a-z][a-z0-9_-]*?)-(\d+)\z/, task_id) do
      [_whole, project, _num] -> {:ok, project}
      _ -> :error
    end
  end

  defp valid_task_id?(task_id), do: Regex.match?(~r/\A[a-z][a-z0-9_-]*-\d+\z/, task_id)

  defp to_detail(task) do
    {prompt, comments} = split_prompt_and_comments(task.prompt_body || "")

    %{
      task_id: task.task_id,
      title: task.title || "",
      status: task.status || "todo",
      assigned_to: task.assigned_to || "",
      priority: if(task.priority, do: Atom.to_string(task.priority), else: ""),
      severity: if(task.severity, do: Atom.to_string(task.severity), else: ""),
      requires_approval: if(task.requires_approval == :director, do: "director", else: ""),
      denial_reason: task.denial_reason || "",
      body: prompt,
      comments: comments
    }
  end

  # Mirror of Kanban's split_prompt_and_comments/1 — ISO-timestamp
  # headers separate the prompt prologue from subsequent comment
  # blocks.
  @ts_header_re ~r/^## (?<ts>\d{4}-\d{2}-\d{2}[^|]*?)\s*\|\s*(?<author>.+?)\s*$/m

  defp split_prompt_and_comments(body) do
    case Regex.scan(@ts_header_re, body, return: :index) do
      [] ->
        {String.trim(body), []}

      matches ->
        [{first_start, _} | _] = matches |> Enum.map(&hd/1)
        prompt = body |> binary_part(0, first_start) |> String.trim()
        comments = parse_comments(body, matches)
        {prompt, comments}
    end
  end

  defp parse_comments(body, matches) do
    matches
    |> Enum.with_index()
    |> Enum.map(fn {[{start, _} | captures], i} ->
      ts =
        case Enum.at(captures, 0) do
          {s, l} -> binary_part(body, s, l)
          _ -> ""
        end

      author =
        case Enum.at(captures, 1) do
          {s, l} -> binary_part(body, s, l)
          _ -> ""
        end

      next_start =
        case Enum.at(matches, i + 1) do
          [{ns, _} | _] -> ns
          _ -> byte_size(body)
        end

      header_end = find_newline(body, start)
      body_text = body |> binary_part(header_end, next_start - header_end) |> String.trim()

      %{author: author, timestamp: ts, body: body_text}
    end)
  end

  defp find_newline(body, from) do
    case :binary.match(body, "\n", scope: {from, byte_size(body) - from}) do
      {idx, _len} -> idx + 1
      :nomatch -> byte_size(body)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-task-page">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">task /</span> {@task.task_id}
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">~/.glorbo/companies/{@company_slug}/{@rel_path}</span>
          </p>
        </div>
        <div class="gl-overview__actions">
          <.link navigate={~p"/companies/#{@company_slug}/kanban?task=#{@rel_path}"} class="gl-btn">
            ← back to kanban
          </.link>
        </div>
      </header>

      <div class="gl-task-page__grid">
        <section class="gl-panel">
          <header class="gl-panel__header">
            <span class="gl-panel__title">{@task.title}</span>
          </header>
          <div class="gl-panel__body gl-task-page__meta">
            <dl>
              <dt>status</dt>
              <dd>{@task.status}</dd>
              <dt>assigned to</dt>
              <dd>{@task.assigned_to || "—"}</dd>
              <dt>priority</dt>
              <dd>{@task.priority || "—"}</dd>
              <dt>severity</dt>
              <dd>{@task.severity || "—"}</dd>
              <dt :if={@task.requires_approval != ""}>approval</dt>
              <dd :if={@task.requires_approval != ""}>director</dd>
            </dl>
          </div>
          <div class="gl-panel__body gl-task-page__body">
            <h2 class="gl-heading gl-heading--heading">description</h2>
            <pre class="gl-task-page__prompt">{@task.body}</pre>
          </div>
        </section>

        <section class="gl-panel">
          <header class="gl-panel__header">
            <span class="gl-panel__title">comments ({length(@task.comments)})</span>
          </header>
          <div class="gl-panel__body">
            <ul :if={@task.comments != []} class="gl-task-comments">
              <li :for={c <- @task.comments} class="gl-task-comments__row">
                <span class="gl-task-comments__author">{c.author}</span>
                <span class="gl-muted gl-task-comments__ts">{c.timestamp}</span>
                <div class="gl-task-comments__body">{c.body}</div>
              </li>
            </ul>
            <p :if={@task.comments == []} class="gl-muted gl-task-comments__empty">
              No comments yet.
            </p>

            <form
              phx-submit="comment_task"
              phx-hook="ResetOnSubmit"
              id="gl-task-page-comment-form"
              class="gl-task-comment"
            >
              <span class="gl-compose__prompt" aria-hidden="true">
                director@{@task.task_id} ▸
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
        </section>
      </div>
    </section>
    """
  end
end
