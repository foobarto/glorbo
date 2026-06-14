defmodule Glorbo.FileSpec.Validator do
  @moduledoc """
  Read-only workspace validator (GEP-25, R27).

  Walks a path, classifies each file via `Glorbo.FileSpec`, parses
  frontmatter, and emits findings against the spec module's schema:

    * `:missing_kind`                — file has no `kind:` frontmatter
    * `:kind_path_mismatch`          — `kind:` doesn't match path
    * `:yaml_parse_error`            — frontmatter YAML won't parse
    * `:missing_required_key`        — required schema key absent
    * `:enum_out_of_range`           — value not in declared enum
    * `:pattern_mismatch`            — value doesn't match pattern
    * `:cap_exceeded`                — body/line bigger than cap
    * `:unknown_key`                 — key not in required ∪ optional
    * `:unknown_file`                — path Glorbo doesn't recognise
    * `:io_error`                    — file not readable

  Never writes to disk. Returns a list of `Glorbo.FileSpec.finding/0`.

  Exit-code semantics:
    * `0` if no `:error`-level findings
    * `1` if any `:error`-level finding
  """

  alias Glorbo.FileSpec
  alias Glorbo.Filesystem.Frontmatter

  @type opts :: [
          kind: binary() | nil,
          severity: :error | :warning | :info | nil
        ]

  @doc """
  Walk `path` (file or directory) and return findings.
  """
  @spec validate_path(Path.t(), opts()) :: %{findings: [FileSpec.finding()], stats: map()}
  def validate_path(path, opts \\ []) when is_binary(path) do
    paths = expand_paths(path)

    findings =
      paths
      |> Enum.flat_map(&validate_file/1)
      |> filter_by_opts(opts)

    stats = build_stats(findings, length(paths))
    %{findings: findings, stats: stats}
  end

  @doc "Convenience: just the findings list."
  @spec findings(Path.t(), opts()) :: [FileSpec.finding()]
  def findings(path, opts \\ []) do
    validate_path(path, opts).findings
  end

  @doc """
  Exit code for a findings list — 1 if any `:error`-level finding,
  else 0.
  """
  @spec exit_code([FileSpec.finding()]) :: 0 | 1
  def exit_code(findings) do
    if Enum.any?(findings, &(&1.severity == :error)), do: 1, else: 0
  end

  # ------------------------------------------------------------------
  # Traversal
  # ------------------------------------------------------------------

  # Threatmodel: refuse to follow symlinks during validate. An agent
  # with workspace-write access could plant a symlink to /dev/zero
  # or /proc/kcore and DoS `glorbo validate`. lstat / read_link_info
  # gives us the link's own type instead of the resolved target.
  defp expand_paths(path) do
    case :file.read_link_info(path) do
      {:ok, {:file_info, _, :regular, _, _, _, _, _, _, _, _, _, _, _}} -> [path]
      {:ok, {:file_info, _, :directory, _, _, _, _, _, _, _, _, _, _, _}} -> walk_dir(path)
      _ -> []
    end
  end

  defp walk_dir(dir) do
    dir
    |> Path.join("**/*.*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&regular_non_symlink?/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.sort()
  end

  defp regular_non_symlink?(path) do
    case :file.read_link_info(path) do
      {:ok, {:file_info, _, :regular, _, _, _, _, _, _, _, _, _, _, _}} -> true
      _ -> false
    end
  end

  # Skip derived artifacts: SQLite db, build outputs, git state, runtime
  # logs, and bench-template fixture source trees (fixtures/ is read-only
  # ground truth the agent works against — not a Glorbo-owned format).
  @excluded_segments ~w(.git _build deps node_modules burrito_out logs fixtures)
  @excluded_extensions ~w(.db .db-wal .db-shm .log .pid .lock .tmp)
  defp excluded?(path) do
    segs = Path.split(path)

    Enum.any?(@excluded_segments, &(&1 in segs)) or
      Enum.any?(@excluded_extensions, &String.ends_with?(path, &1))
  end

  # ------------------------------------------------------------------
  # Per-file validation
  # ------------------------------------------------------------------

  defp validate_file(path) do
    case FileSpec.classify_by_path(path) do
      {:error, :unknown} ->
        [info(path, :unknown_file, "Glorbo doesn't recognise this file")]

      {:ok, mod} ->
        validate_with_spec(path, mod)
    end
  end

  defp validate_with_spec(path, mod) do
    case File.read(path) do
      {:error, reason} ->
        [error(path, :io_error, "can't read file: #{inspect(reason)}")]

      {:ok, content} ->
        case dispatch_parser(path, content) do
          {:ok, fm, body} ->
            schema = mod.frontmatter_schema()

            []
            |> check_kind(path, fm, mod)
            |> check_required(path, fm, schema)
            |> check_enums(path, fm, schema)
            |> check_patterns(path, fm, schema)
            |> check_caps(path, fm, body, schema)
            |> check_unknown_keys(path, fm, schema)
            |> check_kind_specific(path, fm, mod)

          {:error, :missing_kind_wrapper_json} ->
            [error(path, :missing_kind, "top-level `kind` field missing")]

          {:error, reason} ->
            [error(path, :yaml_parse_error, inspect(reason))]
        end
    end
  end

  # Dispatch to markdown-frontmatter parser or JSON parser based on path.
  defp dispatch_parser(path, content) do
    cond do
      String.ends_with?(path, ".json") ->
        case Jason.decode(content) do
          {:ok, %{} = obj} -> {:ok, obj, ""}
          {:ok, _} -> {:error, "top-level JSON must be an object"}
          {:error, e} -> {:error, Exception.message(e)}
        end

      String.ends_with?(path, ".jsonl") ->
        # For JSONL, we treat the whole file as a "multi-record" thing;
        # for now R27 validates line 0 as representative. Full per-line
        # validation lives in R27b (future).
        case content |> String.split("\n", trim: true) |> List.first() do
          nil ->
            {:ok, %{}, ""}

          line ->
            Jason.decode(line)
            |> case do
              {:ok, %{} = obj} -> {:ok, obj, ""}
              _ -> {:error, "first JSONL line is not a JSON object"}
            end
        end

      true ->
        Frontmatter.parse(content)
    end
  end

  # ------------------------------------------------------------------
  # Checks
  # ------------------------------------------------------------------

  defp check_kind(acc, path, fm, mod) do
    case Map.get(fm, "kind") || Map.get(fm, :kind) do
      nil ->
        [
          error(path, :missing_kind, "missing required `kind` field (expected `#{mod.kind()}`)")
          | acc
        ]

      value when is_binary(value) ->
        if value == mod.kind() do
          acc
        else
          [
            error(
              path,
              :kind_path_mismatch,
              "`kind: #{value}` but path shape expects `#{mod.kind()}`"
            )
            | acc
          ]
        end

      other ->
        [error(path, :missing_kind, "`kind` must be a string, got: #{inspect(other)}") | acc]
    end
  end

  defp check_required(acc, path, fm, schema) do
    Enum.reduce(schema.required, acc, fn key, acc ->
      str_key = Atom.to_string(key)

      if Map.has_key?(fm, str_key) or Map.has_key?(fm, key) do
        acc
      else
        [error(path, :missing_required_key, "missing required key `#{str_key}`") | acc]
      end
    end)
  end

  defp check_enums(acc, path, fm, %{enums: enums}) do
    Enum.reduce(enums, acc, fn {key, allowed}, acc ->
      case fetch_key(fm, key) do
        {:ok, value} when is_binary(value) ->
          if value in allowed do
            acc
          else
            [
              error(
                path,
                :enum_out_of_range,
                "`#{key}: #{inspect(value)}` not in allowed: #{inspect(allowed)}"
              )
              | acc
            ]
          end

        _ ->
          acc
      end
    end)
  end

  defp check_enums(acc, _path, _fm, _schema), do: acc

  defp check_patterns(acc, path, fm, %{patterns: patterns}) do
    Enum.reduce(patterns, acc, fn {key, regex}, acc ->
      case fetch_key(fm, key) do
        {:ok, value} when is_binary(value) ->
          if Regex.match?(regex, value) do
            acc
          else
            [
              error(
                path,
                :pattern_mismatch,
                "`#{key}: #{inspect(value)}` doesn't match #{inspect(regex)}"
              )
              | acc
            ]
          end

        _ ->
          acc
      end
    end)
  end

  defp check_patterns(acc, _path, _fm, _schema), do: acc

  defp check_caps(acc, path, _fm, body, %{caps: caps}) when map_size(caps) > 0 do
    Enum.reduce(caps, acc, fn
      {:body, max}, acc ->
        size = byte_size(body)

        if size > max do
          [
            error(
              path,
              :cap_exceeded,
              "body #{size} bytes > cap #{max} bytes"
            )
            | acc
          ]
        else
          acc
        end

      {:line, max}, acc ->
        over =
          body
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _} -> byte_size(line) > max end)

        if over == [] do
          acc
        else
          {_, line_no} = hd(over)

          [
            warning(
              path,
              :cap_exceeded,
              "line #{line_no}: #{byte_size(elem(hd(over), 0))} bytes > cap #{max} bytes",
              line_no
            )
            | acc
          ]
        end

      {_, _}, acc ->
        acc
    end)
  end

  defp check_caps(acc, _path, _fm, _body, _schema), do: acc

  defp check_unknown_keys(acc, path, fm, schema) do
    known =
      (schema.required ++ schema.optional)
      |> Enum.map(&Atom.to_string/1)
      |> MapSet.new()

    extra =
      fm
      |> Map.keys()
      |> Enum.filter(fn k -> is_binary(k) and not MapSet.member?(known, k) end)

    Enum.reduce(extra, acc, fn key, acc ->
      [warning(path, :unknown_key, "key `#{key}` not declared in schema") | acc]
    end)
  end

  # Per-kind extras the generic schema can't express (R28).
  defp check_kind_specific(acc, path, fm, Glorbo.FileSpec.TaskMd) do
    acc
    |> check_task_filename(path)
    |> check_task_dependencies(path, fm)
  end

  # GEP-25: a memory file's filename prefix (`user_` / `feedback_` /
  # `project_` / `reference_`) MUST equal its frontmatter `type:`. The memory
  # loader keys recall off both, so a prefix/type disagreement silently
  # mis-files the entry — flag it as an error.
  defp check_kind_specific(acc, path, fm, Glorbo.FileSpec.MemoryEntryMd) do
    # Guard: a non-binary `type:` (e.g. a YAML mapping) is already flagged by
    # the enum check; never run it through string interpolation here (would
    # raise Protocol.UndefinedError and abort the whole `glorbo validate`).
    type = Map.get(fm, "type")
    prefix = memory_filename_prefix(path)

    if is_binary(type) and is_binary(prefix) and type != "" and prefix != type do
      [
        error(
          path,
          :type_filename_mismatch,
          "filename prefix `#{prefix}_` does not match frontmatter `type: #{type}`"
        )
        | acc
      ]
    else
      acc
    end
  end

  defp check_kind_specific(acc, _path, _fm, _mod), do: acc

  defp check_task_filename(acc, path) do
    if Glorbo.FileSpec.TaskMd.canonical_filename?(path) do
      acc
    else
      [
        info(
          path,
          :non_canonical_task_filename,
          "task filename doesn't match GEP-13 `<project>-NN.md` convention"
        )
        | acc
      ]
    end
  end

  # GEP-47 D1: every `depends_on:` entry is a bare `task_id`, unique within
  # the company (GEP-13). Emit `task.dependency_missing` (error) when an entry
  # resolves to neither a live task (`projects/*/tasks/<id>.md`) nor an
  # archived one (`projects/*/history/tasks/<id>.md`) — the scheduler would
  # auto-cancel the dependent as failure-terminal, so a dangling dep is a real
  # break, not a cosmetic lint.
  defp check_task_dependencies(acc, path, fm) do
    case Map.get(fm, "depends_on") do
      deps when is_list(deps) ->
        Enum.reduce(deps, acc, fn dep, inner ->
          if is_binary(dep) and not dependency_resolves?(path, dep) do
            [
              error(
                path,
                :task_dependency_missing,
                "depends_on `#{dep}` resolves to no live or archived task"
              )
              | inner
            ]
          else
            inner
          end
        end)

      _ ->
        acc
    end
  end

  # Resolve a `depends_on` id against the filesystem WITHOUT globbing the id
  # (it is interpolated into a filename, so a glob/`..`/separator could escape
  # the tree). A non-GEP-13-shaped id can't name a real task, so it is treated
  # as unresolved (→ finding).
  defp dependency_resolves?(task_path, dep_id) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, dep_id) do
      # A TaskMd path is canonically `.../companies/<co>/projects/<proj>/tasks/
      # <file>.md` (TaskMd.@task_path_regex pins exactly one project + filename
      # segment), so three `dirname`s land on the company's `projects/` dir —
      # robust even when the base path itself contains a `projects/` segment.
      projects_dir = task_path |> Path.dirname() |> Path.dirname() |> Path.dirname()
      dependency_file_present?(projects_dir, dep_id)
    else
      false
    end
  end

  defp dependency_file_present?(projects_dir, dep_id) do
    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.any?(projects, fn proj -> live_or_archived?(projects_dir, proj, dep_id) end)

      # Can't enumerate projects (tree not present) — don't false-positive.
      _ ->
        true
    end
  end

  defp live_or_archived?(projects_dir, proj, dep_id) do
    proj_dir = Path.join(projects_dir, proj)

    real_dir?(proj_dir) and
      (real_file_under?(proj_dir, ["tasks", "#{dep_id}.md"]) or
         real_file_under?(proj_dir, ["history", "tasks", "#{dep_id}.md"]))
  end

  # Walk `segments` under `dir`, requiring EVERY intermediate component to be a
  # real directory and the leaf a real regular file — all via lstat
  # (`read_link_info`). `File.regular?/1` / `File.dir?/1` follow symlinks, so a
  # planted symlink (the target file, or any project/`tasks` dir above it) would
  # otherwise fake a resolution and suppress the finding — even though the
  # validator's own traversal skips symlinks and the dispatch-time reader
  # (`AgentWritableFile`, `read_link_info`) rejects them, leaving the task
  # genuinely missing at runtime (codex #71 P2).
  defp real_file_under?(dir, segments) do
    {ancestors, [leaf]} = Enum.split(segments, length(segments) - 1)

    walked =
      Enum.reduce_while(ancestors, dir, fn seg, cur ->
        next = Path.join(cur, seg)
        if real_dir?(next), do: {:cont, next}, else: {:halt, nil}
      end)

    walked != nil and regular_file?(Path.join(walked, leaf))
  end

  defp real_dir?(path), do: link_info_type(path) == :directory
  defp regular_file?(path), do: link_info_type(path) == :regular

  # The lstat'd type of `path` (does NOT follow a final symlink), or nil if the
  # path is absent/unreadable. `:file_info`'s 3rd tuple element is the type.
  defp link_info_type(path) do
    case :file.read_link_info(path) do
      {:ok, info} -> elem(info, 2)
      _ -> nil
    end
  end

  # Anchor to the basename — an ancestor dir like `/memory/user_backup/` must
  # not be mistaken for the file's own prefix.
  defp memory_filename_prefix(path) do
    case Regex.run(~r"\A(user|feedback|project|reference)_", Path.basename(path)) do
      [_, prefix] -> prefix
      _ -> nil
    end
  end

  # ------------------------------------------------------------------
  # Finding builders
  # ------------------------------------------------------------------

  defp fetch_key(fm, key) do
    str_key = Atom.to_string(key)

    case Map.fetch(fm, str_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(fm, key)
    end
  end

  defp error(path, code, message) do
    %{severity: :error, file: path, code: code, message: message, line: nil}
  end

  defp warning(path, code, message, line \\ nil) do
    %{severity: :warning, file: path, code: code, message: message, line: line}
  end

  defp info(path, code, message) do
    %{severity: :info, file: path, code: code, message: message, line: nil}
  end

  # ------------------------------------------------------------------
  # Stats + filters
  # ------------------------------------------------------------------

  defp filter_by_opts(findings, opts) do
    findings
    |> filter_by_kind(opts[:kind])
    |> filter_by_severity(opts[:severity])
  end

  defp filter_by_kind(findings, nil), do: findings

  defp filter_by_kind(findings, kind) when is_binary(kind) do
    # kind filter matches spec kind value; we need to know which spec
    # produced each finding. Cheapest: re-classify path.
    Enum.filter(findings, fn f ->
      case FileSpec.classify_by_path(f.file) do
        {:ok, mod} -> mod.kind() == kind
        _ -> false
      end
    end)
  end

  defp filter_by_severity(findings, nil), do: findings

  defp filter_by_severity(findings, sev) when sev in [:error, :warning, :info] do
    order = %{error: 0, warning: 1, info: 2}
    max_order = order[sev]
    Enum.filter(findings, &(order[&1.severity] <= max_order))
  end

  defp build_stats(findings, file_count) do
    %{
      files_examined: file_count,
      errors: Enum.count(findings, &(&1.severity == :error)),
      warnings: Enum.count(findings, &(&1.severity == :warning)),
      infos: Enum.count(findings, &(&1.severity == :info)),
      total: length(findings)
    }
  end
end
