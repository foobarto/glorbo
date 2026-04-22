defmodule Glorbo.CLI.Scaffold.Company do
  @moduledoc """
  `glorbo new company <slug>` — D-11: scaffold a company directory tree.

  Creates `<base>/companies/<slug>/` with subdirs `agents/`, `projects/`,
  `channels/`, `audit/` and a minimal `company.md` frontmatter.

  Slug regex: `~r/\\A[a-z0-9-]+\\z/` — lowercase letters, digits, hyphens
  only. Anything else rejected at argv-time (threat T-05-01 path injection).

  Idempotent: re-run on an existing slug returns exit 0 with a `⏭`
  marker and does NOT touch files.
  """

  alias Glorbo.CLI.Audit

  # Company/project slug regex — more permissive than the agent/parser
  # slug regex (no length cap, allows digit-leading) because company
  # and project names are user-facing labels, not Elixir atoms or
  # supervisor keys. Kept separate from Glorbo.Agent.Parser's stricter
  # regex on purpose; unifying would tighten semantics that downstream
  # consumers rely on.
  @slug_re ~r/\A[a-z0-9-]+\z/

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: usage()
  def run(["--help" | _]), do: {:new_company, 0, help_text()}
  def run(["-h" | _]), do: {:new_company, 0, help_text()}

  def run(argv) do
    {opts, rest} = parse_opts(argv)

    case rest do
      [] ->
        usage()

      [slug | _] ->
        cond do
          not (slug =~ @slug_re) ->
            {:new_company, 1,
             "Invalid slug: '#{slug}'. Use lowercase letters, numbers, and hyphens only.\n"}

          opts[:template] ->
            scaffold_from_template(slug, opts)

          true ->
            scaffold(slug)
        end
    end
  end

  @doc """
  Public scaffold entry — same effect as `glorbo new company <slug>`
  but with an explicit `base:` opt so callers outside the CLI flow
  (MCP tools, tests) can target a non-default `GLORBO_HOME`.
  """
  @spec scaffold(String.t(), keyword()) ::
          {:new_company, 0 | 1, String.t()}
  def scaffold(slug, opts) when is_binary(slug) and is_list(opts) do
    base = Keyword.get(opts, :base, glorbo_home())
    do_scaffold(slug, base)
  end

  # OptionParser with strict switches for clarity; unknown flags error.
  defp parse_opts(argv) do
    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: [template: :string, provider: :string, model: :string]
      )

    if invalid != [] do
      {%{}, rest ++ Enum.map(invalid, fn {k, _} -> k end)}
    else
      {Map.new(parsed), rest}
    end
  end

  defp scaffold_from_template(slug, opts) do
    template = opts[:template]

    case Glorbo.CLI.Scaffold.CompanyTemplate.run(slug, template,
           provider: opts[:provider],
           model: opts[:model]
         ) do
      {:ok, path} ->
        {:new_company, 0, "✓ scaffolded #{slug} from template #{template} at #{path}\n"}

      {:error, :exists} ->
        {:new_company, 0, "⏭ already exists: #{slug}\n"}

      {:error, :invalid_slug} ->
        {:new_company, 1, "Invalid slug: '#{slug}'.\n"}

      {:error, :template_not_found} ->
        {:new_company, 1,
         "Template not found: '#{template}'. Run `glorbo bench list` to see available templates.\n"}

      {:error, {:glorbo_too_old, declared, current}} ->
        {:new_company, 1,
         "Template '#{template}' requires Glorbo #{declared}; installed #{current}. Upgrade.\n"}

      {:error, {:bad_manifest, reason}} ->
        {:new_company, 1, "Template '#{template}' manifest invalid: #{inspect(reason)}\n"}

      {:error, reason} ->
        {:new_company, 1, "Scaffold failed: #{inspect(reason)}\n"}
    end
  end

  defp scaffold(slug), do: do_scaffold(slug, glorbo_home())

  defp do_scaffold(slug, base) do
    co = Path.join([base, "companies", slug])

    if File.exists?(co) do
      {:new_company, 0, "⏭ already exists: #{slug}\n"}
    else
      Audit.emit("new_company", "start", %{slug: slug})

      File.mkdir_p!(co)
      Enum.each(~w(agents projects channels audit proposals), &File.mkdir_p!(Path.join(co, &1)))

      File.write!(Path.join(co, "company.md"), """
      ---
      kind: company/v1
      slug: #{slug}
      name: #{slug}
      mission: ""
      headcount_budget: 3
      ---

      # #{slug}
      """)

      # B2 (UAT 2026-04-22): the sidebar Chat link hardcodes
      # `/companies/<co>/channels/general`. Without a seeded
      # `general.md` every click flashes "Channel not found" and
      # redirects to Overview — a bad first impression on every
      # fresh company. Drop a minimal channel stub so the link
      # always works.
      File.write!(Path.join([co, "channels", "general.md"]), """
      ---
      kind: channel-log/v1
      channel: general
      created_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
      ---
      """)

      Audit.emit("new_company", "complete", %{slug: slug, path: co})
      {:new_company, 0, "✓ created company: #{co}\n"}
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  defp usage do
    {:new_company, 1, "Usage: glorbo new company <slug>\n  Slug regex: #{inspect(@slug_re)}\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new company — scaffold a new company directory.

    USAGE
      glorbo new company <slug>
      glorbo new company <slug> --template <name>
      glorbo new company <slug> --template <name> --provider <p> --model <m>

    SLUG
      Lowercase letters, digits, and hyphens only (regex: #{inspect(@slug_re)}).

    OPTIONS
      --template NAME   Scaffold from a company template (see GEP-26).
                        List available templates with `glorbo bench list`.
      --provider P      Override template's default provider. Ignored
                        when --template is absent.
      --model M         Override template's default model. Ignored
                        when --template is absent.

    BEHAVIOR (no template)
      Creates ~/.glorbo/companies/<slug>/ with:
        company.md   (frontmatter + markdown body)
        agents/      (empty)
        projects/    (empty)
        channels/    (empty)
        audit/       (empty)

    BEHAVIOR (--template)
      Copies the template's agents/, projects/, and tasks/ into the
      new company. Tasks are routed to their project by filename
      prefix (e.g. `bugs-1-*.md` → `projects/bugs/tasks/`).
      Fixtures are symlinked read-only (or copied RO if the
      platform disallows symlinks).

    Idempotent — re-running on an existing slug is a no-op.
    """
  end
end
