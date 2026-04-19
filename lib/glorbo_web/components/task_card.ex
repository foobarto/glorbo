defmodule GlorboWeb.Components.TaskCard do
  @moduledoc """
  Kanban task card — mockup-aligned (abc.zip views/kanban.jsx).

  Card shape:

      ┌──────────────────────────────┐
      │ t-01 · website     [⚠ gated]  │
      │                              │
      │ Deploy landing page          │
      │                              │
      │ ● high · ceo                 │
      └──────────────────────────────┘

  Tasks flagged `requires_approval: director` in frontmatter get a
  3px amber left border and an `⚠ gated` pill — signalling that the
  director has to approve before the agent's side-effect lands.
  This pill is a *metadata* marker; a task is only actually waiting
  on approval once the agent writes an `awaiting-approval-*.md`
  sentinel, which shows in `/approvals` (and not here — the
  kanban doesn't poll per-task sentinel state, UAT N7).
  Priority renders as a colored dot + label
  (`● high` rose, `● medium` amber, `● low` muted). Project is derived
  from the task_path (`projects/<project>/tasks/…`) in
  `Glorbo.TaskDefinition`.

  Click → opens the task detail overlay in KanbanLive.
  """
  use Phoenix.Component

  attr :task, :map, required: true
  attr :company_slug, :string, required: true

  def task_card(assigns) do
    ~H"""
    <article
      id={"gl-task-" <> @task.task_id <> "-" <> String.replace(@task.task_path, "/", "-")}
      class={[
        "gl-task-card",
        @task.requires_approval == :director && "gl-task-card--approval",
        @task.status == "denied" && "gl-task-card--denied",
        @task.status == "approved" && "gl-task-card--approved"
      ]}
      data-status={@task.status}
      data-task-path={@task.task_path}
      phx-hook="KanbanCard"
      phx-click="open_task"
      phx-keydown="open_task"
      phx-key="Enter"
      phx-value-path={@task.task_path}
      role="button"
      tabindex="0"
      aria-label={"Open task #{@task.task_id}: #{@task.title || "untitled"}"}
    >
      <header class="gl-task-card__header">
        <span class="gl-task-card__id">{@task.task_id}</span>
        <span :if={@task.project} class="gl-task-card__project gl-muted">· {@task.project}</span>
        <span
          :if={@task.status == "denied"}
          class="gl-task-card__status-tag gl-task-card__status-tag--denied"
          title="Director denied this task — see denial_reason in the task detail."
        >
          ✕ denied
        </span>
        <span
          :if={@task.status == "approved"}
          class="gl-task-card__status-tag gl-task-card__status-tag--approved"
          title="Director approved this task."
        >
          ✓ approved
        </span>
        <span
          :if={@task.requires_approval == :director and @task.status not in ["denied", "approved"]}
          class="gl-task-card__approval-tag"
          title="Approval-gated: director approval required before the agent's side-effect lands. Awaiting-approval state appears in /approvals when the agent writes a sentinel."
        >
          ⚠ gated
        </span>
      </header>
      <div class="gl-task-card__title">{@task.title || @task.task_id}</div>
      <div class="gl-task-card__meta">
        <span
          :if={@task.priority}
          class={"gl-task-card__priority gl-task-card__priority--" <> Atom.to_string(@task.priority)}
        >
          ● {Atom.to_string(@task.priority)}
        </span>
        <span :if={@task.priority && @task.severity} class="gl-muted">·</span>
        <span
          :if={@task.severity}
          class={"gl-task-card__severity gl-task-card__severity--" <> Atom.to_string(@task.severity)}
        >
          {Atom.to_string(@task.severity)}
        </span>
        <span :if={(@task.priority || @task.severity) && @task.assigned_to} class="gl-muted">·</span>
        <span :if={@task.assigned_to} class="gl-task-card__assignee">{@task.assigned_to}</span>
      </div>
    </article>
    """
  end
end
