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
    <div
      class={["gl-audit-row", @expanded && "gl-audit-row--open"]}
      role="button"
      tabindex="0"
      aria-expanded={to_string(@expanded)}
      aria-label={"Audit event #{@entry["action"]} by #{@entry["actor"]}"}
      phx-click="toggle"
      phx-value-id={@id}
      phx-keydown="toggle"
      phx-key="Enter"
    >
      <time class="gl-audit-row__ts" datetime={@entry["ts"]}>{format_ts(@entry["ts"])}</time>
      <span class={["gl-audit-row__actor", actor_class(@entry["actor"])]}>{@entry["actor"]}</span>
      <span class={["gl-audit-row__action", action_class(@entry["action"])]}>
        {@entry["action"]}
      </span>
      <span class="gl-audit-row__target">
        <span class="gl-audit-row__target-main">{@entry["target"]}</span>
        <span :if={detail_summary(@entry["detail"]) != ""} class="gl-muted">
          · {detail_summary(@entry["detail"])}
        </span>
      </span>
      <pre :if={@expanded} class="gl-audit-row__payload"><code>{Jason.encode!(@entry, pretty: true)}</code></pre>
    </div>
    """
  end

  defp format_ts(ts) when is_binary(ts),
    do: ts |> String.replace("T", " ") |> String.replace("Z", "")

  defp format_ts(_), do: ""

  defp actor_class("system"), do: "gl-audit-row__actor--system"
  defp actor_class(_), do: nil

  defp action_class(action) when is_binary(action) do
    cond do
      String.starts_with?(action, "budget") -> "gl-audit-row__action--budget"
      String.starts_with?(action, "message") -> "gl-audit-row__action--message"
      String.starts_with?(action, "approval") -> "gl-audit-row__action--approval"
      String.starts_with?(action, "agent.wake") -> "gl-audit-row__action--wake"
      true -> nil
    end
  end

  defp action_class(_), do: nil

  defp detail_summary(nil), do: ""
  defp detail_summary(""), do: ""
  defp detail_summary(d) when is_binary(d), do: d
  defp detail_summary(%{} = d) when map_size(d) == 0, do: ""
  defp detail_summary(%{} = d), do: Jason.encode!(d)
  defp detail_summary(d), do: inspect(d)
end
