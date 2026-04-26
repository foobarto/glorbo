defmodule Glorbo.Shell.Views.Inbox.Data do
  @moduledoc """
  GEP-37 Phase 2 — read path for the Inbox view.

  Loads the per-agent `state/awaiting-approval-*.md` sentinels under
  the given company and returns a slim row shape suitable for the
  TUI's list view. Mirrors `Glorbo.GlorboWeb.InboxLive.load_sentinels/2`
  + `sentinel_row/4` — kept as a separate module here because the
  LV-side helpers are `defp` and the duplication is small. Phase 2b
  will lift them to a shared `Glorbo.Inbox.Approvals` module that
  both consumers use.

  Each row carries:

    * `:task_id` — string, derived from the sentinel filename
      (`awaiting-approval-<id>.md`).
    * `:task_path` — relative path under the company dir; nil when
      the task file no longer exists.
    * `:title` — the task's `title:` frontmatter or the task_id as
      fallback.
    * `:assignee` — the task's `assigned_to:` or nil.
  """

  alias Glorbo.TaskDefinition

  @state_glob "agents/*/state/awaiting-approval-*.md"

  @typedoc "Slim row used by the TUI Inbox view."
  @type approval_row :: %{
          task_id: String.t(),
          task_path: String.t() | nil,
          title: String.t(),
          assignee: String.t() | nil
        }

  @spec load_approvals(Path.t(), String.t()) :: [approval_row()]
  def load_approvals(base, company) do
    co_dir = Path.join([base, "companies", company])

    co_dir
    |> Path.join(@state_glob)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&sentinel_row(&1, co_dir, base, company))
    |> Enum.reject(&is_nil/1)
  end

  defp sentinel_row(sentinel_path, co_dir, base, company) do
    filename = Path.basename(sentinel_path, ".md")

    case String.split(filename, "awaiting-approval-", parts: 2) do
      [_, task_id] when task_id != "" ->
        task_path =
          co_dir
          |> Path.join("projects/**/tasks/#{task_id}.md")
          |> Path.wildcard()
          |> List.first()

        if is_nil(task_path) do
          # Sentinel without a matching task — surface it anyway with
          # a nil task_path so the Director can clear the dangling
          # sentinel via the TUI once Phase 2b adds actions.
          %{task_id: task_id, task_path: nil, title: task_id, assignee: nil}
        else
          rel = Path.relative_to(task_path, co_dir)

          case TaskDefinition.parse_file(task_path, base: base, company: company) do
            {:ok, task} ->
              %{
                task_id: task_id,
                task_path: rel,
                title: task.title || task_id,
                assignee: task.assigned_to
              }

            _ ->
              %{task_id: task_id, task_path: rel, title: task_id, assignee: nil}
          end
        end

      _ ->
        nil
    end
  end
end
