defmodule Glorbo.FileSpec.GoalMd do
  @moduledoc """
  Spec for `companies/<co>/goals/<id>.md` — company-level goal
  files. A goal is a time-bounded outcome the director tracks;
  progress bars on CompanyLive + GoalsLive read these files to
  surface status.
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
      optional: [:status, :name, :owner, :due, :progress],
      enums: %{status: ["active", "paused", "done", "cancelled"]},
      patterns: %{},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :id, :name, :status, :owner, :due, :progress]
  end

  @impl true
  def docs do
    %{
      title: "goals/<id>.md — company goal",
      summary: """
      Time-bounded outcome the director tracks. Progress bars on
      CompanyLive + GoalsLive read `progress:` when present;
      falls back to deriving progress from linked tasks if
      unspecified.
      """,
      examples: [
        """
        ---
        kind: goal/v1
        id: q3-2026
        name: Q3 2026
        status: active
        ---
        # Q3 2026

        Ship a thing. Learn a thing. Repeat.
        """
      ]
    }
  end
end
