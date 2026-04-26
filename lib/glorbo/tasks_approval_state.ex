defmodule Glorbo.TasksApprovalState do
  @moduledoc """
  Ecto schema for tracking task approval state.

  Tasks with `requires_approval: director` in their frontmatter pause at
  pick-up time (D-30). This table records the lifecycle: `awaiting` until
  the Director flips the task's `status:` frontmatter field, then `approved`
  or `denied` (D-31/D-32).

  Unique on `(company_slug, task_path)` — one approval state per task per
  company. Wave 31 (v0.12.x) added `company_slug` to fix a cross-company
  bleed where two companies with the same relative `task_path` would
  silently collide on upsert.

  **Rebuildable from disk** (GEP-34 Phase 2, v0.12.0): `glorbo reindex`
  folds `approval.{requested,granted,denied}` audit lines chronologically
  per `task_path` and bulk-inserts the final state via
  `Glorbo.Filesystem.Reindex.rebuild_tasks_approval_state/1`. Dropping
  `glorbo.db` is safe — `glorbo reindex` reconstructs every active and
  resolved approval row from the on-disk audit log.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @valid_statuses ["awaiting", "approved", "denied"]

  schema "tasks_approval_state" do
    field :company_slug, :string
    field :task_path, :string
    field :agent_slug, :string
    field :status, :string
    field :requested_at, :utc_datetime
    field :resolved_at, :utc_datetime
    field :reason, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating/updating a task approval state."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = state, attrs) do
    state
    |> cast(attrs, [
      :company_slug,
      :task_path,
      :agent_slug,
      :status,
      :requested_at,
      :resolved_at,
      :reason
    ])
    |> validate_required([:company_slug, :task_path, :agent_slug, :status, :requested_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:company_slug, :task_path],
      name: :tasks_approval_state_company_slug_task_path_index
    )
  end
end
