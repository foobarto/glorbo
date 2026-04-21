defmodule Glorbo.Init.ExampleCompany do
  @moduledoc """
  Scaffolds the `acme` example company (D-10).

  Creates the full DESIGN.md §3 tree for a single company with:

    * `company.md` with `name: acme` and a short mission
    * `agents/ceo/AGENT.md` with `provider: claude-code`,
      `network: api-only` (CLI providers need egress to their LLM
      endpoint), default model `claude-sonnet-4-5`
    * `agents/ceo/HEARTBEAT.md` (GEP-14) — cron-wake instructions
    * `channels/general.md` (default company-wide channel)
    * `goals/q3-2026.md` (simple active goal)
    * Empty `agents/ceo/{inbox,outbox,workspace,history}` dirs

  Idempotent (D-19): running twice does NOT overwrite. Returns
  `:already_exists` on second call.
  """

  @company_md ~s"""
  ---
  kind: company/v1
  slug: acme
  name: acme
  mission: Ship small useful things; learn what Glorbo makes easy.
  created_at: 2026-04-16
  ---
  # acme

  An example company scaffolded by `glorbo init`. Edit freely or delete and
  start over — it is just a directory.
  """

  alias Glorbo.CLI.Scaffold.SystemPrompt

  defp ceo_agent_md do
    """
    ---
    kind: agent/v1
    slug: ceo
    name: ceo
    role: Chief Executive Officer
    reports_to: director
    provider: claude-code
    model: claude-sonnet-4-5
    budget:
      monthly_usd: 0.00
      alert_at_pct: 80
    heartbeat: "*/30 * * * *"
    network: api-only
    skills: []
    permissions:
      - projects:read:*
      - tasks:create:*
      - chat:write:general
      - chat:read:*
    ---
    ## System Prompt

    You are the CEO of acme. Your mission: ship small useful things.

    #{SystemPrompt.reply_contract()}
    """
  end

  defp ceo_heartbeat_md do
    ~s"""
    ---
    kind: agent-heartbeat/v1
    ---
    # Heartbeat — ceo

    Every 30 minutes:

    1. Check your inbox. If anything is urgent, reply via outbox.
    2. Skim the audit tail for `approval.denied` or `agent.error`
       events; if any, post a brief summary in `#general`.
    3. If the monthly budget used is > 80%, ping @director.
    4. Otherwise: exit cleanly. A quiet heartbeat is a good heartbeat.
    """
  end

  @general_channel_md ~s"""
  ---
  kind: channel-log/v1
  channel: general
  ---
  # general

  Default company-wide channel. Append-only; Elixir is the sole writer.
  """

  @goal_md ~s"""
  ---
  kind: goal/v1
  id: q3-2026
  name: Q3 2026
  status: active
  ---
  # Q3 2026

  Ship a thing. Learn a thing. Repeat.
  """

  @type result :: :ok | :already_exists

  @spec scaffold!(keyword()) :: result()
  def scaffold!(opts) do
    base = Keyword.fetch!(opts, :base)
    company_dir = Path.join([base, "companies", "acme"])
    sentinel = Path.join(company_dir, "company.md")

    if File.exists?(sentinel) do
      :already_exists
    else
      for sub <- [
            "agents/ceo/inbox",
            "agents/ceo/outbox",
            "agents/ceo/workspace",
            "agents/ceo/history",
            "channels",
            "projects",
            "goals",
            "skills",
            "audit"
          ] do
        File.mkdir_p!(Path.join(company_dir, sub))
      end

      File.write!(sentinel, @company_md)
      File.write!(Path.join(company_dir, "agents/ceo/AGENT.md"), ceo_agent_md())
      File.write!(Path.join(company_dir, "agents/ceo/HEARTBEAT.md"), ceo_heartbeat_md())
      File.write!(Path.join(company_dir, "channels/general.md"), @general_channel_md)
      File.write!(Path.join(company_dir, "goals/q3-2026.md"), @goal_md)
      File.touch!(Path.join(company_dir, "agents/ceo/stdout.log"))
      :ok
    end
  end
end
