defmodule Glorbo.OpenAIProxy.Shape.OpenAI do
  @moduledoc """
  OpenAI v1 wire-shape adapter (GEP-0055).

  Covers the OpenAI v1 request/response format used by:

    * `openai` (api.openai.com)
    * `openrouter` (openrouter.ai)
    * `minimax` (api.minimax.io)
    * Any local OpenAI-compatible endpoint (Ollama, llama.cpp,
      LocalAI, vLLM, LM Studio) — these accept the same
      `Authorization: Bearer <key>` + `/v1/chat/completions`
      request shape

  ## Wire format (request)

      POST /v1/chat/completions
      Authorization: Bearer <api_key>
      Content-Type: application/json

      {
        "model": "gpt-4",
        "messages": [
          {"role": "system", "content": "..."},
          {"role": "user", "content": "..."}
        ],
        "stream": true | false,
        "temperature": 0.7,
        ...
      }

  ## Wire format (response, non-stream)

      {
        "id": "chatcmpl-...",
        "object": "chat.completion",
        "created": 1700000000,
        "model": "gpt-4",
        "choices": [
          {
            "index": 0,
            "message": {"role": "assistant", "content": "..."},
            "finish_reason": "stop"
          }
        ],
        "usage": {
          "prompt_tokens": 13,
          "completion_tokens": 7,
          "total_tokens": 20
        }
      }

  ## Wire format (response, stream)

      data: {"id":"chatcmpl-...","object":"chat.completion.chunk",...,"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
      data: {"id":"chatcmpl-...","object":"chat.completion.chunk",...,"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}
      data: {"id":"chatcmpl-...","object":"chat.completion.chunk",...,"choices":[],"usage":{"prompt_tokens":13,"completion_tokens":7,"total_tokens":20}}
      data: [DONE]

  ## Current status (slice 4a)

  Pass-through translation (OpenAI-shaped agents talk to an
  OpenAI-shaped upstream), Bearer auth attachment, and
  non-stream usage extraction. Streaming chunk translation is
  slice 5.
  """

  @behaviour Glorbo.OpenAIProxy.Shape

  # Path prefixes this adapter owns. Each is matched exactly
  # (no fuzzy matching) — see the behaviour moduledoc for the
  # rationale on exact-match routing.
  @openai_paths ~w(
    /v1/chat/completions
    /v1/completions
    /v1/models
  )

  @impl true
  def route?(path) when is_binary(path) do
    Enum.any?(@openai_paths, &(&1 == path))
  end

  def route?(_), do: false

  @impl true
  def stream?(%{"stream" => true}), do: true
  def stream?(_), do: false

  @impl true
  # Upstream headers are built from an EMPTY allowlist — the inbound
  # headers (host: <proxy loopback:port>, content-length, and the proxy
  # bearer token in `authorization`) must never reach the real provider.
  # Req derives host/content-type/content-length from the URL + json body;
  # the real credential is added by attach_auth/2. (PR #47 review: codex +
  # Copilot — proxy-token leak + Host misroute.)
  def translate_request(body, _headers),
    do: {:ok, body, %{}}

  @impl true
  def attach_auth(headers, api_key) do
    Map.put(headers, "authorization", "Bearer #{api_key}")
  end

  @impl true
  def translate_response(upstream_body, _original),
    do: {:ok, upstream_body}

  @impl true
  def translate_stream_chunk(chunk, state), do: {[chunk], state}

  @impl true
  def initial_stream_state(_body), do: %{}

  @impl true
  def extract_usage({:non_stream, %{"usage" => usage}}) when is_map(usage) do
    {:ok,
     %{
       tracked: true,
       prompt_tokens: Map.get(usage, "prompt_tokens", 0),
       completion_tokens: Map.get(usage, "completion_tokens", 0),
       model: nil,
       duration_ms: 0
     }}
  end

  def extract_usage({:non_stream, _}), do: :no_usage
  def extract_usage({:stream, _}), do: :no_usage
end
