defmodule Glorbo.CLI.Dispatcher.Acp.RpcError do
  @moduledoc """
  JSON-RPC 2.0 error object. Mirrors stado's `acp.RPCError` shape.

  Standard codes (GEP-45 Phase 1b — same constants as stado):

    * `-32700` parse error
    * `-32600` invalid request
    * `-32601` method not found
    * `-32602` invalid params
    * `-32603` internal error
  """

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: any() | nil
        }

  @enforce_keys [:code, :message]
  defstruct [:code, :message, :data]
end
