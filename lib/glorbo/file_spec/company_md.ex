defmodule Glorbo.FileSpec.CompanyMd do
  @moduledoc """
  Spec for `companies/<co>/company.md` — the top-level metadata for
  a company directory. Declares the slug, display name, and the
  list of top-level goals referenced by tasks via `goal:` frontmatter.

  Canonical path: `~/.glorbo/companies/<co>/company.md`.
  """
  @behaviour Glorbo.FileSpec

  @slug_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @impl true
  def kind, do: "company/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/company.md")
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :slug, :name],
      optional: [
        :description,
        :mission,
        :created_at,
        :goals,
        :icon,
        :budget,
        :template,
        :template_version,
        :provider_pin,
        :model_pin
      ],
      enums: %{},
      patterns: %{
        slug: @slug_regex
      },
      caps: %{}
    }
  end

  @impl true
  def canonical_key_order do
    [
      :kind,
      :slug,
      :name,
      :description,
      :mission,
      :icon,
      :budget,
      :template,
      :template_version,
      :provider_pin,
      :model_pin,
      :created_at,
      :goals
    ]
  end

  @impl true
  def docs do
    %{
      title: "company.md — company metadata",
      summary: """
      Top-level metadata for a company directory. Declares the
      canonical slug, the display name, and optional goals list
      consumed by GoalsLive and the per-goal Kanban filter.
      """,
      examples: [
        """
        ---
        kind: company/v1
        slug: acme
        name: Acme
        description: Test company
        goals:
          - slug: ship-v5
            name: Ship v0.0.5
        ---
        # Acme

        A one-person shop shipping small useful things.
        """
      ]
    }
  end
end
