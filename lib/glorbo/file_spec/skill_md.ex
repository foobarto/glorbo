defmodule Glorbo.FileSpec.SkillMd do
  @moduledoc """
  Spec for skill files (GEP-10): both builtin under
  `priv/templates/skills/<name>.md` and custom overrides at
  `~/.glorbo/skills/<name>.md`.

  A skill is a reusable prompt module an agent can reference by
  `skills: [name]` in its `AGENT.md`.
  """
  @behaviour Glorbo.FileSpec

  @slug_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @path_regex ~r{/(priv/templates/skills|skills)/[^/]+\.md\z}

  @impl true
  def kind, do: "skill/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :name, :description],
      optional: [:tags, :version],
      enums: %{},
      patterns: %{name: @slug_regex},
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order, do: [:kind, :name, :description, :version, :tags]

  @impl true
  def docs do
    %{
      title: "<name>.md — skill module",
      summary: """
      Reusable prompt module. Builtins ship under
      `priv/templates/skills/`; user overrides shadow by filename
      under `~/.glorbo/skills/`. Referenced from an agent's
      `AGENT.md` via `skills: [name]`.
      """,
      examples: [
        """
        ---
        kind: skill/v1
        name: code-review
        description: Structured code review covering bugs, security, style.
        tags: [engineering, review]
        ---
        # code-review

        ## Purpose

        Review code along four dimensions: correctness, security, style, maintainability.
        """
      ]
    }
  end
end
