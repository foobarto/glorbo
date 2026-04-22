defmodule Glorbo.CLI.ImportPaperclip do
  @moduledoc """
  `glorbo import paperclip <src> [--as <slug>]` — import a paperclip.ai
  `agentcompanies` tree into a Glorbo company directory.

  Paperclip's on-disk layout (observed 2026-04-19 against
  paperclipai/companies:main):

      <src>/
        <agent-slug>/
          AGENTS.md       — system prompt
          HEARTBEAT.md    — per-tick checklist
          SOUL.md         — tone + character
          TOOLS.md        — tool manifest (paperclip-specific)

  Glorbo's layout (GEP-3 / GEP-15):

      companies/<slug>/
        company.md
        agents/<agent-slug>/
          AGENT.md        — system prompt with Glorbo frontmatter
          HEARTBEAT.md
          SOUL.md
          TOOLS.md        — preserved verbatim for reference; Glorbo
                            doesn't use this file but leaves it
                            in place so the Director can see what
                            the upstream template expected.
        projects/
        channels/
        audit/

  ## What the importer does

    1. Validate `<src>` is a directory.
    2. Pick a target slug (`--as <slug>`, default: `Path.basename(src)`).
    3. Refuse if the target company directory already exists, unless
       `--force` is passed. (`--force` overwrites only `agents/` and
       leaves `projects/`, `channels/`, and `audit/` intact.)
    4. Scaffold the target company dir (same shape as
       `glorbo new company`).
    5. For each sub-directory of `<src>` that contains an `AGENTS.md`:
       * Wrap the body in Glorbo frontmatter (name / slug / role /
         provider / model / network: proxy / heartbeat: null /
         permissions: []).
       * Write to `agents/<slug>/AGENT.md`.
       * Copy `HEARTBEAT.md`, `SOUL.md`, `TOOLS.md` verbatim.
    6. Emit audit events (`import.paperclip.start`,
       `import.paperclip.agent`, `import.paperclip.complete`).
    7. Return a summary that names every paperclip-specific reference
       the Director should review (HTTP API calls, `$AGENT_HOME`
       env var, `paperclip-*` skills) since Glorbo doesn't expose
       those.

  Agents aren't automatically booted after import. The Director runs
  `glorbo up` separately and the dashboard surfaces the new roster on
  next reindex.
  """

  alias Glorbo.CLI.Audit

  @slug_re ~r/\A[a-z0-9-]+\z/

  # Elixir 1.18 cannot escape compiled Regex structs into module
  # attributes (Reference-typed internals don't survive beam-term
  # encoding). Store the source strings here and compile on demand
  # in `detect_hints/1`. Cheap — the module is loaded once per CLI
  # invocation and regex compile at runtime is microseconds.
  @paperclip_hints [
    {"\\$AGENT_HOME",
     "paperclip's `$AGENT_HOME` — Glorbo agents work relative to their sandbox root (`/workspace`, `/inbox`, `/outbox`)"},
    {"PAPERCLIP_[A-Z_]+",
     "paperclip environment variables not set by Glorbo (wake triggers come from `inbox/` / `state/wake-request.md` instead)"},
    {"paperclip-[a-z-]+",
     "paperclip-specific skill (Glorbo skills live under `skills/` per company — install manually or leave as reference)"},
    {"/api/[a-z/{}\\-]+",
     "paperclip HTTP API call (Glorbo has no HTTP control plane for agents; use the filesystem directly)"},
    {"POST /api|GET /api", "paperclip HTTP API call (see above)"}
  ]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: usage()
  def run(["--help" | _]), do: {:import_paperclip, 0, help_text()}
  def run(["-h" | _]), do: {:import_paperclip, 0, help_text()}

  def run(argv) do
    {opts, pos, _} =
      OptionParser.parse(argv,
        strict: [as: :string, force: :boolean],
        aliases: [a: :as, f: :force]
      )

    case pos do
      [src] -> do_import(src, opts)
      _ -> usage()
    end
  end

  defp do_import(src, opts) do
    src = Path.expand(src)

    if File.dir?(src) do
      slug = opts[:as] || Path.basename(src)

      if slug =~ @slug_re do
        do_scaffold(src, slug, opts[:force] == true)
      else
        {:import_paperclip, 1,
         "Invalid slug: '#{slug}'. Use --as <slug> with lowercase letters, digits, hyphens only.\n"}
      end
    else
      {:import_paperclip, 1, "Not a directory: #{src}\n"}
    end
  end

  defp do_scaffold(src, slug, force?) do
    base = glorbo_home()
    co = Path.join([base, "companies", slug])

    if File.exists?(co) and not force? do
      {:import_paperclip, 1,
       "Target exists: #{co}\nRe-run with --force to overwrite its agents/ dir.\n"}
    else
      do_scaffold_fresh(src, slug, co, force?)
    end
  end

  defp do_scaffold_fresh(src, slug, co, force?) do
    Audit.emit("import_paperclip", "start", %{source: src, target: slug, force: force?})

    ensure_company_dirs(co)
    write_company_md_if_missing(co, slug)

    agent_dirs = discover_agents(src)

    {imported, hints} =
      Enum.reduce(agent_dirs, {[], MapSet.new()}, fn agent_src, {imported_acc, hints_acc} ->
        agent_slug = Path.basename(agent_src)

        case import_agent(agent_src, co, agent_slug, slug) do
          {:ok, agent_hints} ->
            Audit.emit("import_paperclip", "agent", %{
              source: agent_src,
              target: Path.join([co, "agents", agent_slug])
            })

            {[agent_slug | imported_acc], MapSet.union(hints_acc, agent_hints)}

          {:error, reason} ->
            Audit.emit("import_paperclip", "agent_skipped", %{
              source: agent_src,
              reason: inspect(reason)
            })

            {imported_acc, hints_acc}
        end
      end)

    Audit.emit("import_paperclip", "complete", %{
      target: slug,
      agents_imported: length(imported)
    })

    {:import_paperclip, 0, render_report(co, slug, imported, hints)}
  end

  defp ensure_company_dirs(co) do
    File.mkdir_p!(co)
    Enum.each(~w(agents projects channels audit), &File.mkdir_p!(Path.join(co, &1)))
  end

  defp write_company_md_if_missing(co, slug) do
    path = Path.join(co, "company.md")

    if File.exists?(path) do
      :ok
    else
      File.write!(path, """
      ---
      kind: company/v1
      slug: #{slug}
      name: #{slug}
      mission: ""
      imported_from: paperclip
      ---

      # #{slug}

      Imported from a paperclip `agentcompanies` tree. The Director
      should review each agent's AGENT.md and TOOLS.md — paperclip
      uses an HTTP control plane and `$AGENT_HOME` conventions that
      Glorbo does not expose. See the import report on your CLI for
      the specific references that need hand-fixing.
      """)
    end
  end

  defp discover_agents(src) do
    case File.ls(src) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(src, &1))
        |> Enum.filter(fn path ->
          File.dir?(path) and File.exists?(Path.join(path, "AGENTS.md"))
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp import_agent(src_agent_dir, co, agent_slug, co_slug) do
    if agent_slug =~ @slug_re do
      do_import_agent(src_agent_dir, co, agent_slug, co_slug)
    else
      {:error, :invalid_agent_slug}
    end
  end

  defp do_import_agent(src_agent_dir, co, agent_slug, co_slug) do
    dest = Path.join([co, "agents", agent_slug])
    Enum.each(~w(inbox outbox workspace history state), &File.mkdir_p!(Path.join(dest, &1)))
    File.mkdir_p!(dest)

    body = File.read!(Path.join(src_agent_dir, "AGENTS.md"))
    hints = detect_hints(body)

    File.write!(Path.join(dest, "AGENT.md"), wrap_agent_md(agent_slug, co_slug, body))

    for fname <- ~w(HEARTBEAT.md SOUL.md TOOLS.md) do
      src_file = Path.join(src_agent_dir, fname)

      if File.exists?(src_file) do
        content = File.read!(src_file)
        _ = detect_hints(content)
        File.write!(Path.join(dest, fname), content)
      end
    end

    {:ok, hints}
  end

  defp wrap_agent_md(agent_slug, co_slug, body) do
    """
    ---
    kind: agent/v1
    slug: #{agent_slug}
    name: #{agent_slug}
    role: "(imported — edit me)"
    reports_to: director
    provider: claude-code
    model: claude-sonnet-4-5
    network: proxy
    heartbeat: null
    budget:
      monthly_usd: 20.00
    skills: []
    permissions:
      - projects:read:*
      - tasks:read:*
      - chat:read:*
      - chat:write:general
    imported_from: paperclip
    imported_company: #{co_slug}
    ---

    #{body}
    """
  end

  defp detect_hints(content) do
    Enum.reduce(@paperclip_hints, MapSet.new(), fn {pattern, hint}, acc ->
      re = Regex.compile!(pattern)
      if Regex.match?(re, content), do: MapSet.put(acc, hint), else: acc
    end)
  end

  defp render_report(co, slug, imported, hints) do
    count = length(imported)
    header = "✓ imported paperclip company -> #{co}\n"
    agent_line = "   agents: #{count} (#{Enum.join(Enum.sort(imported), ", ")})\n"

    hint_block =
      case MapSet.to_list(hints) do
        [] ->
          ""

        list ->
          "\nReview the following paperclip-isms in the imported content:\n" <>
            Enum.map_join(list, "", fn h -> "  - #{h}\n" end) <>
            "\nEach imported AGENT.md carries `imported_from: paperclip` in its\n" <>
            "frontmatter so you can grep for them later.\n"
      end

    next_steps =
      "\nNext: open `companies/#{slug}/agents/<slug>/AGENT.md` in your editor,\n" <>
        "set a real role / provider / permissions for each agent, then run\n" <>
        "`glorbo doctor --fix` and `glorbo reindex`.\n"

    header <> agent_line <> hint_block <> next_steps
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  defp usage do
    {:import_paperclip, 1, "Usage: glorbo import paperclip <src-dir> [--as <slug>] [--force]\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo import paperclip — import a paperclip.ai agentcompanies tree.

    USAGE
      glorbo import paperclip <src-dir> [--as <slug>] [--force]

    FLAGS
      --as SLUG        Target company slug. Default: basename of
                       <src-dir>. Must match [a-z0-9-]+.
      --force          Overwrite the target's agents/ directory if
                       the company already exists. Leaves projects/,
                       channels/, and audit/ intact.

    BEHAVIOUR
      Scans <src-dir> for agent directories (any sub-directory
      containing an AGENTS.md). Each agent becomes
      companies/<target>/agents/<agent-slug>/ with:

        AGENT.md       — Glorbo frontmatter wrap + paperclip body
        HEARTBEAT.md   — copied verbatim if present
        SOUL.md        — copied verbatim if present
        TOOLS.md       — copied verbatim if present

      Paperclip uses an HTTP control plane and $AGENT_HOME
      conventions that Glorbo does not expose. The import report
      lists every such reference it found so you can fix them.

    EXAMPLE
      glorbo import paperclip ~/paperclip-templates/default --as mycompany
    """
  end
end
