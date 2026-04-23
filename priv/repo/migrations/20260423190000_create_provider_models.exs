defmodule Glorbo.Repo.Migrations.CreateProviderModels do
  use Ecto.Migration

  def change do
    create table(:provider_models, primary_key: false) do
      add :alias, :text, null: false
      add :model_id, :text, null: false
      add :context_window, :integer
      add :family, :text
      add :raw_json, :text
      add :refreshed_at, :utc_datetime
    end

    create unique_index(:provider_models, [:alias, :model_id])
    create index(:provider_models, [:alias])
  end
end
