defmodule Glorbo.Repo.Migrations.AddPermissionsHashToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :permissions_hash, :string
    end
  end
end
