defmodule GlorboWeb.TaskUpdateError do
  @moduledoc false

  @spec message(term()) :: String.t()
  def message(:approval_gate_bypass),
    do:
      "This task requires director approval — approve it via the Inbox before changing status to done."

  def message(:approval_status_requires_gate),
    do: "Approve or deny this task through the Inbox approval flow."

  def message(:clears_required_approval),
    do: "Cannot clear `requires_approval` on a task currently awaiting director approval."

  def message(:agent_not_found), do: "The selected assignee does not exist."
  def message({:invalid_slug, :agent, _}), do: "The selected assignee is invalid."
  def message(:invalid_title), do: "Task title must be between 1 and 200 bytes."
  def message(_reason), do: "Could not save task."
end
