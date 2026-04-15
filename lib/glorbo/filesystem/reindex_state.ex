defmodule Glorbo.Filesystem.ReindexState do
  @moduledoc """
  Ecto schema mirror of `reindex_state` — the per-file MD5/size/mtime cache
  that makes `Glorbo.Filesystem.Reindex.run/1` incremental (D-26, D-27).

  Primary key is `file_path` (absolute path on disk) per D-28 discretion —
  no synthetic id, no composite key. Reindex upserts rows on content change
  and deletes rows for vanished files.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:file_path, :string, autogenerate: false}
  schema "reindex_state" do
    field :md5, :string
    field :size, :integer
    field :mtime, :naive_datetime

    timestamps(type: :utc_datetime)
  end
end
