defmodule Glorbo.Repo.Migrations.CreateMemoryIndex do
  @moduledoc """
  GEP-0058 — semantic recall index (optional, default-OFF, derived).

  Three derived tables, all per-company-scoped and rebuilt by
  `glorbo reindex`:

    * `chunks_fts` — SQLite FTS5 virtual table for keyword recall.
      `company`, `source_path` and `chunk_id` are UNINDEXED (stored but
      not tokenised) so the only matched column is `content`. Queries
      filter `company` in the WHERE clause for strict isolation.
    * `chunk_vectors` — the embedding store keyed by
      `{company, source_path, chunk_id}`. The vector lands as a raw
      little-endian float32 BLOB; `model` + `dims` describe it.
    * `memory_index_enabled` — the per-company opt-in flag (default OFF;
      a row exists only for an enabled company).

  All three are derivable from disk — dropping `glorbo.db` and running
  `glorbo reindex` rebuilds them. The markdown home tree (GEP-7) stays
  authoritative.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE VIRTUAL TABLE chunks_fts USING fts5(
      content,
      company UNINDEXED,
      source_path UNINDEXED,
      chunk_id UNINDEXED
    )
    """)

    create table(:chunk_vectors, primary_key: false) do
      add :company, :text, null: false
      add :source_path, :text, null: false
      add :chunk_id, :integer, null: false
      add :embedding, :binary, null: false
      add :model, :text, null: false
      add :dims, :integer, null: false
    end

    create unique_index(:chunk_vectors, [:company, :source_path, :chunk_id])
    create index(:chunk_vectors, [:company])

    create table(:memory_index_enabled, primary_key: false) do
      add :company, :text, null: false
    end

    create unique_index(:memory_index_enabled, [:company])
  end

  def down do
    drop unique_index(:memory_index_enabled, [:company])
    drop table(:memory_index_enabled)
    drop index(:chunk_vectors, [:company])
    drop unique_index(:chunk_vectors, [:company, :source_path, :chunk_id])
    drop table(:chunk_vectors)
    execute("DROP TABLE chunks_fts")
  end
end
