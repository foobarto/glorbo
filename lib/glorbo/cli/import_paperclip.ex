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

  # Gemini round-6 finding (PR #38, MED): the previous shape called
  # `File.mkdir_p!` on `~/.glorbo/companies/<slug>` (and child dirs)
  # without lstat-checking that the parents weren't symlinks. The
  # source side has C-098 lstat guards (good), but the destination
  # side didn't. A prior compromise that plants
  # `~/.glorbo/companies/<slug>` as a symlink to an attacker-
  # controlled dir would land the importer's writes (`AGENT.md`,
  # `HEARTBEAT.md`, etc.) in the attacker's tree. Mostly an
  # integrity/persistence issue; close it.
  defp ensure_company_dirs(co) do
    :ok = ensure_real_dest_dir!(co)
    File.mkdir_p!(co)

    Enum.each(~w(agents projects channels audit), fn sub ->
      sub_path = Path.join(co, sub)
      :ok = ensure_real_dest_dir!(sub_path)
      File.mkdir_p!(sub_path)
    end)
  end

  # Raises if `path` exists and is NOT a real directory (i.e.
  # it's a symlink or any non-dir type) OR if ANY existing
  # ancestor segment is a symlink. The earlier shape only
  # lstat'd the leaf — codex review of 7e750cd caught the
  # commit-message-vs-code mismatch: if `~/.glorbo/companies/`
  # itself were a symlink, the leaf returns `:enoent`, the
  # function returned `:ok`, and `mkdir_p!` followed the parent
  # link. Now walks every ancestor segment with lstat before
  # green-lighting the mkdir. Mirror the round-3 SymlinkGuard
  # shape used by sandbox/PermissionMapper.
  defp ensure_real_dest_dir!(path) do
    expanded = Path.expand(path)

    # Walk from root down. For each ancestor segment that EXISTS,
    # require it to be a real directory (no symlink, no
    # non-directory). Missing segments are fine — mkdir_p! will
    # create them. Bind the reduce result explicitly so credo
    # doesn't flag the side-effect-only walk as unused-return.
    _walked =
      expanded
      |> Path.split()
      |> Enum.reduce("", fn seg, acc ->
        candidate = if acc == "", do: seg, else: Path.join(acc, seg)
        :ok = check_dest_segment!(candidate)
        candidate
      end)

    :ok
  end

  defp check_dest_segment!("/"), do: :ok

  defp check_dest_segment!(seg) do
    case File.lstat(seg) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        # `:eloop` ("too many symbolic links") matches the
        # canonical OS wording for the failure we're refusing
        # (Copilot review on PR #38: only surface :eloop for
        # actual symlinks — non-symlink non-directory ancestor
        # types use :enotdir below).
        raise File.Error,
          reason: :eloop,
          action: "import_paperclip: refusing to mkdir under a symlinked ancestor",
          path: seg

      {:ok, %File.Stat{type: other}} ->
        raise File.Error,
          reason: :enotdir,
          action:
            "import_paperclip: refusing to mkdir under a non-directory ancestor (#{other})",
          path: seg

      {:error, :enoent} ->
        # Missing intermediate is fine; mkdir_p! creates fresh.
        :ok

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "import_paperclip: lstat destination ancestor",
          path: seg
    end
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
          # C-098: a paperclip source tree is operator-supplied but may
          # be attacker-authored (supply chain). `File.dir?`/
          # `File.exists?`/`File.read!` all follow symlinks, so a
          # symlinked agent dir or `AGENTS.md -> ~/.glorbo/config.md`
          # would be copied verbatim into company data. Refuse any
          # symlinked source entry: require the dir AND its AGENTS.md to
          # be real (lstat-checked) regular dir / file.
          real_dir?(path) and real_file?(Path.join(path, "AGENTS.md"))
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # C-098: lstat-based type checks that do NOT follow symlinks.
  defp real_dir?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp real_file?(path) do
    match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
  end

  # C-098: read a source file only after confirming it's a real
  # regular file (no symlink follow). Raises with a clear reason
  # otherwise so the operator sees the refusal.
  defp read_source_file!(path) do
    if real_file?(path) do
      File.read!(path)
    else
      raise File.Error,
        reason: :eloop,
        action: "read file (refusing to follow symlink / non-regular source)",
        path: path
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

    # PR #38 (gemini round-6): same destination-symlink guard as
    # `ensure_company_dirs/1`. The per-agent dest dir is created
    # here; an attacker-planted symlink at `agents/<slug>` would
    # otherwise redirect the imported AGENT.md + companion writes.
    :ok = ensure_real_dest_dir!(dest)
    File.mkdir_p!(dest)

    Enum.each(~w(inbox outbox workspace history state), fn sub ->
      sub_path = Path.join(dest, sub)
      :ok = ensure_real_dest_dir!(sub_path)
      File.mkdir_p!(sub_path)
    end)

    # C-098: only read source files that lstat as real regular files —
    # never follow a symlinked `AGENTS.md` / companion into a host
    # secret (`~/.glorbo/config.md`, provider creds, SSH keys).
    body = read_source_file!(Path.join(src_agent_dir, "AGENTS.md"))
    hints = detect_hints(body)

    File.write!(Path.join(dest, "AGENT.md"), wrap_agent_md(agent_slug, co_slug, body))

    for fname <- ~w(HEARTBEAT.md SOUL.md TOOLS.md) do
      src_file = Path.join(src_agent_dir, fname)

      if real_file?(src_file) do
        content = File.read!(src_file)
        _ = detect_hints(content)
        File.write!(Path.join(dest, fname), wrap_companion_md(fname, content))
      end
    end

    {:ok, hints}
  end

  # GEP-25 R26.2b: every Glorbo-recognised file needs a `kind:`
  # discriminator in frontmatter. Paperclip's source files don't
  # have one — wrap on copy. `TOOLS.md` is "unknown_file" by
  # Glorbo's classifier (kept as paperclip-specific reference per
  # the importer's contract); leave it raw.
  defp wrap_companion_md("HEARTBEAT.md", body),
    do: "---\nkind: agent-heartbeat/v1\n---\n\n" <> body

  defp wrap_companion_md("SOUL.md", body), do: "---\nkind: agent-soul/v1\n---\n\n" <> body
  defp wrap_companion_md(_other, body), do: body

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
