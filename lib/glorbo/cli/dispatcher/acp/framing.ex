defmodule Glorbo.CLI.Dispatcher.Acp.Framing do
  @moduledoc """
  Wire-format encode/decode for ACP's line-delimited JSON-RPC 2.0
  framing (GEP-45 Phase 1b foundation).

  ## Wire format

  ACP frames each message as a single line of JSON terminated by `\\n`.
  This is *not* LSP's Content-Length header framing — stado's
  `acp.NewConn` reads with `bufio.Reader.ReadSlice('\\n')`, so each
  outbound message must end in a single newline and contain no
  embedded raw newlines (JSON escapes `\\n` inside strings, so this
  is automatic for well-formed encoders).

    * Outbound: `encode/1` takes a tagged tuple from
      `Glorbo.CLI.Dispatcher.Acp.Message` and returns iodata
      ending in `\\n`. Caller writes the whole thing to the port.

    * Inbound: ACP messages arrive on stdout in arbitrary chunks (the
      kernel may merge or split lines). `parse_stream/2` takes a
      previously-buffered remainder + a fresh chunk and returns
      `{messages, new_remainder}` — every complete line becomes one
      message in the list, the trailing partial-line bytes (if any)
      become the remainder for the next read.

  Round-trip discipline: every message produced by `encode/1` is
  parseable by `decode_message/1`. Tests exercise the round-trip on
  every kind to keep the two functions in sync.
  """

  alias Glorbo.CLI.Dispatcher.Acp.Message
  alias Glorbo.CLI.Dispatcher.Acp.RpcError

  @json_rpc_version "2.0"

  @doc """
  Encode a tagged-tuple message into iodata ending in `\\n`.

  Returns `iodata()` — caller writes the whole iolist to the port.
  Never raises on a well-formed message; raises a `Jason.EncodeError`
  if `params`/`result` contain unencodable values (caller bug).
  """
  @spec encode(Message.t()) :: iodata()
  def encode({:request, id, method, params}) do
    body = drop_nil(%{jsonrpc: @json_rpc_version, id: id, method: method, params: params})
    [Jason.encode_to_iodata!(body), ?\n]
  end

  def encode({:notification, method, params}) do
    body = drop_nil(%{jsonrpc: @json_rpc_version, method: method, params: params})
    [Jason.encode_to_iodata!(body), ?\n]
  end

  def encode({:response, id, result}) do
    body = %{jsonrpc: @json_rpc_version, id: id, result: result}
    [Jason.encode_to_iodata!(body), ?\n]
  end

  def encode({:error_response, id, %RpcError{} = err}) do
    error = drop_nil(%{code: err.code, message: err.message, data: err.data})
    body = %{jsonrpc: @json_rpc_version, id: id, error: error}
    [Jason.encode_to_iodata!(body), ?\n]
  end

  @doc """
  Decode a single line of JSON into a tagged-tuple message.

  Accepts the line with OR without a trailing `\\n`. Returns:

    * `{:ok, message}` on a well-formed JSON-RPC 2.0 message
    * `{:error, :empty}` if the line is empty / whitespace-only
    * `{:error, {:json_parse, reason}}` if the bytes aren't JSON
    * `{:error, {:invalid, reason}}` if the JSON parses but doesn't
      satisfy the JSON-RPC 2.0 contract (missing `jsonrpc`, ambiguous
      response shape, etc.)
  """
  @spec decode_message(binary()) :: {:ok, Message.t()} | {:error, term()}
  def decode_message(line) when is_binary(line) do
    trimmed = line |> String.trim_trailing("\n") |> String.trim()

    if trimmed == "" do
      {:error, :empty}
    else
      case Jason.decode(trimmed) do
        {:ok, %{} = obj} -> classify(obj)
        {:ok, _other} -> {:error, {:invalid, "json must be an object"}}
        {:error, reason} -> {:error, {:json_parse, reason}}
      end
    end
  end

  @doc """
  Drain a stdout buffer of `\\n`-delimited JSON-RPC messages.

  `prev_remainder` is the partial-line bytes left over from the last
  read (or `""` for the first chunk). `chunk` is the bytes just read
  from the port.

  Returns `{messages, new_remainder}`:

    * `messages` — every complete line, parsed via `decode_message/1`.
      Each entry is `{:ok, msg}` or `{:error, reason}` so a single
      malformed line doesn't drop the surrounding well-formed ones.
    * `new_remainder` — the trailing bytes after the last `\\n` (may
      be `""`). Pass this back as `prev_remainder` for the next chunk.

  Empty lines are silently dropped (some peers emit blank
  keep-alives).
  """
  @spec parse_stream(binary(), binary()) ::
          {[{:ok, Message.t()} | {:error, term()}], binary()}
  def parse_stream(prev_remainder, chunk)
      when is_binary(prev_remainder) and is_binary(chunk) do
    combined = prev_remainder <> chunk

    case String.split(combined, "\n") do
      [single] ->
        # No newline yet — whole buffer is still partial.
        {[], single}

      parts ->
        {complete_lines, [remainder]} = Enum.split(parts, length(parts) - 1)

        messages =
          complete_lines
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.map(&decode_message/1)

        {messages, remainder}
    end
  end

  # ---- private classifiers ----

  defp classify(%{"jsonrpc" => @json_rpc_version} = obj) do
    cond do
      Map.has_key?(obj, "method") and Map.has_key?(obj, "id") ->
        {:ok, {:request, normalize_id(obj["id"]), obj["method"], obj["params"]}}

      Map.has_key?(obj, "method") ->
        {:ok, {:notification, obj["method"], obj["params"]}}

      Map.has_key?(obj, "id") and Map.has_key?(obj, "error") ->
        case obj["error"] do
          %{"code" => code, "message" => message} = err when is_integer(code) ->
            {:ok,
             {:error_response, normalize_id(obj["id"]),
              %RpcError{code: code, message: message, data: Map.get(err, "data")}}}

          _ ->
            {:error, {:invalid, "error object missing code/message"}}
        end

      Map.has_key?(obj, "id") and Map.has_key?(obj, "result") ->
        {:ok, {:response, normalize_id(obj["id"]), obj["result"]}}

      true ->
        {:error, {:invalid, "missing method (notif/req) or result/error (response)"}}
    end
  end

  defp classify(%{"jsonrpc" => other}),
    do: {:error, {:invalid, "jsonrpc must be \"2.0\", got #{inspect(other)}"}}

  defp classify(_), do: {:error, {:invalid, "missing jsonrpc field"}}

  # Normalize id types — JSON ints decode to ints already, but a
  # well-behaved peer might send a numeric string. Reject anything
  # that doesn't look like a non-negative integer; we never emit
  # string ids and we don't accept them.
  defp normalize_id(id) when is_integer(id) and id >= 0, do: id
  defp normalize_id(other), do: other

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
