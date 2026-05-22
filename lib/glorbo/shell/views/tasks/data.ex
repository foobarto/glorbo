defmodule Glorbo.Shell.Views.Tasks.Data do
  @moduledoc """
  GEP-37 Phase 3g — read path for the Tasks view.

  Walks `companies/<co>/projects/*/tasks/*.md` and returns a
  slim row per task. Mirrors the LV `KanbanLive.load_tasks/2`
  + `parse_task_file/4` pipeline (uses `Glorbo.TaskDefinition
  .parse_file/2` for the actual frontmatter parse).

  Each row carries:

    * `:task_id` — task identifier (filename without `.md`).
    * `:project` — parent project slug.
    * `:title` — task title (frontmatter `title:` or task_id).
    * `:status` — frontmatter `status:` or `"todo"`.
    * `:assignee` — frontmatter `assigned_to:` or nil.
    * `:lane` — derived bucket: `:todo | :in_progress |
      :review | :done | :other`. Mirrors the LV's four-lane
      grouping (`group_by_column/1`).
  """

  alias Glorbo.Filesystem.AgentWritableFile
  alias Glorbo.TaskDefinition

  @typedoc "Slim per-task row for the TUI Tasks view."
  @type task_row :: %{
          task_id: String.t(),
          project: String.t(),
          title: String.t(),
          status: String.t(),
          assignee: String.t() | nil,
          lane: :todo | :in_progress | :review | :done | :other
        }

  @lanes [:todo, :in_progress, :review, :done, :other]

  @spec lanes() :: [atom()]
  def lanes, do: @lanes

  @spec lane_label(atom()) :: String.t()
  def lane_label(:todo), do: "TODO"
  def lane_label(:in_progress), do: "IN PROGRESS"
  def lane_label(:review), do: "REVIEW"
  def lane_label(:done), do: "DONE"
  def lane_label(:other), do: "OTHER"

  @doc """
  Single-char status glyph for the Tasks view. Distinguishes the
  four review-lane statuses (pending / pending-approval / approved
  / denied) from each other since they all collapse into the same
  lane bucket. Mirrors the LV's `gl-status--<status>` colour split.
  """
  @spec status_glyph(String.t()) :: String.t()
  def status_glyph("todo"), do: "·"
  def status_glyph("in-progress"), do: "▸"
  def status_glyph("pending"), do: "?"
  def status_glyph("pending-approval"), do: "?"
  def status_glyph("approved"), do: "+"
  def status_glyph("denied"), do: "✗"
  def status_glyph("done"), do: "✓"
  def status_glyph(_), do: "?"

  @spec load_tasks(Path.t(), String.t()) :: [task_row()]
  def load_tasks(base, company) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        projects
        |> Enum.sort()
        |> Enum.flat_map(&load_project(projects_dir, &1, base, company))

      _ ->
        []
    end
  end

  @doc """
  Group rows by lane in canonical order. Empty lanes are
  retained so the view can render their headers (giving the
  Director a "no tasks here yet" signal at a glance).
  """
  @spec group_by_lane([task_row()]) :: [{atom(), [task_row()]}]
  def group_by_lane(rows) do
    grouped = Enum.group_by(rows, & &1.lane)
    Enum.map(@lanes, fn lane -> {lane, Map.get(grouped, lane, [])} end)
  end

  defp load_project(projects_dir, project, base, company) do
    project_dir = Path.join(projects_dir, project)
    tasks_dir = Path.join(project_dir, "tasks")

    # B-007 / C-041: the Tasks view runs in the unsandboxed host
    # (Director) process. An agent with `projects:write:*` can plant
    # `projects/<p>/tasks -> ../../<other-co>/projects/private/tasks`
    # (or a symlinked project dir). `File.ls` follows symlinked
    # ancestors, leaking foreign task metadata into the active-company
    # view. Refuse any project/tasks dir whose path contains a symlink
    # before walking it (mirrors the Kanban LV guard).
    if AgentWritableFile.any_symlink_in_path?(project_dir) or
         AgentWritableFile.any_symlink_in_path?(tasks_dir) do
      []
    else
      walk_tasks_dir(tasks_dir, project, base, company)
    end
  end

  defp walk_tasks_dir(tasks_dir, project, base, company) do
    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.sort()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.flat_map(&parse_task(tasks_dir, &1, project, base, company))

      _ ->
        []
    end
  end

  defp parse_task(tasks_dir, filename, project, base, company) do
    path = Path.join(tasks_dir, filename)

    case TaskDefinition.parse_file(path, base: base, company: company) do
      {:ok, task} ->
        task_id = Path.rootname(filename, ".md")
        status = task.status || "todo"

        [
          %{
            task_id: task_id,
            project: project,
            title: task.title || task_id,
            status: status,
            assignee: task.assigned_to,
            lane: lane_for(status)
          }
        ]

      _ ->
        []
    end
  end

  defp lane_for("todo"), do: :todo
  defp lane_for("in-progress"), do: :in_progress
  defp lane_for("pending"), do: :review
  defp lane_for("pending-approval"), do: :review
  defp lane_for("approved"), do: :review
  defp lane_for("denied"), do: :review
  defp lane_for("done"), do: :done
  defp lane_for(_), do: :other
end
