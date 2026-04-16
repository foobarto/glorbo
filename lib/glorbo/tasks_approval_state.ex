defmodule Glorbo.TasksApprovalState do
  @moduledoc """
  Ecto schema for tracking task approval state.

  Tasks with `requires_approval: director` in their frontmatter pause at
  pick-up time (D-30). This table records the lifecycle: `awaiting` until
  the Director flips the task's `status:` frontmatter field, then `approved`
  or `denied` (D-31/D-32).

  Unique on `task_path` — one approval state per task at a time.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @valid_statuses ["awaiting", "approved", "denied"]

  schema "tasks_approval_state" do
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
    |> cast(attrs, [:task_path, :agent_slug, :status, :requested_at, :resolved_at, :reason])
    |> validate_required([:task_path, :agent_slug, :status, :requested_at])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:task_path)
  end
end
