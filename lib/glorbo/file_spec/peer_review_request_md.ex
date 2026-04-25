defmodule Glorbo.FileSpec.PeerReviewRequestMd do
  @moduledoc """
  Spec for
  `companies/<co>/agents/<reviewer>/inbox/peer-review-<task-id>.md`
  — the peer-review wake sentinel (GEP-42).

  Written by `Glorbo.Actions.Reviews.request_peer_review/4` when
  `Glorbo.Approvals.Gate` first observes that a task needs peer
  review. The reviewer's existing inotify-driven wake pipeline
  picks the file up; the reviewer reads the original task at
  `task_path` and produces a verdict via the standard outbox-reply
  contract. The sentinel is deleted by
  `Glorbo.Actions.Tasks.record_peer_review_verdict/5` when the
  verdict lands.

  ## Pointer, not copy

  The sentinel carries `task_path` rather than the task's prompt
  body — see GEP-42 D1. Two copies of the prompt would create a
  drift surface; the reviewer reads the canonical task file.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/agents/[a-z0-9][a-z0-9-]*/inbox/peer-review-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "peer-review-request/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :task_path, :task_id, :requesting_agent, :severity, :requested_at],
      optional: [:reviewer],
      enums: %{severity: ["info", "minor", "major", "critical"]},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :task_path, :task_id, :requesting_agent, :severity, :requested_at, :reviewer]
  end

  @impl true
  def docs do
    %{
      title: "peer-review-<task-id>.md — peer-review wake sentinel (GEP-42)",
      summary: """
      Inbox sentinel that wakes the reviewer for a task gated by
      peer review. Pointer-style: carries `task_path` rather than
      a copy of the prompt. Deleted by the verdict-recording
      action; re-created by the gate on the next pending-approval
      observation if the engineer revises and re-submits.
      """,
      examples: [
        """
        ---
        kind: peer-review-request/v1
        task_path: projects/release/tasks/release-01.md
        task_id: release-01
        requesting_agent: engineer
        severity: major
        requested_at: 2026-04-25T10:00:00Z
        reviewer: critiqueops
        ---

        # Peer review: ship v1.0

        Read the original task at `projects/release/tasks/release-01.md`
        and reply with a verdict (approve | revise | block).
        """
      ]
    }
  end
end
