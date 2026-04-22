defmodule GlorboWeb.MCP.Tools.GetProposal do
  @moduledoc """
  MCP tool: `glorbo.get_proposal` (GEP-29 wave b.2).

  Returns one proposal's full frontmatter + markdown body. Complement
  to `glorbo.list_proposals`.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Filesystem.Frontmatter
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.get_proposal"

  @impl true
  def description,
    do: """
    Fetch one GEP-28 proposal by id. Returns full frontmatter
    (subtype, status, proposed_by, approved_by, etc.) plus the
    markdown body. Use glorbo.list_proposals to discover ids first.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "id" => %{"type" => "string", "description" => "Proposal id (filename stem)"}
      },
      "required" => ["company", "id"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company, "id" => id}, context)
      when is_binary(company) and is_binary(id) do
    with :ok <- Args.require_slugs(company: company, id: id) do
      do_call(company, id, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_args}

  defp do_call(company, id, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    path = Path.join([base, "companies", company, "proposals", "#{id}.md"])

    case File.read(path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, body} ->
            {:ok,
             %{
               "id" => Map.get(meta, "id", id),
               "frontmatter" => meta,
               "body" => body
             }}

          {:error, reason} ->
            {:error, {:malformed_frontmatter, reason}}
        end

      {:error, :enoent} ->
        {:error, {:proposal_not_found, id}}

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end
end
