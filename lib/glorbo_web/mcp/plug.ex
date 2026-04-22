defmodule GlorboWeb.MCP.Plug do
  @moduledoc """
  MCP Streamable HTTP transport adapter (GEP-29 wave a).

  Implements the MCP 2025-06-18 Streamable HTTP profile at a single
  URL path (`/mcp` by default). Handles:

    * **POST**: client → server JSON-RPC 2.0 requests and
      notifications. Responds with `application/json` for a one-shot
      result, or 202 Accepted (empty body) for notifications. SSE
      response framing is reserved for later waves (resources,
      long-running tool calls).
    * **GET**:  server → client SSE stream for spontaneous
      notifications. Not used in wave (a) — returns 405 so clients
      fall back to request/response.

  ## Security

    * `Origin` is validated on every request to prevent DNS-rebinding
      attacks (spec §Security Warning). Allowed origins default to
      any `http://localhost*`, `http://127.0.0.1*`, and requests with
      no `Origin` header (native CLI clients). Configure via
      `:allowed_origins` opt.
    * The plug is intended to bind to `127.0.0.1` via the Phoenix
      endpoint config — it does not enforce the socket bind itself.

  ## Session IDs

  The server advertises `Mcp-Session-Id: <uuid>` in the `initialize`
  response. Wave (a) issues the ID but does not persist any
  per-session state — the plug is stateless. Later waves attach a
  session GenServer to the ID for resource subscriptions and
  resumability.

  ## JSON-RPC envelope

  The spec allows a POST body to be either a single request or a
  batch array. Wave (a) supports single-request bodies only; batches
  return a JSON-RPC `Invalid Request` error. Batches are deprecated
  in 2025-06-18 anyway (spec removed them).
  """
  @behaviour Plug

  import Plug.Conn
  require Logger

  alias GlorboWeb.MCP.Server

  # Origins are compared by parsed URI.host, not prefix-matched. Prefix
  # matching would accept `http://localhost.evil.tld` as valid; exact
  # host equality against the allowlist closes that DNS-rebind vector.
  @default_allowed_origin_hosts ~w(localhost 127.0.0.1 ::1)

  @impl true
  def init(opts) do
    %{
      allowed_origin_hosts:
        Keyword.get(opts, :allowed_origin_hosts, @default_allowed_origin_hosts)
    }
  end

  @impl true
  def call(%Plug.Conn{method: method} = conn, opts) do
    case validate_origin(conn, opts.allowed_origin_hosts) do
      :ok ->
        dispatch_by_method(method, conn)

      {:error, origin} ->
        conn
        |> send_resp(403, "forbidden: origin #{inspect(origin)} not allowed")
        |> halt()
    end
  end

  # ---------------------------------------------------------------------------
  # Origin validation (DNS-rebind protection — MCP spec §Security)
  # ---------------------------------------------------------------------------

  defp validate_origin(conn, allowed_hosts) do
    case get_req_header(conn, "origin") do
      # No Origin header — typical of native CLI clients. Allowed.
      [] ->
        :ok

      [origin | _] ->
        uri = URI.parse(origin)

        # Exact host match (case-insensitive). `[::1]` in the header
        # parses as host `::1`, so compare stripped of brackets.
        host = if uri.host, do: String.downcase(uri.host), else: nil

        if host && host in allowed_hosts,
          do: :ok,
          else: {:error, origin}
    end
  end

  # ---------------------------------------------------------------------------
  # Method dispatch
  # ---------------------------------------------------------------------------

  defp dispatch_by_method("POST", conn), do: handle_post(conn)
  defp dispatch_by_method("GET", conn), do: handle_get(conn)
  defp dispatch_by_method("DELETE", conn), do: handle_delete(conn)

  defp dispatch_by_method(_other, conn) do
    conn
    |> put_resp_header("allow", "POST, GET, DELETE")
    |> send_resp(405, "method not allowed")
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # POST — client request / notification
  # ---------------------------------------------------------------------------

  defp handle_post(conn) do
    with {:ok, envelope, conn} <- read_envelope(conn),
         {:ok, method, params, id} <- extract_request(envelope) do
      context = build_context(conn)

      cond do
        # Notification per JSON-RPC 2.0: request with no `id` field
        # (or an explicit `null` id). Server MUST NOT return a
        # response body. Dispatch for side effects, then 202.
        is_nil(id) ->
          _ = Server.dispatch(method, params, context)
          send_resp(conn, 202, "")

        true ->
          dispatch_request(conn, method, params, id, context)
      end
    else
      {:error, :invalid_json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(rpc_error(nil, -32_700, "Parse error", nil)))

      {:error, :invalid_request, id} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(rpc_error(id, -32_600, "Invalid Request", nil)))

      {:error, :batch_unsupported} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          400,
          Jason.encode!(
            rpc_error(
              nil,
              -32_600,
              "Invalid Request",
              %{reason: "batch requests are not supported; send one envelope per POST"}
            )
          )
        )

      {:error, :read_body_failed} ->
        send_resp(conn, 400, "failed to read request body")
    end
  end

  defp dispatch_request(conn, method, params, id, context) do
    case Server.dispatch(method, params, context) do
      {:reply, result} ->
        respond(conn, id, {:ok, result})

      {:error, code, message, data} ->
        respond(conn, id, {:error, code, message, data})

      :no_reply ->
        # Handler declared this method a notification even though the
        # client sent an id. Acknowledge with an empty success result
        # so the client's request/response bookkeeping stays happy.
        respond(conn, id, {:ok, %{}})
    end
  end

  # ---------------------------------------------------------------------------
  # GET — server-to-client SSE stream
  # ---------------------------------------------------------------------------

  defp handle_get(conn) do
    # Wave (a): no server-initiated stream. Clients that speak
    # Streamable HTTP accept a 405 here and fall back to request/
    # response. Later waves open an SSE stream for resource
    # subscriptions and forward PubSub events.
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "SSE streams are not yet offered at this endpoint")
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # DELETE — explicit session termination (spec-optional for clients)
  # ---------------------------------------------------------------------------

  defp handle_delete(conn) do
    # Wave (a) is stateless; nothing to terminate server-side.
    # Acknowledge so compliant clients don't error on clean shutdown.
    send_resp(conn, 204, "")
  end

  # ---------------------------------------------------------------------------
  # Response helpers
  # ---------------------------------------------------------------------------

  defp respond(conn, id, outcome) do
    payload =
      case outcome do
        {:ok, result} -> rpc_result(id, result)
        {:error, code, message, data} -> rpc_error(id, code, message, data)
      end

    conn
    |> maybe_put_session_header(payload)
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
  end

  # Stamp `Mcp-Session-Id` on the `initialize` response. Echoed by
  # the client on every subsequent request per spec. Wave (a) does
  # not persist state keyed to the id; it's there so clients can
  # round-trip correctly.
  defp maybe_put_session_header(conn, %{"result" => %{"protocolVersion" => _}}) do
    put_resp_header(conn, "mcp-session-id", session_id())
  end

  defp maybe_put_session_header(conn, _other), do: conn

  defp session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp rpc_result(id, result),
    do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp rpc_error(id, code, message, data) do
    err = %{"code" => code, "message" => message}
    err = if is_nil(data), do: err, else: Map.put(err, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => err}
  end

  # ---------------------------------------------------------------------------
  # Envelope parsing
  # ---------------------------------------------------------------------------

  # Phoenix's `Plug.Parsers` runs before this plug and writes parsed
  # JSON to `conn.body_params`. When the parser ran (the common case
  # under the `phx.server` pipeline), use the pre-parsed map. When it
  # didn't (raw Plug tests, or a non-JSON content type), fall back to
  # reading the body ourselves.
  defp read_envelope(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, value} <- Jason.decode(body) do
      {:ok, value, conn}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      _ -> {:error, :read_body_failed}
    end
  end

  defp read_envelope(%Plug.Conn{body_params: parsed} = conn) when is_map(parsed) do
    if map_size(parsed) == 0 do
      # Phoenix's parser can emit an empty map when there's no body,
      # which looks indistinguishable from a legitimately-empty JSON
      # object. Probe `read_body` to tell them apart.
      case read_body(conn) do
        {:ok, "", _conn2} -> {:error, :invalid_json}
        {:ok, body, conn2} -> fallback_decode(body, conn2)
        _ -> {:ok, parsed, conn}
      end
    else
      {:ok, parsed, conn}
    end
  end

  defp read_envelope(_conn), do: {:error, :read_body_failed}

  defp fallback_decode(body, conn) do
    case Jason.decode(body) do
      {:ok, value} -> {:ok, value, conn}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp extract_request(list) when is_list(list), do: {:error, :batch_unsupported}

  defp extract_request(%{"jsonrpc" => "2.0", "method" => method} = env) when is_binary(method) do
    id = Map.get(env, "id")
    params = Map.get(env, "params", %{})

    if is_map(params) or is_list(params) do
      {:ok, method, params, id}
    else
      {:error, :invalid_request, id}
    end
  end

  defp extract_request(env) do
    id = if is_map(env), do: Map.get(env, "id"), else: nil
    {:error, :invalid_request, id}
  end

  # ---------------------------------------------------------------------------
  # Context construction
  # ---------------------------------------------------------------------------

  defp build_context(conn) do
    %{
      client: client_name(conn),
      base: Glorbo.Filesystem.Hierarchy.default_root()
    }
  end

  # Derive the `mcp:<client>` actor from the Mcp-Client-Name header
  # (set by some clients) or fall back to the generic `mcp:unknown`
  # bucket. Normalizes to lowercase slug characters.
  defp client_name(conn) do
    raw =
      case get_req_header(conn, "mcp-client-name") do
        [name | _] -> name
        [] -> "unknown"
      end

    raw
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "unknown"
      slug -> slug
    end
  end
end
