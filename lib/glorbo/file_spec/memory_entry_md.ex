defmodule Glorbo.FileSpec.MemoryEntryMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/memory/<type>_<topic>.md`
  — individual memory files (GEP-21). Type must match filename
  prefix; topic must match the slug regex; body capped at 8 KB.
  """
  @behaviour Glorbo.FileSpec

  @memory_filename_regex ~r"/memory/(user|feedback|project|reference)_[a-z][a-z0-9_-]{0,63}\.md\z"
  @body_cap_bytes 8_192

  @impl true
  def kind, do: "agent-memory/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@memory_filename_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :name, :type, :description],
      optional: [],
      enums: %{
        type: ["user", "feedback", "project", "reference"]
      },
      patterns: %{},
      caps: %{body: @body_cap_bytes}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :name, :description, :type]

  @impl true
  def docs do
    %{
      title: "<type>_<topic>.md — memory file",
      summary: """
      One memory entry. Filename prefix (`user_`, `feedback_`,
      `project_`, `reference_`) must equal the frontmatter `type:`.
      Body capped at 8 KB; total memory dir capped at 100 KB soft
      (warning only).
      """,
      examples: [
        """
        ---
        kind: agent-memory/v1
        name: Director role and preferences
        description: Director runs acme solo; prefers Apache-2.0
        type: user
        ---
        Director is a one-person shop; Apache-2.0 for new repos.
        """
      ]
    }
  end
end
