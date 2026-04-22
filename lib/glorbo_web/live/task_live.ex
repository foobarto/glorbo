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
  alias GlorboWeb.Components.TaskDetailForm

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
         {:ok, rel_path, abs_path} <- resolve_task_file(co_path, project, task_id, socket),
         {:ok, task} <- Glorbo.TaskDefinition.parse_file(abs_path, base: base, company: co) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")
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
       |> assign(:task, to_detail(task, abs_path))
       |> assign(:usage_totals, load_usage_totals(base, co, rel_path))
       |> assign(:history, Glorbo.Audit.Query.for_task(base, co, rel_path, limit: 25))
       |> assign(:history_expanded, MapSet.new())
       |> assign(:next_fire_at, next_fire_at(co, task_id))
       |> assign(:stuck, load_stuck_for_task(base, co, task_id))
       |> assign(:path_grants, load_path_grants(co, task_id))
       |> ChatDrawer.State.wire_drawer()}
    else
      {:error, {:ambiguous, matches}} ->
        names = Enum.map_join(matches, ", ", &Path.basename/1)

        {:ok,
         socket
         |> put_flash(:error, "Task id \"#{task_id}\" matches multiple files: #{names}")
         |> push_navigate(to: ~p"/companies/#{co}/kanban")}

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

    # GEP-30 D8: the comment thread is a sibling file, so thread-only
    # updates arrive under a different rel_path. Refresh when either
    # the task file itself or its `.comments.md` sibling changes.
    task_rel = socket.assigns.rel_path
    comments_rel = Glorbo.TaskComments.path_for(task_rel)

    if rel == task_rel or rel == comments_rel do
      base = base_dir()
      abs = Path.join([base, "companies", socket.assigns.company_slug, task_rel])

      case Glorbo.TaskDefinition.parse_file(abs,
             base: base,
             company: socket.assigns.company_slug
           ) do
        {:ok, task} ->
          {:noreply,
           socket
           |> assign(:task, to_detail(task, abs))
           |> assign(
             :next_fire_at,
             next_fire_at(socket.assigns.company_slug, socket.assigns.task_id)
           )}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, socket}
  end

  # #264 — refresh task-scoped history on any audit append. Cheap
  # to re-scan the month's JSONL when anything changes; for a real
  # scaling problem we'd push-filter on target first.
  def handle_info({:audit_append, _record}, socket) do
    history =
      Glorbo.Audit.Query.for_task(
        base_dir(),
        socket.assigns.company_slug,
        socket.assigns.rel_path,
        limit: 25
      )

    {:noreply, assign(socket, :history, history)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  # AuditEntry emits phx-click="toggle"; TaskLive receives it for
  # any expanded row of the task-history panel.
  def handle_event("toggle", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.history_expanded, id) do
        MapSet.delete(socket.assigns.history_expanded, id)
      else
        MapSet.put(socket.assigns.history_expanded, id)
      end

    {:noreply, assign(socket, :history_expanded, expanded)}
  end

  def handle_event("convert_to_task", _params, socket) do
    # No-op on TaskLive; directors use this only from AuditLive.
    # Surface a helpful flash rather than silently ignoring.
    {:noreply,
     put_flash(
       socket,
       :info,
       "Open the full audit log and expand the row there to convert."
     )}
  end

  # #274 — stuck-on sentinels for this task. Retry deletes the
  # sentinel only; skip reassigns to director; stop marks denied.
  # Matches InboxLive's `stuck_resolve` handler semantics so the
  # two views stay behaviourally identical.
  def handle_event("stuck_resolve", %{"decision" => dec, "sentinel_path" => sp}, socket)
      when dec in ["retry", "skip", "stop"] do
    base = base_dir()
    co = socket.assigns.company_slug
    abs_sentinel = Path.join([base, "companies", co, sp])

    case Glorbo.Agent.LoopDetector.resolve(
           abs_sentinel,
           String.to_existing_atom(dec),
           base,
           co,
           actor: "director"
         ) do
      :ok ->
        flash_msg =
          case dec do
            "retry" -> "Stuck sentinel cleared — next dispatch will retry."
            "skip" -> "Reassigned to director."
            "stop" -> "Task marked denied."
          end

        {:noreply,
         socket
         |> assign(:stuck, load_stuck_for_task(base, co, socket.assigns.task_id))
         |> put_flash(:info, flash_msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Resolve failed: #{inspect(reason)}")}
    end
  end

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

  # PLAN item — shared-task-detail-component. The shared
  # TaskDetailForm emits `save_task` / `delete_task` / `close_task`
  # events; TaskLive handles them to keep parity with KanbanLive's
  # shelf (without which the form would throw on submit).
  # The shared TaskDetailForm emits save/delete/close events. Save
  # writes frontmatter only (body editing remains KanbanLive-only
  # for now — TaskLive's textarea is editable but the submit ignores
  # the body field; users who need to rewrite the body open the
  # shelf view from Kanban).
  def handle_event("save_task", params, socket) do
    abs =
      Path.join([base_dir(), "companies", socket.assigns.company_slug, socket.assigns.rel_path])

    updates =
      %{
        "title" => params["title"],
        "status" => params["status"],
        "assigned_to" => params["assigned_to"],
        "priority" => params["priority"],
        "severity" => params["severity"]
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    updates =
      case params["requires_approval"] do
        "director" -> Map.put(updates, "requires_approval", "director")
        _ -> updates
      end

    case Glorbo.TaskDefinition.write_frontmatter(abs, updates) do
      :ok -> {:noreply, put_flash(socket, :info, "Saved #{socket.assigns.task_id}.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not save task.")}
    end
  end

  def handle_event("delete_task", %{"path" => _path}, socket) do
    abs =
      Path.join([base_dir(), "companies", socket.assigns.company_slug, socket.assigns.rel_path])

    trash_dir = Path.join([Path.dirname(Path.dirname(abs)), "history", "deleted"])
    File.mkdir_p!(trash_dir)
    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    dest = Path.join(trash_dir, "#{ts}-#{Path.basename(abs)}")

    case File.rename(abs, dest) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Moved #{socket.assigns.rel_path} to history/deleted/.")
         |> push_navigate(to: ~p"/companies/#{socket.assigns.company_slug}/kanban")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  def handle_event("close_task", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/companies/#{socket.assigns.company_slug}/kanban")}
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

  # Resolve the on-disk task file for a canonical id. Two shapes are
  # supported (#314):
  #
  #   1. Canonical `<project>-<NN>.md` — used verbatim.
  #   2. Descriptive `<project>-<NN>-<slug>.md` — resolved when the
  #      canonical file doesn't exist and exactly one descriptive
  #      sibling matches the `<project>-<NN>` prefix. Two or more
  #      matches is ambiguous; the LiveView flashes an error and
  #      sends the director to the kanban where they can see all
  #      tasks in the project.
  @spec resolve_task_file(Path.t(), String.t(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:ok, String.t(), Path.t()}
          | {:error, :not_found}
          | {:error, {:ambiguous, [Path.t()]}}
  defp resolve_task_file(co_path, project, task_id, _socket) do
    rel_canonical = "projects/#{project}/tasks/#{task_id}.md"
    abs_canonical = Path.join(co_path, rel_canonical)

    if File.regular?(abs_canonical) do
      {:ok, rel_canonical, abs_canonical}
    else
      tasks_dir = Path.join([co_path, "projects", project, "tasks"])
      matches = Path.wildcard(Path.join(tasks_dir, "#{task_id}-*.md"))

      case matches do
        [] ->
          {:error, :not_found}

        [abs_match] ->
          rel = Path.relative_to(abs_match, co_path)
          {:ok, rel, abs_match}

        many ->
          {:error, {:ambiguous, many}}
      end
    end
  end

  defp to_detail(task, abs_task_path) do
    %{
      task_id: task.task_id,
      title: task.title || "",
      status: task.status || "todo",
      assigned_to: task.assigned_to || "",
      priority: if(task.priority, do: Atom.to_string(task.priority), else: ""),
      severity: if(task.severity, do: Atom.to_string(task.severity), else: ""),
      requires_approval: if(task.requires_approval == :director, do: "director", else: ""),
      denial_reason: task.denial_reason || "",
      schedule: task.schedule || "",
      body: String.trim(task.prompt_body || ""),
      # GEP-30 D8: thread lives in a sibling `.comments.md` file.
      comments: load_task_comments(abs_task_path)
    }
  end

  defp load_task_comments(abs_task_path) do
    comments_path = Glorbo.TaskComments.path_for(abs_task_path)

    case Glorbo.TaskComments.read(comments_path) do
      {:ok, entries} -> entries
      _ -> []
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
            <span class="gl-muted">
              {GlorboWeb.LiveHelpers.display_base()}/companies/{@company_slug}/{@rel_path}
            </span>
          </p>
        </div>
        <div class="gl-overview__actions">
          <.link navigate={~p"/companies/#{@company_slug}/kanban?task=#{@rel_path}"} class="gl-btn">
            ← back to kanban
          </.link>
        </div>
      </header>

      <aside :if={@stuck != []} class="gl-task-page__stuck" aria-live="polite">
        <div :for={s <- @stuck} class="gl-task-page__stuck-row">
          <div class="gl-task-page__stuck-head">
            <span class="gl-task-page__stuck-glyph" aria-hidden="true">⚠</span>
            <strong>{s.agent}</strong>
            <span class="gl-muted">· stuck on this task</span>
            <span :if={s.stuck_at != ""} class="gl-muted">· {s.stuck_at}</span>
          </div>
          <div class="gl-task-page__stuck-reason gl-muted">{s.reason}</div>
          <div class="gl-task-page__stuck-actions">
            <button
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="stuck_resolve"
              phx-value-decision="retry"
              phx-value-sentinel_path={s.sentinel_path}
            >
              ↻ retry
            </button>
            <button
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="stuck_resolve"
              phx-value-decision="skip"
              phx-value-sentinel_path={s.sentinel_path}
            >
              ⏭ skip (reassign to me)
            </button>
            <button
              type="button"
              class="gl-btn gl-btn--sm gl-btn--deny"
              phx-click="stuck_resolve"
              phx-value-decision="stop"
              phx-value-sentinel_path={s.sentinel_path}
            >
              × stop (deny task)
            </button>
          </div>
        </div>
      </aside>

      <aside class="gl-task-page__usage" aria-label="Usage totals across dispatches">
        <div class="gl-task-page__usage-row">
          <span class="gl-task-page__usage-label">dispatches</span>
          <span class="gl-tabular">{@usage_totals.dispatch_count}</span>
        </div>
        <div class="gl-task-page__usage-row">
          <span class="gl-task-page__usage-label">tokens</span>
          <span class="gl-tabular">
            {@usage_totals.prompt_tokens} in / {@usage_totals.completion_tokens} out
          </span>
        </div>
        <div :if={@task.schedule != ""} class="gl-task-page__usage-row">
          <span class="gl-task-page__usage-label">schedule</span>
          <span class="gl-tabular" title={@task.schedule}>
            ↻ {@task.schedule}<span :if={@next_fire_at} class="gl-muted">
              &nbsp;· next fire {format_next_fire(@next_fire_at)}
            </span>
          </span>
        </div>
        <div class="gl-task-page__usage-row">
          <span class="gl-task-page__usage-label">cost</span>
          <span class="gl-tabular">{format_cost(@usage_totals.cost_usd_cents)}</span>
        </div>
        <div :if={@path_grants != []} class="gl-task-page__usage-row">
          <span class="gl-task-page__usage-label">external paths</span>
          <span class="gl-tabular gl-task-page__grants">
            <span :for={g <- @path_grants} class="gl-task-page__grant">
              @{g.agent}:
              <span :for={p <- g.paths} class="gl-task-page__grant-path">
                {p.sandbox_path} <span class="gl-muted">({p.mode})</span>
              </span>
            </span>
          </span>
        </div>
      </aside>

      <div class="gl-task-page__grid">
        <section class="gl-panel">
          <header class="gl-panel__header">
            <span class="gl-panel__title">{@task.title}</span>
          </header>
          <div class="gl-panel__body gl-task-page__form">
            <TaskDetailForm.task_detail_form
              task={Map.put(@task, :task_path, @rel_path)}
              company_slug={@company_slug}
              assignee_options={[]}
            />
          </div>
        </section>

        <section class="gl-panel">
          <header class="gl-panel__header">
            <span class="gl-panel__title">add a comment</span>
          </header>
          <div class="gl-panel__body">
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

      <section class="gl-panel gl-task-page__history">
        <header class="gl-panel__header gl-panel__header--split">
          <span class="gl-panel__title">history · this task</span>
          <.link
            navigate={~p"/companies/#{@company_slug}/audit?q=#{@task_id}"}
            class="gl-btn gl-btn--sm gl-btn--ghost"
            title="Open the full audit log pre-filtered by this task"
          >
            view full audit →
          </.link>
        </header>
        <div :if={@history == []} class="gl-panel__body gl-muted">
          No audit events yet for this task.
        </div>
        <div :if={@history != []} class="gl-panel__body gl-task-page__history-body">
          <GlorboWeb.Components.AuditEntry.audit_entry
            :for={{entry, idx} <- Enum.with_index(@history)}
            id={history_entry_id(entry, idx)}
            entry={entry}
            expanded={MapSet.member?(@history_expanded, history_entry_id(entry, idx))}
          />
        </div>
      </section>
    </section>
    """
  end

  # #264 — stable per-row id (ts + action hash) so toggling
  # expansion persists across audit appends.
  defp history_entry_id(entry, fallback_idx) do
    ts = to_string(entry["ts"] || "")
    action = to_string(entry["action"] || "")

    case {ts, action} do
      {"", ""} ->
        "task-history-#{fallback_idx}"

      _ ->
        :crypto.hash(:sha256, ts <> "\0" <> action)
        |> Base.url_encode64(padding: false)
        |> binary_part(0, 16)
    end
  end

  # #252 — aggregate tokens + cost for this specific task across
  # GEP-24 — format the next fire time as a compact "in 2h 15m" /
  # "in 30s" hint. For far-future fires we fall back to ISO so
  # a monthly cron doesn't render "in 720h".
  defp format_next_fire(%DateTime{} = dt) do
    secs = DateTime.diff(dt, DateTime.utc_now(), :second)

    cond do
      secs <= 0 -> "imminent"
      secs < 60 -> "in #{secs}s"
      secs < 3600 -> "in #{div(secs, 60)}m"
      secs < 86_400 -> "in #{div(secs, 3600)}h #{rem(div(secs, 60), 60)}m"
      secs < 7 * 86_400 -> "in #{div(secs, 86_400)}d"
      true -> String.slice(DateTime.to_iso8601(dt), 0, 16) <> "Z"
    end
  end

  defp format_next_fire(_), do: ""

  # GEP-24 — next armed fire time from the per-company
  # `TaskScheduler` process, or `nil` when the task isn't armed
  # (no schedule, unparseable cron, or scheduler not running in
  # this context — e.g. a test that boots TaskLive without the
  # full Company.Supervisor). Tolerates the "not running" case
  # via the scheduler's own `catch :exit`.
  defp next_fire_at(co, task_id) do
    server = Glorbo.Company.Supervisor.via(co, :task_scheduler)
    Glorbo.Company.TaskScheduler.next_fire_at(server, task_id)
  rescue
    _ -> nil
  end

  # GEP-27 — load active path grants for this task from ETS.
  defp load_path_grants(co, task_id) do
    Glorbo.PathGrantStore.lookup_by_task_id(co, task_id)
  end

  # #274 — load any `stuck-on-<this-task>.md` sentinels under
  # agents/*/state. Mirrors InboxLive.load_stuck/2 but filtered to
  # this task_id. Returns at most one row; multiple agents stuck
  # on the same task is allowed (shouldn't happen in practice but
  # we render all of them).
  defp load_stuck_for_task(base, co, task_id) do
    # R21: apply agent-dropped resolution files before listing. Keeps
    # TaskLive and InboxLive behaviourally identical.
    _ = Glorbo.Agent.LoopDetector.apply_resolution_files(base, co)

    co_dir = Path.join([base, "companies", co])

    co_dir
    |> Path.join("agents/*/state/stuck-on-#{task_id}.md")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&stuck_row(&1, co_dir))
    |> Enum.reject(&is_nil/1)
  end

  defp stuck_row(sentinel_path, co_dir) do
    with {:ok, content} <- File.read(sentinel_path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      rel_sentinel = Path.relative_to(sentinel_path, co_dir) |> to_string()
      agent = agent_from_sentinel_path(sentinel_path)

      %{
        sentinel_path: rel_sentinel,
        agent: agent,
        stuck_at: to_string(fm["detected_at"] || fm["stuck_at"] || ""),
        reason: to_string(fm["reason"] || fm["signature"] || "repeated identical outputs")
      }
    else
      _ -> nil
    end
  end

  # Extract the agent slug from a sentinel absolute path:
  # `.../agents/<slug>/state/stuck-on-...` → `<slug>`.
  defp agent_from_sentinel_path(path) do
    path
    |> Path.split()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value("", fn
      ["agents", slug, "state"] -> slug
      _ -> false
    end)
  end

  # every `agent.complete` in the current month's audit. Audit is
  # append-only so one pass is cheap; older months are reachable
  # via AuditLive.
  defp load_usage_totals(base, co, rel_path) do
    month = DateTime.utc_now() |> DateTime.to_date() |> Date.to_string() |> String.slice(0, 7)
    path = Path.join([base, "companies", co, "audit", "#{month}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reduce(
          %{prompt_tokens: 0, completion_tokens: 0, cost_usd_cents: 0, dispatch_count: 0},
          fn line, acc -> accumulate_usage(line, rel_path, acc) end
        )

      _ ->
        %{prompt_tokens: 0, completion_tokens: 0, cost_usd_cents: 0, dispatch_count: 0}
    end
  rescue
    _ -> %{prompt_tokens: 0, completion_tokens: 0, cost_usd_cents: 0, dispatch_count: 0}
  end

  defp accumulate_usage(line, rel_path, acc) do
    case Jason.decode(line) do
      {:ok, %{"action" => "agent.complete", "target" => ^rel_path, "detail" => detail}}
      when is_map(detail) ->
        %{
          prompt_tokens: acc.prompt_tokens + (detail["prompt_tokens"] || 0),
          completion_tokens: acc.completion_tokens + (detail["completion_tokens"] || 0),
          cost_usd_cents: acc.cost_usd_cents + (detail["cost_usd_cents"] || 0),
          dispatch_count: acc.dispatch_count + 1
        }

      _ ->
        acc
    end
  end

  # #246 rule — tokens always, cost only when pricing known
  # (non-zero total means at least one dispatch had cost data).
  defp format_cost(0), do: "—"

  defp format_cost(cents) when is_integer(cents) do
    whole = div(cents, 100)
    cents_part = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{whole}.#{cents_part}"
  end

  defp format_cost(_), do: "—"
end
