defmodule GlorboWeb.MCP.Tools.GetAgent do
  @moduledoc """
  MCP tool: `glorbo.get_agent` (GEP-29 wave b).

  Returns a single agent's parsed AGENT.md (full spec — role,
  provider, model, network, budget, heartbeat, permissions, etc.).
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Agent.FileLayout
  alias Glorbo.Agent.Parser, as: AgentParser
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.get_agent"

  @impl true
  def description,
    do: """
    Fetch the full AGENT.md spec for the given agent in the given
    company. Returns the parsed frontmatter as structured fields.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string", "description" => "Company slug"},
        "agent" => %{"type" => "string", "description" => "Agent slug"}
      },
      "required" => ["company", "agent"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "agent" => agent}, context)
      when is_binary(company) and is_binary(agent) do
    with :ok <- Args.require_slugs(company: company, agent: agent) do
      do_call(company, agent, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, agent, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    agent_dir = Path.join([base, "companies", company, "agents", agent])
    path = FileLayout.agent_md(agent_dir)

    case AgentParser.parse_file(path) do
      {:ok, spec} ->
        {:ok,
         %{
           "slug" => spec.slug,
           "company" => spec.company,
           "role" => spec.role,
           "reports_to" => spec.reports_to,
           "provider" => spec.provider,
           "model" => spec.model,
           "network" => network_to_wire(spec.network),
           "heartbeat" => spec.heartbeat,
           "budget_usd_cents_month" => spec.budget_usd_cents_month,
           "allow_untracked_budget" => spec.allow_untracked_budget,
           "autonomy" => to_string(spec.autonomy),
           "skills" => spec.skills,
           "permissions" => permission_strings(spec.permissions)
         }}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp permission_strings(perms) when is_list(perms) do
    Enum.map(perms, fn
      {r, a, s} -> "#{r}:#{a}:#{s}"
      other -> inspect(other)
    end)
  end

  defp permission_strings(_), do: []

  # Agent.Spec's network is parsed as an atom with underscores
  # (`:proxy`). The on-disk canonical form uses hyphens
  # (`proxy`); MCP clients expect the hyphen form.
  defp network_to_wire(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.replace("_", "-")
  end

  defp network_to_wire(other), do: to_string(other)
end
