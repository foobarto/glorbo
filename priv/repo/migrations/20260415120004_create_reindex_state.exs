defmodule Glorbo.Repo.Migrations.CreateReindexState do
  use Ecto.Migration

  def change do
    create table(:reindex_state, primary_key: false) do
      add :file_path, :text, primary_key: true
      add :md5, :text, null: false
      add :size, :integer
      add :mtime, :naive_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:reindex_state, [:md5])
  end
end
