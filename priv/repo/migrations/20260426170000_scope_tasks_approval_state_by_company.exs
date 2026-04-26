defmodule Glorbo.Repo.Migrations.ScopeTasksApprovalStateByCompany do
  @moduledoc """
  Wave 31: scope `tasks_approval_state` by company_slug.

  Pre-fix the table had a unique index on `task_path` alone. Two
  companies with awaiting tasks at the same relative path would
  collide: the second upsert no-ops, and `find_awaiting_row` returns
  the wrong company's row. Violates the "Company isolation is
  absolute" CLAUDE.md invariant.

  Pre-1.0 fix: drop and recreate the table with `company_slug`
  as a NOT NULL column and a composite unique index on
  `(company_slug, task_path)`. SQLite doesn't support ALTER COLUMN
  to make an added column NOT NULL after backfill, so drop+recreate
  is the correct path here. Pre-existing rows are wiped — `glorbo
  reindex` regenerates the table from `companies/<co>/audit/*.jsonl`
  per GEP-34 Phase 2.
  """
  use Ecto.Migration

  def up do
    drop table(:tasks_approval_state)

    create table(:tasks_approval_state) do
      add :company_slug, :string, null: false
      add :task_path, :string, null: false
      add :agent_slug, :string, null: false
      add :status, :string, null: false
      add :requested_at, :utc_datetime, null: false
      add :resolved_at, :utc_datetime
      add :reason, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tasks_approval_state, [:company_slug, :task_path])
  end

  def down do
    drop table(:tasks_approval_state)

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
