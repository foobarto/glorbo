defmodule Glorbo.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :company_id, references(:companies, on_delete: :delete_all)
      add :name, :text, null: false
      add :role, :text
      add :provider, :text
      add :model, :text
      add :file_path, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:file_path])
    create unique_index(:agents, [:company_id, :name])
  end
end
