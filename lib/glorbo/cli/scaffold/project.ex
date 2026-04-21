defmodule Glorbo.CLI.Scaffold.Project do
  @moduledoc """
  `glorbo new project <company>/<slug>` — D-13: scaffold a project
  directory inside a company.

  Minimal scaffold: creates `projects/<slug>/` with `README.md` and
  `project.md` frontmatter. Projects are just directories — tasks are
  materialized lazily by the Director adding `tasks/*.md` files.

  Company must exist. Idempotent on the project directory level.
  """

  alias Glorbo.CLI.Audit

  @slug_re ~r/\A[a-z0-9-]+\z/

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run([]), do: usage()
  def run(["--help" | _]), do: {:new_project, 0, help_text()}
  def run(["-h" | _]), do: {:new_project, 0, help_text()}

  def run([co_slash_slug | _rest]) do
    case String.split(co_slash_slug, "/", parts: 2) do
      [company, slug]
      when byte_size(company) > 0 and byte_size(slug) > 0 ->
        if company =~ @slug_re and slug =~ @slug_re do
          scaffold(company, slug)
        else
          {:new_project, 1,
           "Invalid slug in '#{co_slash_slug}'. Slug regex: #{inspect(@slug_re)}.\n"}
        end

      _ ->
        usage()
    end
  end

  defp scaffold(company, slug) do
    base = glorbo_home()
    co_path = Path.join([base, "companies", company])
    proj_path = Path.join([co_path, "projects", slug])

    cond do
      not File.exists?(co_path) ->
        {:new_project, 1,
         "Company '#{company}' not found. Run `glorbo new company #{company}` first.\n"}

      File.exists?(proj_path) ->
        {:new_project, 0, "⏭ already exists: #{company}/#{slug}\n"}

      true ->
        do_scaffold(company, slug, proj_path)
    end
  end

  defp do_scaffold(company, slug, proj_path) do
    Audit.emit("new_project", "start", %{company: company, project: slug})

    File.mkdir_p!(proj_path)

    File.write!(Path.join(proj_path, "README.md"), """
    # #{slug}

    (Project scaffolded by `glorbo new project #{company}/#{slug}`.)
    """)

    File.write!(Path.join(proj_path, "project.md"), """
    ---
    kind: project/v1
    slug: #{slug}
    name: #{slug}
    status: active
    ---

    # #{slug}
    """)

    Audit.emit("new_project", "complete", %{
      company: company,
      project: slug,
      path: proj_path
    })

    {:new_project, 0, "✓ created project: #{proj_path}\n"}
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  defp usage do
    {:new_project, 1, "Usage: glorbo new project <company>/<slug>\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new project — scaffold a new project inside a company.

    USAGE
      glorbo new project <company>/<slug>

    BEHAVIOR
      Creates projects/<slug>/ with README.md + project.md frontmatter.
      Idempotent — re-running on an existing project is a no-op.
    """
  end
end
