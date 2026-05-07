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
        # `Glorbo.Company.Router.read_headcount_budget/1` reads this to
        # gate `proposal/v1 hire` auto-approvals (router.ex §1456).
        # MCP `get_company_health` and `list_companies` also surface
        # the value. Default cap is read from disk; absence means "no
        # auto-approve under cap" (Director must approve every hire).
        :headcount_budget,
        # GEP-46: per-company throttle on simultaneous dispatches across
        # the entire roster. Positive integer; absence = unbounded.
        :max_concurrent_dispatches,
        :template,
        :template_version,
        :provider_pin,
        :model_pin,
        # Set by `glorbo import paperclip` so Directors can grep
        # for imported companies later.
        :imported_from
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
      :headcount_budget,
      :max_concurrent_dispatches,
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
