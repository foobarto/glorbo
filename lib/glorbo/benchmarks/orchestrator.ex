defmodule Glorbo.Benchmarks.Orchestrator do
  @moduledoc """
  GEP-26 Phase B dispatch orchestrator.

  `run/4` forks one shadow company per provider, pins the template's
  agents to that provider, fires the named task, captures the reply
  into `benchmarks/runs/<run-id>/providers/<provider>/output.md`, and
  cleans up the shadow company on success. The manifest is written
  up-front with `status: in-progress` and flipped to `completed` (or
  `failed`) after the dispatch fan-out finishes.

  Shadow companies live at
  `~/.glorbo/companies/_bench-<run-id>-<provider>/` — the underscore
  prefix keeps them out of the normal company listing. The caller
  can leave them in place on failure for debugging by passing
  `:keep_shadow? true`.

  The module is deliberately thin — it glues together existing
  pieces:

    * `Glorbo.CLI.Scaffold.CompanyTemplate` — the template reader
      the existing `glorbo new company --template` path uses.
    * `Glorbo.Filesystem.FrontmatterWriter.update_keys/3` — the
      per-AGENT.md provider pin.
    * `Glorbo.Agent.Parser.parse_file/1` — builds a Spec the
      Dispatch path expects.
    * `Glorbo.Agent.Dispatch.execute/3` — actual bwrap invocation.
  """

  alias Glorbo.Agent.Dispatch
  alias Glorbo.Agent.Parser
  alias Glorbo.Benchmarks
  alias Glorbo.Filesystem.FrontmatterWriter
  alias Glorbo.Filesystem.Hierarchy

  @type run_result :: %{
          run_id: String.t(),
          providers: [String.t()],
          results: [%{provider: String.t(), ok?: boolean(), path: Path.t() | nil, error: term()}],
          manifest_path: Path.t()
        }

  @spec run(String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, run_result()} | {:error, term()}
  def run(template, task_id, providers, opts \\ [])
      when is_binary(template) and is_binary(task_id) and is_list(providers) do
    base = Keyword.get(opts, :base, Hierarchy.default_root())
    keep_shadow? = Keyword.get(opts, :keep_shadow?, false)
    run_id = Keyword.get(opts, :run_id) || generate_run_id()
    now_fun = Keyword.get(opts, :now_fun, &iso_now/0)
    dispatch_fun = Keyword.get(opts, :dispatch_fun, &Dispatch.execute/3)
    # Unknown providers fail up front; no half-runs.
    template_dir = template_dir_for(template)

    with :ok <- validate_providers(providers),
         :ok <- validate_template_exists(template_dir),
         {:ok, task_path} <- validate_task_exists(template_dir, task_id),
         run_dir <- run_dir_for(base, run_id),
         :ok <- File.mkdir_p(run_dir) do
      started_at = now_fun.()
      :ok = copy_frozen_task(task_path, run_dir)

      :ok =
        write_manifest(run_dir, run_id, template, task_id, providers, started_at, "in-progress")

      results =
        Enum.map(providers, fn provider ->
          run_one_provider(
            provider,
            template_dir,
            task_id,
            run_id,
            run_dir,
            base,
            dispatch_fun,
            keep_shadow?
          )
        end)

      completed_at = now_fun.()
      status = if Enum.all?(results, & &1.ok?), do: "completed", else: "failed"

      :ok =
        write_manifest(
          run_dir,
          run_id,
          template,
          task_id,
          providers,
          started_at,
          status,
          completed_at
        )

      {:ok,
       %{
         run_id: run_id,
         providers: providers,
         results: results,
         manifest_path: Path.join(run_dir, "manifest.md")
       }}
    end
  end

  # ------------------------------------------------------------------
  # Per-provider dispatch
  # ------------------------------------------------------------------

  defp run_one_provider(
         provider,
         template_dir,
         task_id,
         run_id,
         run_dir,
         base,
         dispatch_fun,
         keep_shadow?
       ) do
    provider_out_dir = Path.join([run_dir, "providers", provider])
    File.mkdir_p!(provider_out_dir)

    shadow_slug = "_bench-#{run_id}-#{provider}"
    shadow_dir = Path.join([base, "companies", shadow_slug])

    try do
      :ok = scaffold_shadow_company(template_dir, shadow_dir, provider)

      case dispatch_task(shadow_dir, task_id, provider, shadow_slug, dispatch_fun) do
        {:ok, reply} ->
          output_path = Path.join(provider_out_dir, "output.md")
          File.write!(output_path, render_output_md(provider, reply))

          unless keep_shadow?, do: File.rm_rf!(shadow_dir)

          %{provider: provider, ok?: true, path: output_path, error: nil}

        {:error, reason} ->
          File.write!(
            Path.join(provider_out_dir, "dispatch-error.txt"),
            "#{inspect(reason, pretty: true)}\n"
          )

          %{provider: provider, ok?: false, path: nil, error: reason}
      end
    rescue
      e ->
        %{
          provider: provider,
          ok?: false,
          path: nil,
          error: {:scaffold_failed, Exception.message(e)}
        }
    end
  end

  # Load the task's assigned_to agent out of the shadow company,
  # parse the AGENT.md, and hand the Dispatch module the shape it
  # expects. If the task has no assigned_to we fall back to the
  # first agent in the shadow — keeps bench templates that leave
  # assignment implicit functional.
  defp dispatch_task(shadow_dir, task_id, _provider, shadow_slug, dispatch_fun) do
    # Bench templates keep tasks at `tasks/<id>.md` at the company
    # root; `glorbo new company --template` would route them into
    # `projects/<matching>/tasks/<id>.md`. Look in both places so
    # either layout works.
    task_candidates =
      Path.wildcard(Path.join([shadow_dir, "projects", "*", "tasks", "#{task_id}.md"])) ++
        Path.wildcard(Path.join([shadow_dir, "tasks", "#{task_id}.md"]))

    with [task_file | _] <- task_candidates,
         {:ok, task_content} <- File.read(task_file),
         {agent_slug, task_body} <- pick_assignee(task_content, shadow_dir) do
      agent_md = Path.join([shadow_dir, "agents", agent_slug, "AGENT.md"])

      case Parser.parse_file(agent_md) do
        {:ok, spec} ->
          task = %{
            task_id: task_id,
            task_path: Path.relative_to(task_file, shadow_dir),
            prompt: task_body,
            trigger: :bench
          }

          case dispatch_fun.(spec, task, []) do
            {:ok, %{reply: reply}} -> {:ok, reply}
            {:ok, %{} = other} -> {:ok, Map.get(other, :reply, inspect(other))}
            {:error, _} = err -> err
            other -> {:error, {:unexpected_dispatch_shape, other}}
          end

        {:error, reason} ->
          {:error, {:parse_agent_md, reason}}
      end
    else
      [] -> {:error, {:task_not_found_in_shadow, task_id, shadow_slug}}
      {:error, _} = err -> err
      other -> {:error, {:unexpected_task_shape, other, shadow_slug}}
    end
  end

  defp pick_assignee(task_content, shadow_dir) do
    case Regex.run(~r/^assigned_to:\s*(\S+)/m, task_content) do
      [_, slug] when is_binary(slug) and slug != "" ->
        {slug, task_content |> strip_frontmatter()}

      _ ->
        first_agent_slug =
          [shadow_dir, "agents"]
          |> Path.join()
          |> File.ls!()
          |> Enum.filter(&File.dir?(Path.join([shadow_dir, "agents", &1])))
          |> List.first()

        {first_agent_slug || "engineer", task_content |> strip_frontmatter()}
    end
  end

  defp strip_frontmatter(content) do
    case String.split(content, ~r/\A---\n|\n---\n/, parts: 3) do
      ["", _fm, body] -> body
      _ -> content
    end
  end

  # ------------------------------------------------------------------
  # Shadow-company scaffolding
  # ------------------------------------------------------------------

  defp scaffold_shadow_company(template_dir, shadow_dir, provider) do
    File.mkdir_p!(shadow_dir)
    copy_template_tree(template_dir, shadow_dir)

    # Bench templates carry `{{ provider }}` / `{{ model }}` placeholders
    # (Renderer fills them in the `glorbo new company --template` flow).
    # Substitute inline so the shadow company parses cleanly — pull the
    # default model out of the template's manifest.
    default_model = default_model_for(template_dir)

    Path.wildcard(Path.join([shadow_dir, "agents", "*", "AGENT.md"]))
    |> Enum.each(fn agent_md ->
      content = File.read!(agent_md)

      rendered =
        content
        |> String.replace(~r/\{\{\s*provider\s*\}\}/, provider)
        |> String.replace(~r/\{\{\s*model\s*\}\}/, default_model)

      File.write!(agent_md, rendered)

      # Belt-and-suspenders: if a shadow's AGENT.md didn't carry a
      # `{{ provider }}` placeholder, still pin it to the matrix value.
      _ = FrontmatterWriter.update_keys(agent_md, %{"provider" => provider})
    end)

    :ok
  end

  defp default_model_for(template_dir) do
    template_md = Path.join(template_dir, "template.md")

    case File.read(template_md) do
      {:ok, content} ->
        case Regex.run(~r/^default_model:\s*(\S+)/m, content) do
          [_, model] -> model
          _ -> "claude-sonnet-4-5"
        end

      _ ->
        "claude-sonnet-4-5"
    end
  end

  defp copy_template_tree(src, dst) do
    src
    |> File.ls!()
    # Skip the template's own metadata file — it doesn't belong in a
    # live company.
    |> Enum.reject(&(&1 in ["template.md"]))
    |> Enum.each(fn entry ->
      src_path = Path.join(src, entry)
      dst_path = Path.join(dst, entry)

      if File.dir?(src_path) do
        File.mkdir_p!(dst_path)
        copy_template_tree(src_path, dst_path)
      else
        File.cp!(src_path, dst_path)
      end
    end)
  end

  # ------------------------------------------------------------------
  # Manifest + output.md formatting
  # ------------------------------------------------------------------

  defp write_manifest(
         run_dir,
         run_id,
         template,
         task,
         providers,
         started_at,
         status,
         completed_at \\ nil
       ) do
    providers_line = Enum.map_join(providers, ", ", &"\"#{&1}\"")

    completed_line =
      if completed_at, do: "completed_at: \"#{completed_at}\"\n", else: ""

    content = """
    ---
    kind: benchmark-run/v1
    run_id: #{run_id}
    template: #{template}
    task: #{task}
    providers: [#{providers_line}]
    started_at: "#{started_at}"
    #{completed_line}status: #{status}
    ---
    """

    FrontmatterWriter.atomic_write(Path.join(run_dir, "manifest.md"), content)
  end

  defp copy_frozen_task(task_path, run_dir) do
    File.cp!(task_path, Path.join(run_dir, "task.md"))
    :ok
  end

  defp render_output_md(provider, reply) when is_binary(reply) do
    """
    ---
    kind: benchmark-output/v1
    provider: #{provider}
    ---
    #{reply}
    """
  end

  defp render_output_md(provider, other),
    do: render_output_md(provider, inspect(other, pretty: true))

  # ------------------------------------------------------------------
  # Validation + paths
  # ------------------------------------------------------------------

  # Provider strings land in shadow-company slugs
  # (`_bench-<run-id>-<provider>/`), manifest YAML, output.md
  # frontmatter, and are substituted into AGENT.md. Every sink needs
  # a slug-safe string, so reject anything that isn't.
  @provider_slug_re ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  # Cap fan-out — each provider is a full shadow-company fork. 32 is
  # more than any practical A/B comparison while keeping a bad CLI
  # invocation from filling the disk.
  @max_providers 32

  defp validate_providers([]), do: {:error, :providers_list_empty}

  defp validate_providers(list) when length(list) > @max_providers do
    {:error, {:providers_too_many, length(list), @max_providers}}
  end

  defp validate_providers(list) do
    with :ok <- validate_provider_slugs(list) do
      validate_no_duplicates(list)
    end
  end

  defp validate_provider_slugs(list) do
    case Enum.reject(list, &Regex.match?(@provider_slug_re, &1)) do
      [] -> :ok
      bad -> {:error, {:providers_invalid_slug, bad}}
    end
  end

  defp validate_no_duplicates(list) do
    case list -- Enum.uniq(list) do
      [] -> :ok
      dups -> {:error, {:providers_duplicate, Enum.uniq(dups)}}
    end
  end

  defp validate_template_exists(dir) do
    cond do
      not File.dir?(dir) -> {:error, {:template_not_found, dir}}
      not File.regular?(Path.join(dir, "template.md")) -> {:error, {:not_a_template, dir}}
      true -> :ok
    end
  end

  defp validate_task_exists(template_dir, task_id) do
    path = Path.join([template_dir, "tasks", "#{task_id}.md"])

    if File.regular?(path) do
      {:ok, path}
    else
      {:error, {:task_not_in_template, task_id}}
    end
  end

  defp template_dir_for(name) do
    Application.app_dir(:glorbo, "priv/templates/companies/#{name}")
  end

  defp run_dir_for(base, run_id), do: Path.join([base, "benchmarks", "runs", run_id])

  # ------------------------------------------------------------------
  # Misc
  # ------------------------------------------------------------------

  defp generate_run_id do
    now =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> Calendar.strftime("%Y-%m-%dT%H%MZ")

    rand = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)

    "#{now}-bench-#{rand}"
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Public for Benchmarks.Orchestrator tests that want to inspect
  # the rendered output without going through the actual filesystem.
  @doc false
  def __render_output_md__(provider, reply), do: render_output_md(provider, reply)

  # Alias so callers who want the Benchmarks view of an existing run
  # can do it through a single namespace.
  @spec fetch(String.t(), keyword()) :: {:ok, Benchmarks.run()} | {:error, term()}
  def fetch(run_id, opts \\ []), do: Benchmarks.fetch(run_id, opts)
end
