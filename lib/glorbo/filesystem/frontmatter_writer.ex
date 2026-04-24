defmodule Glorbo.Filesystem.FrontmatterWriter do
  @moduledoc """
  Shared frontmatter rewrite helper used by both
  `Glorbo.TaskDefinition.write_frontmatter/2` and the AgentLive
  Configuration tab (paperclip-ux-gaps §5).

  `update_keys/2` preserves order, comments, indentation, and
  unknown keys — only rewriting the allow-listed keys present in
  `updates`. Missing keys are left alone (unlike `replace/2` which
  drops everything not in the allow-list).

  Atomic writes via a `.tmp` + rename so a crash mid-write never
  leaves a half-written file on disk.
  """

  @doc """
  Rewrite `file_path` by updating the frontmatter keys in `updates`.

  Returns `:ok` or `{:error, reason}`. Keys whose value is `nil` or
  `""` get serialized as empty strings (still present in the file)
  unless `remove_blank?` is `true`, in which case blank keys are
  stripped entirely.

  `atom` or `string` keys are both accepted — atoms are stringified
  before matching.
  """
  @spec update_keys(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def update_keys(file_path, updates, opts \\ [])
      when is_binary(file_path) and is_map(updates) and is_list(opts) do
    remove_blank? = Keyword.get(opts, :remove_blank?, false)

    with {:ok, content} <- File.read(file_path),
         {:ok, new_content} <- rewrite(content, updates, remove_blank?) do
      atomic_write(file_path, new_content)
    end
  end

  @doc """
  Atomic-write the content at `file_path`.

  Contract:

    * Target must be a regular file (or absent). Symlinks, FIFOs,
      directories are refused — callers writing into agent-writable
      trees would otherwise redirect the write through a planted
      symlink.
    * Tmp path includes a unique integer so concurrent writers to
      the same canonical file don't collide on the rename staging
      slot. The prior `file_path <> ".tmp"` literal collided under
      parallel frontmatter updates.
    * On any failure (stat, write, rename), the tmp is cleaned up
      best-effort and the original target is left intact.
  """
  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(file_path, new_content) do
    with :ok <- Glorbo.Filesystem.AgentWritableFile.ensure_writable(file_path) do
      tmp = file_path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

      case File.write(tmp, new_content, [:sync]) do
        :ok ->
          case File.rename(tmp, file_path) do
            :ok ->
              :ok

            {:error, _} = err ->
              _ = File.rm(tmp)
              err
          end

        {:error, _} = err ->
          _ = File.rm(tmp)
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp rewrite(content, updates, remove_blank?) do
    normalized = Map.new(updates, fn {k, v} -> {to_string(k), v} end)

    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, body] ->
        new_fm =
          fm
          |> String.split("\n")
          |> Enum.map(fn line -> rewrite_line(line, normalized) end)
          |> maybe_filter_blank(remove_blank?, normalized)
          |> Enum.join("\n")

        {:ok, "---\n" <> new_fm <> "\n---\n" <> body}

      _ ->
        {:error, :no_frontmatter}
    end
  end

  defp rewrite_line(line, updates) do
    case Regex.run(~r/\A(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\z/, line) do
      [_full, indent, key, _value] when is_map_key(updates, key) ->
        "#{indent}#{key}: #{yaml_scalar(updates[key])}"

      _ ->
        line
    end
  end

  defp maybe_filter_blank(lines, false, _), do: lines

  defp maybe_filter_blank(lines, true, updates) do
    Enum.reject(lines, fn line ->
      case Regex.run(~r/\A(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)\z/, line) do
        [_full, _indent, key, _value] ->
          is_map_key(updates, key) and updates[key] in [nil, ""]

        _ ->
          false
      end
    end)
  end

  @doc """
  YAML-scalar quoter. The canonical implementation; every other
  `yaml_scalar` in the codebase should delegate here.

  Behaviour:

    * `nil` → the bare YAML token `null`.
    * Integer / float → `to_string/1` (YAML parses these unambiguously).
    * Empty string → `""` (bare `` would parse as null).
    * Binary containing YAML-ambiguous characters (spaces, `#`, `:`,
      brackets, flow indicators), reserved words (true/false/null/
      yes/no), or ASCII control chars (`\\x00..\\x1f`) is
      double-quoted with standard escapes (`\\`, `\\\"`, `\\n`, `\\r`,
      `\\t`). Any remaining control byte is stripped so the scalar
      stays single-line.
    * Binary without ambiguity falls through verbatim — `status: approved`
      stays unquoted.
    * Anything else → `to_string/1` then recurse.
  """
  def yaml_scalar(nil), do: "null"
  def yaml_scalar(""), do: ~s("")
  # Emit booleans as bare YAML tokens so the parser reads them back as
  # booleans, not strings. GEP-40 `peer_review_required:` is strict
  # boolean per its enum; quoting `"true"` would break round-trip.
  def yaml_scalar(true), do: "true"
  def yaml_scalar(false), do: "false"

  def yaml_scalar(v) when is_binary(v) do
    if v =~ ~r/[\s#:\[\]\{\},&\*!\|>'"%@`]|\A(true|false|null|yes|no)\z|[\x00-\x1f]/ do
      escaped =
        v
        |> String.replace("\\", "\\\\")
        |> String.replace(~s("), ~s(\\"))
        |> String.replace("\n", "\\n")
        |> String.replace("\r", "\\r")
        |> String.replace("\t", "\\t")
        |> String.replace(~r/[\x00-\x1f]/, "")

      ~s("#{escaped}")
    else
      v
    end
  end

  def yaml_scalar(v) when is_integer(v) or is_float(v), do: to_string(v)
  def yaml_scalar(v), do: yaml_scalar(to_string(v))
end
