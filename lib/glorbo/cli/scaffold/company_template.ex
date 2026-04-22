defmodule Glorbo.CLI.Scaffold.CompanyTemplate do
  @moduledoc """
  GEP-26: scaffold a company from a `company-template/v1` tree under
  `priv/templates/companies/<template-name>/`.

  Unlike `Glorbo.CLI.Scaffold.Company` (the minimal company
  scaffolder), this one copies a whole pre-populated tree — agents,
  projects, tasks, and fixtures — rewriting frontmatter placeholders
  (`{{ slug }}`, `{{ name }}`, `{{ provider }}`, `{{ model }}`) as
  it goes.

  ## Invariants

  - Fixtures (`fixtures/` subtree under the template) are symlinked
    into the scaffolded company rather than copied, so reruns
    verify against the same fixture tree and updates to the
    template propagate to every scaffolded bench company. (GEP-26
    D2.) On macOS or filesystems where symlink isn't reliable, we
    fall back to a recursive copy with `chmod -R u-w`.
  - Every template file's frontmatter carries `kind:` (GEP-25 D9).
    The rendered files carry the same kinds, just with placeholder
    substitution applied.
  - Idempotent: running against an existing company slug returns
    `{:error, :exists}` without touching the directory.
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Scaffold.Renderer
  alias Glorbo.Filesystem.Frontmatter

  @slug_re ~r/\A[a-z0-9-]+\z/

  @spec run(String.t(), String.t(), keyword()) ::
          {:ok, Path.t()} | {:error, atom() | {atom(), term()}}
  def run(slug, template_name, opts \\ [])

  def run(slug, template_name, opts)
      when is_binary(slug) and is_binary(template_name) do
    with :ok <- validate_slug(slug),
         {:ok, template_dir} <- resolve_template_dir(template_name),
         {:ok, manifest} <- read_manifest(template_dir),
         :ok <- check_min_glorbo_version(manifest),
         base <- glorbo_home(),
         co <- Path.join([base, "companies", slug]),
         :ok <- refuse_if_exists(co) do
      do_scaffold(slug, template_name, template_dir, manifest, co, opts)
    end
  end

  # ----------------------------------------------------------------
  # List available templates (backs `glorbo bench list`).
  # ----------------------------------------------------------------

  @doc """
  List all available company templates with their manifest summary.
  """
  @spec list_templates() :: [map()]
  def list_templates do
    templates_root()
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(&Path.join(templates_root(), &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&summarise_template/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # ----------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------

  defp validate_slug(slug) do
    if slug =~ @slug_re, do: :ok, else: {:error, :invalid_slug}
  end

  defp resolve_template_dir(name) do
    path = Path.join(templates_root(), name)

    if File.dir?(path) and File.exists?(Path.join(path, "template.md")) do
      {:ok, path}
    else
      {:error, :template_not_found}
    end
  end

  defp read_manifest(template_dir) do
    path = Path.join(template_dir, "template.md")

    with {:ok, content} <- File.read(path),
         {:ok, fm, _body} <- Frontmatter.parse(content),
         "company-template/v1" <- Map.get(fm, "kind") do
      {:ok, fm}
    else
      other -> {:error, {:bad_manifest, other}}
    end
  end

  # Soft-check: compare declared `min_glorbo_version:` against Glorbo's
  # release-time version. Skipped if the template doesn't declare one.
  defp check_min_glorbo_version(manifest) do
    case Map.get(manifest, "min_glorbo_version") do
      nil -> :ok
      declared when is_binary(declared) -> compare_glorbo_version(declared)
    end
  end

  defp compare_glorbo_version(declared) do
    current = Application.spec(:glorbo, :vsn) |> to_string()

    with {:ok, declared_v} <- Version.parse(declared),
         {:ok, current_v} <- Version.parse(current),
         :lt <- Version.compare(current_v, declared_v) do
      {:error, {:glorbo_too_old, declared, current}}
    else
      _ -> :ok
    end
  end

  defp refuse_if_exists(path) do
    if File.exists?(path), do: {:error, :exists}, else: :ok
  end

  defp do_scaffold(slug, template_name, template_dir, manifest, co, opts) do
    provider =
      (opts[:provider] && to_string(opts[:provider])) ||
        Map.get(manifest, "default_provider", "claude-code")

    model =
      (opts[:model] && to_string(opts[:model])) ||
        Map.get(manifest, "default_model", "claude-sonnet-4-5")

    vars =
      Renderer.build_vars(
        slug: slug,
        company: slug,
        name: slug,
        provider: provider,
        model: model
      )

    Audit.emit("new_company", "start", %{
      slug: slug,
      template: template_name
    })

    File.mkdir_p!(co)
    Enum.each(~w(agents projects channels audit), &File.mkdir_p!(Path.join(co, &1)))

    copy_rendered_files(template_dir, co, vars)
    link_or_copy_fixtures(template_dir, co, manifest)
    place_task_files(template_dir, co, vars)
    ensure_default_channel(co)

    Audit.emit("new_company", "complete", %{
      slug: slug,
      template: template_name,
      path: co
    })

    {:ok, co}
  end

  # Every markdown file under the template (except those in
  # `fixtures/` and `tasks/` — handled separately) is rendered with
  # placeholder substitution and copied to the company dir.
  defp copy_rendered_files(template_dir, co, vars) do
    template_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.reject(&excluded_from_render?(&1, template_dir))
    |> Enum.each(fn src ->
      rel = Path.relative_to(src, template_dir)
      dst = Path.join(co, rel)
      File.mkdir_p!(Path.dirname(dst))
      content = src |> File.read!() |> Renderer.render(vars)
      File.write!(dst, content)
    end)
  end

  # template.md + README.md (inside fixtures/) + tasks/* + fixtures/*
  # are handled elsewhere.
  defp excluded_from_render?(src, template_dir) do
    rel = Path.relative_to(src, template_dir)

    String.starts_with?(rel, "fixtures/") or
      String.starts_with?(rel, "tasks/") or
      rel == "template.md"
  end

  # Tasks under template/tasks/*.md land at
  # companies/<slug>/projects/<proj>/tasks/<task-id>.md. Routing
  # uses longest-prefix match against the template's existing
  # `projects/<name>/` dirs so filenames like `bugs-py-1.md` land
  # in project `bugs-py`, not project `bugs`.
  defp place_task_files(template_dir, co, vars) do
    tasks_dir = Path.join(template_dir, "tasks")
    projects = known_projects(template_dir)

    case File.ls(tasks_dir) do
      {:ok, entries} ->
        Enum.each(entries, fn fname ->
          src = Path.join(tasks_dir, fname)
          place_one_task(src, co, vars, projects)
        end)

      _ ->
        :ok
    end
  end

  # List project slugs from the template's projects/ tree. Sorted by
  # length desc so longest-prefix matches win during routing.
  defp known_projects(template_dir) do
    projects_dir = Path.join(template_dir, "projects")

    case File.ls(projects_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(projects_dir, &1)))
        |> Enum.sort_by(&(-String.length(&1)))

      _ ->
        []
    end
  end

  defp place_one_task(src, co, vars, projects) do
    if File.regular?(src) and String.ends_with?(src, ".md") do
      fname = Path.basename(src)
      project = route_task_to_project(fname, projects)
      dst_dir = Path.join([co, "projects", project, "tasks"])
      File.mkdir_p!(dst_dir)

      content =
        src
        |> File.read!()
        |> Renderer.render(vars)

      File.write!(Path.join(dst_dir, fname), content)
    end
  end

  # Pick the longest project slug that's a prefix of the task
  # filename's stem. Fallback to the pre-first-dash slice for
  # templates that don't declare projects/.
  defp route_task_to_project(fname, projects) do
    stem = Path.rootname(fname, ".md")

    Enum.find(projects, fn p -> stem == p or String.starts_with?(stem, p <> "-") end) ||
      stem |> String.split("-", parts: 2) |> List.first() || "general"
  end

  # Fixtures: try symlink first (bind-mount-friendly, repeatable);
  # fall back to RO copy if symlinks are unsupported or the source
  # is already under a read-only path.
  defp link_or_copy_fixtures(template_dir, co, manifest) do
    fixtures_src = Path.join(template_dir, Map.get(manifest, "fixtures_dir", "fixtures"))

    if File.dir?(fixtures_src) do
      fixtures_dst = Path.join(co, "fixtures")

      case File.ln_s(fixtures_src, fixtures_dst) do
        :ok ->
          :ok

        {:error, _} ->
          File.cp_r!(fixtures_src, fixtures_dst)
          make_tree_read_only(fixtures_dst)
      end
    end
  end

  defp make_tree_read_only(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.each(fn p ->
      if File.regular?(p) do
        _ = File.chmod(p, 0o444)
      end
    end)

    :ok
  end

  defp summarise_template(template_dir) do
    manifest_path = Path.join(template_dir, "template.md")

    with true <- File.regular?(manifest_path),
         {:ok, content} <- File.read(manifest_path),
         {:ok, fm, _body} <- Frontmatter.parse(content) do
      %{
        name: Map.get(fm, "name", Path.basename(template_dir)),
        archetype: Map.get(fm, "archetype", "(untagged)"),
        description: Map.get(fm, "description", ""),
        version: Map.get(fm, "version", "?"),
        default_provider: Map.get(fm, "default_provider", "?"),
        default_model: Map.get(fm, "default_model", "?"),
        tags: Map.get(fm, "tags", [])
      }
    else
      _ -> nil
    end
  end

  defp templates_root do
    Path.join([:code.priv_dir(:glorbo), "templates/companies"])
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  # B2 (UAT 2026-04-22): the sidebar Chat link targets
  # `/companies/<co>/channels/general`. Most templates don't seed a
  # channels dir, so a freshly-scaffolded company's Chat link flashes
  # "Channel not found" and bounces back to Overview. Drop a minimal
  # `general.md` stub unless the template already provided one.
  defp ensure_default_channel(co) do
    path = Path.join([co, "channels", "general.md"])

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      ---
      kind: channel-log/v1
      channel: general
      created_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
      ---
      """)
    end
  end
end
