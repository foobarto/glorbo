defmodule GlorboWeb.Components.TaskDetailForm do
  @moduledoc """
  Shared task-detail form used by both `KanbanLive` (shelf overlay)
  and `TaskLive` (dedicated page).

  Renders the save form (title / status / assigned_to / priority /
  severity / requires_approval / done_when / body), the
  denial-reason notice, the attachments list, and the comments
  feed. The parent LV owns the `save_task` / `delete_task` event
  handlers — this component just emits `phx-submit="save_task"`
  and `phx-click="delete_task"` and lets the standard delegation
  bubble them to the LV.

  The comment-submit form stays per-caller because its layout
  (inline at the bottom of the shelf vs. a separate section on
  TaskLive's page) differs.

  ## Assigns

    * `:task` — the task detail map: `:task_id`, `:task_path`,
      `:title`, `:status`, `:assigned_to`, `:priority`, `:severity`,
      `:requires_approval`, `:done_when`, `:denial_reason`, `:body`,
      `:comments`, `:attachments` (may be absent).
    * `:company_slug` — used in the footer path label.
    * `:assignee_options` — list of slugs to suggest in the
      `<datalist>`. Pass `[]` if unknown.
    * `:include_footer` — default `true`; pass `false` when the
      calling layout supplies its own cancel/save/delete row (for
      example, TaskLive keeps cancel implicit via navigation).
  """
  use Phoenix.Component

  attr :task, :map, required: true
  attr :company_slug, :string, required: true
  attr :assignee_options, :list, default: []
  attr :include_footer, :boolean, default: true

  def task_detail_form(assigns) do
    ~H"""
    <form
      id={"task-detail-form-#{@task.task_id}"}
      phx-submit="save_task"
      class="gl-task-detail__save-form"
    >
      <div class="gl-task-detail__fields">
        <label class="gl-task-detail__field">
          <span class="gl-muted">title</span>
          <input type="text" name="title" value={@task.title} class="gl-input" required />
        </label>

        <label class="gl-task-detail__field">
          <span class="gl-muted">status</span>
          <select name="status" class="gl-input">
            <option value="todo" selected={@task.status == "todo"}>todo</option>
            <option value="in-progress" selected={@task.status == "in-progress"}>
              in-progress
            </option>
            <optgroup label="review (approval gate)">
              <option value="pending" selected={@task.status == "pending"}>pending</option>
              <option value="pending-approval" selected={@task.status == "pending-approval"}>
                pending-approval
              </option>
              <option value="approved" selected={@task.status == "approved"}>approved</option>
              <option value="denied" selected={@task.status == "denied"}>denied</option>
            </optgroup>
            <option value="done" selected={@task.status == "done"}>done</option>
          </select>
        </label>

        <label class="gl-task-detail__field">
          <span class="gl-muted">assigned_to</span>
          <input
            type="text"
            name="assigned_to"
            value={@task.assigned_to}
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
            <option value="" selected={@task.priority == ""}>—</option>
            <option value="low" selected={@task.priority == "low"}>low</option>
            <option value="medium" selected={@task.priority == "medium"}>medium</option>
            <option value="high" selected={@task.priority == "high"}>high</option>
          </select>
        </label>

        <label class="gl-task-detail__field">
          <span class="gl-muted">severity</span>
          <select name="severity" class="gl-input">
            <option value="" selected={@task.severity == ""}>—</option>
            <option value="info" selected={@task.severity == "info"}>info</option>
            <option value="minor" selected={@task.severity == "minor"}>minor</option>
            <option value="major" selected={@task.severity == "major"}>major</option>
            <option value="critical" selected={@task.severity == "critical"}>critical</option>
          </select>
        </label>

        <label class="gl-task-detail__field gl-task-detail__field--check">
          <input type="hidden" name="requires_approval" value="" />
          <input
            type="checkbox"
            name="requires_approval"
            value="director"
            checked={@task.requires_approval == "director"}
          />
          <span>requires Director approval</span>
        </label>

        <label class="gl-task-detail__field gl-task-detail__field--body">
          <span class="gl-muted">done when</span>
          <textarea
            name="done_when"
            rows="3"
            class="gl-input"
            placeholder="Definition of done — what makes this task complete?"
          >{Map.get(@task, :done_when) || ""}</textarea>
        </label>

        <label class="gl-task-detail__field gl-task-detail__field--body">
          <span class="gl-muted">body</span>
          <textarea name="body" rows="8" class="gl-input">{@task.body}</textarea>
        </label>

        <div :if={@task.denial_reason && @task.denial_reason != ""} class="gl-task-detail__field">
          <span class="gl-muted">denial reason</span>
          <div class="gl-approval-card__reason">{@task.denial_reason}</div>
        </div>

        <div
          :if={Map.get(@task, :attachments, []) != []}
          class="gl-task-detail__field"
        >
          <span class="gl-muted">attachments</span>
          <ul class="gl-upload-list">
            <li :for={a <- Map.get(@task, :attachments, [])} class="gl-upload-list__row">
              <span class="gl-upload-list__name">{a.name}</span>
              <span class="gl-muted gl-upload-list__size">
                {Float.round(a.size / 1024, 1)} KB
              </span>
            </li>
          </ul>
        </div>

        <div class="gl-task-detail__field">
          <span class="gl-muted">comments ({length(@task.comments)})</span>
          <ul :if={@task.comments != []} class="gl-task-comments">
            <li :for={c <- @task.comments} class="gl-task-comments__row">
              <span class="gl-task-comments__author">{c.author}</span>
              <span class="gl-muted gl-task-comments__ts">{c.timestamp}</span>
              <div class="gl-task-comments__body">
                {Phoenix.HTML.raw(linkify_body(c.body, @company_slug))}
              </div>
            </li>
          </ul>
          <p :if={@task.comments == []} class="gl-muted gl-task-comments__empty">
            No comments yet — use the field below to add one. @mentions wake the agent.
          </p>
        </div>
      </div>

      <footer :if={@include_footer} class="gl-task-detail__footer">
        <span class="gl-muted gl-task-detail__path">
          {GlorboWeb.LiveHelpers.display_base()}/companies/{@company_slug}/{@task.task_path}
        </span>
        <div class="gl-task-detail__actions">
          <button
            type="button"
            class="gl-btn gl-btn--deny"
            phx-click="delete_task"
            phx-value-path={@task.task_path}
            data-confirm="Delete this task? It'll move to projects/history/tasks/ (recoverable on disk)."
          >
            ✕ delete
          </button>
          <button type="button" class="gl-btn" phx-click="close_task">cancel</button>
          <button type="submit" class="gl-btn gl-btn--primary">save</button>
        </div>
      </footer>
    </form>
    """
  end

  # #276 — linkify comment body task-IDs. Escape first to prevent
  # XSS from user-supplied comment text, then run the linkifier so
  # `abc-02` becomes a clickable anchor to the kanban deep-link
  # (consistent with how channel messages handle task-ID tokens).
  # Returns a raw-safe string; callers wrap in `Phoenix.HTML.raw/1`.
  defp linkify_body(body, company) when is_binary(body) and is_binary(company) do
    escaped =
      body
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    GlorboWeb.Markdown.Linkify.rewrite(escaped, company)
  end

  defp linkify_body(_, _), do: ""
end
