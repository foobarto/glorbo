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
    * `network:` — `"proxy"`.
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

  @doc """
  Public scaffold entry — same effect as `glorbo new agent <co>/<ag>`
  with the given flags. `opts[:base]` lets non-CLI callers (MCP,
  tests) target a non-default `GLORBO_HOME`.
  """
  @spec scaffold(String.t(), String.t(), keyword()) :: {:new_agent, 0 | 1, String.t()}
  def scaffold(company, agent, opts)
      when is_binary(company) and is_binary(agent) and is_list(opts) do
    base = Keyword.get(opts, :base) || glorbo_home()
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

    # threatmodel M12: role/provider/model flow verbatim into
    # AGENT.md frontmatter. Rejecting newlines / `"` / `---` here
    # prevents frontmatter-injection even if a caller skipped the
    # Actions-layer validator (defense in depth).
    role = sanitize_yaml_scalar(opts[:role] || "Agent", "Agent")
    provider = sanitize_yaml_scalar(opts[:provider] || "claude-code", "claude-code")
    model = sanitize_yaml_scalar(opts[:model] || "claude-sonnet-4-5", "claude-sonnet-4-5")

    File.write!(Path.join(ag_path, "AGENT.md"), """
    ---
    kind: agent/v1
    slug: #{agent}
    name: #{String.upcase(agent)}
    role: "#{role}"
    provider: #{provider}
    model: #{model}
    network: proxy
    heartbeat: null
    # threatmodel M21: scaffolded agents start with zero
    # permissions. Grant narrowly scoped access (e.g.
    # `projects:read:<project-slug>`) by editing AGENT.md; don't
    # leave the default `:*` wildcards that let every fresh agent
    # read every project and chat log.
    permissions: []
    budget:
      monthly_usd: 10.00
    skills:
      - glorbo
    ---

    # #{String.upcase(agent)}

    Scaffolded by `glorbo new agent #{company}/#{agent}`.

    ## Provenance in every output

    When you include a number, date, fact, or quote in any output
    (reply, task body, channel message), say where it came from:

    - **tool** — from a command / file read / web fetch during
      this invocation. Name the source (command, path, URL).
    - **memory** — from training. Mark with `(from memory)`.

    Unsourced specifics are worse than absent ones. When in doubt,
    default to the `memory` tag.

    #{SystemPrompt.reply_contract()}
    """)

    File.write!(Path.join(ag_path, "HEARTBEAT.md"), """
    ---
    kind: agent-heartbeat/v1
    ---
    # HEARTBEAT — #{agent}

    Read `AGENT.md` first. Read `SOUL.md` for tone.

    Check your inbox. Reply to anything that needs attention.
    Otherwise write a one-line "no action" summary to
    `$GLORBO_REPLY_PATH` and exit cleanly.

    ## Self-improvement

    You are expected to improve yourself between wakes. Your
    instructions (`AGENT.md`), your voice (`SOUL.md`), and your
    memory (`memory/MEMORY.md` + `memory/<type>_<topic>.md`) are
    editable — treat them as living documents.

    Learn continuously from your own work, director corrections,
    peer agents' task comments and chat messages, and web
    research. Capture patterns as `feedback_<topic>.md` memory
    entries; reusable references as `reference_<topic>.md`; project
    context as `project_<topic>.md`.

    Drop memory writes in `outbox/memory/` per GEP-21 (frontmatter:
    `kind: agent-memory/v1`, `type:` matching filename prefix,
    `name:` + `description:` for the index). Edit `AGENT.md` or
    `SOUL.md` only when an insight is stable enough to change your
    approach to *every* task — ephemeral lessons go in memory.
    """)

    # SOUL.md is the tone/voice sibling to AGENT.md (task #118). The
    # template-backed path resolves it from `priv/templates/souls/<t>.md`;
    # the default path had no SOUL.md at all, which left AgentLive's
    # contract-files panel showing a `+ CREATE` placeholder for every
    # freshly-scaffolded agent. Give the default path a minimal SOUL.md
    # so the three canonical files (AGENT / HEARTBEAT / SOUL) are always
    # present after scaffold (PLAN P1-4).
    File.write!(Path.join(ag_path, "SOUL.md"), """
    ---
    kind: agent-soul/v1
    ---
    # SOUL — #{agent}

    Tone and voice for #{String.upcase(agent)}. Keep it short, direct,
    and human. Write in first person. Prefer concrete over abstract.

    Edit this file to shape how the agent speaks in channel messages
    and task comments. The reply contract in `AGENT.md` still governs
    the final deliverable; `SOUL.md` governs the *feel*.
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

    # GEP-14: HEARTBEAT.md drives the tick-by-tick action loop. When a
    # role-specific heartbeat exists (e.g. CEO's company-stewardship
    # checklist), use it; otherwise fall back to the minimal default.
    maybe_write_heartbeat(ag_path, agent, entry.name, vars)

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

  # threatmodel M12: trim + reject anything that would break out
  # of a YAML scalar (newline, double-quote, backslash, `---` run,
  # NUL, control chars, `>` `|` block-scalar indicators). Fall back
  # to the sanitized default rather than raising so a misbehaving
  # caller still gets a well-formed AGENT.md with a safe baseline.
  @yaml_scalar_bad_re ~r/[\x00-\x1f"\n\r\\\|>]|---/

  defp sanitize_yaml_scalar(value, fallback) do
    str = value |> to_string() |> String.trim()

    cond do
      str == "" -> fallback
      Regex.match?(@yaml_scalar_bad_re, str) -> fallback
      String.length(str) > 128 -> fallback
      true -> str
    end
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
          # Present if the Director has shadowed it under the company's
          # own `skills/` dir, OR if we ship it as a builtin (matches
          # `Glorbo.Skills.Resolver.resolve_skill_src/3`).
          File.exists?(Path.join([co_path, "skills", "#{name}.md"])) or
            File.exists?(
              Path.join([Application.app_dir(:glorbo, "priv/templates/skills"), "#{name}.md"])
            )
        end)

      _ ->
        []
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
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

  # GEP-14 extension: role-specific HEARTBEAT.md templates. Ships under
  # priv/templates/heartbeats/<name>.md; missing template falls through
  # to the minimal default so every agent still gets a heartbeat file.
  defp maybe_write_heartbeat(ag_path, agent, template_name, vars) do
    template_path =
      Path.join([:code.priv_dir(:glorbo), "templates/heartbeats", "#{template_name}.md"])

    content =
      if File.exists?(template_path) do
        template_path
        |> File.read!()
        |> Renderer.render(vars)
      else
        """
        ---
        kind: agent-heartbeat/v1
        ---
        # HEARTBEAT — #{agent}

        Read `AGENT.md` first. Read `SOUL.md` for tone.

        ## Tick-by-tick checklist

        1. **Inbox.** Check `agents/#{agent}/inbox/`. Reply to anything
           that needs attention.
        2. **Kanban board.** Scan `projects/*/tasks/*.md` for tasks
           assigned to you (`assigned_to: #{agent}`) or mentioning you
           that are not `status: done|closed|cancelled`. Pick up work
           that is `todo` or `in_progress`. Groom blocked tasks —
           unblock them, reassign, or escalate.
        3. **Reply.** Write a one-line summary to `$GLORBO_REPLY_PATH`
           even if there is nothing to do.

        ## Self-improvement

        You are expected to improve yourself between wakes. Your
        instructions (`AGENT.md`), your voice (`SOUL.md`), and your
        memory (`memory/MEMORY.md` + `memory/<type>_<topic>.md`)
        are editable. Capture patterns as `feedback_<topic>.md`
        memory entries, references as `reference_<topic>.md`,
        project context as `project_<topic>.md`. Drop writes in
        `outbox/memory/` per GEP-21.
        """
      end

    File.write!(Path.join(ag_path, "HEARTBEAT.md"), content)
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
      network=proxy, permissions=[] (edit AGENT.md to grant
      project/chat access — no broad reads by default),
      budget.monthly_usd=10.00, skills=[], heartbeat=null

    COMPANY
      Must already exist — run `glorbo new company <company>` first.
    """
  end
end
