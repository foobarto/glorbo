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
    sentence = to_sentence(assigns.entry)
    actor = to_string(assigns.entry["actor"] || "system")

    assigns =
      assigns
      |> assign(:sentence, sentence)
      |> assign(:actor_initials, actor_initials(actor))
      |> assign(:actor_kind, actor_kind(actor))

    ~H"""
    <div
      class={["gl-audit-row", @expanded && "gl-audit-row--open"]}
      role="button"
      tabindex="0"
      aria-expanded={to_string(@expanded)}
      aria-label={@sentence}
      phx-click="toggle"
      phx-value-id={@id}
      phx-keydown="toggle"
      phx-key="Enter"
    >
      <time class="gl-audit-row__ts" datetime={@entry["ts"]}>{format_ts(@entry["ts"])}</time>
      <span
        class={["gl-avatar", "gl-avatar--" <> @actor_kind]}
        aria-hidden="true"
        title={@entry["actor"]}
      >
        {@actor_initials}
      </span>
      <span class="gl-audit-row__sentence">{@sentence}</span>
      <span class={["gl-audit-row__actor gl-muted", actor_class(@entry["actor"])]}>
        {@entry["actor"]}
      </span>
      <span class={[
        "gl-audit-row__action gl-muted gl-audit-row__action--raw",
        action_class(@entry["action"])
      ]}>
        {@entry["action"]}
      </span>
      <pre :if={@expanded} class="gl-audit-row__payload"><code>{Jason.encode!(@entry, pretty: true)}</code></pre>
    </div>
    """
  end

  @doc """
  Two-letter initials for an actor slug. `system` → `SY`, `director` → `DI`,
  `ceo` → `CE`. For multi-word slugs (`content-writer`), take the first letter
  of each word: `CW`. Kept in a public helper so other components (Channel,
  Inbox) can reuse.
  """
  def actor_initials(actor) when is_binary(actor) do
    actor
    |> String.split(~r/[-_\s]+/, trim: true)
    |> case do
      [] -> "??"
      [one] -> one |> String.slice(0, 2) |> String.upcase()
      [a, b | _] -> String.upcase(String.first(a) <> String.first(b))
    end
  end

  def actor_initials(_), do: "??"

  @doc """
  Coarse actor classification for avatar colouring.
  `system` | `director` | `agent` — CSS uses these for background tint.
  """
  def actor_kind("system"), do: "system"
  def actor_kind("director"), do: "director"
  def actor_kind("board"), do: "director"
  def actor_kind(_other), do: "agent"

  # Render `<ACTOR> <verb> <OBJECT>` — paperclip-ux-gaps §10. The
  # verb and object phrasing are derived from the audit action;
  # common actions get tailored copy and the fallback degrades
  # gracefully to the raw action name.
  #
  # Status-change entries (agent.complete, task.update, etc.) surface
  # the delta as `from X to Y` when both are present.
  defp to_sentence(%{} = entry) do
    actor = to_string(entry["actor"] || "system")
    action = to_string(entry["action"] || "")
    target = to_string(entry["target"] || "")
    detail = entry["detail"] || %{}

    phrase =
      case action do
        "task.create" -> "created " <> target_label(target)
        "task.comment" -> "commented on " <> target_label(target)
        "task.update" -> describe_update(detail, target_label(target))
        "agent.dispatch" -> "dispatched " <> dispatch_target(entry, detail)
        "agent.complete" -> describe_complete(detail, target_label(target))
        "agent.wake_request" -> "requested wake of " <> target_label(target)
        "message.route" -> "routed a message to " <> target_label(target)
        "message.reject" -> "had a message rejected: " <> target_label(target)
        "approval.granted" -> "approved " <> target_label(target)
        "approval.denied" -> "denied " <> target_label(target)
        "new_company" -> "created company " <> target_label(target)
        "new_agent" -> "created agent " <> target_label(target)
        "new_project" -> "created project " <> target_label(target)
        "" -> "did nothing (empty event)"
        other -> other <> " " <> target_label(target)
      end

    "#{actor} #{phrase}"
  end

  defp target_label(""), do: "(no target)"
  defp target_label(t) when is_binary(t), do: t
  defp target_label(_), do: "(unknown)"

  defp dispatch_target(entry, detail) do
    task = entry["task_path"] || detail["task_path"]
    trigger = detail["trigger"] || entry["trigger"]
    base = if is_binary(task) and task != "", do: task, else: "(no task)"
    if is_binary(trigger) and trigger != "", do: base <> " (" <> trigger <> ")", else: base
  end

  defp describe_complete(%{} = detail, target) do
    exit_s = detail["exit_status"]
    duration = detail["duration_ms"]

    exit_desc =
      cond do
        is_nil(exit_s) -> "finished"
        exit_s in ["0", 0] -> "finished cleanly"
        true -> "finished exit=" <> to_string(exit_s)
      end

    dur_desc = if is_integer(duration), do: " in " <> humanize_ms(duration), else: ""
    exit_desc <> " on " <> target <> dur_desc
  end

  defp describe_complete(_detail, target), do: "finished on " <> target

  defp describe_update(%{"from" => f, "to" => t, "field" => field}, target),
    do: "changed #{field} from #{inspect(f)} to #{inspect(t)} on #{target}"

  defp describe_update(%{"status_from" => f, "status_to" => t}, target),
    do: "changed status from #{f} to #{t} on #{target}"

  defp describe_update(_detail, target), do: "updated " <> target

  defp humanize_ms(ms) when ms < 1_000, do: "#{ms}ms"
  defp humanize_ms(ms) when ms < 60_000, do: "#{div(ms, 1_000)}s"
  defp humanize_ms(ms), do: "#{div(ms, 60_000)}m#{rem(div(ms, 1_000), 60)}s"

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
end
