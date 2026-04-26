defmodule Glorbo.Shell.Views.Overview.Data do
  @moduledoc """
  GEP-37 Phase 3c + 3c-revisit — read path for the Overview view.

  Cross-company snapshot: lists every directory under
  `<base>/companies/` and returns a slim row per workspace.
  Phase 3c shipped FS-only counts; Phase 3c-revisit
  (post-v0.15.0) widens with the LV's per-company total
  spend column (sums each agent's current-month
  `Glorbo.Budget.Ledger` row). The LV's `in_progress_count`
  + `goals_summary` columns are still future work — they
  walk every task file per company which gets expensive at
  many-companies scale; deferred until the read pattern
  stabilises.

  Each row carries:

    * `:slug` — directory name (the canonical company slug).
    * `:name` — `name:` from `company.md` frontmatter, or
      slug if frontmatter is missing / unreadable.
    * `:agent_count` — number of `agents/<slug>/AGENT.md`
      files (case-insensitive `(AGENT|agent).md`).
    * `:alert_count` — number of `alerts/*-budget.md` files.
    * `:spend_cents` — sum of every agent's
      `cost_usd_cents` for the current month (0 when the
      ledger has no rows / Repo isn't connected).
  """

  alias Glorbo.Budget.Ledger
  alias Glorbo.Filesystem.Frontmatter

  @typedoc "Slim cross-company row for the TUI Overview."
  @type overview_row :: %{
          slug: String.t(),
          name: String.t(),
          agent_count: non_neg_integer(),
          alert_count: non_neg_integer(),
          spend_cents: non_neg_integer()
        }

  @doc """
  Load cross-company rows. Opts:

    * `:ledger_fetch_fn` — `(company, agent_slug, year_month)
      -> %Glorbo.Budget{} | nil`. Defaults to the real
      `&Glorbo.Budget.Ledger.fetch/3`. Tests inject a stub.
    * `:year_month` — override the current-month bucket
      (`"YYYY-MM"`). Defaults to
      `Ledger.month_bucket(DateTime.utc_now())`.
  """
  @spec load_companies(Path.t(), keyword()) :: [overview_row()]
  def load_companies(base, opts \\ []) do
    ledger_fetch_fn = Keyword.get(opts, :ledger_fetch_fn, &Ledger.fetch/3)
    year_month = Keyword.get_lazy(opts, :year_month, fn -> Ledger.month_bucket(DateTime.utc_now()) end)
    ctx = %{ledger_fetch_fn: ledger_fetch_fn, year_month: year_month}

    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.flat_map(fn slug ->
          path = Path.join(co_dir, slug)
          if File.dir?(path), do: [load_company(slug, path, ctx)], else: []
        end)

      _ ->
        []
    end
  end

  defp load_company(slug, path, ctx) do
    %{
      slug: slug,
      name: read_company_name(path, slug),
      agent_count: count_agents(path),
      alert_count: count_alerts(path),
      spend_cents: sum_company_spend(slug, path, ctx)
    }
  end

  defp sum_company_spend(company_slug, company_path, ctx) do
    agents_dir = Path.join(company_path, "agents")

    case File.ls(agents_dir) do
      {:ok, agent_slugs} ->
        agent_slugs
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.reduce(0, fn slug, acc -> acc + agent_spend_cents(company_slug, slug, ctx) end)

      _ ->
        0
    end
  end

  defp agent_spend_cents(company_slug, agent_slug, ctx) do
    case ctx.ledger_fetch_fn.(company_slug, agent_slug, ctx.year_month) do
      %{cost_usd_cents: c} when is_integer(c) and c >= 0 -> c
      _ -> 0
    end
  rescue
    _ -> 0
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
