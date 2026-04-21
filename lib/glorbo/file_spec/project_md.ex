defmodule Glorbo.FileSpec.ProjectMd do
  @moduledoc """
  Spec for `companies/<co>/projects/<slug>/project.md` — project
  metadata. Slug in the path must match the `slug:` field.
  """
  @behaviour Glorbo.FileSpec

  @project_slug_regex ~r/\A[a-z][a-z0-9-]*(?<!-\d)\z/

  @impl true
  def kind, do: "project/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/project.md")
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :slug, :name],
      optional: [:status, :description, :icon, :created_at, :goal],
      enums: %{status: ["active", "paused", "done", "archived"]},
      patterns: %{slug: @project_slug_regex},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [:kind, :slug, :name, :status, :description, :icon, :goal, :created_at]
  end

  @impl true
  def docs do
    %{
      title: "project.md — project metadata",
      summary: """
      Project metadata sitting at the root of each projects/<slug>/
      directory. Slug must be URL-safe kebab-case and must NOT end
      in `-<digits>` (parser ambiguity with task IDs — GEP-13).
      """,
      examples: [
        """
        ---
        kind: project/v1
        slug: release
        name: Release engineering
        description: Cut + announce Glorbo releases
        icon: rocket
        ---
        """
      ]
    }
  end
end
