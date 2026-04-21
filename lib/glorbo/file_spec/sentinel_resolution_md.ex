defmodule Glorbo.FileSpec.SentinelResolutionMd do
  @moduledoc """
  Spec for
  `companies/<co>/agents/<slug>/state/resolved-<decision>-<task-id>.md`
  — stuck-on resolution file (R21). Consumed by
  `Glorbo.Agent.LoopDetector.apply_resolution_files/3` on the next
  InboxLive/TaskLive render; file is removed after apply. Body
  is optional.
  """
  @behaviour Glorbo.FileSpec

  @sentinel_regex ~r{/state/resolved-(retry|skip|stop)-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "sentinel-resolution/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@sentinel_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind],
      optional: [:actor, :note, :ts],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :actor, :note, :ts]

  @impl true
  def docs do
    %{
      title: "resolved-<decision>-<task>.md — stuck resolution",
      summary: """
      Drop this file next to a `stuck-on-<task>.md` sentinel to
      apply the resolution. Decisions: `retry`, `skip`, `stop`.
      InboxLive/TaskLive pick up the file on next render; both
      the resolution file and the stuck sentinel are deleted after
      apply. Frontmatter is minimal — the filename carries the
      decision and task ID.
      """,
      examples: [
        """
        ---
        kind: sentinel-resolution/v1
        actor: director
        note: Retrying with budget bump
        ts: 2026-04-21T11:00:00Z
        ---
        """
      ]
    }
  end
end
