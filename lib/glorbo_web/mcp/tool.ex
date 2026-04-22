defmodule GlorboWeb.MCP.Tool do
  @moduledoc """
  Behaviour for an MCP tool exposed by Glorbo (GEP-29 wave a).

  Each tool is a stateless module. The server registry
  (`GlorboWeb.MCP.Server`) enumerates tools at compile time; adding
  one means writing the module + adding it to the `@tools` list.

  Implementations must be best-effort: on any unexpected condition
  return `{:error, reason}`. The dispatcher converts that into a
  JSON-RPC error; raising would also work, but `{:error, _}` gives
  the caller a cleaner surface.

  ## Context

  `call/2` receives a context map with per-request metadata. Wave (a)
  surfaces:

    * `:client` — normalized MCP client name, used as the audit actor
      prefix (`mcp:<client>`).
    * `:base`   — `~/.glorbo` root override (tests use a tmp dir).

  Tools that don't need the context can ignore it.
  """

  @type arguments :: map()
  @type context :: %{
          optional(:client) => String.t(),
          optional(:base) => Path.t()
        }

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback call(arguments(), context()) :: {:ok, term()} | {:error, term()}
end
