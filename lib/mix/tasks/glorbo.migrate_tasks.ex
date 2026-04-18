defmodule Mix.Tasks.Glorbo.MigrateTasks do
  @moduledoc """
  Rename legacy `t-NN.md` task files to the GEP-13 shape
  `<project-slug>-NN.md`.

  Walks every project under `<base>/companies/<co>/projects/<proj>/tasks/`,
  finds files matching `t-NN.md`, and renames each to `<proj>-NN.md`.
  Collisions (a `<proj>-NN.md` already exists) are reported and skipped
  so running the task twice — or on a mixed directory — is safe.

  Every successful rename appends a `task.migrate` event to the company
  audit log (`audit/YYYY-MM.jsonl`) linking old → new path.

  ## Usage

      mix glorbo.migrate_tasks             # live run on every company
      mix glorbo.migrate_tasks --dry-run   # plan only, no mutations

  Exit codes: `0` always. Collisions are reported but do not fail the
  run — the user decides what to do with the remnants.

  See GEP-13 for the design rationale.
  """
  @shortdoc "Migrate task filenames from t-NN.md to <project>-NN.md (GEP-13)"

  use Mix.Task

  @switches [dry_run: :boolean, base: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    base = opts[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    dry_run? = Keyword.get(opts, :dry_run, false)

    if dry_run?, do: Mix.shell().info("[dry-run] no files will be renamed\n")

    case list_companies(base) do
      [] ->
        Mix.shell().info("No companies found under #{inspect(base)}.")

      companies ->
        Enum.each(companies, fn co -> migrate_company(base, co, dry_run?) end)
    end

    :ok
  end

  defp list_companies(base) do
    dir = Path.join(base, "companies")

    case File.ls(dir) do
      {:ok, slugs} -> Enum.filter(slugs, &File.dir?(Path.join(dir, &1)))
      _ -> []
    end
  end

  defp migrate_company(base, company, dry_run?) do
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.each(projects, fn proj ->
          if File.dir?(Path.join(projects_dir, proj)) do
            migrate_project(base, company, proj, dry_run?)
          end
        end)

      _ ->
        :ok
    end
  end

  defp migrate_project(base, company, project, dry_run?) do
    tasks_dir = Path.join([base, "companies", company, "projects", project, "tasks"])
    legacy_re = ~r/\At-(\d+)\.md\z/

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&Regex.match?(legacy_re, &1))
        |> Enum.each(fn old_name ->
          [_, num] = Regex.run(legacy_re, old_name)
          new_name = "#{project}-#{num}.md"
          old_path = Path.join(tasks_dir, old_name)
          new_path = Path.join(tasks_dir, new_name)

          process_rename(
            base,
            company,
            project,
            old_name,
            new_name,
            old_path,
            new_path,
            dry_run?
          )
        end)

      _ ->
        :ok
    end
  end

  defp process_rename(base, company, project, old_name, new_name, old_path, new_path, dry_run?) do
    rel_old = "projects/#{project}/tasks/#{old_name}"
    rel_new = "projects/#{project}/tasks/#{new_name}"

    cond do
      File.exists?(new_path) ->
        Mix.shell().info([
          :red,
          "  skip  ",
          :reset,
          "#{company}/",
          rel_old,
          " → ",
          rel_new,
          " (target exists)"
        ])

      dry_run? ->
        Mix.shell().info([
          :cyan,
          "  plan  ",
          :reset,
          "#{company}/",
          rel_old,
          " → ",
          rel_new
        ])

      true ->
        case File.rename(old_path, new_path) do
          :ok ->
            Mix.shell().info([
              :green,
              "  move  ",
              :reset,
              "#{company}/",
              rel_old,
              " → ",
              rel_new
            ])

            emit_audit(base, company, rel_old, rel_new)

          {:error, reason} ->
            Mix.shell().error("  fail  #{company}/#{rel_old}: #{inspect(reason)}")
        end
    end
  end

  # Direct JSONL append; avoids booting the GenServer for a one-shot CLI.
  defp emit_audit(base, company, old_rel, new_rel) do
    ts = DateTime.utc_now()

    record = %{
      ts: DateTime.to_iso8601(ts),
      actor: "system",
      action: "task.migrate",
      target: new_rel,
      detail: %{
        "from" => old_rel,
        "to" => new_rel,
        "gep" => "GEP-13"
      }
    }

    yyyy_mm =
      [ts.year, String.pad_leading(Integer.to_string(ts.month), 2, "0")]
      |> Enum.join("-")

    path = Path.join([base, "companies", company, "audit", "#{yyyy_mm}.jsonl"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, Jason.encode!(record) <> "\n", [:append, :sync])
  end
end
