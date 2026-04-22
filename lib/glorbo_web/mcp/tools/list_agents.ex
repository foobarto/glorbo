defmodule GlorboWeb.MCP.Tools.ListAgents do
  @moduledoc """
  MCP tool: `glorbo.list_agents` (GEP-29 wave b).

  Enumerates agent directories under `companies/<co>/agents/` and
  returns the parsed AGENT.md summary for each.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Agent.FileLayout
  alias Glorbo.Agent.Parser, as: AgentParser
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.list_agents"

  @impl true
  def description,
    do: """
    List all agents in the given company. Each entry carries slug,
    role, provider, model, network policy, reports_to, and a list of
    permission strings parsed from AGENT.md frontmatter. Malformed
    or unparseable AGENT.md files are included with their slug and
    an `error` field.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string", "description" => "Company slug"}
      },
      "required" => ["company"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company}, context) when is_binary(company) do
    with :ok <- Args.require_slug(company, :company) do
      do_call(company, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_company_arg}

  defp do_call(company, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, entries} ->
        agents =
          entries
          |> Enum.sort()
          |> Enum.map(&build_entry(agents_dir, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, %{"agents" => agents}}

      {:error, :enoent} ->
        {:ok, %{"agents" => []}}

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp build_entry(agents_dir, slug) do
    agent_dir = Path.join(agents_dir, slug)

    if File.dir?(agent_dir) do
      parse_entry(agent_dir, slug)
    end
  end

  defp parse_entry(agent_dir, slug) do
    path = FileLayout.agent_md(agent_dir)

    case AgentParser.parse_file(path) do
      {:ok, spec} ->
        %{
          "slug" => spec.slug,
          "role" => spec.role,
          "provider" => spec.provider,
          "model" => spec.model,
          "network" => network_to_wire(spec.network),
          "reports_to" => spec.reports_to,
          "permissions" => permission_strings(spec.permissions)
        }

      {:error, reason} ->
        %{"slug" => slug, "error" => inspect(reason)}
    end
  end

  defp permission_strings(perms) when is_list(perms) do
    Enum.map(perms, fn
      {r, a, s} -> "#{r}:#{a}:#{s}"
      other -> inspect(other)
    end)
  end

  defp permission_strings(_), do: []

  # Agent.Spec parses `network` as an atom with underscores; convert
  # back to the canonical hyphen-cased wire form for MCP clients.
  defp network_to_wire(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.replace("_", "-")
  end

  defp network_to_wire(other), do: to_string(other)
end
