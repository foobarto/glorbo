defmodule Glorbo.Filesystem.Frontmatter do
  @moduledoc """
  Safe-loader YAML frontmatter parser.

  Wraps `YamlFrontMatter.parse/1` (which in turn uses `YamlElixir` on top of
  `yamerl` — a safe, anchor-bounded loader; no Ruby/Python-style `!!tag`
  class instantiation). Returns `{:ok, meta_map, body}` or `{:error, reason}`.

  Threat-model note (T-2-01): arbitrary YAML from disk is untrusted; this
  loader MUST NOT execute code. `yamerl` is a pure-Erlang libyaml-style
  scanner/parser and does not load tagged objects. Unit tests in
  `frontmatter_test.exs` assert this explicitly with a `!!python/object`
  payload.

  Size cap (residual-risk mitigation for billion-laughs / expansion bombs):
  content above `@max_content_bytes` is rejected before parsing.
  """

  # 10 MB — far above any realistic markdown frontmatter, well below the
  # expansion-bomb threshold for yamerl.
  @max_content_bytes 10_485_760

  @doc """
  Parse `content` into `{:ok, meta_map, body}` or `{:error, reason}`.

  Behaviour:
    - No `---` fence → `{:ok, %{}, content}`
    - Valid frontmatter → `{:ok, parsed_map, body_after_fence}`
    - Invalid YAML → `{:error, reason}`
    - Content over size cap → `{:error, :too_large}`
  """
  @spec parse(binary()) :: {:ok, map(), binary()} | {:error, term()}
  def parse(content) when is_binary(content) do
    # WR-02: normalise CRLF so Windows-authored files match the strict
    # `---\n` fence used by both this parser and the Python worker's
    # `_split_frontmatter`. Previously `String.starts_with?(content, "---")`
    # was lenient about what came after the dashes, diverging from the
    # worker's stricter check.
    normalized = String.replace(content, "\r\n", "\n")

    cond do
      byte_size(normalized) > @max_content_bytes ->
        {:error, :too_large}

      not String.starts_with?(normalized, "---\n") ->
        {:ok, %{}, normalized}

      true ->
        do_parse(normalized)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp do_parse(content) do
    case YamlFrontMatter.parse(content) do
      {:ok, meta, body} ->
        {:ok, normalize(meta), body}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize(nil), do: %{}
  defp normalize(map) when is_map(map), do: map
  defp normalize(_), do: %{}
end
