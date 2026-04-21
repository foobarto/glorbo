defmodule Glorbo.FileSpec.SentinelStuckMd do
  @moduledoc """
  Spec for
  `companies/<co>/agents/<slug>/state/stuck-on-<task-id>.md` —
  the LoopDetector stuck-on sentinel (GEP-21-adjacent, via
  `Glorbo.Agent.LoopDetector`). Written after N consecutive
  dispatch failures on the same task; cleared by resolution
  (either buttons in InboxLive/TaskLive or the file-drop
  protocol via `resolved-<decision>-<task>.md`).
  """
  @behaviour Glorbo.FileSpec

  @sentinel_regex ~r{/state/stuck-on-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "sentinel-stuck/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@sentinel_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :agent, :task_id, :task_path, :failure_count],
      optional: [:first_failure_ts, :last_failure_ts, :audit_month],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [
      :kind,
      :agent,
      :task_id,
      :task_path,
      :failure_count,
      :first_failure_ts,
      :last_failure_ts,
      :audit_month
    ]
  end

  @impl true
  def docs do
    %{
      title: "stuck-on-<task-id>.md — loop-detector sentinel",
      summary: """
      Written by `Glorbo.Agent.LoopDetector` after 3 consecutive
      dispatch failures on the same task. Director resolves via
      inbox buttons (retry/skip/stop) or by dropping a
      `resolved-<decision>-<task>.md` sibling; both paths go through
      `Glorbo.Agent.LoopDetector.resolve/5`.
      """,
      examples: [
        """
        ---
        kind: sentinel-stuck/v1
        agent: engineer
        task_id: release-01
        task_path: projects/release/tasks/release-01.md
        failure_count: 3
        first_failure_ts: 2026-04-21T09:00:00Z
        last_failure_ts: 2026-04-21T10:30:00Z
        ---
        Agent has failed 3 consecutive dispatches. Director action needed.
        """
      ]
    }
  end
end
