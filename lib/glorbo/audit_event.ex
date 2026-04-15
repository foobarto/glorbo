defmodule Glorbo.AuditEvent do
  @moduledoc """
  Ecto schema mirror of a single JSONL line in `audit/YYYY-MM.jsonl`.

  CLAUDE.md invariant: the JSONL file on disk is the source of truth; this
  table is derived. The `detail` column carries the raw JSON-encoded payload
  (beyond the well-known keys ts / actor / action / target) so the dashboard
  can filter without re-parsing the JSONL file.

  **W2 scope note:** Phase-2 reindex does NOT rebuild this table from disk.
  JSONL-to-SQLite import is deferred to Phase 3. Dropping `glorbo.db` does
  not affect the on-disk audit log.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :company, :string
    field :actor, :string
    field :action, :string
    field :target, :string
    # JSON-encoded additional fields beyond the well-known keys
    field :detail, :string
    field :ts, :utc_datetime
  end
end
