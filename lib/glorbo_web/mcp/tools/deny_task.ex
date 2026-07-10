defmodule GlorboWeb.MCP.Tools.DenyTask do
  @moduledoc """
  MCP tool: `glorbo.deny_task` (GEP-29 wave c.1).

  Denies a task awaiting Director review (GEP-19) with a required
  `denial_reason`. Calls `Glorbo.Actions.set_approval/4` so
  behaviour matches the LiveView Deny button exactly. Actor is
  `mcp:<client>` (GEP-29 D4).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.deny_task"

  @impl true
  def description,
    do: """
    Deny a task awaiting Director review. Writes status=denied and
    the provided denial_reason to the task frontmatter, then emits
    approval.denied on the audit log with actor=mcp:<client>.
    denial_reason is required and must be non-empty.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "project" => %{"type" => "string"},
        "task_id" => %{"type" => "string"},
        "denial_reason" => %{"type" => "string"}
      },
      "required" => ["company", "project", "task_id", "denial_reason"],
      "additionalProperties" => false
    }

  @impl true
  def call(
        %{
          "company" => company,
          "project" => project,
          "task_id" => task_id,
          "denial_reason" => reason
        },
        context
      )
      when is_binary(company) and is_binary(project) and is_binary(task_id) and
             is_binary(reason) do
    with :ok <- Args.require_slugs(company: company, project: project, task_id: task_id),
         :ok <- require_nonempty(reason) do
      do_call(company, project, task_id, reason, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, project, task_id, reason, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    task_path = "projects/#{project}/tasks/#{task_id}.md"
    actor = mcp_actor(context)

    opts =
      Keyword.merge(
        [base: base, actor: actor, denial_reason: reason],
        audit_opt(context)
      )

    case Actions.set_approval(company, task_path, :denied, opts) do
      :ok ->
        {:ok,
         %{
           "task_path" => task_path,
           "status" => "denied",
           "actor" => actor,
           "denial_reason" => reason
         }}

      {:error, err} ->
        {:error, {:denial_failed, err}}
    end
  end

  defp require_nonempty(s) when is_binary(s) do
    if String.trim(s) == "", do: {:error, :empty_denial_reason}, else: :ok
  end

  defp mcp_actor(context) do
    client = Map.get(context, :client, "unknown")
    "mcp:#{client}"
  end

  defp audit_opt(%{audit: audit}) when not is_nil(audit), do: [audit: audit]
  defp audit_opt(_), do: []
end
