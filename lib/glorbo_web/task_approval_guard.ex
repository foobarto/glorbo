defmodule GlorboWeb.TaskApprovalGuard do
  @moduledoc """
  Shared application-layer approval-gate guards for the two task editors —
  `KanbanLive`'s shelf and `TaskLive`'s detail page. Both write task
  frontmatter via the same shared `TaskDetailForm`, so both MUST refuse the
  status flips / `requires_approval` clears that would bypass the director
  approval workflow (GEP-19).

  Extracted from `KanbanLive` so the two `save_task` paths cannot drift:
  `TaskLive.save_task` previously lacked these checks entirely (the
  kernel-layer `Glorbo.Approvals.Gate` watcher still reverted an
  unauthorised flip, but the two-layer-enforcement invariant — every
  permission enforced at BOTH the Elixir layer AND the watcher/kernel layer
  — wants the application layer to refuse up front too).
  """

  alias Glorbo.Filesystem.Frontmatter

  @doc """
  Refuse a move/edit that would push an approval-gated task to `done` or
  `in-progress` without it first being `approved`. A task carrying
  `requires_approval: director` must go through the Inbox approval flow;
  it may not skip the gate by being dragged (Kanban) or saved (Task page)
  straight past it. Statuses other than `done`/`in-progress` are unaffected.
  """
  @spec refuse_if_bypasses_approval_gate(Path.t(), String.t() | nil) ::
          :ok | {:error, :approval_gate_bypass}
  def refuse_if_bypasses_approval_gate(abs_path, target_status)
      when target_status in ["done", "in-progress"] do
    case File.read(abs_path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, fm, _body} ->
            requires? = to_string(Map.get(fm, "requires_approval", "")) == "director"
            current_status = to_string(Map.get(fm, "status", ""))
            approved? = current_status == "approved"

            # A save that does NOT change the status is a title/body edit, not a
            # transition into the gated status — never a bypass. This matters
            # because `set_approval/4` leaves `requires_approval: director` in
            # place after approving, so a task can validly sit at
            # `requires_approval: director` + `status: in-progress`/`done` once
            # it has moved past approval; re-saving it (e.g. to edit the title
            # or body) must not be rejected. Only an actual transition INTO
            # done/in-progress from a still-gated, not-yet-approved task is a
            # bypass attempt.
            no_transition? = current_status == target_status

            if requires? and not approved? and not no_transition? do
              {:error, :approval_gate_bypass}
            else
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  def refuse_if_bypasses_approval_gate(_abs, _status), do: :ok

  @doc """
  Refuse clearing `requires_approval` on a task that is currently awaiting
  approval — removing the gate is itself a bypass. Fires only when the
  caller asserts an EXPLICIT clear attempt (the form carried the field with
  an empty value); partial submissions where the field was absent entirely
  are preserved upstream and must pass `false` here.
  """
  @spec refuse_if_clears_required_approval(Path.t(), boolean()) ::
          :ok | {:error, :clears_required_approval}
  def refuse_if_clears_required_approval(abs_path, true),
    do: refuse_if_currently_required(abs_path)

  def refuse_if_clears_required_approval(_abs, false), do: :ok

  defp refuse_if_currently_required(abs_path) do
    case File.read(abs_path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, fm, _body} ->
            currently_required? =
              to_string(Map.get(fm, "requires_approval", "")) == "director"

            currently_approved? =
              to_string(Map.get(fm, "status", "")) == "approved"

            if currently_required? and not currently_approved? do
              {:error, :clears_required_approval}
            else
              :ok
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
