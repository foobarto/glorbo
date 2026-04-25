defmodule Glorbo.FileSpec.AgentMd do
  @moduledoc """
  Spec for `companies/<co>/agents/<slug>/AGENT.md` — the agent
  contract file. Declares the agent's role, provider, model,
  budget, heartbeat schedule, network policy, permissions, skills,
  and (optionally) per-agent proxy allowlist extensions.

  ALLCAPS filename is required (GEP-15); per GEP-25 D9 the
  soft-migration window accepting `agent.md` is closed.
  """
  @behaviour Glorbo.FileSpec

  @slug_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @impl true
  def kind, do: "agent/v1"

  @impl true
  def path_match?(path) when is_binary(path) do
    String.ends_with?(path, "/AGENT.md")
  end

  @impl true
  def frontmatter_schema do
    %{
      required: [:kind, :slug, :role, :provider, :network],
      optional: [
        :name,
        :reports_to,
        :model,
        :heartbeat,
        :heartbeat_file,
        :budget,
        :skills,
        :permissions,
        :network_allow,
        :autonomy,
        # Set by `glorbo import paperclip` so Directors can grep
        # for imported agents later. Free-form; the validator
        # doesn't enforce a value.
        :imported_from,
        :imported_company
      ],
      enums: %{
        network: ["loopback", "proxy", "full"],
        autonomy: ["supervised", "semi-autonomous", "autonomous"]
      },
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
      :role,
      :reports_to,
      :provider,
      :model,
      :network,
      :network_allow,
      :heartbeat,
      :heartbeat_file,
      :budget,
      :autonomy,
      :skills,
      :permissions
    ]
  end

  @impl true
  def docs do
    %{
      title: "AGENT.md — agent contract",
      summary: """
      Declares everything about an agent: provider/model, budget,
      heartbeat, network policy, permissions (enforced by Router +
      bwrap), skills, and optional per-agent allowlist extensions
      (GEP-23). ALLCAPS filename is mandatory (GEP-15).
      """,
      examples: [
        """
        ---
        kind: agent/v1
        slug: ceo
        role: Chief Executive Officer
        reports_to: director
        provider: claude-code
        model: claude-sonnet-4-5
        network: proxy
        heartbeat: "*/30 * * * *"
        budget:
          monthly_usd: 0.00
          alert_at_pct: 80
        skills: [glorbo]
        permissions:
          - projects:read:*
          - tasks:create:*
          - chat:write:general
        ---
        # CEO

        System prompt body goes here.
        """
      ]
    }
  end
end
