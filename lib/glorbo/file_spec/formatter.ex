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
    * Multi-line strings emit as YAML `|` (clip) block scalars
      instead of double-quoted scalars with literal `\\n`. Applies
      both to top-level fields (`done_when:`, future paragraph
      fields) and to values inside list-of-maps items
      (`handoff_chain[].reason`). `|` clip chomping always yields
      a single trailing newline; the formatter normalises to that
      shape so a string written without one becomes `:changed` on
      first pass and `:unchanged` thereafter.
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
    if block_scalar?(v) do
      [pad(indent), k, ": |\n", emit_block_scalar_body(v, indent + 2), "\n"]
    else
      [pad(indent), k, ": ", emit_scalar(v), "\n"]
    end
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
        first_line = emit_list_item_pair(first_k, first_v, indent + 2)

        rest_lines =
          Enum.map(rest, fn {k, v} ->
            ["\n", pad(indent + 2), emit_list_item_pair(k, v, indent + 2)]
          end)

        [first_line, rest_lines]
    end
  end

  # Multi-line values use a block scalar; everything else falls
  # back to `emit_leaf`.
  defp emit_list_item_pair(k, v, indent) when is_binary(v) do
    if block_scalar?(v) do
      [to_string(k), ": |\n", emit_block_scalar_body(v, indent + 2)]
    else
      [to_string(k), ": ", emit_leaf(v)]
    end
  end

  defp emit_list_item_pair(k, v, _indent),
    do: [to_string(k), ": ", emit_leaf(v)]

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

  # Multi-line strings round-trip cleanly only via YAML `|`
  # block scalars. Embedded `\n` characters in a double-quoted
  # form are valid YAML but the resulting frontmatter is hostile
  # to read (single-line `"line1\nline2"` instead of the natural
  # paragraph shape). Pick `|` when the string contains an
  # internal newline (a single trailing `\n` doesn't count — that
  # gets normalised away by `String.trim_trailing/2` on emit).
  defp block_scalar?(s) when is_binary(s) do
    String.contains?(String.trim_trailing(s, "\n"), "\n")
  end

  # Render the body of a `|` block scalar at `indent` columns.
  # Returns iodata for the indented lines joined by `\n` *without*
  # a trailing newline — the caller adds whichever terminator fits
  # the surrounding context (top-level pairs add `\n`, list-item
  # pairs leave it to the outer separator). `|` (clip) chomping
  # always produces a single trailing newline, so strip every
  # trailing `\n` from the input first; the YAML reader will
  # re-add exactly one when round-tripping.
  defp emit_block_scalar_body(s, indent) do
    s
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map(fn
      "" -> ""
      line -> [pad(indent), line]
    end)
    |> Enum.intersperse("\n")
  end

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

  # Wave 28: random-suffix + O_EXCL — `mix glorbo fmt` operates on
  # agent-RW files (task md, AGENT.md, etc.). Predictable
  # `<file>.tmp.<monotonic-int>` was attacker-plantable as a
  # symlink in the same directory. Same pattern as Router /
  # Memory.Writer / FrontmatterWriter post-wave-22.
  defp atomic_write(path, content) do
    rand = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{path}.tmp-#{rand}"

    # B-013: `fmt --write` reformats every classified markdown under the
    # workspace, including the root `config.md` that carries
    # `secret_key_base` / `dashboard_token` / `erl_cookie` at mode 0600.
    # The fresh exclusive temp is created at the process umask (typically
    # 0644); renaming it over a 0600 file silently relaxes the secrets
    # file to world-readable. Preserve the original file's mode (chmod the
    # temp to match before rename); default to 0600 for new files so a
    # secret-bearing file is never created world-readable.
    mode =
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o777)
        _ -> 0o600
      end

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :file.close(fd)

        case result do
          :ok ->
            with :ok <- File.chmod(tmp, mode),
                 :ok <- File.rename(tmp, path) do
              :ok
            else
              {:error, _} = err ->
                _ = File.rm(tmp)
                err
            end

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        err
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
    # Codex round-4 finding (PR #36): `File.stat` and `File.regular?`
    # follow symlinks. If `glorbo fmt --write` is run over a path
    # that contains agent-planted symlinks (e.g. an agent symlinks
    # `projects/x/tasks/t.md` → `/etc/passwd`), the formatter would
    # read the link target and write a re-rendered version BACK
    # into the company tree — exfiltrating host content into a
    # location agents can read. Use `File.lstat` so symlinks are
    # never followed during expansion or filtering.
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        [path]

      {:ok, %{type: :directory}} ->
        path
        |> Path.join("**/*.md")
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&lstat_regular_file?/1)
        |> Enum.reject(&excluded?/1)
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp lstat_regular_file?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _ -> false
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
