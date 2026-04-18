defmodule Glorbo.CLI.Scaffold.Skill do
  @moduledoc """
  `glorbo new skill <company> <name> [--template T]` — scaffold a
  skill markdown file under `companies/<company>/skills/<name>.md`
  (GEP-10).

  Two modes, symmetric with `Glorbo.CLI.Scaffold.Agent`:

    * **Default** (no `--template`) — writes a minimal skill.md stub
      with just the name + description frontmatter.
    * **Templated** (`--template <name>`) — renders a template from
      `priv/templates/skills/<name>.md` (or user override).

  Company must exist. Idempotent at the skill-file level: if a file
  with the same name already exists, exit 0 with a skip message.
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Scaffold.Renderer
  alias Glorbo.CLI.Scaffold.TemplateRegistry

  @slug_re ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @switches [template: :string, help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, positional, _} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] -> {:new_skill, 0, help_text()}
      length(positional) < 2 -> usage()
      true -> do_run(positional, opts)
    end
  end

  defp do_run([company, name | _], opts) do
    if company =~ @slug_re and name =~ @slug_re do
      scaffold(company, name, opts)
    else
      {:new_skill, 1,
       "Invalid slug. Both company and skill name must match #{inspect(@slug_re)}.\n"}
    end
  end

  defp scaffold(company, name, opts) do
    base = glorbo_home()
    co_path = Path.join([base, "companies", company])
    skill_path = Path.join([co_path, "skills", "#{name}.md"])

    cond do
      not File.exists?(co_path) ->
        {:new_skill, 1,
         "Company '#{company}' not found. Run `glorbo new company #{company}` first.\n"}

      File.exists?(skill_path) ->
        {:new_skill, 0, "⏭ already exists: #{skill_path}\n"}

      true ->
        do_scaffold(company, name, opts, skill_path)
    end
  end

  defp do_scaffold(company, name, opts, skill_path) do
    case resolve_template(opts) do
      {:ok, nil} ->
        scaffold_default(company, name, skill_path)

      {:ok, entry} ->
        scaffold_from_template(company, name, skill_path, entry)

      {:error, msg} ->
        {:new_skill, 1, msg}
    end
  end

  defp scaffold_default(company, name, skill_path) do
    Audit.emit("new_skill", "start", %{company: company, skill: name, template: nil})

    File.mkdir_p!(Path.dirname(skill_path))

    File.write!(skill_path, """
    ---
    name: #{name}
    description: "[EDIT: one-line description]"
    tags: []
    ---

    # #{name}

    Scaffolded by `glorbo new skill #{company} #{name}`.

    [EDIT: describe when this skill applies, what inputs it expects,
    and what output format it should produce.]
    """)

    Audit.emit("new_skill", "complete", %{
      company: company,
      skill: name,
      path: skill_path,
      template: nil
    })

    {:new_skill, 0, "✓ created skill: #{skill_path}\n"}
  end

  defp scaffold_from_template(company, name, skill_path, entry) do
    Audit.emit("new_skill", "start", %{company: company, skill: name, template: entry.name})

    File.mkdir_p!(Path.dirname(skill_path))

    # Skill templates get the same var map as agent templates, with
    # `name` defaulting to the skill slug as-is (not upcased — skill
    # names are typically kebab-case and stay that way in headings).
    vars =
      Renderer.build_vars(slug: name, company: company, name: name)

    rendered =
      entry.path
      |> File.read!()
      |> Renderer.render(vars)

    File.write!(skill_path, rendered)

    Audit.emit("new_skill", "complete", %{
      company: company,
      skill: name,
      path: skill_path,
      template: entry.name
    })

    {:new_skill, 0, "✓ created skill: #{skill_path} (template: #{entry.name})\n"}
  end

  defp resolve_template(opts) do
    case opts[:template] do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      name ->
        case TemplateRegistry.fetch(:skill, name) do
          {:ok, entry} ->
            {:ok, entry}

          {:error, :not_found} ->
            available =
              TemplateRegistry.list(:skill)
              |> Enum.map(& &1.name)

            msg =
              "Unknown skill template: #{inspect(name)}\n" <>
                "Available: #{Enum.join(available, ", ")}\n"

            {:error, msg}
        end
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  defp usage do
    {:new_skill, 1, "Usage: glorbo new skill <company> <name> [--template T]\n"}
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo new skill — scaffold a new skill inside a company.

    USAGE
      glorbo new skill <company> <name> [--template T]

    FLAGS
      --template T   Scaffold from a GEP-10 skill template (see
                     `glorbo templates list skill`).

    COMPANY
      Must already exist — run `glorbo new company <company>` first.
    """
  end
end
