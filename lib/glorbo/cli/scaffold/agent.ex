defmodule Glorbo.CLI.Scaffold.Agent do
  @moduledoc """
  `glorbo new agent <company>/<slug> [--role R] [--provider P]` — D-12:
  scaffold an agent directory inside a company.

  Frontmatter defaults (D-12 contract — must match
  `Glorbo.Agent.Parser.parse_file/1` expectations):

    * `name:` — slug upcased (e.g. `ceo` → `CEO`).
    * `slug:` — the provided slug.
    * `role:` — `"Agent"` (override via `--role`).
    * `provider:` — `"claude-code"` (override via `--provider`).
    * `model:` — `"claude-sonnet-4-5"`.
    * `network:` — `"api-only"`.
    * `permissions:` — `[]`.
    * `budget.monthly_usd:` — `10.00` (= 1000 ¢/month).
    * `skills:` — `[]`.
    * `heartbeat:` — `null`.

  Company must exist (returns exit 1 naming the `glorbo new company`
  remediation verb on absence, per D-29). Idempotent on the agent
  directory level.
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Scaffold.SystemPrompt

  @slug_re ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @switches [role: :string, provider: :string, help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, positional, _} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] -> {:new_agent, 0, help_text()}
      positional == [] -> usage()
      true -> do_run(hd(positional), opts)
    end
  end

  defp do_run(co_slash_ag, opts) do
    case String.split(co_slash_ag, "/", parts: 2) do
      [company, agent]
      when byte_size(company) > 0 and byte_size(agent) > 0 ->
        if company =~ @slug_re and agent =~ @slug_re do
          scaffold(company, agent, opts)
        else
          {:new_agent, 1, "Invalid slug in '#{co_slash_ag}'. Slug regex: #{inspect(@slug_re)}.\n"}
        end

      _ ->
        usage()
    end
  end

  defp scaffold(company, agent, opts) do
    base = glorbo_home()
    co_path = Path.join([base, "companies", company])

    cond do
      not File.exists?(co_path) ->
        {:new_agent, 1,
         "Company '#{company}' not found. Run `glorbo new company #{company}` first.\n"}

      File.exists?(Path.join([co_path, "agents", agent])) ->
        {:new_agent, 0, "⏭ already exists: #{company}/#{agent}\n"}

      true ->
        do_scaffold(company, agent, opts, co_path)
    end
  end

  defp do_scaffold(company, agent, opts, co_path) do
    Audit.emit("new_agent", "start", %{company: company, agent: agent})

    ag_path = Path.join([co_path, "agents", agent])
    File.mkdir_p!(ag_path)

    # D-12 canonical sub-dirs — same shape as PortabilityFixtures +
    # seed_acme/1 so Glorbo.Agent.Parser and the runtime consumers find
    # the expected layout.
    Enum.each(~w(inbox outbox workspace history state), &File.mkdir_p!(Path.join(ag_path, &1)))

    File.write!(Path.join(ag_path, "stdout.log"), "")

    role = opts[:role] || "Agent"
    provider = opts[:provider] || "claude-code"

    File.write!(Path.join(ag_path, "agent.md"), """
    ---
    name: #{String.upcase(agent)}
    slug: #{agent}
    role: "#{role}"
    provider: #{provider}
    model: claude-sonnet-4-5
    network: api-only
    heartbeat: null
    permissions: []
    budget:
      monthly_usd: 10.00
    skills: []
    ---

    # #{String.upcase(agent)}

    Scaffolded by `glorbo new agent #{company}/#{agent}`.

    #{SystemPrompt.reply_contract()}
    """)

    Audit.emit("new_agent", "complete", %{
      company: company,
      agent: agent,
      role: role,
      provider: provider,
      path: ag_path
    })

    {:new_agent, 0, "✓ created agent: #{ag_path}\n"}
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
  end

  defp usage do
    {:new_agent, 1, "Usage: glorbo new agent <company>/<slug> [--role R] [--provider P]\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new agent — scaffold a new agent inside a company.

    USAGE
      glorbo new agent <company>/<slug> [--role R] [--provider P]

    DEFAULTS (D-12)
      role=Agent, provider=claude-code, model=claude-sonnet-4-5,
      network=api-only, permissions=[], budget.monthly_usd=10.00,
      skills=[], heartbeat=null

    COMPANY
      Must already exist — run `glorbo new company <company>` first.
    """
  end
end
