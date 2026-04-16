defmodule Glorbo.Repo.Migrations.CreateBudgets do
  use Ecto.Migration

  def change do
    create table(:budgets) do
      add :agent_slug, :string, null: false
      add :year_month, :string, null: false
      add :prompt_tokens, :integer, default: 0, null: false
      add :completion_tokens, :integer, default: 0, null: false
      add :cost_usd_cents, :integer, default: 0, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:budgets, [:agent_slug, :year_month])
  end
end
