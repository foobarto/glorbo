defmodule Glorbo.OpenAIProxy.Shape do
  @moduledoc """
  Behaviour for an OpenAI-proxy wire-shape adapter (GEP-0055).

  Each adapter is responsible for translating between the
  agent's expected wire format (OpenAI v1, Anthropic Messages,
  Gemini, ...) and the upstream provider's actual wire format.
  The proxy layer is protocol-aware at the adapter boundary;
  adapters are protocol-aware on both sides.

  ## Why a behaviour, not a single module

  Three wire shapes ship in v1 (OpenAI v1, Anthropic, Gemini).
  Each shape is small (200-300 LOC) but the translation rules
  differ in three non-trivial ways: request body shape (Anthropic
  uses `messages[]` with `system` as a top-level field, OpenAI
  uses `messages[]` with `system` as a message role), auth header
  shape (Anthropic uses `x-api-key` + `anthropic-version`, OpenAI
  uses `Authorization: Bearer`), and streaming event shape
  (Anthropic emits `message_start` / `content_block_delta` /
  `message_delta` / `message_stop`; OpenAI emits incremental
  `choices[].delta`). Folding all three into a single module
  would push the LOC over 1000 and make the per-shape tests
  noisier than necessary.

  A behaviour keeps each adapter focused, makes adding a fourth
  shape (Mistral, Cohere, etc.) a one-day exercise, and lets
  the proxy layer's `do_handle_request/2` be a clean dispatch on
  the right adapter.

  ## Callbacks

  See each `@callback` declaration below for the contract. The
  proxy calls them in this order per request:

    1. `route?(path)` — does this adapter own the path?
    2. `stream?(body)` — does the request ask for streaming?
    3. `translate_request(body, headers)` — agent's wire → upstream's wire
    4. `attach_auth(headers, api_key)` — add the upstream's auth header
    5. (proxy makes the upstream HTTP call)
    6. (if non-stream) `translate_response(upstream_body, original_body)` — upstream's wire → agent's wire
    7. (if stream) `translate_stream_chunk(chunk, state)` per upstream SSE chunk
    8. `extract_usage(final_body_or_chunks)` — parse upstream's `usage` block

  As of slice 4a every adapter implements all eight callbacks.
  The OpenAI and Anthropic adapters pass bodies through
  untranslated (correct while same-shape agents talk to
  same-shape upstreams; cross-shape translation comes with the
  later slices), and extract usage from non-stream responses.
  Streaming translation is slice 5; the Gemini request/auth
  translation is slice 9.
  """

  @doc """
  Does this adapter own the given HTTP path?

  Match is exact on the wire-shape path prefix. The proxy's
  `ShapeRouter` iterates adapters and returns the first one
  whose `route?/1` returns true. There is no path-confusion
  surface: `/v1/chat/completions` only ever goes to the OpenAI
  adapter, `/v1/messages` only ever goes to Anthropic, etc.
  """
  @callback route?(path :: String.t()) :: boolean()

  @doc """
  Does the request body ask for streaming?

  The OpenAI v1 wire sets `stream: true` at the top level.
  Anthropic sets `stream: true` at the top level too, but
  emits a different SSE event vocabulary. Gemini uses
  `?alt=sse` as a query parameter. Each adapter owns the
  detection logic; the proxy doesn't know.
  """
  @callback stream?(body :: map()) :: boolean()

  @doc """
  Translate the agent's wire-format request body to the
  upstream's wire-format request body.

  Returns `{:ok, translated_body, translated_headers}` where
  `translated_headers` is a flat map of header-name → value
  strings. The proxy passes those to `Req`. Adapters that
  need to add shape-specific headers (Anthropic adds
  `anthropic-version: 2023-06-01`; Gemini adds nothing) own
  the choice.

  Returns `{:error, :bad_request, reason}` when the request
  body is malformed for this shape. The proxy surfaces
  `{:error, :bad_request, _}` as a `400` to the agent with
  an OpenAI/Anthropic-shaped error body.
  """
  @callback translate_request(body :: map(), headers :: %{String.t() => String.t()}) ::
              {:ok, translated_body :: map(), translated_headers :: %{String.t() => String.t()}}
              | {:error, :bad_request, String.t()}

  @doc """
  Attach the upstream's auth header.

  `api_key` is the value of `System.get_env(provider.api_key_env)`
  at request time. OpenAI/OpenRouter use
  `Authorization: Bearer <key>`. Anthropic uses
  `x-api-key: <key>` + `anthropic-version: 2023-06-01`.
  Each adapter owns the format.
  """
  @callback attach_auth(
              headers :: %{String.t() => String.t()},
              api_key :: String.t()
            ) :: %{String.t() => String.t()}

  @doc """
  Translate the upstream's non-stream response body to the
  agent's expected wire format. The proxy calls this once per
  non-stream request. The translated body is the bytes the
  agent sees.
  """
  @callback translate_response(
              upstream_body :: map(),
              original_agent_body :: map()
            ) :: {:ok, translated_body :: map()}

  @doc """
  Translate one upstream SSE chunk to one agent SSE chunk.

  The proxy calls this per chunk during streaming. `state` is
  per-stream and shaped per adapter; the proxy treats it as
  opaque. OpenAI v1 chunks are already the right shape for
  OpenAI v1 agents; Anthropic's `message_delta` events need
  to become OpenAI-shaped `choices[].delta` chunks for
  OpenAI agents. Gemini emits different chunks for streamed
  vs. non-streamed.

  Returns `{[translated_chunks], new_state}`. Multiple
  translated chunks per upstream chunk is valid (e.g. one
  upstream Anthropic event can produce multiple agent-visible
  events).
  """
  @callback translate_stream_chunk(
              upstream_chunk :: String.t(),
              state :: term()
            ) :: {[String.t()], term()}

  @doc """
  Initial state for a stream. Called once at stream start.
  `original_agent_body` is the request body the agent sent;
  some adapters (Anthropic) need to track the message_start's
  `id` + `model` to enrich subsequent `message_delta` events.
  """
  @callback initial_stream_state(original_agent_body :: map()) :: term()

  @typedoc """
  Usage block in the GEP-32 D12 shape. Each adapter's
  `extract_usage/1` returns this; the proxy writes it to
  `~/.glorbo/run/<dispatch_id>/usage.json` for the existing
  `usage_parser = "native-v1"` chain to consume.
  """
  @type usage_map :: %{
          required(:tracked) => boolean(),
          required(:prompt_tokens) => non_neg_integer(),
          required(:completion_tokens) => non_neg_integer(),
          optional(:model) => String.t() | nil,
          optional(:duration_ms) => non_neg_integer()
        }

  @doc """
  Extract a `usage` block from the upstream's response.

  For non-streaming responses, `upstream_body` is the parsed
  JSON object. For streaming responses, `upstream_chunks` is
  the list of SSE chunks the proxy has already teed (post-
  translation). The returned shape matches GEP-32 D12.

  Returns `:no_usage` when the upstream did not include
  usage data (e.g. Gemini's streaming API as of 2026-06).
  """
  @callback extract_usage(
              {:non_stream, upstream_body :: map()}
              | {:stream, upstream_chunks :: [String.t()]}
            ) :: {:ok, usage_map()} | :no_usage
end
