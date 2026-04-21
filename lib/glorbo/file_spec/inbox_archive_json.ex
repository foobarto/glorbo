defmodule Glorbo.FileSpec.InboxArchiveJson do
  @moduledoc """
  Spec for `companies/<co>/audit/_inbox_archive.json` — the
  director's archived-inbox-item state (GEP-20, Archive actions).
  The single admitted exception to GEP-3's "markdown + YAML or
  JSONL only" rule (see GEP-25 D7): whole-set mutations (add/remove
  a key) don't fit either format cleanly, so the archive is a
  top-level JSON object.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/audit/_inbox_archive\.json\z}

  @impl true
  def kind, do: "inbox-archive/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :keys],
      optional: [:updated_at],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :keys, :updated_at]

  @impl true
  def docs do
    %{
      title: "_inbox_archive.json — archived inbox items",
      summary: """
      Top-level JSON object listing opaque archive keys
      (`approval:<task_path>`, `audit:<ts>|<action>|<target>`) that
      the director has stashed via the Archive tab. Not part of the
      audit contract — append-only doesn't apply. The ONE admitted
      exception to GEP-3's format rules (GEP-25 D7).
      """,
      examples: [
        ~s({\n  "kind": "inbox-archive/v1",\n  "keys": ["approval:projects/release/tasks/release-01.md"],\n  "updated_at": "2026-04-21T10:00:00Z"\n})
      ]
    }
  end
end
