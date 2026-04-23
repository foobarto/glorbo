defmodule Glorbo.Repo.Migrations.ScopeBudgetsByCompany do
  use Ecto.Migration

  def change do
    alter table(:budgets) do
      add :company_slug, :string, default: "_legacy", null: false
    end

    drop_if_exists unique_index(:budgets, [:agent_slug, :year_month])

    create unique_index(:budgets, [:company_slug, :agent_slug, :year_month],
             name: :budgets_company_slug_agent_slug_year_month_index
           )

    create index(:budgets, [:company_slug, :year_month])
  end
end
