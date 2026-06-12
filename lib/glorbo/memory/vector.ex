defmodule Glorbo.Memory.Vector do
  @moduledoc """
  Pure-Elixir vector arithmetic for GEP-0058 semantic re-rank (D3).

  NO `sqlite-vec`, NO C-NIF — the Burrito 4-target cross-build rejects
  C-NIF deps (GEP-53 D13). Cosine similarity and reciprocal-rank fusion
  are plain BEAM arithmetic over `float32` lists. The candidate set is
  bounded (it's the FTS5 keyword top-N), so an O(n·d) cosine pass in
  Elixir is comfortably fast enough at single-director scale.

  ## Storage encoding

  Embeddings persist as a packed little-endian `float32` BLOB in
  `chunk_vectors.embedding`. `pack/1` serialises a float list to that
  blob; `unpack/1` reverses it. Keeping the on-disk form compact (4
  bytes/dim) matters because a markdown tree can produce thousands of
  chunks.
  """

  @doc """
  Pack a list of floats into a little-endian float32 binary.
  """
  @spec pack([number()]) :: binary()
  def pack(values) when is_list(values) do
    for v <- values, into: <<>>, do: <<v::float-32-little>>
  end

  @doc """
  Unpack a little-endian float32 binary back into a list of floats.
  Non-multiple-of-4 trailing bytes are ignored (defensive against a
  truncated blob).
  """
  @spec unpack(binary()) :: [float()]
  def unpack(blob) when is_binary(blob) do
    for <<v::float-32-little <- blob>>, do: v
  end

  @doc """
  Cosine similarity of two equal-length float vectors.

  Returns a float in `[-1.0, 1.0]`. Returns `0.0` when either vector is
  the zero vector (undefined direction) or the lengths differ — callers
  treat a length mismatch as "not comparable", never a crash.
  """
  @spec cosine([number()], [number()]) :: float()
  def cosine(a, b) when is_list(a) and is_list(b) and length(a) == length(b) do
    {dot, na, nb} =
      Enum.zip(a, b)
      |> Enum.reduce({0.0, 0.0, 0.0}, fn {x, y}, {d, sa, sb} ->
        {d + x * y, sa + x * x, sb + y * y}
      end)

    denom = :math.sqrt(na) * :math.sqrt(nb)
    if denom == 0.0, do: 0.0, else: dot / denom
  end

  def cosine(_a, _b), do: 0.0

  @doc """
  Reciprocal-rank fusion (RRF) over two ranked lists of opaque ids.

  Each input is an ordered list (best first) of ids; an id's fused score
  is `sum over lists of 1 / (k + rank)` (rank is 1-based). The
  conventional `k = 60` damps the contribution of low ranks. Ids missing
  from a list simply contribute nothing from that list. Returns ids
  sorted by descending fused score; ties break on the id term for a
  deterministic order.

  RRF is the final ordering for the hybrid retrieval: it fuses the FTS5
  keyword ranking with the cosine re-rank ranking without needing either
  score to be on a comparable scale.
  """
  @spec rrf([term()], [term()], keyword()) :: [{term(), float()}]
  def rrf(list_a, list_b, opts \\ []) when is_list(list_a) and is_list(list_b) do
    k = Keyword.get(opts, :k, 60)

    scores =
      [list_a, list_b]
      |> Enum.reduce(%{}, fn list, acc ->
        list
        |> Enum.with_index(1)
        |> Enum.reduce(acc, fn {id, rank}, inner ->
          Map.update(inner, id, 1.0 / (k + rank), &(&1 + 1.0 / (k + rank)))
        end)
      end)

    scores
    |> Enum.sort_by(fn {id, score} -> {-score, id} end)
  end
end
