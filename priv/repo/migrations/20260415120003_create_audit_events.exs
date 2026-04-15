defmodule Glorbo.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :company, :text
      add :actor, :text, null: false
      add :action, :text, null: false
      add :target, :text
      add :detail, :text
      add :ts, :utc_datetime, null: false
    end

    create index(:audit_events, [:company, :ts])
    create index(:audit_events, [:action])
  end
end
