defmodule Glorbo.CLI.Dispatcher.Acp.Message do
  @moduledoc """
  Tagged-tuple representation of JSON-RPC 2.0 messages used by ACP
  (Agent Client Protocol). GEP-45 Phase 1b foundation.

  Four message kinds, distinguished by tag:

    * `{:request, id, method, params}` — outbound from glorbo, expects
      a response. `id` is a non-negative integer (we never use string
      ids — closed numeric space simplifies state-machine matching).
    * `{:notification, method, params}` — fire-and-forget; no `id`,
      no response expected. Glorbo emits these for `cancel` and the
      ACP server emits them as `session/update` event chunks.
    * `{:response, id, result}` — successful reply to a request.
    * `{:error_response, id, error}` — error reply to a request.
      `error` is a `%Glorbo.CLI.Dispatcher.Acp.RpcError{}` struct.

  This module is pure data — encoding/decoding lives in
  `Glorbo.CLI.Dispatcher.Acp.Framing`. Keeping the two split lets the
  client state machine match on tagged tuples without ever parsing
  JSON itself.
  """

  alias Glorbo.CLI.Dispatcher.Acp.RpcError

  @type id :: non_neg_integer()
  @type method :: String.t()
  @type params :: map() | nil
  @type result :: map() | nil

  @type t ::
          {:request, id(), method(), params()}
          | {:notification, method(), params()}
          | {:response, id(), result()}
          | {:error_response, id(), RpcError.t()}

  @doc "Build an outbound JSON-RPC request."
  @spec new_request(id(), method(), params()) :: t()
  def new_request(id, method, params \\ nil) when is_integer(id) and is_binary(method),
    do: {:request, id, method, params}

  @doc "Build an outbound JSON-RPC notification (no response expected)."
  @spec new_notification(method(), params()) :: t()
  def new_notification(method, params \\ nil) when is_binary(method),
    do: {:notification, method, params}

  @doc "Build a successful response to an inbound request."
  @spec new_response(id(), result()) :: t()
  def new_response(id, result) when is_integer(id),
    do: {:response, id, result}

  @doc "Build an error response. `code` follows JSON-RPC 2.0 conventions."
  @spec new_error_response(id(), integer(), String.t()) :: t()
  def new_error_response(id, code, message)
      when is_integer(id) and is_integer(code) and is_binary(message),
      do: {:error_response, id, %RpcError{code: code, message: message}}

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @spec parse_error_code() :: integer()
  def parse_error_code, do: @parse_error

  @spec invalid_request_code() :: integer()
  def invalid_request_code, do: @invalid_request

  @spec method_not_found_code() :: integer()
  def method_not_found_code, do: @method_not_found

  @spec invalid_params_code() :: integer()
  def invalid_params_code, do: @invalid_params

  @spec internal_error_code() :: integer()
  def internal_error_code, do: @internal_error
end
