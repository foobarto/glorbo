defmodule Glorbo.Shell.Views.Agents.Data do
  @moduledoc """
  GEP-37 Phase 3d + 3d-revisit — read path for the Agents view.

  Walks `<base>/companies/<co>/agents/*/AGENT.md` (or legacy
  `agent.md`) and returns a slim row per agent. Phase 3d-revisit
  (post-v0.15.0) widens the row with the LV's two budget
  columns — `budget_used_cents` (this month's spend, from
  `Glorbo.Budget.Ledger.fetch/3`) and `budget_cap_cents` (the
  agent's `budget.monthly_usd` declaration, converted to
  cents). Tests can inject a `:ledger_fetch_fn` that bypasses
  the Repo. The remaining LV-side columns (last-wake, pill
  status) ship later.

  Each row carries:

    * `:slug` — agent dir name.
    * `:name` — `name:` from frontmatter, falls back to slug.
    * `:role` — `role:` from frontmatter, falls back to `"—"`.
    * `:provider` — `provider:` from frontmatter or `"—"`.
    * `:model` — `model:` from frontmatter or empty string.
    * `:network` — `network:` from frontmatter, defaults to
      `"loopback"` matching the LV's behaviour.
    * `:reports_to` — `reports_to:` from frontmatter or nil.
    * `:budget_used_cents` — non-negative integer, current
      month's spend in cents (0 when the ledger has no row).
    * `:budget_cap_cents` — non-negative integer or nil
      (nil = no cap declared / unlimited).
  """

  alias Glorbo.Budget.Ledger
  alias Glorbo.Filesystem.Frontmatter

  @typedoc "Slim per-agent row for the TUI Agents view."
  @type agent_row :: %{
          slug: String.t(),
          name: String.t(),
          role: String.t(),
          provider: String.t(),
          model: String.t(),
          network: String.t(),
          reports_to: String.t() | nil,
          budget_used_cents: non_neg_integer(),
          budget_cap_cents: non_neg_integer() | nil
        }

  @doc """
  Load per-agent rows for the company. Opts:

    * `:ledger_fetch_fn` — `(company, agent_slug, year_month)
      -> %Glorbo.Budget{} | nil`. Defaults to the real
      `&Glorbo.Budget.Ledger.fetch/3`. Tests pass a stub that
      bypasses the Repo.
    * `:year_month` — override the current-month bucket
      (`"YYYY-MM"`) used for the spend lookup. Defaults to
      `Ledger.month_bucket(DateTime.utc_now())`.
  """
  @spec load_agents(Path.t(), String.t(), keyword()) :: [agent_row()]
  def load_agents(base, company, opts \\ []) do
    ledger_fetch_fn = Keyword.get(opts, :ledger_fetch_fn, &Ledger.fetch/3)
    year_month = Keyword.get_lazy(opts, :year_month, fn -> Ledger.month_bucket(DateTime.utc_now()) end)
    ctx = %{ledger_fetch_fn: ledger_fetch_fn, year_month: year_month, company: company}

    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(fn slug ->
          # Hide `.archive/` and other dotfiles — retired agents
          # live elsewhere.
          not String.starts_with?(slug, ".") and File.dir?(Path.join(agents_dir, slug))
        end)
        |> Enum.flat_map(&load_agent(agents_dir, &1, ctx))

      _ ->
        []
    end
  end

  defp load_agent(agents_dir, slug, ctx) do
    agent_path = Path.join(agents_dir, slug)

    case read_agent_md(agent_path) do
      nil ->
        # Hide agents whose AGENT.md is missing entirely — they're
        # not bootable. The LV behaves the same way.
        []

      meta ->
        [
          %{
            slug: slug,
            name: meta["name"] || slug,
            role: meta["role"] || "—",
            provider: meta["provider"] || "—",
            model: meta["model"] || "",
            network: meta["network"] || "loopback",
            reports_to: meta["reports_to"],
            budget_used_cents: fetch_budget_used(ctx, slug),
            budget_cap_cents: extract_budget_cap_cents(meta)
          }
        ]
    end
  end

  defp fetch_budget_used(ctx, agent_slug) do
    case ctx.ledger_fetch_fn.(ctx.company, agent_slug, ctx.year_month) do
      nil -> 0
      %{cost_usd_cents: c} when is_integer(c) and c >= 0 -> c
      _ -> 0
    end
  rescue
    # Ledger reads can fail when the Repo isn't connected (e.g.
    # `glorbo shell` boot before DB starts on a recovery path).
    # Fail open with 0 so the view still renders.
    _ -> 0
  end

  defp extract_budget_cap_cents(meta) do
    case meta["budget"] do
      %{"monthly_usd" => usd} -> normalise_cap_cents(usd)
      _ -> nil
    end
  end

  defp normalise_cap_cents(usd) when is_integer(usd) and usd >= 0, do: usd * 100
  defp normalise_cap_cents(usd) when is_float(usd) and usd >= 0, do: round(usd * 100)

  defp normalise_cap_cents(usd) when is_binary(usd) do
    case Float.parse(usd) do
      {f, _} when f >= 0 -> round(f * 100)
      _ -> nil
    end
  end

  defp normalise_cap_cents(_), do: nil

  defp read_agent_md(agent_path) do
    # AGENT.md is canonical; agent.md is the legacy lowercase form
    # still tolerated per the wave-30-era reindex pattern.
    paths = [Path.join(agent_path, "AGENT.md"), Path.join(agent_path, "agent.md")]

    case Enum.find_value(paths, &maybe_read_md/1) do
      nil -> nil
      {:ok, meta} -> meta
    end
  end

  defp maybe_read_md(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Frontmatter.parse(content) do
      {:ok, meta}
    else
      _ -> nil
    end
  end
end
