defmodule Glorbo.FileSpec.TaskMd do
  @moduledoc """
  Spec for `companies/<co>/projects/<project>/tasks/*.md` —
  individual task files.

  **Path match** is permissive: any `.md` under `projects/<proj>/
  tasks/` is a task (matches what `Glorbo.TaskDefinition.parse_file`
  actually accepts — R28 finding from the validator UAT).

  **Canonical filename** per GEP-13 is `<project-slug>-<NN>.md`
  (e.g. `release-01.md`). Non-canonical names (descriptive slugs
  directors write by hand) are valid but flagged at info severity
  via a check the Validator runs using `canonical_filename?/1`.
  """
  @behaviour Glorbo.FileSpec

  # Permissive path match: any .md under projects/<proj>/tasks/.
  @task_path_regex ~r{/projects/[^/]+/tasks/[^/]+\.md\z}

  # Canonical shape per GEP-13. Used by the validator to surface
  # non-canonical-but-valid task filenames as info-level findings.
  @canonical_filename_regex ~r{/projects/[^/]+/tasks/[a-z][a-z0-9-]*-\d+\.md\z}

  @doc """
  True when the path matches the GEP-13 canonical `<project>-NN.md`
  shape. Exposed so the Validator can emit info findings for
  non-canonical names.
  """
  @spec canonical_filename?(Path.t()) :: boolean()
  def canonical_filename?(path) when is_binary(path) do
    Regex.match?(@canonical_filename_regex, path)
  end

  @impl true
  def kind, do: "task/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@task_path_regex, path)
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
        priority: ["low", "medium", "high", "critical"],
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
