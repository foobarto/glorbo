defmodule Glorbo.Skills.Resolver do
  @moduledoc """
  Per-task-id skills materialisation + cleanup (D-04, D-05, D-38..D-40).

  Copies the skill files listed in `Glorbo.Agent.Spec.skills` from
  `<base>/skills/<name>.md` to the per-task workspace directory
  `.glorbo-run/<task_id>/.glorbo-skills/<name>.md`, then writes a
  `INDEX.md` listing the resolved skills with their titles.

  ## Missing skills

  Missing skill files emit a `skill.missing` audit event via the injected
  `:audit_fun` and are DROPPED from the result. The caller (Dispatch) still
  proceeds with the remaining skills (D-39 — recoverable; Director notices
  the audit).

  ## Security (T-03-19)

  Skill names are validated against `@skill_name_regex` BEFORE any file IO.
  A traversal attempt (`../etc/passwd`) returns `{:error, {:invalid_skill_name, ...}}`
  without touching the filesystem.

  ## Dependency injection

  All IO is routed through a `:fs_fun` map (defaults to `File.*/2`
  equivalents) so tests can stub it. `:audit_fun` defaults to
  `Glorbo.Company.AuditLog.append/2`.
  """
  require Logger

  alias Glorbo.Company.AuditLog

  @skill_name_regex ~r/\A[a-z][a-z0-9_-]{0,63}\z/

  @type opts :: [
          base: Path.t(),
          company: String.t(),
          agent_slug: String.t(),
          audit_fun: (String.t(), map() -> any()),
          fs_fun: map()
        ]

  @doc """
  Copy requested skills into `target_dir` and write `INDEX.md`.

  Returns `{:ok, resolved_names}` where `resolved_names` is the subset of
  requested names whose source files were present on disk. Missing skills
  are logged via `skill.missing` audit events and excluded from the result.

  Returns `{:error, {:invalid_skill_name, name}}` without any IO if any
  requested name fails the `@skill_name_regex` gate (T-03-19).
  """
  @spec materialize([String.t()], Path.t(), opts()) ::
          {:ok, [String.t()]} | {:error, term()}
  def materialize(skills, target_dir, opts \\ [])
      when is_list(skills) and is_binary(target_dir) and is_list(opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    company = Keyword.get(opts, :company, "")
    agent_slug = Keyword.get(opts, :agent_slug, "")
    audit_fun = Keyword.get(opts, :audit_fun, &AuditLog.append/2)
    fs_fun = Keyword.get(opts, :fs_fun, default_fs_fun())

    with :ok <- validate_all_names(skills) do
      do_materialize(skills, target_dir, base, company, agent_slug, audit_fun, fs_fun)
    end
  end

  @doc """
  Remove a per-task run directory recursively. Idempotent — a non-existent
  directory returns `:ok` without raising.

  Uses `File.rm_rf/1` which does NOT follow symlinks (Elixir stdlib
  semantics) — deleting a dir containing a symlink to `/etc` removes the
  symlink entry, not `/etc`'s contents.
  """
  @spec cleanup(Path.t()) :: :ok
  def cleanup(run_dir) when is_binary(run_dir) do
    case File.rm_rf(run_dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        Logger.warning(
          "skills.cleanup failed for #{inspect(path)}: #{inspect(reason)} — ignoring (best-effort cleanup)"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("skills.cleanup raised: #{Exception.message(e)} — ignoring")
      :ok
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp validate_all_names(skills) do
    Enum.reduce_while(skills, :ok, fn name, :ok ->
      if is_binary(name) and Regex.match?(@skill_name_regex, name) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_skill_name, to_string(name)}}}
      end
    end)
  end

  defp do_materialize([], target_dir, _base, _company, _agent_slug, _audit_fun, fs_fun) do
    # S5: empty list → don't create INDEX.md, return immediately. Dispatch's
    # try/after cleanup handles the run_dir lifecycle.
    _ = fs_fun.mkdir_p!.(target_dir)
    {:ok, []}
  end

  defp do_materialize(skills, target_dir, base, company, agent_slug, audit_fun, fs_fun) do
    fs_fun.mkdir_p!.(target_dir)

    resolved =
      skills
      |> Enum.reduce([], fn name, acc ->
        case resolve_skill_src(name, base, fs_fun) do
          nil ->
            emit_missing_audit(audit_fun, company, agent_slug, name)
            acc

          src when is_binary(src) ->
            dst = Path.join(target_dir, "#{name}.md")
            fs_fun.cp!.(src, dst)
            [{name, src} | acc]
        end
      end)
      |> Enum.reverse()

    write_index!(target_dir, resolved, fs_fun)
    {:ok, Enum.map(resolved, fn {name, _src} -> name end)}
  end

  # Prefer per-instance skills under `<base>/skills/<name>.md` (the
  # Director can override or shadow any builtin), then fall back to the
  # bundled skill templates under `priv/templates/skills/`. Returns
  # the resolved absolute path, or `nil` if neither exists.
  defp resolve_skill_src(name, base, fs_fun) do
    user = Path.join([base, "skills", "#{name}.md"])
    builtin = Path.join([Application.app_dir(:glorbo, "priv/templates/skills"), "#{name}.md"])

    cond do
      regular_file?(user, fs_fun) -> user
      regular_file?(builtin, fs_fun) -> builtin
      true -> nil
    end
  end

  defp regular_file?(path, fs_fun) do
    case fs_fun.lstat.(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp write_index!(target_dir, resolved, fs_fun) do
    content = render_index(resolved, fs_fun)
    path = Path.join(target_dir, "INDEX.md")
    fs_fun.write!.(path, content)
  end

  defp render_index(resolved, fs_fun) do
    header = "# Available Skills\n\n"

    body =
      Enum.map_join(resolved, "\n", fn {name, src} ->
        title = extract_title(name, src, fs_fun)
        "- [#{name}](./#{name}.md) — #{title}"
      end)

    header <> body <> "\n"
  end

  # Extract first-line title from a skill markdown file. If the file starts
  # with `# Title`, the text after `# ` is the title; otherwise fall back to
  # the skill name.
  defp extract_title(name, src, fs_fun) do
    case fs_fun.read.(src) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.find(fn line -> String.trim(line) != "" end)
        |> case do
          nil -> name
          line -> parse_title_line(line, name)
        end

      _ ->
        name
    end
  end

  defp parse_title_line(line, fallback) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "#") do
      trimmed
      |> String.trim_leading("#")
      |> String.trim()
      |> case do
        "" -> fallback
        other -> other
      end
    else
      fallback
    end
  end

  defp emit_missing_audit(audit_fun, company, agent_slug, skill_name) do
    entry = %{
      action: "skill.missing",
      actor: "system",
      agent: agent_slug,
      skill_name: skill_name
    }

    audit_fun.(company, entry)
    :ok
  rescue
    e ->
      Logger.warning("skills.resolver audit emit failed: #{Exception.message(e)}")
      :ok
  end

  # Production defaults — File.* modules. Tests pass a map replacing specific
  # keys with stub lambdas.
  defp default_fs_fun do
    %{
      mkdir_p!: &File.mkdir_p!/1,
      exists?: &File.exists?/1,
      lstat: &File.lstat/1,
      cp!: &File.cp!/2,
      write!: &File.write!/2,
      read: &File.read/1
    }
  end
end
