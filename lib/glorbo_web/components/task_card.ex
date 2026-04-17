defmodule GlorboWeb.Components.TaskCard do
  @moduledoc """
  Kanban task card — mockup-aligned (abc.zip views/kanban.jsx).

  Card shape:

      ┌──────────────────────────────┐
      │ t-01 · website     [⚠ approval]
      │                              │
      │ Deploy landing page          │
      │                              │
      │ ● high · ceo                 │
      └──────────────────────────────┘

  Approval-gated tasks get a 3px amber left border and an `⚠ approval`
  pill in the top-right. Priority renders as a colored dot + label
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
        @task.requires_approval == :director && "gl-task-card--approval"
      ]}
      data-status={@task.status}
      data-task-path={@task.task_path}
      phx-hook="KanbanCard"
      phx-click="open_task"
      phx-value-path={@task.task_path}
      role="button"
      tabindex="0"
    >
      <header class="gl-task-card__header">
        <span class="gl-task-card__id">{@task.task_id}</span>
        <span :if={@task.project} class="gl-task-card__project gl-muted">· {@task.project}</span>
        <span :if={@task.requires_approval == :director} class="gl-task-card__approval-tag">
          ⚠ approval
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
        <span :if={@task.priority && @task.assigned_to} class="gl-muted">·</span>
        <span :if={@task.assigned_to} class="gl-task-card__assignee">{@task.assigned_to}</span>
      </div>
    </article>
    """
  end
end
