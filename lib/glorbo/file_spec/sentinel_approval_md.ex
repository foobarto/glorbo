defmodule Glorbo.FileSpec.SentinelApprovalMd do
  @moduledoc """
  Spec for
  `companies/<co>/agents/<slug>/state/awaiting-approval-<task-id>.md`
  — the director-approval sentinel (GEP-19). Written by the
  Router/Gate when an agent requests director approval; cleared
  when approval is granted or denied.
  """
  @behaviour Glorbo.FileSpec

  @sentinel_regex ~r{/state/awaiting-approval-[a-z0-9][a-z0-9-]*\.md\z}

  @impl true
  def kind, do: "sentinel-approval/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@sentinel_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :agent, :task_id, :task_path, :requested_at],
      optional: [:requires],
      enums: %{},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :agent, :task_id, :task_path, :requested_at, :requires]
  end

  @impl true
  def docs do
    %{
      title: "awaiting-approval-<task-id>.md — approval sentinel",
      summary: """
      Director-approval sentinel written by the Router when an
      agent asks to act on a task with `requires_approval: director`.
      Cleared on grant or deny; the outcome audited as
      `approval.granted`, `approval.approved`, or `approval.denied`
      (GEP-19).
      """,
      examples: [
        """
        ---
        kind: sentinel-approval/v1
        agent: ceo
        task_id: release-01
        task_path: projects/release/tasks/release-01.md
        requested_at: 2026-04-21T10:00:00Z
        ---
        Body is optional prose explaining the ask.
        """
      ]
    }
  end
end
