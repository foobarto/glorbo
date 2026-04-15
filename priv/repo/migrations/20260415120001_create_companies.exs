defmodule Glorbo.Repo.Migrations.CreateCompanies do
  use Ecto.Migration

  def change do
    create table(:companies) do
      add :name, :text, null: false
      add :mission, :text
      add :file_path, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:companies, [:file_path])
    create index(:companies, [:name])
  end
end
