defmodule Glorbo.AuditEvent do
  @moduledoc """
  Ecto schema mirror of a single JSONL line in `audit/YYYY-MM.jsonl`.

  CLAUDE.md invariant: the JSONL file on disk is the source of truth; this
  table is derived. The `detail` column carries the raw JSON-encoded payload
  (beyond the well-known keys ts / actor / action / target) so the dashboard
  can filter without re-parsing the JSONL file.

  **Rebuildable from disk** (GEP-34 Phase 1, v0.12.0): `glorbo reindex`
  streams every `companies/<co>/audit/<YYYY-MM>.jsonl` and
  `<base>/audit/_system/<YYYY-MM>.jsonl` line-by-line back into this
  table via `Glorbo.Filesystem.Reindex.rebuild_audit_events/1`. Dropping
  `glorbo.db` is safe — `glorbo reindex` regenerates the full mirror.
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
