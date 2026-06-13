defmodule Glorbo.FileSpec.GoalMd do
  @moduledoc """
  Spec for `companies/<co>/goals/<id>.md` — company-level goal
  files. A goal is a time-bounded outcome the director tracks.

  GEP-63: these files are the **single canonical goal store**. The
  goals UI (`GoalsLive`, `CompanyLive`, `OverviewLive`) reads them via
  `Glorbo.Company.Goals.list/1`; `company.md` no longer carries a
  `goals:` list. `id` is the one identifier — it MUST equal the
  filename basename and doubles as the `task/v1` `goal:` join key and
  the Kanban `?goal=<id>` filter value.
  """
  @behaviour Glorbo.FileSpec

  @path_regex ~r{/goals/[^/]+\.md\z}

  @impl true
  def kind, do: "goal/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :id],
      optional: [:status, :name, :description, :owner, :due, :progress],
      enums: %{status: ["active", "paused", "done", "cancelled"]},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :id, :name, :description, :status, :owner, :due, :progress]
  end

  @impl true
  def docs do
    %{
      title: "goals/<id>.md — company goal",
      summary: """
      Time-bounded outcome the director tracks. One file per goal —
      the canonical goal store (GEP-63). Progress bars on CompanyLive +
      GoalsLive use `progress:` (an integer `0..100`) when present and
      in range; otherwise they derive progress from linked tasks (tasks
      whose `goal:` equals this `id`). `id` MUST equal the filename
      basename.
      """,
      examples: [
        """
        ---
        kind: goal/v1
        id: q3-2026
        name: Q3 2026
        description: Ship a thing. Learn a thing. Repeat.
        status: active
        progress: 40
        ---
        # Q3 2026

        Ship a thing. Learn a thing. Repeat.
        """
      ]
    }
  end
end
