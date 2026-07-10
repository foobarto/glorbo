defmodule GlorboWeb.MCP.Tools.ForceAgentHeartbeat do
  @moduledoc """
  MCP tool: `glorbo.force_agent_heartbeat` (GEP-29 wave c.2).

  Drops a wake-request sentinel for the target agent, triggering its
  next dispatch as if the scheduler had fired. Wraps
  `Glorbo.Actions.wake_agent/4` (same code path as the AgentLive
  "Wake now" button).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Actions
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.force_agent_heartbeat"

  @impl true
  def description,
    do: """
    Force a heartbeat on the given agent — writes a wake-request
    sentinel that the Agent.Server picks up and runs like any other
    scheduled wake. Use after posting a task the agent should pick
    up immediately.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "agent" => %{"type" => "string"},
        "reason" => %{
          "type" => ["string", "null"],
          "description" => "Human-readable reason logged on the audit entry"
        }
      },
      "required" => ["company", "agent"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "agent" => agent} = args, context)
      when is_binary(company) and is_binary(agent) do
    with :ok <- Args.require_slugs(company: company, agent: agent) do
      do_call(company, agent, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, agent, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    reason = args["reason"] || "mcp heartbeat"
    actor = mcp_actor(context)

    opts = Keyword.merge([base: base, actor: actor], audit_opt(context))

    case Actions.wake_agent(company, agent, reason, opts) do
      :ok ->
        {:ok, %{"agent" => agent, "reason" => reason, "actor" => actor}}

      {:error, err} ->
        {:error, {:wake_failed, err}}
    end
  end

  defp mcp_actor(context) do
    client = Map.get(context, :client, "unknown")
    "mcp:#{client}"
  end

  defp audit_opt(%{audit: audit}) when not is_nil(audit), do: [audit: audit]
  defp audit_opt(_), do: []
end
