defmodule Glorbo.FileSpec.Formatter do
  @moduledoc """
  Canonical-form rewriter for on-disk files under `~/.glorbo/`
  (GEP-25 R33).

  Produces byte-for-byte stable output:

    * YAML frontmatter keys ordered by each spec's
      `canonical_key_order/0`; unknown keys (warning-level from the
      validator) land alphabetically after the known block.
    * Fence normalisation: `---\\n` at the top, `---\\n` between
      frontmatter and body, no leading blank lines.
    * Body preserved byte-for-byte — the formatter **never**
      touches what's below the closing `---`. Task prose, agent
      instructions, channel-log entries stay as the director wrote
      them.
    * File ends with exactly one trailing `\\n`.

  Scope (GEP-25 D3): syntactic only. The formatter does NOT add
  missing required fields, fill defaults, rename files, or
  rewrite body prose. Use the Validator for semantic gaps.

  **Idempotence** is the load-bearing property. Round-trip
  `format(format(x)) == format(x)` for every fixture — asserted
  by tests.

  Exposes three entry points for the CLI:

    * `format_content/2` — pure transform, takes content + path,
      returns `{:ok, :unchanged | :changed, binary()}`.
    * `check_path/1` — walks a path, returns `{changed: [paths],
      unchanged: n, stats: ...}` without writing.
    * `write_path/1` — applies the formatter via atomic tmp+rename
      (same pattern as `FrontmatterWriter`).

  JSON / JSONL files are skipped (leave intact) — the formatter
  scope is YAML frontmatter. Unknown paths yield `:skipped`.
  """

  alias Glorbo.FileSpec
  alias Glorbo.Filesystem.Frontmatter

  @type change :: :unchanged | :changed | :skipped
  @type stats :: %{
          required(:files_examined) => non_neg_integer(),
          required(:changed) => non_neg_integer(),
          required(:unchanged) => non_neg_integer(),
          required(:skipped) => non_neg_integer()
        }

  # ------------------------------------------------------------------
  # Pure content transform
  # ------------------------------------------------------------------

  @doc """
  Given a file's path + content, return either the canonical form
  (`:changed`) or the original content unchanged (`:unchanged`),
  or `:skipped` for files this formatter doesn't touch.

  Pure — does not touch disk.
  """
  @spec format_content(Path.t(), binary()) ::
          {:ok, change(), binary()} | {:error, term()}
  def format_content(path, content) when is_binary(path) and is_binary(content) do
    with {:ok, mod} <- classify(path, content),
         :ok <- only_markdown?(path) do
      do_format(content, mod)
    else
      {:error, :json} -> {:ok, :skipped, content}
      {:error, :unknown} -> {:ok, :skipped, content}
      other -> other
    end
  end

  defp only_markdown?(path) do
    cond do
      String.ends_with?(path, ".json") -> {:error, :json}
      String.ends_with?(path, ".jsonl") -> {:error, :json}
      true -> :ok
    end
  end

  defp classify(path, content) do
    # Prefer kind-based classification once we can read frontmatter;
    # fall back to path-match for pre-kind files. R33 cares only about
    # path match since the kind: cut is R26.2b.
    case FileSpec.classify_by_path(path) do
      {:ok, mod} ->
        _ = content
        {:ok, mod}

      {:error, :unknown} ->
        {:error, :unknown}
    end
  end

  defp do_format(content, mod) do
    # Frontmatter.parse/1 is strict about `content` starting with
    # `---\n` — no leading blanks. Trim leading whitespace before
    # parsing so files that drifted into having a leading newline
    # still get normalised.
    trimmed = String.trim_leading(content, "\n")

    case Frontmatter.parse(trimmed) do
      {:ok, %{} = fm, body} when map_size(fm) > 0 ->
        rebuilt = rebuild(fm, body, mod)
        change = if rebuilt == content, do: :unchanged, else: :changed
        {:ok, change, rebuilt}

      {:ok, _empty_fm, _body} ->
        # No frontmatter at all — leave alone. The validator already
        # flags missing-frontmatter files via :missing_required_key.
        {:ok, :unchanged, content}

      {:error, reason} ->
        {:error, {:yaml_parse_error, reason}}
    end
  end

  defp rebuild(fm, body, mod) do
    order = mod.canonical_key_order() |> Enum.map(&Atom.to_string/1)

    keyed = stringify_keys(fm)

    known =
      Enum.flat_map(order, fn k ->
        case Map.fetch(keyed, k) do
          {:ok, v} -> [{k, v}]
          :error -> []
        end
      end)

    unknown_keys = keyed |> Map.keys() |> Kernel.--(order) |> Enum.sort()
    unknown = Enum.map(unknown_keys, &{&1, Map.fetch!(keyed, &1)})

    pairs = known ++ unknown

    yaml = emit_pairs(pairs) |> IO.iodata_to_binary()

    # Canonical layout: fence, yaml (trailing newline), fence, body.
    body_trimmed_left = String.trim_leading(body, "\n")
    body_trailing_nl = ensure_trailing_newline(body_trimmed_left)

    "---\n" <> yaml <> "---\n" <> body_trailing_nl
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp ensure_trailing_newline(""), do: ""

  defp ensure_trailing_newline(binary) do
    if String.ends_with?(binary, "\n"), do: binary, else: binary <> "\n"
  end

  # ------------------------------------------------------------------
  # YAML emission (minimal — covers Glorbo's actual frontmatter shapes)
  # ------------------------------------------------------------------

  defp emit_pairs(pairs) do
    Enum.map(pairs, &emit_pair(&1, 0))
  end

  defp emit_pair({k, v}, indent), do: emit_key_value(k, v, indent)

  defp emit_key_value(k, v, indent) when is_binary(v) do
    [pad(indent), k, ": ", emit_scalar(v), "\n"]
  end

  defp emit_key_value(k, v, indent) when is_number(v) or is_boolean(v) or is_nil(v) do
    [pad(indent), k, ": ", emit_scalar(v), "\n"]
  end

  defp emit_key_value(k, v, indent) when is_list(v) do
    if v == [] do
      [pad(indent), k, ": []\n"]
    else
      [
        pad(indent),
        k,
        ":\n",
        Enum.map(v, fn item -> [pad(indent + 2), "- ", emit_list_item(item, indent + 2), "\n"] end)
      ]
    end
  end

  defp emit_key_value(k, v, indent) when is_map(v) do
    if map_size(v) == 0 do
      [pad(indent), k, ": {}\n"]
    else
      inner =
        v
        |> Enum.sort_by(fn {mk, _} -> to_string(mk) end)
        |> Enum.map(fn {mk, mv} -> emit_key_value(to_string(mk), mv, indent + 2) end)

      [pad(indent), k, ":\n", inner]
    end
  end

  # List-item emission. For scalar items, one line. For nested maps
  # (rare in our frontmatter — only `goals:` and `budget:` do it),
  # emit the first key inline with `- ` and subsequent keys indented.
  defp emit_list_item(item, _indent) when is_binary(item) do
    emit_scalar(item)
  end

  defp emit_list_item(item, _indent) when is_number(item) or is_boolean(item) or is_nil(item) do
    emit_scalar(item)
  end

  defp emit_list_item(item, indent) when is_map(item) do
    # `- key1: value1\n  key2: value2` shape.
    #
    # The dash line is already written at column `indent` (via the
    # caller's `pad(indent) ++ "- "`), so the first key sits at
    # column `indent + 2`. Continuation keys in the same item must
    # align with that first key — one pad deeper than `indent`, not
    # at `indent` itself (which is the dash column).
    pairs = Enum.sort_by(item, fn {k, _} -> to_string(k) end)

    case pairs do
      [] ->
        "{}"

      [{first_k, first_v} | rest] ->
        first_line = [to_string(first_k), ": ", emit_leaf(first_v)]

        rest_lines =
          Enum.map(rest, fn {k, v} ->
            ["\n", pad(indent + 2), to_string(k), ": ", emit_leaf(v)]
          end)

        [first_line, rest_lines]
    end
  end

  # Scalar emission — quote only when the YAML parser might
  # otherwise reinterpret the value.
  defp emit_scalar(nil), do: "null"
  defp emit_scalar(true), do: "true"
  defp emit_scalar(false), do: "false"
  defp emit_scalar(n) when is_integer(n), do: Integer.to_string(n)
  defp emit_scalar(n) when is_float(n), do: Float.to_string(n)

  defp emit_scalar(s) when is_binary(s) do
    if needs_quoting?(s), do: ~s("#{escape_for_dquote(s)}"), else: s
  end

  # Nested-map-inside-list leaf values only support scalars;
  # nested lists/maps there are reserved for a later round.
  defp emit_leaf(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: emit_scalar(v)

  defp emit_leaf(v), do: inspect(v)

  # Quote a scalar when (a) it's empty, (b) it collides with a YAML
  # special, or (c) it contains characters that wouldn't round-trip
  # unquoted. Keep the list narrow — over-quoting is ugly.
  defp needs_quoting?(""), do: true
  defp needs_quoting?("true"), do: true
  defp needs_quoting?("false"), do: true
  defp needs_quoting?("null"), do: true
  defp needs_quoting?("~"), do: true

  defp needs_quoting?(s) do
    starts_special =
      String.starts_with?(s, [" ", "\t", "#", "&", "*", "!", "|", ">", "%", "@", "`"])

    cond do
      starts_special -> true
      String.contains?(s, [":", "#", "\n", "\"", "'"]) -> true
      # Looks like a number → quote so it reads back as string.
      Regex.match?(~r/\A-?\d+(\.\d+)?\z/, s) -> true
      true -> false
    end
  end

  defp escape_for_dquote(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp pad(0), do: ""
  defp pad(n) when n > 0, do: String.duplicate(" ", n)

  # ------------------------------------------------------------------
  # Path walks — check + write
  # ------------------------------------------------------------------

  @doc """
  Walk `path` (file or directory), classify, parse, rebuild — does
  not write. Returns the list of paths that would change + stats.
  """
  @spec check_path(Path.t()) :: %{changed: [Path.t()], stats: stats()}
  def check_path(path) when is_binary(path) do
    traverse(path, &check_one/1)
  end

  defp check_one(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case format_content(file_path, content) do
          {:ok, :changed, _new} -> {file_path, :changed}
          {:ok, :unchanged, _} -> {file_path, :unchanged}
          {:ok, :skipped, _} -> {file_path, :skipped}
          {:error, _reason} -> {file_path, :skipped}
        end

      {:error, _} ->
        {file_path, :skipped}
    end
  end

  @doc """
  Walk `path`, classify, parse, rebuild, **write** (atomic tmp+rename)
  when content would change. Returns the list of paths actually
  rewritten + stats.
  """
  @spec write_path(Path.t()) :: %{changed: [Path.t()], stats: stats()}
  def write_path(path) when is_binary(path) do
    traverse(path, &write_one/1)
  end

  defp write_one(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case format_content(file_path, content) do
          {:ok, :changed, new_content} ->
            case atomic_write(file_path, new_content) do
              :ok -> {file_path, :changed}
              {:error, _} -> {file_path, :skipped}
            end

          {:ok, :unchanged, _} ->
            {file_path, :unchanged}

          {:ok, :skipped, _} ->
            {file_path, :skipped}

          {:error, _} ->
            {file_path, :skipped}
        end

      {:error, _} ->
        {file_path, :skipped}
    end
  end

  # Atomic tmp+rename — same pattern as the other filesystem
  # writers in the tree (Router, Memory.Writer, FrontmatterWriter).
  # A crash between write and rename leaves the original intact.
  defp atomic_write(path, content) do
    tmp = path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp traverse(path, per_file_fun) do
    paths = expand_paths(path)

    results = Enum.map(paths, per_file_fun)

    changed = for {p, :changed} <- results, do: p
    stats = build_stats(results)

    %{changed: changed, stats: stats}
  end

  defp expand_paths(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} ->
        [path]

      {:ok, %{type: :directory}} ->
        path
        |> Path.join("**/*.md")
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&excluded?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  @excluded_segments ~w(.git _build deps node_modules burrito_out)
  defp excluded?(path) do
    segs = Path.split(path)
    Enum.any?(@excluded_segments, &(&1 in segs))
  end

  defp build_stats(results) do
    changed = Enum.count(results, fn {_, s} -> s == :changed end)
    unchanged = Enum.count(results, fn {_, s} -> s == :unchanged end)
    skipped = Enum.count(results, fn {_, s} -> s == :skipped end)

    %{
      files_examined: length(results),
      changed: changed,
      unchanged: unchanged,
      skipped: skipped
    }
  end
end
