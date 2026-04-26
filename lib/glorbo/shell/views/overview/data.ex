defmodule Glorbo.Shell.Views.Overview.Data do
  @moduledoc """
  GEP-37 Phase 3c — read path for the Overview view.

  Cross-company snapshot: lists every directory under
  `<base>/companies/` and returns a slim row per workspace.
  Phase 3c carries lightweight FS-only counts (no SQL); Phase
  3d adds spend / in-progress task counts that need the
  Repo-backed projections.

  Each row carries:

    * `:slug` — directory name (the canonical company slug).
    * `:name` — `name:` from `company.md` frontmatter, or
      slug if frontmatter is missing / unreadable.
    * `:agent_count` — number of `agents/<slug>/AGENT.md`
      files (case-insensitive `(AGENT|agent).md`).
    * `:alert_count` — number of `alerts/*-budget.md` files.
  """

  alias Glorbo.Filesystem.Frontmatter

  @typedoc "Slim cross-company row for the TUI Overview."
  @type overview_row :: %{
          slug: String.t(),
          name: String.t(),
          agent_count: non_neg_integer(),
          alert_count: non_neg_integer()
        }

  @spec load_companies(Path.t()) :: [overview_row()]
  def load_companies(base) do
    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.flat_map(fn slug ->
          path = Path.join(co_dir, slug)
          if File.dir?(path), do: [load_company(base, slug, path)], else: []
        end)

      _ ->
        []
    end
  end

  defp load_company(_base, slug, path) do
    %{
      slug: slug,
      name: read_company_name(path, slug),
      agent_count: count_agents(path),
      alert_count: count_alerts(path)
    }
  end

  defp read_company_name(path, slug) do
    company_md = Path.join(path, "company.md")

    with true <- File.regular?(company_md),
         {:ok, content} <- File.read(company_md),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         name when is_binary(name) and name != "" <- meta["name"] do
      name
    else
      _ -> slug
    end
  end

  defp count_agents(path) do
    path
    |> Path.join("agents/*/[Aa][Gg][Ee][Nn][Tt].md")
    |> Path.wildcard()
    |> length()
  end

  defp count_alerts(path) do
    path
    |> Path.join("alerts/*-budget.md")
    |> Path.wildcard()
    |> length()
  end
end
