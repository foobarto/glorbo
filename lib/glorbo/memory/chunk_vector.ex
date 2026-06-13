defmodule Glorbo.Memory.ChunkVector do
  @moduledoc """
  Ecto schema for a single embedded chunk (GEP-0058, D3/D5).

  One row per `{company, source_path, chunk_id}`. The `embedding` is the
  packed little-endian float32 representation of the chunk's vector (see
  `Glorbo.Memory.Vector` for the pack/unpack helpers); `dims` and `model`
  record its shape and provenance so a re-rank never compares vectors of
  different dimensionality or from a different embedder.

  **Per-company isolation (load-bearing):** `company` is part of the
  composite key and EVERY query that reads this table MUST filter on it.
  A query for company A must never see company B's vectors — the
  `Glorbo.Memory.Index` query surface enforces this; the schema documents
  the contract.

  **Derived, rebuildable (GEP-7):** this table is disposable derived
  state. `glorbo reindex` re-embeds the *enabled* companies' markdown
  tree and repopulates it; the markdown files stay authoritative. Caveat:
  the enabled-set (`memory_index_enabled`) is itself SQLite-only, so a
  full `rm glorbo.db` drops the opt-in and reindex repopulates nothing
  until re-enabled — see `Glorbo.Memory.Index` for the GEP-3
  rebuildability gap.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  schema "chunk_vectors" do
    field :company, :string
    field :source_path, :string
    field :chunk_id, :integer
    field :embedding, :binary
    field :model, :string
    field :dims, :integer
  end

  @doc "Changeset for inserting/replacing a chunk vector row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = vector, attrs) do
    vector
    |> cast(attrs, [:company, :source_path, :chunk_id, :embedding, :model, :dims])
    |> validate_required([:company, :source_path, :chunk_id, :embedding, :model, :dims])
    |> validate_number(:chunk_id, greater_than_or_equal_to: 0)
    |> validate_number(:dims, greater_than: 0)
    |> unique_constraint([:company, :source_path, :chunk_id],
      name: :chunk_vectors_company_source_path_chunk_id_index
    )
  end
end
