defmodule Glorbo.Company do
  @moduledoc """
  Ecto schema mirror of `companies/<name>/company.md`.

  Derived row populated by `Glorbo.Filesystem.Reindex` from the markdown's
  YAML frontmatter. The row is disposable — reindex reconstructs it from the
  file at any time (FS-03 / FS-04).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "companies" do
    field :name, :string
    field :mission, :string
    field :file_path, :string

    timestamps(type: :utc_datetime)
  end
end
