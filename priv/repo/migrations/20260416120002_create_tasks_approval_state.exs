defmodule Glorbo.Repo.Migrations.CreateTasksApprovalState do
  use Ecto.Migration

  def change do
    create table(:tasks_approval_state) do
      add :task_path, :string, null: false
      add :agent_slug, :string, null: false
      add :status, :string, null: false
      add :requested_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
      add :reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tasks_approval_state, [:task_path])
  end
end
