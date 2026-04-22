defmodule GlorboWeb.MCP.Tools.ListCompanies do
  @moduledoc """
  MCP tool: `glorbo.list_companies` (GEP-29 wave a).

  Enumerates companies under `<base>/companies/` and returns slug,
  display name, and headcount budget per entry. Mirrors the data
  `OverviewLive.load_companies/0` uses for the dashboard — no SQLite
  round-trip, filesystem-as-source-of-truth.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias Glorbo.Filesystem.Frontmatter

  @impl true
  def name, do: "glorbo.list_companies"

  @impl true
  def description,
    do: """
    List all companies on this Glorbo instance. Returns one entry per
    subdirectory of ~/.glorbo/companies/ with basic metadata parsed
    from the company.md frontmatter.
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{},
      "additionalProperties" => false
    }

  @impl true
  def call(_args, context) do
    base = Map.get(context, :base, default_base())
    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        companies =
          slugs
          |> Enum.sort()
          |> Enum.map(&load(base, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, %{"companies" => companies}}

      {:error, :enoent} ->
        {:ok, %{"companies" => []}}

      {:error, reason} ->
        {:error, {:ls_failed, reason}}
    end
  end

  defp default_base do
    Glorbo.Filesystem.Hierarchy.default_root()
  end

  defp load(base, slug) do
    path = Path.join([base, "companies", slug])

    if File.dir?(path) do
      meta = parse_company_md(path)

      %{
        "slug" => slug,
        "name" => Map.get(meta, "name", slug),
        "headcount_budget" => Map.get(meta, "headcount_budget")
      }
    end
  end

  defp parse_company_md(path) do
    case File.read(Path.join(path, "company.md")) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _body} -> meta
          _ -> %{}
        end

      _ ->
        %{}
    end
  end
end
