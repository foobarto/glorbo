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

  def run([slug | _rest]) do
    if slug =~ @slug_re do
      scaffold(slug)
    else
      {:new_company, 1,
       "Invalid slug: '#{slug}'. Use lowercase letters, numbers, and hyphens only.\n"}
    end
  end

  defp scaffold(slug) do
    base = glorbo_home()
    co = Path.join([base, "companies", slug])

    if File.exists?(co) do
      {:new_company, 0, "⏭ already exists: #{slug}\n"}
    else
      Audit.emit("new_company", "start", %{slug: slug})

      File.mkdir_p!(co)
      Enum.each(~w(agents projects channels audit), &File.mkdir_p!(Path.join(co, &1)))

      File.write!(Path.join(co, "company.md"), """
      ---
      name: #{slug}
      mission: ""
      ---

      # #{slug}
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

    SLUG
      Lowercase letters, digits, and hyphens only (regex: #{inspect(@slug_re)}).

    BEHAVIOR
      Creates ~/.glorbo/companies/<slug>/ with:
        company.md   (frontmatter + markdown body)
        agents/      (empty)
        projects/    (empty)
        channels/    (empty)
        audit/       (empty)

      Idempotent — re-running on an existing slug is a no-op.
    """
  end
end
