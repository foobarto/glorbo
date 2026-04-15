defmodule Glorbo.Agent do
  @moduledoc """
  Ecto schema mirror of `companies/<co>/agents/<n>/agent.md`.

  Derived row populated by `Glorbo.Filesystem.Reindex`. Links to `companies`
  via `company_id`. Rebuilt from disk — no data stored here that isn't in
  the markdown frontmatter.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :role, :string
    field :provider, :string
    field :model, :string
    field :file_path, :string

    belongs_to :company, Glorbo.Company

    timestamps(type: :utc_datetime)
  end
end
