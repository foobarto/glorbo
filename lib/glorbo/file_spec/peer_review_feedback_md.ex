defmodule Glorbo.FileSpec.PeerReviewFeedbackMd do
  @moduledoc """
  Spec for
  `companies/<co>/agents/<assignee>/inbox/peer-review-feedback-<task-id>.md`
  — the revise-verdict feedback sentinel (GEP-42).

  Written by `Glorbo.Actions.Tasks.record_peer_review_verdict/5`
  when a reviewer returns `revise`. Lands in the *original
  assignee's* inbox (not the Director's) so the wake-and-fix loop
  closes without manual intervention. The note carries the
  reviewer's verdict justification.

  Cleared by the recipient on next dispatch (their inbox-scan
  picks the oldest unread file; once read it can be archived
  through the existing inbox flow).
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/agents/[a-z0-9][a-z0-9-]*/inbox/peer-review-feedback-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "peer-review-feedback/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :task_path, :task_id, :reviewer, :verdict, :delivered_at],
      optional: [:note],
      enums: %{verdict: ["revise"]},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :task_path, :task_id, :reviewer, :verdict, :delivered_at, :note]
  end

  @impl true
  def docs do
    %{
      title: "peer-review-feedback-<task-id>.md — revise-verdict feedback (GEP-42)",
      summary: """
      Inbox sentinel for the original assignee when the peer
      reviewer returns `revise`. Carries the reviewer slug, the
      verdict (always `revise` for this kind — `approve` and
      `block` don't generate feedback files), the verdict note,
      and the back-pointer to the task. Wakes the assignee so the
      revise-and-re-submit loop fires automatically.
      """,
      examples: [
        """
        ---
        kind: peer-review-feedback/v1
        task_path: projects/release/tasks/release-01.md
        task_id: release-01
        reviewer: critiqueops
        verdict: revise
        delivered_at: 2026-04-25T10:30:00Z
        note: |
          Citation 3 (link to vendor spec) returned 404 on 2026-04-25.
          Replace with archive.org snapshot or remove the claim.
        ---

        # Peer-review feedback for release-01

        Your task got a `revise` verdict from critiqueops. See
        `note` above; address the feedback and re-submit (status
        flip back to `pending-approval` triggers re-review
        automatically).
        """
      ]
    }
  end
end
