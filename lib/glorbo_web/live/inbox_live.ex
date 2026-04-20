defmodule GlorboWeb.InboxLive do
  @moduledoc """
  Director's unified inbox — `/companies/:company/inbox`.

  Aggregates the director's attention-demanding items into one
  chronological feed with filter tabs:

  - **Mine** — pending approvals (same source as `/approvals`).
  - **Recent** — last 50 audit entries visible to the director
    (excludes bulk `stdout_line` / `heartbeat_skipped` noise).
  - **All** — union of Mine + Recent, newest first.
  - **Archive** — placeholder for future "I handled this" flow.

  Approval rows expose inline approve / deny actions so the
  director doesn't have to detour through ApprovalQueueLive for
  the common case. Denial opens the same prompt modal pattern.

  Paperclip-ux-gaps.md §3 motivated this — paperclip's `/Inbox`
  surfaces approvals + comments + assignments in one place; we
  ship the approvals-and-audit slice now, leaving @mention and
  assignment feeds as later additions.
  """
  use GlorboWeb, :live_view
  require Logger

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.Inbox.Archive
  alias GlorboWeb.Components.AuditEntry
  alias GlorboWeb.Components.ChatDrawer

  @valid_tabs ~w(mine recent all archive)

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    if GlorboWeb.Slug.valid?(co) do
      mount_valid(co, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid company identifier.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  defp mount_valid(co, socket) do
    base = base_dir()

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:approvals")
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
    end

    sentinels = load_sentinels(base, co)
    stuck = load_stuck(base, co)
    audits = load_recent_audit(base, co)
    archived = Archive.list(base, co)

    {:ok,
     socket
     |> assign(:page_title, "Inbox — #{co} — Glorbo")
     |> assign(:sidebar_active, :approvals)
     |> assign(:company_slug, co)
     |> assign(:current_company, co)
     |> assign(:base, base)
     |> assign(:tab, :mine)
     |> assign(:sentinels, sentinels)
     |> assign(:stuck, stuck)
     |> assign(:audit_rows, audits)
     |> assign(:archived, archived)
     |> assign(:deny_task_path, nil)
     |> ChatDrawer.State.wire_drawer()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab =
      case Map.get(params, "tab") do
        t when t in @valid_tabs -> String.to_existing_atom(t)
        _ -> :mine
      end

    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def handle_info({:file_event, rel, _events}, socket) do
    socket = ChatDrawer.State.maybe_refresh_drawer(socket, rel)
    sentinels = load_sentinels(socket.assigns.base, socket.assigns.company_slug)
    stuck = load_stuck(socket.assigns.base, socket.assigns.company_slug)
    audits = load_recent_audit(socket.assigns.base, socket.assigns.company_slug)
    archived = Archive.list(socket.assigns.base, socket.assigns.company_slug)

    {:noreply,
     socket
     |> assign(:sentinels, sentinels)
     |> assign(:stuck, stuck)
     |> assign(:audit_rows, audits)
     |> assign(:archived, archived)}
  end

  def handle_info({:audit_append, _row}, socket) do
    audits = load_recent_audit(socket.assigns.base, socket.assigns.company_slug)
    {:noreply, assign(socket, :audit_rows, audits)}
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("tab", %{"tab" => tab}, socket) when tab in @valid_tabs do
    {:noreply,
     push_patch(socket, to: ~p"/companies/#{socket.assigns.company_slug}/inbox?tab=#{tab}")}
  end

  def handle_event("approve", %{"task_path" => tp}, socket) do
    case GlorboWeb.Actions.set_approval(socket.assigns.company_slug, tp, :approved,
           base: socket.assigns.base
         ) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Approved #{tp}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
    end
  end

  def handle_event("deny_prompt", %{"task_path" => tp}, socket) do
    {:noreply, assign(socket, :deny_task_path, tp)}
  end

  def handle_event("deny_cancel", _params, socket) do
    {:noreply, assign(socket, :deny_task_path, nil)}
  end

  def handle_event("deny_confirm", %{"reason" => reason}, socket) do
    tp = socket.assigns.deny_task_path

    case GlorboWeb.Actions.set_approval(socket.assigns.company_slug, tp, :denied,
           base: socket.assigns.base,
           denial_reason: reason
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:deny_task_path, nil)
         |> put_flash(:info, "Denied #{tp}.")}

      {:error, reason_err} ->
        {:noreply, put_flash(socket, :error, "Deny failed: #{inspect(reason_err)}")}
    end
  end

  # Archive actions — the director marks an audit row (or pending
  # approval) as "handled". Stored in a per-company JSON file; the
  # Archive tab renders marked rows. Unarchive is symmetric.
  def handle_event("archive", %{"key" => key}, socket) do
    :ok = Archive.add(socket.assigns.base, socket.assigns.company_slug, key)

    {:noreply,
     socket
     |> assign(:archived, Archive.list(socket.assigns.base, socket.assigns.company_slug))
     |> put_flash(:info, "Archived.")}
  end

  def handle_event("unarchive", %{"key" => key}, socket) do
    :ok = Archive.remove(socket.assigns.base, socket.assigns.company_slug, key)

    {:noreply,
     socket
     |> assign(:archived, Archive.list(socket.assigns.base, socket.assigns.company_slug))
     |> put_flash(:info, "Unarchived.")}
  end

  # Resolve a stuck-on sentinel. Three decisions:
  #
  # * `retry` — delete the sentinel only. Next dispatch cycle can
  #   try again; the LoopDetector will re-flag if it keeps failing.
  # * `skip`  — delete the sentinel + reassign task to `director`.
  #   Director picks up the work themselves.
  # * `stop`  — delete the sentinel + set task `status: denied`.
  #   Work is abandoned.
  def handle_event("stuck_resolve", %{"decision" => dec, "sentinel_path" => sp}, socket)
      when dec in ["retry", "skip", "stop"] do
    base = socket.assigns.base
    co = socket.assigns.company_slug
    abs_sentinel = Path.join([base, "companies", co, sp])

    case resolve_stuck(abs_sentinel, dec, base, co) do
      :ok ->
        stuck = load_stuck(base, co)

        flash_msg =
          case dec do
            "retry" -> "Stuck sentinel cleared — next dispatch will retry."
            "skip" -> "Reassigned to director."
            "stop" -> "Task marked denied."
          end

        {:noreply,
         socket
         |> assign(:stuck, stuck)
         |> put_flash(:info, flash_msg)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Resolve failed: #{inspect(reason)}")}
    end
  end

  # Resolution: delete sentinel + optionally mutate the task. Task
  # mutation uses TaskDefinition.write/2 — same atomic path as
  # kanban saves. Sentinel removal is best-effort; if TaskDefinition
  # update fails the sentinel stays so the director still sees it.
  defp resolve_stuck(abs_sentinel, decision, base, company) do
    with {:ok, content} <- File.read(abs_sentinel),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      task_path = to_string(fm["task_path"] || "")
      abs_task = Path.join([base, "companies", company, task_path])

      case decision do
        "retry" ->
          _ = File.rm(abs_sentinel)
          :ok

        "skip" ->
          with :ok <- Glorbo.TaskDefinition.write(abs_task, %{assigned_to: "director"}) do
            _ = File.rm(abs_sentinel)
            :ok
          end

        "stop" ->
          with :ok <-
                 Glorbo.TaskDefinition.write(abs_task, %{status: "denied"}) do
            _ = File.rm(abs_sentinel)
            :ok
          end
      end
    else
      err -> err
    end
  end

  # ---------------------------------------------------------------------------
  # Data helpers
  # ---------------------------------------------------------------------------

  # Mirror ApprovalQueueLive's sentinel loader so the approvals slice
  # stays consistent across views. Kept local (not extracted) because
  # the approval UI component depends on the exact shape.
  @state_glob "agents/*/state/awaiting-approval-*.md"
  @stuck_glob "agents/*/state/stuck-on-*.md"

  defp load_sentinels(base, company) do
    co_dir = Path.join([base, "companies", company])

    co_dir
    |> Path.join(@state_glob)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&sentinel_row(&1, co_dir, base, company))
    |> Enum.reject(&is_nil/1)
  end

  defp load_stuck(base, company) do
    co_dir = Path.join([base, "companies", company])

    co_dir
    |> Path.join(@stuck_glob)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&stuck_row(&1, co_dir))
    |> Enum.reject(&is_nil/1)
  end

  defp stuck_row(sentinel_path, co_dir) do
    filename = Path.basename(sentinel_path, ".md")

    with [_, task_id] when task_id != "" <- String.split(filename, "stuck-on-", parts: 2),
         {:ok, content} <- File.read(sentinel_path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      # Sentinel carries agent + task_path in frontmatter.
      agent = to_string(fm["agent"] || "")
      task_path = to_string(fm["task_path"] || "")

      %{
        task_id: task_id,
        task_path: task_path,
        agent: agent,
        failure_count: fm["failure_count"] || 0,
        sentinel_path: Path.relative_to(sentinel_path, co_dir),
        last_failure_ts: to_string(fm["last_failure_ts"] || "")
      }
    else
      _ -> nil
    end
  end

  defp sentinel_row(sentinel_path, co_dir, base, company) do
    filename = Path.basename(sentinel_path, ".md")

    case String.split(filename, "awaiting-approval-", parts: 2) do
      [_, task_id] when task_id != "" ->
        task_path =
          co_dir
          |> Path.join("projects/**/tasks/#{task_id}.md")
          |> Path.wildcard()
          |> List.first()

        if is_nil(task_path) do
          nil
        else
          rel = Path.relative_to(task_path, co_dir)

          case Glorbo.TaskDefinition.parse_file(task_path, base: base, company: company) do
            {:ok, task} ->
              %{
                task_id: task_id,
                task_path: rel,
                title: task.title || task_id,
                assignee: task.assigned_to
              }

            _ ->
              %{task_id: task_id, task_path: rel, title: task_id, assignee: nil}
          end
        end

      _ ->
        nil
    end
  end

  @audit_limit 50
  @audit_noise_actions ~w(stdout_line heartbeat_skipped)

  defp load_recent_audit(base, company) do
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    path = Path.join([base, "companies", company, "audit", "#{month}.jsonl"])

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.flat_map(&decode_audit/1)
        |> Enum.reject(&noise?/1)
        |> Enum.take(@audit_limit)

      _ ->
        []
    end
  end

  defp decode_audit(line) do
    case Jason.decode(line) do
      {:ok, row} -> [row]
      _ -> []
    end
  end

  defp noise?(%{"action" => a}) when a in @audit_noise_actions, do: true
  defp noise?(_), do: false

  # Archive-key derivation — opaque strings the director uses to mark
  # an item as "handled". Stable across page reloads because they're
  # built from on-disk identifiers (task path or audit row coords).
  defp approval_key(%{task_path: tp}), do: "approval:" <> tp

  defp audit_key(row) do
    ts = to_string(row["ts"] || "")
    action = to_string(row["action"] || "")
    target = to_string(row["target"] || "")
    "audit:" <> ts <> "|" <> action <> "|" <> target
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :visible_sentinels,
        Enum.reject(assigns.sentinels, &MapSet.member?(assigns.archived, approval_key(&1)))
      )
      |> assign(
        :visible_audits,
        Enum.reject(assigns.audit_rows, &MapSet.member?(assigns.archived, audit_key(&1)))
      )
      |> assign(
        :archived_sentinels,
        Enum.filter(assigns.sentinels, &MapSet.member?(assigns.archived, approval_key(&1)))
      )
      |> assign(
        :archived_audits,
        Enum.filter(assigns.audit_rows, &MapSet.member?(assigns.archived, audit_key(&1)))
      )

    ~H"""
    <section class="gl-view gl-inbox">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">
          Inbox <span class="gl-muted">({length(@visible_sentinels)} pending)</span>
        </h1>
      </header>

      <div class="gl-inbox__tabs" role="tablist">
        <button
          :for={tab <- [:mine, :recent, :all, :archive]}
          type="button"
          role="tab"
          aria-selected={@tab == tab}
          class={["gl-inbox__tab", @tab == tab && "gl-inbox__tab--active"]}
          phx-click="tab"
          phx-value-tab={Atom.to_string(tab)}
        >
          {String.capitalize(Atom.to_string(tab))}
        </button>
      </div>

      <div :if={@tab in [:mine, :all]} class="gl-inbox__section">
        <h2 class="gl-heading gl-heading--heading">Pending approvals</h2>

        <div :if={@visible_sentinels == []} class="gl-muted gl-inbox__empty">
          No approvals pending. Tasks with <code>requires_approval: director</code>
          in frontmatter will appear here.
        </div>

        <ul :if={@visible_sentinels != []} class="gl-inbox__list">
          <li :for={s <- @visible_sentinels} class="gl-inbox__approval">
            <div class="gl-inbox__approval-meta">
              <span class="gl-tabular">{s.task_id}</span>
              <span :if={s.assignee} class="gl-muted">· {s.assignee}</span>
            </div>
            <div class="gl-inbox__approval-title">{s.title}</div>
            <div class="gl-inbox__approval-actions">
              <button
                type="button"
                class="gl-btn gl-btn--primary"
                phx-click="approve"
                phx-value-task_path={s.task_path}
              >
                approve
              </button>
              <button
                type="button"
                class="gl-btn gl-btn--deny"
                phx-click="deny_prompt"
                phx-value-task_path={s.task_path}
              >
                deny
              </button>
              <button
                type="button"
                class="gl-btn gl-btn--sm"
                phx-click="archive"
                phx-value-key={approval_key(s)}
                title="Archive (hide without acting)"
              >
                archive
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@tab in [:mine, :all] and @stuck != []} class="gl-inbox__section">
        <h2 class="gl-heading gl-heading--heading">
          Stuck agents <span class="gl-muted">({length(@stuck)})</span>
        </h2>

        <ul class="gl-inbox__list">
          <li :for={s <- @stuck} class="gl-inbox__approval gl-inbox__stuck">
            <div class="gl-inbox__approval-meta">
              <span class="gl-tabular">{s.task_id}</span>
              <span class="gl-muted">· @{s.agent}</span>
              <span class="gl-danger">· {s.failure_count} consecutive failures</span>
            </div>
            <div class="gl-inbox__approval-title">
              Agent is stuck — last failure {s.last_failure_ts}
            </div>
            <div class="gl-inbox__approval-actions">
              <button
                type="button"
                class="gl-btn"
                phx-click="stuck_resolve"
                phx-value-decision="retry"
                phx-value-sentinel_path={s.sentinel_path}
                title="Keep retrying this task"
              >
                retry
              </button>
              <button
                type="button"
                class="gl-btn"
                phx-click="stuck_resolve"
                phx-value-decision="skip"
                phx-value-sentinel_path={s.sentinel_path}
                title="Reassign to director"
              >
                skip
              </button>
              <button
                type="button"
                class="gl-btn gl-btn--deny"
                phx-click="stuck_resolve"
                phx-value-decision="stop"
                phx-value-sentinel_path={s.sentinel_path}
                title="Mark task as denied"
              >
                stop
              </button>
            </div>
          </li>
        </ul>
      </div>

      <div :if={@tab in [:recent, :all]} class="gl-inbox__section">
        <h2 class="gl-heading gl-heading--heading">Recent activity</h2>

        <div :if={@visible_audits == []} class="gl-muted gl-inbox__empty">
          No recent activity this month.
        </div>

        <ul :if={@visible_audits != []} class="gl-inbox__list gl-inbox__audit">
          <li :for={row <- @visible_audits} class="gl-inbox__audit-row">
            <span class="gl-muted gl-tabular">{Map.get(row, "ts", "")}</span>
            <span
              class={[
                "gl-avatar",
                "gl-avatar--" <> AuditEntry.actor_kind(Map.get(row, "actor", "system"))
              ]}
              aria-hidden="true"
              title={Map.get(row, "actor", "system")}
            >
              {AuditEntry.actor_initials(Map.get(row, "actor", "system"))}
            </span>
            <span class="gl-inbox__audit-actor">{Map.get(row, "actor", "system")}</span>
            <span class="gl-inbox__audit-action">{Map.get(row, "action", "?")}</span>
            <span :if={Map.get(row, "target")} class="gl-muted gl-inbox__audit-target">
              {Map.get(row, "target")}
            </span>
            <button
              type="button"
              class="gl-btn gl-btn--sm gl-inbox__audit-archive"
              phx-click="archive"
              phx-value-key={audit_key(row)}
              title="Archive this activity row"
            >
              archive
            </button>
          </li>
        </ul>
      </div>

      <div :if={@tab == :archive} class="gl-inbox__section">
        <h2 class="gl-heading gl-heading--heading">Archived</h2>

        <div
          :if={@archived_sentinels == [] and @archived_audits == []}
          class="gl-muted gl-inbox__empty"
        >
          Nothing archived yet. Use the <strong>archive</strong>
          button on any approval or activity row to hide it from
          the live feed. Unarchive restores it.
        </div>

        <ul :if={@archived_sentinels != []} class="gl-inbox__list">
          <li :for={s <- @archived_sentinels} class="gl-inbox__approval gl-inbox__approval--archived">
            <div class="gl-inbox__approval-meta">
              <span class="gl-tabular">{s.task_id}</span>
              <span :if={s.assignee} class="gl-muted">· {s.assignee}</span>
            </div>
            <div class="gl-inbox__approval-title">{s.title}</div>
            <div class="gl-inbox__approval-actions">
              <button
                type="button"
                class="gl-btn gl-btn--sm"
                phx-click="unarchive"
                phx-value-key={approval_key(s)}
              >
                unarchive
              </button>
            </div>
          </li>
        </ul>

        <ul :if={@archived_audits != []} class="gl-inbox__list gl-inbox__audit">
          <li :for={row <- @archived_audits} class="gl-inbox__audit-row">
            <span class="gl-muted gl-tabular">{Map.get(row, "ts", "")}</span>
            <span
              class={[
                "gl-avatar",
                "gl-avatar--" <> AuditEntry.actor_kind(Map.get(row, "actor", "system"))
              ]}
              aria-hidden="true"
              title={Map.get(row, "actor", "system")}
            >
              {AuditEntry.actor_initials(Map.get(row, "actor", "system"))}
            </span>
            <span class="gl-inbox__audit-actor">{Map.get(row, "actor", "system")}</span>
            <span class="gl-inbox__audit-action">{Map.get(row, "action", "?")}</span>
            <span :if={Map.get(row, "target")} class="gl-muted gl-inbox__audit-target">
              {Map.get(row, "target")}
            </span>
            <button
              type="button"
              class="gl-btn gl-btn--sm gl-inbox__audit-archive"
              phx-click="unarchive"
              phx-value-key={audit_key(row)}
            >
              unarchive
            </button>
          </li>
        </ul>
      </div>

      <div :if={@deny_task_path} class="gl-modal-scrim" phx-click-away="deny_cancel">
        <form
          class="gl-modal"
          phx-submit="deny_confirm"
          phx-window-keydown="deny_cancel"
          phx-key="Escape"
        >
          <header class="gl-modal__header">
            <strong>Deny {@deny_task_path}</strong>
            <button type="button" class="gl-modal__close" phx-click="deny_cancel">✕</button>
          </header>
          <div class="gl-modal__body">
            <label class="gl-form__row">
              <span class="gl-form__label">reason (optional)</span>
              <textarea
                name="reason"
                class="gl-input"
                rows="4"
                placeholder="Why are you denying this?"
              ></textarea>
            </label>
          </div>
          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="deny_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary gl-btn--deny">deny</button>
          </footer>
        </form>
      </div>
    </section>
    """
  end
end
