defmodule Glorbo.Budget.Ledger do
  @moduledoc """
  Pure-logic layer over `Glorbo.Budget` schema (Plan 03-01 D-31).

  Responsibilities:

    * `compute_cost_cents/4` — translate `{provider, model, prompt, completion}`
      into integer USD cents via the `config/llm_rates.exs` rate table.
      Missing rates log a warning and return 0 (D-30 user-accepted tradeoff —
      undercounting is preferred to crashing dispatch).
    * `record!/1` — atomic upsert of a `{agent_slug, year_month}` ledger row
      via Ecto `on_conflict: [inc: [...]]` — the delta is added to the
      existing row under SQL-level atomicity, guaranteeing that concurrent
      writers do not lose updates (RESEARCH Pitfall 2, T-03-08 mitigation).
    * `month_bucket/1` — `"YYYY-MM"` UTC bucket from a `DateTime` or `Date`.
    * `fetch/2` — plain `Repo.get_by` convenience wrapper.

  **Why pure (not GenServer):** `record!/1` is stateless; all state lives in
  the SQLite row with DB-level atomicity via the composite unique index on
  `(agent_slug, year_month)` shipped in Plan 03-01's migration. A GenServer
  would serialise writes (bottleneck) without adding safety.

  **Why integer cents:** Plan 03-01 locked `cost_usd_cents :: non_neg_integer()`;
  `SUM` aggregation must be float-drift-free.
  """
  require Logger

  alias Glorbo.Budget
  alias Glorbo.Repo

  @type provider :: String.t()
  @type model :: String.t()
  @type usage_record :: %{
          required(:agent_slug) => String.t(),
          required(:year_month) => String.t(),
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          required(:cost_usd_cents) => non_neg_integer(),
          optional(:provider) => String.t(),
          optional(:model) => String.t()
        }

  # ---------------------------------------------------------------------------
  # compute_cost_cents/4
  # ---------------------------------------------------------------------------

  @doc """
  Compute the USD-cents cost of a `{prompt_tokens, completion_tokens}` pair
  for the given `{provider, model}`.

  Returns 0 (with a `Logger.warning`) if the provider or model is not in the
  rate table. Budget undercount is preferred to a raise — a misconfigured
  `agent.md` should not crash the dispatch pipeline (D-30).

  Rounding: half-up for non-negative inputs via `trunc(x + 0.5)`. This makes
  small fractional-cent costs round up rather than banker's-rounding toward
  even, which is friendlier when displaying "$X used this month" in alerts.
  """
  @spec compute_cost_cents(provider(), model(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def compute_cost_cents(provider, model, prompt_tokens, completion_tokens)
      when is_binary(provider) and is_binary(model) and is_integer(prompt_tokens) and
             prompt_tokens >= 0 and is_integer(completion_tokens) and completion_tokens >= 0 do
    rates = Application.get_env(:glorbo, :llm_rates, %{})

    case get_in(rates, [provider, model]) do
      %{input_usd_per_mtok: input_rate, output_usd_per_mtok: output_rate} ->
        input_cost = prompt_tokens / 1_000_000 * input_rate * 100
        output_cost = completion_tokens / 1_000_000 * output_rate * 100
        round_half_up(input_cost + output_cost)

      _ ->
        Logger.warning(
          "budget.cost_rate_missing: provider=#{inspect(provider)} model=#{inspect(model)} — recording 0 cents (D-30 undercount tradeoff)"
        )

        0
    end
  end

  # Half-up rounding for non-negative floats. `trunc/1` drops the fractional
  # part toward 0, which for non-negatives is equivalent to floor; adding 0.5
  # first yields half-up.
  defp round_half_up(x) when is_float(x) and x >= 0.0, do: trunc(x + 0.5)

  # ---------------------------------------------------------------------------
  # month_bucket/1
  # ---------------------------------------------------------------------------

  @doc """
  Return the UTC `"YYYY-MM"` bucket string for a DateTime or Date.

  The ledger is keyed by this bucket so all costs in a calendar month
  aggregate into one row.
  """
  @spec month_bucket(DateTime.t() | Date.t()) :: String.t()
  def month_bucket(%DateTime{year: y, month: m}), do: format_year_month(y, m)
  def month_bucket(%Date{year: y, month: m}), do: format_year_month(y, m)

  defp format_year_month(year, month) do
    "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"
  end

  # ---------------------------------------------------------------------------
  # record!/1
  # ---------------------------------------------------------------------------

  @doc """
  Atomically upsert a usage record into the `budgets` table.

  Semantics: the `prompt_tokens`, `completion_tokens`, and `cost_usd_cents`
  fields in `record` are treated as DELTAS. On first write for a
  `{agent_slug, year_month}` pair a row is inserted with those values. On
  subsequent writes the existing row's columns are atomically incremented by
  the deltas via `on_conflict: [inc: [...]]` — the increment happens at the
  SQL layer under row-level locking, so concurrent writers never lose
  updates (T-03-08 mitigation).

  Raises `Ecto.InvalidChangesetError` if `record` fails changeset validation
  (e.g. negative tokens). Callers MUST ensure deltas are non-negative.
  """
  @spec record!(usage_record()) :: Budget.t()
  def record!(record) do
    case record(record) do
      {:ok, budget} -> budget
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset
    end
  end

  @doc """
  Non-raising variant of `record!/1`. Returns `{:ok, Budget.t()}` on
  success and `{:error, %Ecto.Changeset{}}` on validation failure —
  callers that want to distinguish "negative tokens" from "DB unique
  constraint violation" can inspect `changeset.errors` (TODO.md
  Minor #13).
  """
  @spec record(usage_record()) :: {:ok, Budget.t()} | {:error, Ecto.Changeset.t()}
  def record(%{
        agent_slug: agent_slug,
        year_month: year_month,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        cost_usd_cents: cost_usd_cents
      })
      when is_binary(agent_slug) and is_binary(year_month) do
    attrs = %{
      agent_slug: agent_slug,
      year_month: year_month,
      prompt_tokens: prompt_tokens,
      completion_tokens: completion_tokens,
      cost_usd_cents: cost_usd_cents
    }

    changeset = Budget.changeset(%Budget{}, attrs)

    if changeset.valid? do
      {:ok,
       Repo.insert!(changeset,
         on_conflict: [
           inc: [
             prompt_tokens: prompt_tokens,
             completion_tokens: completion_tokens,
             cost_usd_cents: cost_usd_cents
           ]
         ],
         conflict_target: [:agent_slug, :year_month]
       )}
    else
      {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------------
  # fetch/2
  # ---------------------------------------------------------------------------

  @doc """
  Fetch the ledger row for `{agent_slug, year_month}` or `nil`.
  """
  @spec fetch(String.t(), String.t()) :: Budget.t() | nil
  def fetch(agent_slug, year_month) when is_binary(agent_slug) and is_binary(year_month) do
    Repo.get_by(Budget, agent_slug: agent_slug, year_month: year_month)
  end
end
