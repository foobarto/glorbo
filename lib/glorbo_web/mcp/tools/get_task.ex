defmodule GlorboWeb.MCP.Tools.GetTask do
  @moduledoc """
  MCP tool: `glorbo.get_task` (GEP-29 wave b).

  Returns the full parsed task file for a given project + task id,
  including the markdown body (agent prompt).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.TaskDefinition
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.get_task"

  @impl true
  def description,
    do: """
    Fetch the full task definition — frontmatter fields plus the
    markdown body (agent prompt). Use glorbo.list_tasks to discover
    task ids first.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "project" => %{"type" => "string"},
        "task_id" => %{"type" => "string"}
      },
      "required" => ["company", "project", "task_id"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => co, "project" => project, "task_id" => task_id}, context)
      when is_binary(co) and is_binary(project) and is_binary(task_id) do
    with :ok <- Args.require_slugs(company: co, project: project, task_id: task_id) do
      do_call(co, project, task_id, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(co, project, task_id, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()

    file_path =
      Path.join([base, "companies", co, "projects", project, "tasks", "#{task_id}.md"])

    if File.exists?(file_path) do
      case TaskDefinition.parse_file(file_path, base: base, company: co) do
        {:ok, task} -> {:ok, to_map(task)}
        {:error, reason} -> {:error, {:parse_failed, reason}}
      end
    else
      {:error, {:task_not_found, task_id}}
    end
  end

  defp to_map(task) do
    %{
      "task_id" => task.task_id,
      "task_path" => task.task_path,
      "title" => task.title,
      "status" => task.status,
      "assigned_to" => task.assigned_to,
      "requires_approval" => task.requires_approval && to_string(task.requires_approval),
      "denial_reason" => task.denial_reason,
      "priority" => task.priority && to_string(task.priority),
      "severity" => task.severity && to_string(task.severity),
      "project" => task.project,
      "goal" => task.goal,
      "model" => task.model,
      "provider" => task.provider,
      "schedule" => task.schedule,
      "budget_usd_cents" => task.budget_usd_cents,
      "body" => task.prompt_body
    }
  end
end
