defmodule GlorboWeb.Components.AuditEntry do
  @moduledoc """
  A single row inside `AuditLive` (UI-SPEC §Copy for AuditLive).

  Collapsed row: `ts · actor · action · target` in label-size text.
  Expanded row: pretty-printed JSON payload under the row, bg delta to
  `--gl-surface-raised`. Toggled by the parent LV via `phx-click="toggle"
  phx-value-id={id}`.
  """
  use Phoenix.Component

  attr :entry, :map, required: true
  attr :expanded, :boolean, default: false
  attr :id, :string, required: true

  def audit_entry(assigns) do
    ~H"""
    <article
      class={["gl-audit-entry", @expanded && "gl-audit-entry--expanded"]}
      phx-click="toggle"
      phx-value-id={@id}
    >
      <div class="gl-audit-entry__row">
        <span class="gl-muted gl-tabular">{@entry["ts"]}</span>
        <span>{@entry["actor"]}</span>
        <span>{@entry["action"]}</span>
        <span class="gl-muted">{@entry["target"]}</span>
      </div>
      <pre :if={@expanded} class="gl-audit-entry__payload">{Jason.encode!(@entry, pretty: true)}</pre>
    </article>
    """
  end
end
