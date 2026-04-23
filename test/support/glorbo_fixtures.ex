defmodule Glorbo.Test.Fixtures do
  @moduledoc """
  Fixture seeder for Phase 4 LiveView integration tests.

  `seed_acme/1` plants a minimal but fully-shaped company tree at
  `<base>/companies/acme/` with:

    * `company.md` frontmatter (name: acme)
    * one agent `ceo` with canonical directory layout
      (inbox, outbox, workspace, history, state + empty stdout.log)
    * one channel `general.md`
    * one project `website` with one task `t-01.md` flagged
      `requires_approval: director`
    * one seed audit entry in `audit/2026-04.jsonl`

  Every downstream Wave 1 LV test uses this fixture so the mount-time
  filesystem reads succeed out of the box.
  """

  @type seed_result :: %{base: Path.t(), company: String.t()}

  @doc """
  Plant the acme fixture under `base`. Returns the seed context
  (`%{base: base, company: "acme"}`).

  > **Phase 5 note.** For portability + backup/restore tests, prefer
  > `Glorbo.Test.PortabilityFixtures.write_minimal_company/3` — it stages
  > a DB + cookie-stable config.md and omits the kanban/approval fixtures
  > which the portability suite doesn't exercise.
  """
  @spec seed_acme(Path.t()) :: seed_result()
  def seed_acme(base) do
    co = Path.join([base, "companies", "acme"])
    File.mkdir_p!(co)

    File.write!(Path.join(co, "company.md"), """
    ---
    name: acme
    mission: "Build the Plumbus"
    ---

    # acme
    """)

    agent_dir = Path.join([co, "agents", "ceo"])

    Enum.each(
      ~w(inbox outbox workspace history state),
      &File.mkdir_p!(Path.join(agent_dir, &1))
    )

    File.write!(Path.join(agent_dir, "stdout.log"), "")

    File.write!(Path.join(agent_dir, "AGENT.md"), """
    ---
    kind: agent/v1
    name: CEO
    slug: ceo
    role: "Chief Executive Officer"
    provider: claude-code
    model: claude-sonnet-4-5
    network: loopback
    heartbeat: null
    permissions:
      - projects:read:*
      - chat:write:general
      - chat:read:*
    budget:
      monthly_usd: 10.00
    skills: []
    ---

    # CEO
    You run acme.
    """)

    File.mkdir_p!(Path.join(co, "channels"))
    File.write!(Path.join([co, "channels", "general.md"]), "# general\n")

    tasks_dir = Path.join([co, "projects", "website", "tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([co, "projects", "website", "project.md"]), """
    ---
    name: website
    status: active
    ---

    # website
    """)

    File.write!(Path.join(tasks_dir, "t-01.md"), """
    ---
    kind: task/v1
    title: "Deploy landing page"
    status: pending
    assigned_to: ceo
    requires_approval: director
    ---

    Ship it.
    """)

    File.mkdir_p!(Path.join(co, "audit"))
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    File.write!(
      Path.join([co, "audit", "2026-04.jsonl"]),
      Jason.encode!(%{
        ts: now,
        actor: "system",
        action: "company.create",
        target: "acme",
        detail: %{}
      }) <> "\n"
    )

    %{base: base, company: "acme"}
  end
end
