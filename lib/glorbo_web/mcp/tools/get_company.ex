defmodule GlorboWeb.MCP.Tools.GetCompany do
  @moduledoc """
  MCP tool: `glorbo.get_company` (GEP-29 wave b).

  Returns the full `company.md` frontmatter for a single company,
  plus derived counts (agents, projects, proposals). Mirrors the
  information an MCP client would otherwise scrape from
  `CompanyLive`.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Filesystem.Frontmatter
  alias GlorboWeb.MCP.Args

  @impl true
  def name, do: "glorbo.get_company"

  @impl true
  def description,
    do: """
    Return the company.md frontmatter for the given company slug,
    plus counts of agents, projects, and proposals on disk.
    Returns an error result if the company directory does not exist.
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
    co_path = Path.join([base, "companies", company])

    if File.dir?(co_path) do
      {:ok,
       %{
         "slug" => company,
         "frontmatter" => company_frontmatter(co_path),
         "counts" => %{
           "agents" => count_subdirs(Path.join(co_path, "agents")),
           "projects" => count_subdirs(Path.join(co_path, "projects")),
           "proposals" => count_md_files(Path.join(co_path, "proposals"))
         }
       }}
    else
      {:error, {:company_not_found, company}}
    end
  end

  defp company_frontmatter(co_path) do
    case File.read(Path.join(co_path, "company.md")) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _body} -> meta
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp count_subdirs(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.count(entries, &File.dir?(Path.join(dir, &1)))
      _ -> 0
    end
  end

  defp count_md_files(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.count(entries, &String.ends_with?(&1, ".md"))
      _ -> 0
    end
  end
end
