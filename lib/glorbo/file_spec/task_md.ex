defmodule Glorbo.FileSpec.TaskMd do
  @moduledoc """
  Spec for `companies/<co>/projects/<project>/tasks/<project>-NN.md`
  — individual task files. Per GEP-13, filename shape is
  `<project-slug>-<NN>.md`; soft-migration windows accepting
  `t-NN.md` are closed by GEP-25 D9.
  """
  @behaviour Glorbo.FileSpec

  @task_filename_regex ~r{/projects/[^/]+/tasks/[a-z][a-z0-9-]*-\d+\.md\z}

  @impl true
  def kind, do: "task/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@task_filename_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :id, :title, :status],
      optional: [
        :assigned_to,
        :priority,
        :goal,
        :schedule,
        :requires_approval,
        :created_at,
        :created_by,
        :denial_reason,
        :budget_usd_cents,
        :provider,
        :model
      ],
      enums: %{
        status: [
          "todo",
          "in-progress",
          "pending",
          "pending-approval",
          "approved",
          "denied",
          "done"
        ],
        priority: ["p0", "p1", "p2", "p3"],
        requires_approval: ["director"]
      },
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [
      :kind,
      :id,
      :title,
      :status,
      :assigned_to,
      :priority,
      :goal,
      :schedule,
      :requires_approval,
      :provider,
      :model,
      :budget_usd_cents,
      :created_at,
      :created_by,
      :denial_reason
    ]
  end

  @impl true
  def docs do
    %{
      title: "<project>-NN.md — task file",
      summary: """
      One markdown file per task. Filename format is
      `<project-slug>-<NN>.md` where NN is zero-padded 01-99 then
      natural. Supports `schedule:` for recurring task dispatch
      (GEP-24), `requires_approval:` for director gates (GEP-19),
      and per-task provider/model override.
      """,
      examples: [
        """
        ---
        kind: task/v1
        id: release-01
        title: Cut v0.0.5 release
        status: in-progress
        assigned_to: engineer
        priority: p1
        goal: ship-v5
        ---
        Body with plain markdown. The task prompt for the agent.
        """
      ]
    }
  end
end
