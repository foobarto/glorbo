defmodule GlorboWeb.MCP.Tools.ListTasks do
  @moduledoc """
  MCP tool: `glorbo.list_tasks` (GEP-29 wave b).

  Returns all task files under `companies/<co>/projects/*/tasks/`,
  optionally filtered by project, status, or assignee.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.TaskDefinition
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.list_tasks"

  @impl true
  def description,
    do: """
    List tasks in the given company. Optional filters narrow by
    project (slug), status (e.g. todo / in-progress / done), or
    assigned_to (agent slug). Every task is returned as a minimal
    summary: id, title, status, project, assigned_to, priority.
    Use glorbo.get_task to fetch the full body.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "project" => %{"type" => ["string", "null"]},
        "status" => %{"type" => ["string", "null"]},
        "assigned_to" => %{"type" => ["string", "null"]}
      },
      "required" => ["company"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company} = args, context) when is_binary(company) do
    project_filter = nilify(args["project"])
    status_filter = nilify(args["status"])
    assigned_filter = nilify(args["assigned_to"])

    # Validate every slug that will land in a filesystem path or a
    # wildcard pattern. Filters are optional; when set they get the
    # same gate as the company arg. (list_tasks is especially
    # dangerous if unsanitized because "company" flows into
    # Path.wildcard/1.)
    slugs =
      [{:company, company}]
      |> append_if_present(:project, project_filter)
      |> append_if_present(:assigned_to, assigned_filter)

    with :ok <- Args.require_slugs(slugs) do
      do_call(company, project_filter, status_filter, assigned_filter, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_company_arg}

  defp do_call(company, project_filter, status_filter, assigned_filter, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    projects_dir = Path.join([base, "companies", company, "projects"])

    tasks =
      projects_dir
      |> Path.join("*/tasks/*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&parse_task(&1, base, company))
      |> Enum.reject(&is_nil/1)
      |> apply_filters(project_filter, status_filter, assigned_filter)
      |> Enum.map(&summarize/1)

    {:ok, %{"tasks" => tasks}}
  end

  defp append_if_present(list, _field, nil), do: list
  defp append_if_present(list, field, value), do: list ++ [{field, value}]

  defp parse_task(file_path, base, company) do
    case TaskDefinition.parse_file(file_path, base: base, company: company) do
      {:ok, task} -> task
      _ -> nil
    end
  end

  defp apply_filters(tasks, project, status, assigned) do
    tasks
    |> filter_by(project, & &1.project)
    |> filter_by(status, & &1.status)
    |> filter_by(assigned, & &1.assigned_to)
  end

  defp filter_by(tasks, nil, _), do: tasks
  defp filter_by(tasks, value, getter), do: Enum.filter(tasks, &(getter.(&1) == value))

  defp summarize(task) do
    %{
      "task_id" => task.task_id,
      "title" => task.title,
      "status" => task.status,
      "project" => task.project,
      "assigned_to" => task.assigned_to,
      "priority" => task.priority && to_string(task.priority),
      "requires_approval" => task.requires_approval && to_string(task.requires_approval)
    }
  end

  defp nilify(""), do: nil
  defp nilify(nil), do: nil
  defp nilify(v) when is_binary(v), do: v
  defp nilify(_), do: nil
end
