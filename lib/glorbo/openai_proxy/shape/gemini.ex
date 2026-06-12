defmodule Glorbo.OpenAIProxy.Shape.Gemini do
  @moduledoc """
  Google Gemini wire-shape adapter (GEP-0055).

  Covers the Gemini API used by `gemini-cli` and any
  Gemini-compatible endpoint (Vertex AI, etc.).

  ## Wire format (request)

      POST /v1beta/models/gemini-1.5-pro:generateContent
      ?key=<api_key>                       # key in query string
      Content-Type: application/json

      {
        "contents": [
          {"role": "user", "parts": [{"text": "..."}]}
        ],
        "systemInstruction": {
          "parts": [{"text": "..."}]
        },
        "generationConfig": {
          "maxOutputTokens": 1024,
          "temperature": 0.7
        }
      }

  Note: Gemini's auth is the `?key=` query parameter, not
  a header. The `attach_auth/2` callback surfaces the API
  key in the URL path that the proxy builds.

  ## Wire format (response, non-stream)

      {
        "candidates": [
          {
            "content": {"parts": [{"text": "..."}], "role": "model"},
            "finishReason": "STOP"
          }
        ],
        "usageMetadata": {
          "promptTokenCount": 13,
          "candidatesTokenCount": 7,
          "totalTokenCount": 20
        }
      }

  ## Wire format (response, stream)

      data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"}}]}

      data: {"candidates":[{"content":{"parts":[{"text":" world"}],"role":"model"}}]}

      (final chunk has no usageMetadata; Gemini's streaming
      API does not include usage as of 2026-06 — see GEP
      Open Question 3.)

  ## Current status (slice 4a)

  Routing and non-stream usage extraction only. The request
  translation, the `?key=` query-param auth, and the streaming
  translation are slice 9 — until then `attach_auth/2` is a
  no-op and bodies pass through untranslated.
  """

  @behaviour Glorbo.OpenAIProxy.Shape

  # Gemini's path includes the model name as a path segment
  # and ends with `:generateContent` (non-stream) or
  # `:streamGenerateContent` (stream). We match both suffixes
  # since the model name is provider-specific.
  @gemini_path_suffixes [":generateContent", ":streamGenerateContent"]

  @impl true
  def route?(path) when is_binary(path) do
    String.starts_with?(path, "/v1beta/models/") and
      Enum.any?(@gemini_path_suffixes, &String.ends_with?(path, &1))
  end

  def route?(_), do: false

  @impl true
  def stream?(body) when is_map(body) do
    # Gemini doesn't have a body-level `stream` flag;
    # streaming is controlled by the URL suffix
    # (`:streamGenerateContent` vs `:generateContent`).
    # Slice 9 will plumb that through the path.
    _ = body
    false
  end

  def stream?(_), do: false

  @impl true
  # Empty upstream-header allowlist — never forward inbound host /
  # content-length / the proxy bearer token. Gemini auth is the `?key=`
  # query param and attach_auth/2 is a no-op, so a forwarded inbound
  # `authorization` would have leaked the proxy token straight upstream.
  # (PR #47 review: codex + Copilot.)
  def translate_request(body, _headers),
    do: {:ok, body, %{}}

  @impl true
  # Gemini's auth is the `?key=` query parameter, not a
  # header. The proxy embeds it in the upstream URL
  # (slice 4 wires this up); `attach_auth/2` here is a
  # no-op placeholder.
  def attach_auth(headers, _api_key), do: headers

  @impl true
  def translate_response(upstream_body, _original),
    do: {:ok, upstream_body}

  @impl true
  def translate_stream_chunk(chunk, state), do: {[chunk], state}

  @impl true
  def initial_stream_state(_body), do: %{}

  @impl true
  def extract_usage({:non_stream, %{"usageMetadata" => usage}}) when is_map(usage) do
    {:ok,
     %{
       tracked: true,
       prompt_tokens: Map.get(usage, "promptTokenCount", 0),
       completion_tokens: Map.get(usage, "candidatesTokenCount", 0),
       model: nil,
       duration_ms: 0
     }}
  end

  def extract_usage({:non_stream, _}), do: :no_usage
  def extract_usage({:stream, _}), do: :no_usage
end
