defmodule Glorbo.FileSpec.CompanyMd do
  @moduledoc """
  Spec for `companies/<co>/company.md` — the top-level metadata for
  a company directory. Declares the slug and display name.

  GEP-63: goals are no longer a `company.md` frontmatter list — they
  live one-file-per-goal under `goals/<id>.md` (`Glorbo.FileSpec.GoalMd`).
  A stray `goals:` key here is an `unknown_key` Validator finding.

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
        # GEP-58 semantic-recall opt-in, persisted to disk (GEP-3
        # rebuildability): `glorbo memory index <co> --enable/--disable`
        # writes this boolean, and `glorbo reindex` re-derives the enabled
        # set from it (the SQLite `memory_index_enabled` table is a cache).
        :memory_index,
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
      :memory_index,
      :created_at
    ]
  end

  @impl true
  def docs do
    %{
      title: "company.md — company metadata",
      summary: """
      Top-level metadata for a company directory. Declares the
      canonical slug and the display name. Goals live one-file-per-goal
      under `goals/<id>.md` (GEP-63), not in this frontmatter.
      """,
      examples: [
        """
        ---
        kind: company/v1
        slug: acme
        name: Acme
        description: Test company
        ---
        # Acme

        A one-person shop shipping small useful things.
        """
      ]
    }
  end
end
