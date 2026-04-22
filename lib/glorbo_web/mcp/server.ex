defmodule GlorboWeb.MCP.Server do
  @moduledoc """
  MCP tool registry and JSON-RPC dispatcher (GEP-29 wave a).

  Holds the static catalog of Glorbo tools and resolves incoming
  `tools/call` requests to their handler modules. Also handles the
  protocol-level methods (`initialize`, `ping`, `tools/list`). No
  per-session state lives here — that belongs in
  `GlorboWeb.MCP.Plug`.

  A tool is a module implementing the `GlorboWeb.MCP.Tool` behaviour:

    * `name/0`     — dotted string, e.g. `"glorbo.list_companies"`.
    * `description/0` — human-readable prose (shown to the model).
    * `input_schema/0` — JSON Schema for the tool's arguments.
    * `call/2`     — `(arguments, context) → {:ok, result} | {:error, reason}`.

  The registry is assembled at compile time from the tools listed in
  `@tools`; to add a new tool, create the module and add it here.

  ## Errors

  All `dispatch/3` failures map to JSON-RPC errors via
  `{:error, code, message, data}` tuples. Codes follow the JSON-RPC
  2.0 standard plus MCP-specific extensions:

    * `-32601` method not found (unknown JSON-RPC method)
    * `-32602` invalid params (bad or missing tool arguments)
    * `-32603` internal error (handler crashed or returned unexpected shape)
    *  -32000  MCP tool not found (valid `tools/call` for an unknown name)

  ## Context

  The second argument to `call/2` is a map carrying per-request
  metadata:

    * `:client`      — normalized client name (actor prefix, e.g. `mcp:claude-code`)
    * `:base`        — `~/.glorbo` root (swappable for tests)

  Tools should not crash. On `{:error, reason}` the dispatcher
  returns a spec-compliant `CallToolResult` with `isError: true`
  (MCP 2025-06-18 convention — JSON-RPC errors are reserved for
  protocol violations). Raises are caught and also flow through the
  isError path.
  """

  alias GlorboWeb.MCP.Tools

  @protocol_version "2025-06-18"
  @server_name "glorbo"
  @server_version "0.0.4"

  # Tool registry — one module per tool.
  @tools [
    # Wave (a): scaffolding + first read tool
    Tools.ListCompanies,
    # Wave (b.1): core read tools
    Tools.GetCompany,
    Tools.ListAgents,
    Tools.GetAgent,
    Tools.ListTasks,
    Tools.GetTask,
    Tools.ListProposals
  ]

  @type request :: %{
          required(String.t()) => any()
        }

  @type response ::
          {:reply, map()}
          | {:error, integer(), String.t(), any()}
          | :no_reply

  @doc """
  Dispatch a parsed JSON-RPC request.

  Returns `{:reply, result}` with the JSON-RPC `result` field on
  success, `{:error, code, message, data}` on failure, or `:no_reply`
  for notifications (methods with no `id` in the envelope).
  """
  @spec dispatch(String.t(), map(), map()) :: response()
  def dispatch(method, params, context) when is_binary(method) do
    case method do
      "initialize" -> handle_initialize(params)
      "notifications/initialized" -> :no_reply
      "ping" -> {:reply, %{}}
      "tools/list" -> handle_tools_list()
      "tools/call" -> handle_tools_call(params, context)
      _ -> {:error, -32_601, "Method not found", %{method: method}}
    end
  end

  @doc """
  The server's declared protocol version.
  """
  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @doc """
  The compiled-in list of registered tool modules.
  """
  @spec tools() :: [module()]
  def tools, do: @tools

  # ---------------------------------------------------------------------------
  # MCP protocol methods
  # ---------------------------------------------------------------------------

  defp handle_initialize(_params) do
    {:reply,
     %{
       "protocolVersion" => @protocol_version,
       "capabilities" => %{
         "tools" => %{"listChanged" => false}
       },
       "serverInfo" => %{
         "name" => @server_name,
         "version" => @server_version
       }
     }}
  end

  defp handle_tools_list do
    {:reply,
     %{
       "tools" => Enum.map(@tools, &tool_descriptor/1)
     }}
  end

  defp handle_tools_call(%{"name" => name} = params, context) when is_binary(name) do
    args = Map.get(params, "arguments", %{})

    case find_tool(name) do
      nil ->
        # Unknown tool is a protocol-level error (client bug), not a
        # tool-execution failure.
        {:error, -32_000, "Tool not found", %{name: name}}

      mod ->
        invoke(mod, args, context)
    end
  end

  defp handle_tools_call(_bad, _context),
    do: {:error, -32_602, "Invalid params", %{expected: "name: string"}}

  # ---------------------------------------------------------------------------
  # Invocation
  # ---------------------------------------------------------------------------

  # MCP spec: `tools/call` responses are always a `CallToolResult`
  # (content array + optional structuredContent + isError). Tool
  # failures are in-band via `isError: true`, NOT as JSON-RPC errors
  # — JSON-RPC errors are reserved for protocol violations (unknown
  # method, bad envelope, unknown tool name).
  defp invoke(mod, args, context) do
    case mod.call(args, context) do
      {:ok, result} ->
        {:reply, call_tool_result(result, false)}

      {:error, reason} ->
        {:reply, call_tool_result(%{"reason" => inspect(reason)}, true)}

      other ->
        {:reply,
         call_tool_result(%{"reason" => "unexpected handler return: #{inspect(other)}"}, true)}
    end
  rescue
    e ->
      {:reply, call_tool_result(%{"reason" => "tool raised: #{Exception.message(e)}"}, true)}
  end

  # Structured tool output → spec-compliant `CallToolResult`. We
  # always populate `content` with a text block carrying the JSON
  # representation so naïve MCP clients that only read `content` see
  # something useful; rich clients can read `structuredContent` for
  # the typed data.
  defp call_tool_result(payload, is_error?) do
    %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(payload)}],
      "structuredContent" => payload,
      "isError" => is_error?
    }
  end

  defp find_tool(name) do
    Enum.find(@tools, fn mod -> mod.name() == name end)
  end

  defp tool_descriptor(mod) do
    %{
      "name" => mod.name(),
      "description" => mod.description(),
      "inputSchema" => mod.input_schema()
    }
  end
end
