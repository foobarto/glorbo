defmodule Glorbo.Budget.CompanyCap do
  @moduledoc """
  Company-level monthly budget cap (#245).

  Complements the per-agent cap (AGENT.md `budget_usd_cents_month`):
  an AGENT-level cap protects one agent from runaway; a company-
  level cap protects the whole org when many small agents add up.

  Source of truth: `company.md` frontmatter key
  `budget_usd_cents_month:`. Missing / nil → no cap (unlimited,
  same default as per-agent).

  Sum comparison is over all rows in `Glorbo.Budget` whose
  `agent_slug` appears in the company's agents directory for the
  current `year_month`. This is O(agents + rows-this-month), so
  cheap enough to run on every dispatch pre-check without caching.

  Usage:

      CompanyCap.check(company, base: base) ->
        :ok                     # under cap or no cap configured
        | {:stop, used, cap}    # at or over cap — refuse dispatch
        | {:alert, used, cap}   # over 80% of cap — warning only
  """

  alias Glorbo.Budget
  alias Glorbo.Budget.Ledger
  alias Glorbo.Repo

  @alert_threshold_pct 80

  @type result ::
          :ok
          | {:alert, non_neg_integer(), non_neg_integer()}
          | {:stop, non_neg_integer(), non_neg_integer()}

  @doc """
  Check the company cap. Returns `:ok` when under cap or no cap is
  set, `{:alert, used, cap}` when over the warning threshold but
  still under, or `{:stop, used, cap}` when at or over cap.
  """
  @spec check(String.t(), keyword()) :: result()
  def check(company, opts \\ []) when is_binary(company) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())

    case read_cap(base, company) do
      nil ->
        :ok

      cap_cents when is_integer(cap_cents) ->
        used = used_this_month(base, company)
        classify(used, cap_cents)
    end
  end

  @doc """
  Read the current month's used cents for `company` without the
  cap logic — useful for UI display.
  """
  @spec used_this_month(Path.t(), String.t()) :: non_neg_integer()
  def used_this_month(base, company) do
    slugs = list_agent_slugs(base, company)
    month = Ledger.month_bucket(DateTime.utc_now())
    sum_rows(slugs, month)
  end

  @doc """
  Read the configured cap from `company.md`. Returns `nil` when
  the file or the key is missing, or the value is unparseable.
  """
  @spec read_cap(Path.t(), String.t()) :: non_neg_integer() | nil
  def read_cap(base, company) do
    path = Path.join([base, "companies", company, "company.md"])

    with {:ok, content} <- File.read(path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      parse_cap(Map.get(fm, "budget_usd_cents_month"))
    else
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp classify(used, cap) when used >= cap, do: {:stop, used, cap}

  defp classify(used, cap) do
    if used * 100 >= cap * @alert_threshold_pct do
      {:alert, used, cap}
    else
      :ok
    end
  end

  defp list_agent_slugs(base, company) do
    dir = Path.join([base, "companies", company, "agents"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))

      _ ->
        []
    end
  end

  defp sum_rows(slugs, month) when is_list(slugs) do
    import Ecto.Query

    Budget
    |> where([b], b.year_month == ^month and b.agent_slug in ^slugs)
    |> select([b], sum(b.cost_usd_cents))
    |> Repo.one()
    |> case do
      nil -> 0
      n when is_integer(n) -> n
    end
  rescue
    _ -> 0
  end

  defp parse_cap(nil), do: nil
  defp parse_cap(""), do: nil
  defp parse_cap(n) when is_integer(n) and n >= 0, do: n

  defp parse_cap(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_cap(_), do: nil
end
