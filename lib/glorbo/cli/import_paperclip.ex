defmodule Glorbo.CLI.ImportPaperclip do
  @moduledoc """
  `glorbo import paperclip <src> [--as <slug>]` — import a paperclip.ai
  `agentcompanies` tree into a Glorbo company directory.

  Two paperclip source layouts are auto-detected (GEP-54).

  Flat — the `paperclipai/companies:main` git template
  (observed 2026-04-19):

      <src>/
        <agent-slug>/
          AGENTS.md       — system prompt
          HEARTBEAT.md    — per-tick checklist
          SOUL.md         — tone + character
          TOOLS.md        — tool manifest (paperclip-specific)

  Instance — a live paperclip install's company directory
  (observed 2026-06-02 against `~/.paperclip/instances/<id>/
  companies/<uuid>/`):

      <src>/
        agents/
          <agent-uuid>/
            instructions/
              AGENTS.md   — system prompt
              HEARTBEAT.md / SOUL.md / TOOLS.md
            memory/ life/ — NOT imported (GEP-54 D5)
          _templates/     — scaffolding, skipped

  Detection: if `<src>/agents/` is a real directory it becomes the
  agent container; otherwise `<src>` itself is. For each agent dir,
  AGENTS.md is read from `instructions/` if present, else the dir
  root. In the instance layout agents import under their UUID dir
  names — no slug derivation (GEP-54 D2); the Director renames later.

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
    5. For each discovered agent dir (see layout detection above):
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

    agent_dirs = discover_agents(agent_container(src))

    {imported, hints, dropped_aux?} =
      Enum.reduce(agent_dirs, {[], MapSet.new(), false}, fn {agent_src, instr_dir},
                                                            {imported_acc, hints_acc, aux_acc} ->
        agent_slug = Path.basename(agent_src)

        case import_agent(instr_dir, co, agent_slug, slug) do
          {:ok, agent_hints} ->
            Audit.emit("import_paperclip", "agent", %{
              source: agent_src,
              target: Path.join([co, "agents", agent_slug])
            })

            {[agent_slug | imported_acc], MapSet.union(hints_acc, agent_hints),
             aux_acc or uncarried_aux_dirs?(agent_src)}

          {:error, reason} ->
            Audit.emit("import_paperclip", "agent_skipped", %{
              source: agent_src,
              reason: inspect(reason)
            })

            {imported_acc, hints_acc, aux_acc}
        end
      end)

    Audit.emit("import_paperclip", "complete", %{
      target: slug,
      agents_imported: length(imported)
    })

    {:import_paperclip, 0, render_report(co, slug, imported, hints, dropped_aux?)}
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
  # Codex review (GEP-54): `ensure_real_dest_dir!` guards destination
  # *directories*, but the leaf files were written with a plain
  # `File.write!`, which follows symlinks. On a `--force` re-import a
  # pre-planted `companies/<slug>/agents/<agent>/AGENT.md -> /etc/...`
  # symlink would redirect the write outside the company tree. Refuse to
  # write through any pre-existing non-regular file; regular files are
  # overwritten normally (that is what `--force` means). Mirrors the
  # read-side `read_source_file!` refusal.
  defp safe_write!(path, content) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        File.write!(path, content)

      {:error, :enoent} ->
        File.write!(path, content)

      {:ok, %File.Stat{type: :symlink}} ->
        raise File.Error,
          reason: :eloop,
          action: "import_paperclip: refusing to write through a symlinked destination file",
          path: path

      {:ok, %File.Stat{type: other}} ->
        raise File.Error,
          reason: :eperm,
          action:
            "import_paperclip: refusing to overwrite a non-regular destination file (#{other})",
          path: path

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "import_paperclip: lstat destination file",
          path: path
    end
  end

  # Guard the destination path against symlinked segments — but only AT
  # OR BELOW the glorbo home (the trust boundary). The threat model is a
  # symlink planted *inside* the glorbo home (e.g.
  # `companies/<slug> -> /attacker`), redirecting our writes. Ancestors
  # at/above the home (`/`, `/home`, `/var`, the home dir itself) are OS-
  # and operator-owned and may legitimately be symlinks — most notably
  # `/home -> /var/home` on atomic Fedora (Silverblue/Bazzite), where
  # walking from `/` would false-positive on `/home` and make `glorbo
  # import paperclip` unusable with the default `~/.glorbo` (GEP-54).
  defp ensure_real_dest_dir!(path) do
    base = Path.expand(glorbo_home())
    expanded = Path.expand(path)
    rel = Path.relative_to(expanded, base)

    if rel == expanded do
      # Destination is not under the glorbo home — fail closed.
      raise File.Error,
        reason: :eperm,
        action: "import_paperclip: refusing a destination outside the glorbo home",
        path: expanded
    end

    # Walk only the segments below `base`, lstat-checking each. `base`
    # itself and its ancestors are trusted and not inspected. Bind the
    # reduce result so credo doesn't flag the side-effect-only walk.
    _walked =
      rel
      |> Path.split()
      |> Enum.reduce(base, fn seg, acc ->
        candidate = Path.join(acc, seg)
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
          action: "import_paperclip: refusing to mkdir under a non-directory ancestor (#{other})",
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
      safe_write!(path, """
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

  # GEP-54: the directory that holds agent dirs is either `<src>` itself
  # (the flat `paperclipai/companies:main` template layout) or
  # `<src>/agents/` (a live paperclip instance, e.g.
  # `~/.paperclip/instances/<id>/companies/<uuid>/`). lstat-checked so a
  # symlinked `agents/` is never followed.
  defp agent_container(src) do
    agents = Path.join(src, "agents")

    # Descend into `agents/` only when it is a real directory that is NOT
    # itself a flat agent (i.e. has no direct AGENTS.md). This
    # disambiguates a live instance company dir (whose `agents/` holds
    # per-agent sub-dirs) from a flat-layout company that happens to have
    # an agent literally named `agents` (codex review, GEP-54).
    #
    # Note: a symlinked `<src>` typed by the operator is followed by the
    # earlier `File.dir?(src)` — that is operator intent, not the C-098
    # threat (which is untrusted *content within* the tree). Every entry
    # discovered below is still lstat-guarded, so a malicious symlink
    # inside the tree is refused regardless of how `<src>` resolved.
    if real_dir?(agents) and not real_file?(Path.join(agents, "AGENTS.md")) do
      agents
    else
      src
    end
  end

  # Returns `{agent_dir, instr_dir}` pairs. `agent_dir`'s basename is the
  # imported slug (a UUID in the instance layout — GEP-54 D2); `instr_dir`
  # is where AGENTS.md and companion files are read from. Skips
  # `_`/`.`-prefixed entries (e.g. `_templates`) and any directory that
  # resolves to no AGENTS.md.
  #
  # C-098: a paperclip source tree is operator-supplied but may be
  # attacker-authored (supply chain). `File.dir?`/`File.exists?`/
  # `File.read!` all follow symlinks, so a symlinked agent dir or
  # `AGENTS.md -> ~/.glorbo/config.md` would be copied verbatim into
  # company data. Every check below is lstat-based and refuses symlinks.
  defp discover_agents(container) do
    case File.ls(container) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&excluded_entry?/1)
        |> Enum.map(&Path.join(container, &1))
        |> Enum.filter(&real_dir?/1)
        |> Enum.map(fn dir -> {dir, resolve_instr_dir(dir)} end)
        |> Enum.reject(fn {_dir, instr} -> is_nil(instr) end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp excluded_entry?(name) do
    String.starts_with?(name, "_") or String.starts_with?(name, ".")
  end

  # AGENTS.md lives either at `<agent>/instructions/AGENTS.md` (instance
  # layout) or `<agent>/AGENTS.md` (flat layout). Return the directory
  # that holds it, or nil if neither (skip the dir). lstat-based, so a
  # symlinked `instructions/` or a symlinked `AGENTS.md` is refused here,
  # before any read.
  defp resolve_instr_dir(agent_dir) do
    instr = Path.join(agent_dir, "instructions")

    cond do
      real_dir?(instr) and real_file?(Path.join(instr, "AGENTS.md")) -> instr
      real_file?(Path.join(agent_dir, "AGENTS.md")) -> agent_dir
      true -> nil
    end
  end

  # GEP-54 D5: paperclip agents may carry `memory/` and `life/`
  # sub-trees that Glorbo does not import. Detect their presence so the
  # report can flag the omission instead of dropping them silently.
  defp uncarried_aux_dirs?(agent_dir) do
    real_dir?(Path.join(agent_dir, "memory")) or real_dir?(Path.join(agent_dir, "life"))
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

  defp import_agent(instr_dir, co, agent_slug, co_slug) do
    if agent_slug =~ @slug_re do
      do_import_agent(instr_dir, co, agent_slug, co_slug)
    else
      {:error, :invalid_agent_slug}
    end
  end

  # `instr_dir` is the directory that holds AGENTS.md + companions —
  # `<agent>/instructions/` in the instance layout, `<agent>/` in the
  # flat layout (resolved by `resolve_instr_dir/1`).
  defp do_import_agent(instr_dir, co, agent_slug, co_slug) do
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
    body = read_source_file!(Path.join(instr_dir, "AGENTS.md"))
    hints = detect_hints(body)

    safe_write!(Path.join(dest, "AGENT.md"), wrap_agent_md(agent_slug, co_slug, body))

    for fname <- ~w(HEARTBEAT.md SOUL.md TOOLS.md) do
      src_file = Path.join(instr_dir, fname)

      if real_file?(src_file) do
        content = File.read!(src_file)
        _ = detect_hints(content)
        safe_write!(Path.join(dest, fname), wrap_companion_md(fname, content))
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

  defp render_report(co, slug, imported, hints, dropped_aux?) do
    count = length(imported)
    header = "✓ imported paperclip company -> #{co}\n"
    agent_line = "   agents: #{count} (#{Enum.join(Enum.sort(imported), ", ")})\n"

    empty_block =
      if count == 0 do
        "\n⚠  0 agents imported. Nothing under the source matched a paperclip\n" <>
          "agent layout (expected `<agent>/AGENTS.md` or\n" <>
          "`<agent>/instructions/AGENTS.md`). Check that <src> points at a\n" <>
          "paperclip company directory.\n"
      else
        ""
      end

    aux_block =
      if dropped_aux? do
        "\nNote: paperclip `memory/` / `life/` directories were present but\n" <>
          "not carried over — Glorbo agents rebuild working memory from their\n" <>
          "own inbox/outbox. Copy them by hand if you need the history.\n"
      else
        ""
      end

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

    header <> agent_line <> empty_block <> aux_block <> hint_block <> next_steps
  end

  defp glorbo_home do
    Glorbo.Filesystem.Hierarchy.home_root()
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
      Auto-detects two paperclip source layouts:
        * flat template   — <src>/<agent>/AGENTS.md
        * live instance   — <src>/agents/<uuid>/instructions/AGENTS.md

      If <src>/agents/ is a directory it is treated as the agent
      container; otherwise <src> itself is. Each agent becomes
      companies/<target>/agents/<agent-slug>/ with:

        AGENT.md       — Glorbo frontmatter wrap + paperclip body
        HEARTBEAT.md   — copied verbatim if present
        SOUL.md        — copied verbatim if present
        TOOLS.md       — copied verbatim if present

      In the instance layout, agents keep their UUID directory names
      (rename them later and re-run `glorbo reindex`). Paperclip
      `memory/` and `life/` directories are not carried over.

      Paperclip uses an HTTP control plane and $AGENT_HOME
      conventions that Glorbo does not expose. The import report
      lists every such reference it found so you can fix them.

    EXAMPLE
      # flat template
      glorbo import paperclip ~/paperclip-templates/default --as mycompany
      # live instance company directory
      glorbo import paperclip \\
        ~/.paperclip/instances/default/companies/<uuid> --as mycompany
    """
  end
end
