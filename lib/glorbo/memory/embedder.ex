defmodule Glorbo.Memory.Embedder do
  @moduledoc """
  Embedding client for GEP-0058 (D4): calls a local OpenAI-compatible
  `/v1/embeddings` endpoint over the app-supervised Finch pool.

  **No bundled inference, no extra deps** (GEP-0058 D1, GEP-53 D13): the
  operator runs their own ollama / llama.cpp / LM Studio server; this
  module only POSTs to it. The endpoint is discovered the same way native
  providers are (GEP-8) — a localhost `/v1/embeddings` URL.

  ## Injectability (load-bearing for tests)

  `embed/2` accepts an `:embed_fun` option — a
  `(model, [text] -> {:ok, [[float]]} | {:error, term})` function. The
  default hits the real endpoint via `Req` (pooled `Glorbo.Finch`); the
  test suite injects a deterministic stub so NO real server is needed.
  Everything downstream (index, re-rank, fusion) is exercised against the
  stub.

  ## Request / response shape

  Request body matches the OpenAI embeddings API:

      {"model": "<model>", "input": ["chunk one", "chunk two"]}

  Response is expected to carry a `"data"` array of
  `{"embedding": [floats], "index": n}` objects, which `embed/2` returns
  ordered by `index` so the caller can zip vectors back to inputs.
  """

  require Logger

  @default_timeout_ms 30_000

  @type vector :: [float()]

  @doc """
  Embed a list of texts with `model`.

  Options:

    * `:endpoint` — base URL of the embeddings server (e.g.
      `"http://127.0.0.1:11434/v1"`). Required by the default
      `embed_fun`; ignored when a stub `:embed_fun` is supplied.
    * `:embed_fun` — `(model, [text] -> {:ok, [vector]} | {:error, term})`.
      Defaults to the real Finch-backed call.
    * `:timeout_ms` — per-request receive timeout (default 30s).

  Returns `{:ok, [vector]}` in the same order as `texts`, or
  `{:error, reason}`. An empty `texts` list short-circuits to `{:ok, []}`.
  """
  @spec embed(String.t(), [String.t()], keyword()) :: {:ok, [vector()]} | {:error, term()}
  def embed(model, texts, opts \\ [])

  def embed(_model, [], _opts), do: {:ok, []}

  def embed(model, texts, opts) when is_binary(model) and is_list(texts) do
    embed_fun = Keyword.get(opts, :embed_fun, &default_embed_fun(&1, &2, opts))
    embed_fun.(model, texts)
  end

  # The real embedding call. Kept private so the public surface is just
  # `embed/3` + the `:embed_fun` seam; tests never reach this path.
  defp default_embed_fun(model, texts, opts) do
    endpoint = Keyword.get(opts, :endpoint)
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    if not is_binary(endpoint) or endpoint == "" do
      {:error, :endpoint_missing}
    else
      url = String.trim_trailing(endpoint, "/") <> "/embeddings"
      body = %{model: model, input: texts}

      case Req.post(url, finch: Glorbo.Finch, json: body, receive_timeout: timeout) do
        {:ok, %{status: status, body: resp}} when status >= 200 and status < 300 ->
          parse_response(resp)

        {:ok, %{status: status}} ->
          {:error, {:embeddings_http_status, status}}

        {:error, reason} ->
          Logger.warning("Memory.Embedder request failed: #{inspect(reason)}")
          {:error, :embeddings_unreachable}
      end
    end
  end

  # Order the returned embeddings by their `index` field so the caller can
  # zip them back to the input list. Defends against a server that returns
  # the data array out of order. `@doc false` (public only so the
  # malformed-response guards are unit-testable; the documented surface
  # stays `embed/3` + the `:embed_fun` seam).
  @doc false
  def parse_response(%{"data" => data}) when is_list(data) do
    vectors =
      data
      |> Enum.sort_by(fn row -> Map.get(row, "index", 0) end)
      |> Enum.map(fn row -> Map.get(row, "embedding", []) end)

    # Reject NON-EMPTY lists only: a row missing the `embedding` field
    # defaults to `[]` above, which is still a list — accepting it would
    # store a zero-dim vector. That write goes through `insert_all`, which
    # bypasses the `ChunkVector` changeset's `dims > 0` validation, so the
    # empty vector lands on disk and then silently scores 0.0 on every query
    # (cosine's length-mismatch fallback). A legitimate embeddings endpoint
    # always returns a non-empty vector on a 2xx, so this only rejects a
    # malformed / partial server response — fail loud instead.
    if vectors != [] and Enum.all?(vectors, &(is_list(&1) and &1 != [])) do
      {:ok, vectors}
    else
      {:error, :embeddings_malformed}
    end
  end

  def parse_response(_), do: {:error, :embeddings_malformed}
end
