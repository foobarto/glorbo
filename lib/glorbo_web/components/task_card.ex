defmodule GlorboWeb.Components.TaskCard do
  @moduledoc """
  Kanban cell (D-23). Renders title, assignee, and the lightning glyph
  when the task frontmatter carries `requires_approval: director`
  (the accessible `<title>` reads `Requires Director approval`, matching
  04-UI-SPEC §Copy).

  Stateless — takes a `Glorbo.TaskDefinition` struct and the enclosing
  company slug (unused right now but kept for future task-detail links).
  """
  use Phoenix.Component

  attr :task, :map, required: true
  attr :company_slug, :string, required: true

  def task_card(assigns) do
    ~H"""
    <article class="gl-task-card" data-status={@task.status}>
      <header class="gl-task-card__title">
        {@task.title || @task.task_id}
        <GlorboWeb.CoreComponents.icon
          :if={@task.requires_approval == :director}
          name="lightning"
          label="Requires Director approval"
          class="gl-task-card__lightning"
        />
      </header>
      <div class="gl-task-card__meta">
        <span :if={@task.assigned_to} class="gl-muted">{@task.assigned_to}</span>
      </div>
    </article>
    """
  end
end
