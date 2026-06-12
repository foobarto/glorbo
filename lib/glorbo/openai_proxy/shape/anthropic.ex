defmodule Glorbo.OpenAIProxy.Shape.Anthropic do
  @moduledoc """
  Anthropic Messages wire-shape adapter (GEP-0055).

  Covers the Anthropic Messages API used by:

    * `claude-code` (Claude Code CLI)
    * `kiro` (Kiro CLI)
    * Any Anthropic-Messages-compatible endpoint

  ## Wire format (request)

      POST /v1/messages
      x-api-key: <api_key>
      anthropic-version: 2023-06-01
      Content-Type: application/json

      {
        "model": "claude-opus-4-5",
        "max_tokens": 1024,
        "system": "...",
        "messages": [
          {"role": "user", "content": "..."}
        ],
        "stream": true | false
      }

  Note: Anthropic uses `system` as a top-level field, not
  as a message role. The translation callback pulls the
  `system` message out of the OpenAI-style `messages[]`
  and promotes it to the top.

  ## Wire format (response, non-stream)

      {
        "id": "msg_...",
        "type": "message",
        "role": "assistant",
        "content": [{"type": "text", "text": "..."}],
        "model": "claude-opus-4-5",
        "stop_reason": "end_turn",
        "usage": {
          "input_tokens": 13,
          "output_tokens": 7
        }
      }

  ## Wire format (response, stream)

      event: message_start
      data: {"type":"message_start","message":{"id":"msg_...","type":"message","role":"assistant","content":[],"model":"claude-opus-4-5","stop_reason":null,"usage":{"input_tokens":13,"output_tokens":0}}}

      event: content_block_start
      data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

      event: content_block_delta
      data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

      event: content_block_stop
      data: {"type":"content_block_stop","index":0}

      event: message_delta
      data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

      event: message_stop
      data: {"type":"message_stop"}

  ## Current status (slice 4a)

  Pass-through translation (Anthropic-shaped agents talk to an
  Anthropic-shaped upstream), x-api-key auth attachment, and
  non-stream usage extraction. The OpenAI-to-Anthropic `system`
  promotion and the streaming event translation land with the
  cross-shape slices.
  """

  @behaviour Glorbo.OpenAIProxy.Shape

  @anthropic_paths ~w(
    /v1/messages
    /v1/models
  )

  @impl true
  def route?(path) when is_binary(path) do
    Enum.any?(@anthropic_paths, &(&1 == path))
  end

  def route?(_), do: false

  @impl true
  def stream?(%{"stream" => true}), do: true
  def stream?(_), do: false

  @impl true
  # Empty upstream-header allowlist — never forward inbound host /
  # content-length / the proxy bearer token. attach_auth/2 adds x-api-key
  # (Anthropic ignores `authorization`, so a forwarded proxy token would
  # have leaked upstream). (PR #47 review: codex + Copilot.)
  def translate_request(body, _headers),
    do: {:ok, body, %{}}

  @impl true
  def attach_auth(headers, api_key) do
    headers
    |> Map.put("x-api-key", api_key)
    |> Map.put("anthropic-version", "2023-06-01")
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
       prompt_tokens: Map.get(usage, "input_tokens", 0),
       completion_tokens: Map.get(usage, "output_tokens", 0),
       model: nil,
       duration_ms: 0
     }}
  end

  def extract_usage({:non_stream, _}), do: :no_usage
  def extract_usage({:stream, _}), do: :no_usage
end
