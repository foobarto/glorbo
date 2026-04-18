defmodule Glorbo.CLI.Scaffold.Agent do
  @moduledoc """
  `glorbo new agent <company>/<slug> [--role R] [--provider P]
  [--template T] [--reports-to R]` — D-12: scaffold an agent
  directory inside a company.

  Two modes:

    * **Default** (no `--template`) — writes a minimal AGENT.md with
      the D-12 contract defaults.
    * **Templated** (`--template <name>`) — renders a template from
      `priv/templates/agents/<name>.md` (or
      `~/.glorbo/templates/agents/<name>.md` if the user shadows the
      built-in — GEP-10 D5). Supported template names come from
      `Glorbo.CLI.Scaffold.TemplateRegistry.list(:agent)`.

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
  alias Glorbo.CLI.Scaffold.Renderer
  alias Glorbo.CLI.Scaffold.SystemPrompt
  alias Glorbo.CLI.Scaffold.TemplateRegistry

  @slug_re ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @switches [
    role: :string,
    provider: :string,
    template: :string,
    reports_to: :string,
    help: :boolean
  ]

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
    case resolve_template(opts) do
      {:ok, nil} -> scaffold_default(company, agent, opts, co_path)
      {:ok, entry} -> scaffold_from_template(company, agent, opts, co_path, entry)
      {:error, msg} -> {:new_agent, 1, msg}
    end
  end

  # Default scaffold — pre-GEP-10 behaviour. Used when no `--template`
  # is passed; preserves backward compatibility for every caller that
  # scaffolds without picking a role template.
  defp scaffold_default(company, agent, opts, co_path) do
    Audit.emit("new_agent", "start", %{company: company, agent: agent, template: nil})

    ag_path = prepare_agent_dir(co_path, agent)

    role = opts[:role] || "Agent"
    provider = opts[:provider] || "claude-code"

    File.write!(Path.join(ag_path, "AGENT.md"), """
    ---
    name: #{String.upcase(agent)}
    slug: #{agent}
    role: "#{role}"
    provider: #{provider}
    model: claude-sonnet-4-5
    network: api-only
    heartbeat: null
    permissions:
      - projects:read:*
      - chat:read:*
    budget:
      monthly_usd: 10.00
    skills: []
    ---

    # #{String.upcase(agent)}

    Scaffolded by `glorbo new agent #{company}/#{agent}`.

    #{SystemPrompt.reply_contract()}
    """)

    File.write!(Path.join(ag_path, "HEARTBEAT.md"), """
    # Heartbeat — #{agent}

    Check your inbox. Reply to anything that needs attention.
    Otherwise exit cleanly.
    """)

    Audit.emit("new_agent", "complete", %{
      company: company,
      agent: agent,
      role: role,
      provider: provider,
      path: ag_path,
      template: nil
    })

    {:new_agent, 0, "✓ created agent: #{ag_path}\n"}
  end

  # Template-backed scaffold (GEP-10). The template file supplies every
  # frontmatter field; the Director's CLI flags (`--provider`,
  # `--reports-to`) only feed the variable map for `{{ var }}`
  # substitution. `--role` is ignored in template mode — the template
  # declares the role.
  defp scaffold_from_template(company, agent, opts, co_path, entry) do
    Audit.emit("new_agent", "start", %{company: company, agent: agent, template: entry.name})

    ag_path = prepare_agent_dir(co_path, agent)

    vars =
      Renderer.build_vars(
        slug: agent,
        company: company,
        provider: opts[:provider],
        reports_to: opts[:reports_to]
      )

    rendered =
      entry.path
      |> File.read!()
      |> Renderer.render(vars)

    File.write!(Path.join(ag_path, "AGENT.md"), rendered)

    # GEP-15 extension (task #118): SOUL.md for tone + character. We
    # look up a soul template with the same name as the agent template;
    # missing = no soul file (the Director can write one later).
    maybe_write_soul(ag_path, entry.name, vars)

    File.write!(Path.join(ag_path, "HEARTBEAT.md"), """
    # Heartbeat — #{agent}

    Check your inbox. Reply to anything that needs attention.
    Otherwise exit cleanly.
    """)

    Audit.emit("new_agent", "complete", %{
      company: company,
      agent: agent,
      role: "(from template)",
      provider: vars.provider,
      path: ag_path,
      template: entry.name
    })

    missing_skills = detect_missing_skills(rendered, co_path)

    message =
      case missing_skills do
        [] ->
          "✓ created agent: #{ag_path} (template: #{entry.name})\n"

        skills ->
          lines =
            Enum.map(skills, fn s ->
              "  glorbo new skill #{company} #{s} --template #{s}"
            end)

          "✓ created agent: #{ag_path} (template: #{entry.name})\n" <>
            "⚠ template references skills not present in this company. Scaffold them:\n" <>
            Enum.join(lines, "\n") <> "\n"
      end

    {:new_agent, 0, message}
  end

  defp prepare_agent_dir(co_path, agent) do
    ag_path = Path.join([co_path, "agents", agent])
    File.mkdir_p!(ag_path)

    # D-12 canonical sub-dirs — same shape as PortabilityFixtures +
    # seed_acme/1 so Glorbo.Agent.Parser and the runtime consumers find
    # the expected layout.
    Enum.each(~w(inbox outbox workspace history state), &File.mkdir_p!(Path.join(ag_path, &1)))

    File.write!(Path.join(ag_path, "stdout.log"), "")
    ag_path
  end

  # Resolve the `--template` flag through TemplateRegistry. Returns
  # {:ok, nil} when absent (use default), {:ok, entry} when resolved,
  # or an error string with the list of available names.
  defp resolve_template(opts) do
    case opts[:template] do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      name ->
        case TemplateRegistry.fetch(:agent, name) do
          {:ok, entry} ->
            {:ok, entry}

          {:error, :not_found} ->
            available =
              TemplateRegistry.list(:agent)
              |> Enum.map(& &1.name)

            msg =
              "Unknown agent template: #{inspect(name)}\n" <>
                "Available: #{Enum.join(available, ", ")}\n"

            {:error, msg}
        end
    end
  end

  # Extract the `skills:` list from rendered frontmatter and return
  # names whose file doesn't exist under `<company>/skills/`. Best-
  # effort regex; if frontmatter parsing gets complex later this
  # should switch to `Glorbo.Filesystem.Frontmatter.parse/1`.
  defp detect_missing_skills(rendered, co_path) do
    case Regex.run(~r/^skills:\s*\n((?:\s*-\s*\S+\s*\n)+)/m, rendered) do
      [_full, block] ->
        block
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/-\s*([a-z][a-z0-9_-]{0,63})/, line) do
            [_, name] -> [name]
            _ -> []
          end
        end)
        |> Enum.reject(fn name ->
          File.exists?(Path.join([co_path, "skills", "#{name}.md"]))
        end)

      _ ->
        []
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
  end

  defp usage do
    {:new_agent, 1,
     "Usage: glorbo new agent <company>/<slug> [--role R] [--provider P]" <>
       " [--template T] [--reports-to R]\n"}
  end

  # task #118 — SOUL.md is a sibling of AGENT.md carrying tone + voice
  # rather than prescriptive rules. Ships per agent template under
  # priv/templates/souls/<name>.md; missing template = no file written
  # (user can author one later).
  defp maybe_write_soul(ag_path, template_name, vars) do
    soul_path = Path.join([:code.priv_dir(:glorbo), "templates/souls", "#{template_name}.md"])

    if File.exists?(soul_path) do
      rendered =
        soul_path
        |> File.read!()
        |> Renderer.render(vars)

      File.write!(Path.join(ag_path, "SOUL.md"), rendered)
    end

    :ok
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new agent — scaffold a new agent inside a company.

    USAGE
      glorbo new agent <company>/<slug> [--role R] [--provider P]
                                        [--template T] [--reports-to R]

    FLAGS
      --template T     Scaffold from a GEP-10 role template (see
                       `glorbo templates list agent`).
      --role R         Set `role:` in frontmatter. Ignored when
                       `--template` is used (template owns role).
      --provider P     Override the provider field (default: claude-code).
      --reports-to R   Fill `{{ reports_to }}` in a template (default:
                       director). Ignored without --template.

    DEFAULTS (D-12, no-template mode)
      role=Agent, provider=claude-code, model=claude-sonnet-4-5,
      network=api-only, permissions=[projects:read:*, chat:read:*],
      budget.monthly_usd=10.00, skills=[], heartbeat=null

    COMPANY
      Must already exist — run `glorbo new company <company>` first.
    """
  end
end
