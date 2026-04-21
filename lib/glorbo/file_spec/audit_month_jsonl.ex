defmodule Glorbo.FileSpec.AuditMonthJsonl do
  @moduledoc """
  Spec for `companies/<co>/audit/YYYY-MM.jsonl` (per-company) and
  `audit/_system/YYYY-MM.jsonl` (global) — append-only audit event
  log (GEP-3 D3, GEP-19 D2).

  Each line is a JSON object carrying `kind: "audit-event/v1"` and
  event fields (`ts`, `actor`, `action`, `target`, `detail`).
  Validator checks per-line shape; unknown `action:` values are
  warnings, not errors (audit event vocabulary grows across GEPs).
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r|/audit/(_system/)?[0-9]{4}-[0-9]{2}\.jsonl\z|

  @impl true
  def kind, do: "audit-event/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :ts, :actor, :action],
      optional: [:target, :detail, :company, :agent],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :ts, :actor, :action, :target, :agent, :company, :detail]
  end

  @impl true
  def docs do
    %{
      title: "audit/YYYY-MM.jsonl — audit events",
      summary: """
      Append-only JSONL. Each line is a JSON object with
      `kind: "audit-event/v1"`, `ts` (ISO-8601 UTC), `actor`,
      `action`, optional `target` + `detail`. The sole writer is
      `Glorbo.Company.AuditLog` (invariant: FS-05). SQLite mirror
      exists but is derived.
      """,
      examples: [
        ~s({"kind":"audit-event/v1","ts":"2026-04-21T10:00:00Z","actor":"ceo","action":"agent.complete","target":"projects/release/tasks/release-01.md","detail":{"exit_status":0}})
      ]
    }
  end
end
