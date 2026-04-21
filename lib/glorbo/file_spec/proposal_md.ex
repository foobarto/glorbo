defmodule Glorbo.FileSpec.ProposalMd do
  @moduledoc """
  Spec for `companies/<co>/proposals/*.md` — agent-created structural
  proposals (GEP-28).

  **Path match:** any `.md` directly under `companies/<co>/proposals/`.
  **Filename:** agent-chosen; the file stem is the proposal `id`.

  **id ↔ filename invariant:** `id` in frontmatter should match the
  filename stem. The generic validator does not currently enforce this
  cross-check (GEP-28 D4 open question); agents should keep them in
  sync by convention.
  """
  @behaviour Glorbo.FileSpec

  @proposal_path_regex ~r{/proposals/[^/]+\.md\z}

  @impl true
  def kind, do: "proposal/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    Regex.match?(@proposal_path_regex, path)
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :id, :subtype, :status, :proposed_by, :requires_approval, :proposed_at],
      optional: [
        :approved_by,
        :approved_at,
        :denial_reason,
        :superseded_by
      ],
      enums: %{
        status: [
          "pending-approval",
          "approved",
          "denied",
          "superseded"
        ],
        subtype: [
          "hire",
          "fire",
          "budget",
          "project",
          "custom"
        ],
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
      :subtype,
      :status,
      :proposed_by,
      :requires_approval,
      :proposed_at,
      :approved_by,
      :approved_at,
      :denial_reason,
      :superseded_by
    ]
  end

  @impl true
  def docs do
    %{
      title: "proposals/<id>.md — proposal file",
      summary: """
      Agent-created structural proposals (GEP-28). Used for hiring,
      firing, budget changes, new projects, and custom requests that
      require Director approval. Frontmatter-driven approval flow;
      auto-approval within headcount budget for hire/fire subtypes.
      """,
      examples: [
        """
        ---
        kind: proposal/v1
        id: hire-writer-2026-04-21
        subtype: hire
        status: pending-approval
        proposed_by: ceo
        requires_approval: director
        proposed_at: 2026-04-21T10:00:00Z
        ---

        ## Rationale

        We need a Writer to handle the editorial calendar.

        ## Execution hint

        ```bash
        glorbo new agent techblog/writer --role writer --provider opencode
        ```
        """
      ]
    }
  end
end
