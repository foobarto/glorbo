defmodule Glorbo.Memory.Index do
  @moduledoc """
  Semantic recall index (GEP-0058) — the hybrid keyword + vector layer
  over a company's markdown home tree.

  ## Shape (D3 — elasticsearch-style hybrid)

    1. **Keyword recall** — an SQLite FTS5 virtual table (`chunks_fts`)
       holds every chunk's text. A query is a `MATCH` against it, scoped
       to the calling company. This is the always-on candidate path.
    2. **Cosine re-rank** — the FTS5 candidate set's stored vectors
       (`chunk_vectors`) are re-ranked by pure-Elixir cosine similarity
       (`Glorbo.Memory.Vector`) against the query embedding. No
       `sqlite-vec`, no C-NIF (GEP-53 D13).
    3. **RRF fusion** — the keyword ranking and the cosine ranking are
       fused by reciprocal-rank fusion into the final ordering.

  ## Default-OFF, per-company (D1)

  Indexing is opt-in per company via `enable/2` (CLI:
  `glorbo memory index --enable`). `enabled?/2` gates every write — a
  company that never enabled gets NO rows. `reindex_company/3` is a
  no-op for a disabled company.

  ## Isolation (load-bearing)

  EVERY query — FTS5 `MATCH`, vector load, fusion — is filtered by the
  calling `company`. A company-A search NEVER returns company-B chunks.
  The `company` column is part of every table's key and appears in every
  WHERE clause here. This mirrors the absolute company-isolation
  invariant (CLAUDE.md / GEP isolation).

  ## Derived, rebuildable (D2 / GEP-7)

  Fully rebuildable from disk (GEP-3). The chunk/vector/FTS tables are
  disposable, AND the per-company opt-in is persisted to disk —
  `enable/2`/`disable/2` write `company.md`'s `memory_index:` boolean (the
  source of truth), so the `memory_index_enabled` SQLite table is a pure
  cache. `glorbo reindex` re-derives the enabled set from `company.md`
  (`company_memory_enabled?/2`), re-seeds the cache (`mark_enabled/2`), and
  re-embeds. So `rm glorbo.db && glorbo reindex` restores both the opt-in
  and the embeddings — the markdown files stay authoritative throughout.
  """

  import Ecto.Query

  alias Glorbo.Memory.{ChunkVector, Embedder, Vector}
  alias Glorbo.Repo

  @keyword_candidate_limit 50
  @default_result_limit 10

  # ---------------------------------------------------------------------------
  # Enable / disable (default-OFF opt-in)
  # ---------------------------------------------------------------------------

  @doc """
  Opt `company` into semantic indexing. Idempotent.

  Persists the opt-in to disk (`company.md` `memory_index: true`) so it
  survives a `rm glorbo.db && glorbo reindex` (GEP-3 rebuildability), and
  marks the SQLite cache so runtime reads see it immediately.
  """
  @spec enable(String.t(), keyword()) :: :ok
  def enable(company, opts \\ []) when is_binary(company) do
    write_memory_flag(company, true, opts)
    mark_enabled(company, opts)
    :ok
  end

  @doc """
  Mark `company` enabled in the SQLite cache only (no disk write).
  Idempotent. Used by `glorbo reindex` to re-seed the cache from the disk
  source of truth after a DB wipe.
  """
  @spec mark_enabled(String.t(), keyword()) :: :ok
  def mark_enabled(company, opts \\ []) when is_binary(company) do
    repo = repo(opts)

    repo.insert_all("memory_index_enabled", [%{company: company}],
      on_conflict: :nothing,
      conflict_target: :company
    )

    :ok
  end

  @doc """
  Opt `company` out of semantic indexing and purge its derived rows.

  Clears the disk opt-in (`company.md` `memory_index: false`), drops the
  SQLite enabled row, and purges the company's vectors + FTS rows so a
  disabled company carries no stale index (and no storage cost). Scoped to
  the one company — never touches another company's rows.
  """
  @spec disable(String.t(), keyword()) :: :ok
  def disable(company, opts \\ []) when is_binary(company) do
    repo = repo(opts)

    write_memory_flag(company, false, opts)
    repo.delete_all(from(e in "memory_index_enabled", where: e.company == ^company))
    purge_company(company, repo)
    :ok
  end

  @doc """
  Read the on-disk opt-in for `company` — `company.md`'s `memory_index:`
  frontmatter (the GEP-3 source of truth). `false` when the file or key is
  absent. `opts[:base]` overrides the glorbo home root.
  """
  @spec company_memory_enabled?(String.t(), keyword()) :: boolean()
  def company_memory_enabled?(company, opts \\ []) when is_binary(company) do
    path = company_md_path(company, opts)

    with {:ok, content} <- File.read(path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      Map.get(fm, "memory_index") == true
    else
      _ -> false
    end
  end

  defp write_memory_flag(company, value, opts) do
    path = company_md_path(company, opts)

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path) do
      _ =
        Glorbo.Filesystem.FrontmatterWriter.atomic_write(
          path,
          upsert_memory_index(content, value)
        )
    end

    :ok
  end

  # Update the `memory_index:` frontmatter line if present, else append it to
  # the frontmatter block. (`FrontmatterWriter.update_keys/2` only rewrites
  # existing keys; this opt-in may be absent on first enable.)
  defp upsert_memory_index(content, value) do
    scalar = "memory_index: #{Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(value)}"

    case String.split(content, ~r/\A---\r?\n|\r?\n---\r?\n/, parts: 3) do
      ["", fm, body] ->
        new_fm = set_memory_index_line(String.split(fm, "\n"), scalar)
        "---\n" <> new_fm <> "\n---\n" <> body

      _ ->
        content
    end
  end

  defp set_memory_index_line(lines, scalar) do
    if Enum.any?(lines, &memory_index_line?/1) do
      Enum.map_join(lines, "\n", &replace_memory_index_line(&1, scalar))
    else
      Enum.join(lines ++ [scalar], "\n")
    end
  end

  defp replace_memory_index_line(line, scalar) do
    if memory_index_line?(line), do: scalar, else: line
  end

  defp memory_index_line?(line), do: String.match?(line, ~r/\A\s*memory_index\s*:/)

  defp company_md_path(company, opts) do
    base = Keyword.get_lazy(opts, :base, &Glorbo.Filesystem.Hierarchy.default_root/0)
    Path.join([base, "companies", company, "company.md"])
  end

  @doc "Returns true iff `company` has opted into semantic indexing."
  @spec enabled?(String.t(), keyword()) :: boolean()
  def enabled?(company, opts \\ []) when is_binary(company) do
    repo = repo(opts)

    repo.exists?(from(e in "memory_index_enabled", where: e.company == ^company))
  end

  # ---------------------------------------------------------------------------
  # Indexing (D6 — embed lazily, on reindex, for enabled companies only)
  # ---------------------------------------------------------------------------

  @doc """
  Re-index `chunks` for `company`.

  `chunks` is a list of `{source_path, chunk_id, text}` tuples. No-op
  (returns `{:ok, 0}`) when the company is disabled — this is the lazy
  hook `glorbo reindex` calls per-company (D6): the cost is only paid for
  opted-in companies.

  For an enabled company, every chunk's text lands in the FTS5 table and
  its embedding (from `Embedder.embed/3`, which the caller stubs in
  tests) lands in `chunk_vectors`. Both tables are wiped for the company
  first so the rebuild is a clean projection of the current chunk set
  (GEP-7 derived-state discipline). Returns `{:ok, indexed_count}` or
  `{:error, reason}` if embedding fails (leaves the prior index intact).
  """
  @spec reindex_company(String.t(), [{String.t(), non_neg_integer(), String.t()}], keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def reindex_company(company, chunks, opts \\ []) when is_binary(company) and is_list(chunks) do
    repo = repo(opts)

    if enabled?(company, opts) do
      do_reindex_company(company, chunks, repo, opts)
    else
      {:ok, 0}
    end
  end

  defp do_reindex_company(company, [], repo, _opts) do
    purge_company(company, repo)
    {:ok, 0}
  end

  defp do_reindex_company(company, chunks, repo, opts) do
    model = Keyword.get(opts, :model, "nomic-embed-text")
    texts = Enum.map(chunks, fn {_path, _id, text} -> text end)

    case Embedder.embed(model, texts, opts) do
      {:ok, vectors} when length(vectors) == length(chunks) ->
        purge_company(company, repo)
        insert_chunks(company, chunks, vectors, model, repo)
        {:ok, length(chunks)}

      {:ok, _mismatch} ->
        {:error, :embedding_count_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Hybrid search: FTS5 candidates → cosine re-rank → RRF fusion
  # ---------------------------------------------------------------------------

  @doc """
  Hybrid semantic search for `query` within `company`.

  1. FTS5 `MATCH` gives the keyword-ranked candidate set (scoped to
     `company`, capped at `@keyword_candidate_limit`).
  2. The candidates' stored vectors are cosine-re-ranked against the
     query's embedding.
  3. Reciprocal-rank fusion of the two rankings produces the final order.

  Returns a list of `%{source_path, chunk_id, content, score}` maps,
  best first, capped at `:limit` (default #{@default_result_limit}).
  Returns `[]` for a disabled company, an empty query, or when no
  candidate matches — never another company's rows.
  """
  @spec search(String.t(), String.t(), keyword()) :: [map()]
  def search(company, query, opts \\ [])

  def search(_company, "", _opts), do: []
  def search(_company, nil, _opts), do: []

  def search(company, query, opts) when is_binary(company) and is_binary(query) do
    repo = repo(opts)
    limit = Keyword.get(opts, :limit, @default_result_limit)

    if enabled?(company, opts) do
      candidates = keyword_candidates(company, query, repo)

      if candidates == [] do
        []
      else
        fuse(company, query, candidates, repo, opts) |> Enum.take(limit)
      end
    else
      []
    end
  end

  @doc """
  Raw FTS5 keyword recall for `company` — the always-on path, exposed for
  callers (and tests) that want keyword candidates without the vector
  re-rank. Returns `%{source_path, chunk_id, content, rank}` maps ordered
  by FTS5 relevance (best first), scoped to `company`.
  """
  @spec keyword_candidates(String.t(), String.t(), Ecto.Repo.t()) :: [map()]
  def keyword_candidates(company, query, repo \\ Repo) when is_binary(company) do
    # bm25() is ascending-better in FTS5 (more-negative = more relevant);
    # ORDER BY rank uses FTS5's built-in relevance. `company` is filtered
    # in the WHERE clause — isolation is enforced in SQL, not in Elixir.
    sql = """
    SELECT source_path, chunk_id, content, rank
    FROM chunks_fts
    WHERE chunks_fts MATCH ? AND company = ?
    ORDER BY rank
    LIMIT ?
    """

    case Ecto.Adapters.SQL.query(repo, sql, [
           fts_match_query(query),
           company,
           @keyword_candidate_limit
         ]) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [source_path, chunk_id, content, rank] ->
          %{source_path: source_path, chunk_id: chunk_id, content: content, rank: rank}
        end)

      {:error, _reason} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp fuse(company, query, candidates, repo, opts) do
    keyword_ranking = Enum.map(candidates, &candidate_key/1)

    cosine_ranking = cosine_ranking(company, query, candidates, repo, opts)

    fused = Vector.rrf(keyword_ranking, cosine_ranking)

    by_key = Map.new(candidates, &{candidate_key(&1), &1})

    Enum.map(fused, fn {key, score} ->
      cand = Map.fetch!(by_key, key)

      %{
        source_path: cand.source_path,
        chunk_id: cand.chunk_id,
        content: cand.content,
        score: score
      }
    end)
  end

  # Cosine re-rank: embed the query, load the candidates' stored vectors
  # (scoped to `company`), score by cosine, return the candidate keys
  # ordered best-first. On any embedding failure the cosine ranking is
  # empty — RRF then degrades gracefully to keyword-only order.
  defp cosine_ranking(company, query, candidates, repo, opts) do
    model = Keyword.get(opts, :model, "nomic-embed-text")

    case Embedder.embed(model, [query], opts) do
      {:ok, [query_vec]} ->
        stored = load_vectors(company, candidates, repo)

        candidates
        |> Enum.flat_map(fn cand ->
          case Map.get(stored, candidate_key(cand)) do
            nil -> []
            vec -> [{candidate_key(cand), Vector.cosine(query_vec, vec)}]
          end
        end)
        |> Enum.sort_by(fn {_key, sim} -> -sim end)
        |> Enum.map(fn {key, _sim} -> key end)

      _ ->
        []
    end
  end

  # Load the float vectors for exactly the candidate set, scoped to
  # `company`. Returns `%{{source_path, chunk_id} => [float]}`.
  defp load_vectors(company, candidates, repo) do
    paths = candidates |> Enum.map(& &1.source_path) |> Enum.uniq()

    repo.all(
      from(v in ChunkVector,
        where: v.company == ^company and v.source_path in ^paths,
        select: {v.source_path, v.chunk_id, v.embedding}
      )
    )
    |> Map.new(fn {path, id, blob} -> {{path, id}, Vector.unpack(blob)} end)
  end

  defp candidate_key(%{source_path: path, chunk_id: id}), do: {path, id}

  defp insert_chunks(company, chunks, vectors, model, repo) do
    fts_rows =
      Enum.map(chunks, fn {path, id, text} ->
        %{company: company, source_path: path, chunk_id: id, content: text}
      end)

    vector_rows =
      chunks
      |> Enum.zip(vectors)
      |> Enum.map(fn {{path, id, _text}, vec} ->
        %{
          company: company,
          source_path: path,
          chunk_id: id,
          embedding: Vector.pack(vec),
          model: model,
          dims: length(vec)
        }
      end)

    # FTS5 is an external-content-free virtual table; insert_all targets it
    # by name. chunk_vectors goes through the schema.
    repo.insert_all("chunks_fts", fts_rows)
    repo.insert_all(ChunkVector, vector_rows)
  end

  # Wipe a single company's derived rows. Scoped — never touches another
  # company. Used by disable/2 and before each reindex_company rebuild.
  defp purge_company(company, repo) do
    repo.delete_all(from(v in ChunkVector, where: v.company == ^company))
    repo.delete_all(from(f in "chunks_fts", where: f.company == ^company))
    :ok
  end

  # Turn a free-text query into an FTS5 MATCH expression: split on
  # whitespace, drop FTS5 syntax characters, quote each token and OR them
  # together. Quoting defends against an injected MATCH operator (e.g. a
  # query containing `"` or `*`) becoming a query-syntax error or
  # unexpected operator.
  defp fts_match_query(query) do
    tokens =
      query
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(&String.replace(&1, "\"", ""))
      |> Enum.reject(&(&1 == ""))

    case tokens do
      [] -> "\"\""
      list -> Enum.map_join(list, " OR ", &"\"#{&1}\"")
    end
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
