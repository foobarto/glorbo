defmodule GlorboWeb.Components.ApprovalCard do
  @moduledoc """
  Approval queue row (D-26, 04-UI-SPEC §Copy for ApprovalQueueLive).

  Props:

    * `:sentinel` — map with `:task_id`, `:task_path`, `:title`,
      `:requesting_agent`, `:requested_at` (ISO8601 string).

  Renders title + requester/timestamp meta + Approve (accent, check
  glyph) and Deny (danger, x glyph) buttons. Both buttons carry
  `phx-click="approve"|"deny"` + `phx-value-task_path={task_path}`;
  the enclosing LiveView handles both events through
  `GlorboWeb.Actions.set_approval/4` which validates the path before
  writing (T-04-09 mitigation).
  """
  use Phoenix.Component

  alias GlorboWeb.TimeFormat

  attr :sentinel, :map, required: true

  def approval_card(assigns) do
    ~H"""
    <article class="gl-approval-card">
      <header class="gl-approval-card__title">{@sentinel.title}</header>
      <div class="gl-approval-card__meta gl-muted">
        {@sentinel.requesting_agent} ·
        <time
          datetime={TimeFormat.iso(@sentinel.requested_at)}
          title={TimeFormat.iso(@sentinel.requested_at)}
        >
          {TimeFormat.relative(@sentinel.requested_at)}
        </time>
      </div>
      <div :if={Map.get(@sentinel, :reason)} class="gl-approval-card__reason">
        {Map.get(@sentinel, :reason)}
      </div>
      <div class="gl-approval-card__actions">
        <button
          type="button"
          class="gl-btn gl-btn--approve"
          phx-click="approve"
          phx-value-task_path={@sentinel.task_path}
        >
          <GlorboWeb.CoreComponents.icon name="check" /> Approve
        </button>
        <button
          type="button"
          class="gl-btn gl-btn--deny"
          phx-click="deny"
          phx-value-task_path={@sentinel.task_path}
        >
          <GlorboWeb.CoreComponents.icon name="x" /> Deny
        </button>
      </div>
    </article>
    """
  end
end
