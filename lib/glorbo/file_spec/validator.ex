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

  defp expand_paths(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> [path]
      {:ok, %{type: :directory}} -> walk_dir(path)
      _ -> []
    end
  end

  defp walk_dir(dir) do
    dir
    |> Path.join("**/*.*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded?/1)
    |> Enum.sort()
  end

  # Skip derived artifacts: SQLite db, build outputs, git state.
  @excluded_segments ~w(.git _build deps node_modules burrito_out)
  defp excluded?(path) do
    segs = Path.split(path)

    Enum.any?(@excluded_segments, &(&1 in segs)) or
      String.ends_with?(path, ".db") or
      String.ends_with?(path, ".db-wal") or
      String.ends_with?(path, ".db-shm")
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
