defmodule GlorboWeb.Components.AuditEntry do
  @moduledoc """
  A single row inside `AuditLive` (UI-SPEC §Copy for AuditLive).

  Collapsed row: `ts · actor · action · target` in label-size text.
  Expanded row: pretty-printed JSON payload under the row, bg delta to
  `--gl-surface-raised`. Toggled by the parent LV via `phx-click="toggle"
  phx-value-id={id}`.

  ## Keyboard support (TODO.md P1)

  The whole `<article>` acts as a button: `role="button"`,
  `tabindex="0"`, and a `phx-keydown="toggle"` binding with
  `phx-key="Enter"` so keyboard users can expand/collapse rows. (LV's
  `phx-key` filter is a single key — Enter is the primary affordance;
  Space-to-toggle on custom-roled buttons is a nice-to-have that WAI-
  ARIA documents as "either works" — we take Enter only to keep one
  server event per key press.)

  `aria-expanded` reflects the current state so screen readers announce
  the collapse/expand.

  Raw ISO timestamps are wrapped in `<time datetime=>` so screen
  readers surface a real datetime rather than an opaque string.
  """
  use Phoenix.Component

  attr :entry, :map, required: true
  attr :expanded, :boolean, default: false
  attr :id, :string, required: true

  def audit_entry(assigns) do
    ~H"""
    <article
      class={["gl-audit-entry", @expanded && "gl-audit-entry--expanded"]}
      role="button"
      tabindex="0"
      aria-expanded={to_string(@expanded)}
      aria-label={"Audit event #{@entry["action"]} by #{@entry["actor"]}"}
      phx-click="toggle"
      phx-value-id={@id}
      phx-keydown="toggle"
      phx-key="Enter"
    >
      <div class="gl-audit-entry__row">
        <time class="gl-muted gl-tabular" datetime={@entry["ts"]}>{@entry["ts"]}</time>
        <span>{@entry["actor"]}</span>
        <span>{@entry["action"]}</span>
        <span class="gl-muted">{@entry["target"]}</span>
      </div>
      <pre :if={@expanded} class="gl-audit-entry__payload">{Jason.encode!(@entry, pretty: true)}</pre>
    </article>
    """
  end
end
