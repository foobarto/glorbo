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
  Atomic-write the content at `file_path`. Exposed so callers
  (e.g. file editors that rewrite the whole body, not just frontmatter)
  can share the same crash-safety guarantee.
  """
  @spec atomic_write(Path.t(), binary()) :: :ok | {:error, term()}
  def atomic_write(file_path, new_content) do
    tmp = file_path <> ".tmp"

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
  YAML-scalar quoter — mirrors `TaskDefinition.yaml_scalar/1`. Values
  that look like booleans / nulls / contain YAML-special characters
  are double-quoted; simple identifiers fall through verbatim.
  """
  def yaml_scalar(nil), do: "null"

  def yaml_scalar(v) when is_binary(v) do
    if v =~ ~r/[\s#:\[\]\{\},&\*!\|>'"%@`]|\A(true|false|null|yes|no)\z/ do
      escaped = String.replace(v, ~s("), ~s(\\"))
      ~s("#{escaped}")
    else
      v
    end
  end

  def yaml_scalar(v) when is_integer(v) or is_float(v), do: to_string(v)
  def yaml_scalar(v), do: yaml_scalar(to_string(v))
end
