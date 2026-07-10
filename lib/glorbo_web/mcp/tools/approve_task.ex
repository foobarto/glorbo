defmodule GlorboWeb.MCP.Tools.ApproveTask do
  @moduledoc """
  MCP tool: `glorbo.approve_task` (GEP-29 wave c.1).

  Approves a task currently in `status: pending-approval` (GEP-19).
  Calls the same `Glorbo.Actions.set_approval/4` function the
  LiveView Approve button uses, so the audit shape, `assigned_to`
  restoration, and scaffold-on-approve side effects stay identical.
  Actor on the audit entry is `mcp:<client>` (GEP-29 D4).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.approve_task"

  @impl true
  def description,
    do: """
    Approve a task awaiting Director review. Mirrors the LiveView
    Approve button: updates frontmatter status to "approved",
    restores assigned_to to the requesting agent, and emits
    approval.approved on the audit log with actor=mcp:<client>.
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
  def call(
        %{"company" => company, "project" => project, "task_id" => task_id},
        context
      )
      when is_binary(company) and is_binary(project) and is_binary(task_id) do
    with :ok <- Args.require_slugs(company: company, project: project, task_id: task_id) do
      do_call(company, project, task_id, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, project, task_id, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    task_path = "projects/#{project}/tasks/#{task_id}.md"
    actor = mcp_actor(context)

    opts = Keyword.merge([base: base, actor: actor], audit_opt(context))

    case Actions.set_approval(company, task_path, :approved, opts) do
      :ok ->
        {:ok, %{"task_path" => task_path, "status" => "approved", "actor" => actor}}

      {:error, reason} ->
        {:error, {:approval_failed, reason}}
    end
  end

  defp mcp_actor(context) do
    client = Map.get(context, :client, "unknown")
    "mcp:#{client}"
  end

  defp audit_opt(%{audit: audit}) when not is_nil(audit), do: [audit: audit]
  defp audit_opt(_), do: []
end
