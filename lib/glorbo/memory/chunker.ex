defmodule Glorbo.Memory.Chunker do
  @moduledoc """
  Splits a company's markdown home tree into embeddable chunks for
  GEP-0058 indexing.

  A "chunk" is a `{source_path, chunk_id, text}` tuple — `source_path`
  is the path relative to the home base (so the same chunk id is stable
  across reindexes of an unmodified file), `chunk_id` is the 0-based
  ordinal within the file, `text` is the chunk body.

  Chunking is deliberately simple and dependency-free: split each file on
  blank lines (paragraph boundaries), trim, drop empties. Single-director
  scale doesn't need a token-aware splitter, and keeping it pure keeps the
  Burrito binary lean (GEP-53 D13). Oversize files are capped the same way
  the reindex walker caps them so one giant markdown file can't OOM the
  embed pass.
  """

  alias Glorbo.Filesystem.AgentWritableFile

  # Match the reindex walker's per-file cap (10 MB) so the embed pass and
  # the domain-row pass agree on what's too large.
  @max_file_bytes 10_485_760

  # Skip chunks shorter than this — single-word fragments add noise to the
  # FTS5 index and embed to near-useless vectors.
  @min_chunk_bytes 8

  @type chunk :: {String.t(), non_neg_integer(), String.t()}

  @doc """
  Walk `companies/<company>/` under `base` and return every markdown
  chunk as a `{relative_source_path, chunk_id, text}` tuple.

  Symlinked-ancestor paths are rejected (mirrors the reindex walker's
  isolation discipline) so an agent can't smuggle out-of-tree content
  into another company's index.
  """
  @spec chunk_company(Path.t(), String.t()) :: [chunk()]
  def chunk_company(base, company) when is_binary(base) and is_binary(company) do
    company_dir = Path.join([base, "companies", company])
    company_abs = Path.expand(company_dir)

    company_dir
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.filter(&safe_path?(&1, company_abs))
    |> Enum.flat_map(&chunk_file(&1, base))
  end

  defp safe_path?(path, company_abs) do
    expanded = Path.expand(path)

    String.starts_with?(expanded, company_abs <> "/") and
      not AgentWritableFile.any_symlink_in_path?(expanded)
  end

  defp chunk_file(path, base) do
    rel = Path.relative_to(path, base)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        case File.read(path) do
          {:ok, content} -> chunks_of(rel, content)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp chunks_of(rel, content) do
    content
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(byte_size(&1) < @min_chunk_bytes))
    |> Enum.with_index()
    |> Enum.map(fn {text, idx} -> {rel, idx, text} end)
  end
end
