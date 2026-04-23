defmodule Glorbo.Budget do
  @moduledoc """
  Ecto schema for per-agent monthly budget tracking.

  Each row aggregates LLM usage for one agent in one company for one
  calendar month (UTC).
  Costs are stored in integer cents to avoid floating-point drift in SUM
  aggregations (D-26 confirmed).

  The `budgets` table has a composite unique index on
  `{company_slug, agent_slug, year_month}` so per-agent and company-level
  caps stay isolated even when two companies reuse the same agent slug.
  Plan 02's BudgetTracker upserts against that conflict target with atomic
  `inc:` (see RESEARCH Pitfall 4 for the safe Ecto pattern).
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "budgets" do
    field :company_slug, :string
    field :agent_slug, :string
    field :year_month, :string
    field :prompt_tokens, :integer, default: 0
    field :completion_tokens, :integer, default: 0
    field :cost_usd_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/updating a budget row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = budget, attrs) do
    budget
    |> cast(attrs, [
      :company_slug,
      :agent_slug,
      :year_month,
      :prompt_tokens,
      :completion_tokens,
      :cost_usd_cents
    ])
    |> validate_required([:company_slug, :agent_slug, :year_month])
    |> validate_number(:prompt_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:completion_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_usd_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:agent_slug,
      name: :budgets_company_slug_agent_slug_year_month_index
    )
  end
end
