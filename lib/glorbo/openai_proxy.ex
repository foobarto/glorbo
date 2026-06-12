defmodule Glorbo.OpenAIProxy do
  @moduledoc """
  In-process OpenAI v1-compatible inference proxy for sandboxed agents
  (GEP-0055).

  ## Mental model

  The proxy is the agent's API endpoint. The agent's CLI process inside
  the sandbox reads its `*_BASE_URL` env (or its mounted
  `settings.json`) and sees `http://127.0.0.1:<PROXY_PORT>`. It
  makes its first inference call to that URL. The proxy receives
  the HTTP request, routes by path to a `Glorbo.OpenAIProxy.Shape`
  adapter, the adapter translates the request to the upstream's
  wire format and attaches the upstream's auth header (read from
  the host's `System.get_env/1`), the proxy calls the upstream,
  the adapter translates the response back, the proxy returns it
  to the agent.

  The agent never sees a real API key. The real key is read by
  the proxy from the host's env at request time, used to call
  the upstream, and never written to a sandbox-visible path.

  ## Why a per-company GenServer

  Each company has its own proxy listener, bound to a unique
  ephemeral loopback port. The GEP-31 pasta netns then enforces
  that an agent can only reach *its company's* proxy port — a
  sandboxed agent in company A cannot reach company B's proxy
  at the kernel level, even if it knew the port. On top of that
  kernel boundary, the listener cross-checks every token's
  `company` against its own (the both-layers invariant; the
  GEP-0055 failure-mode table's `proxy.cross_company_blocked`
  row).

  ## Current status (slice 4a)

  Implemented: the listener, path-based routing to the three
  shape adapters (OpenAI v1, Anthropic, Gemini), per-dispatch
  token auth (Bearer or `X-Glorbo-Token`), the token-company
  cross-check, the provider `auth = via_proxy` check, and the
  real non-streaming upstream call (translated body, upstream
  auth headers, origin + request-target URL).

  Not yet implemented (future slices): SSE streaming (slice 5),
  the Gemini request/response translation and `?key=` auth
  (slice 9), the claude-code settings.json injection (D11),
  audit rows (`proxy.*` action vocabulary), and the
  `usage.json` write. The shape adapters currently pass
  OpenAI-/Anthropic-shaped bodies through untranslated, which
  is correct while each shape's agents talk to a same-shape
  upstream.

  ## DoS posture

  Loopback-only listener behind a per-company netns: only the
  company's own sandboxed agents can connect. Each request is
  bounded — 16 KiB head cap, 1 MiB body cap, a 15 s wall-clock
  deadline on reading the request, and a 30 s upstream timeout.
  There is deliberately no concurrent-connection cap yet; the
  reachable population is the company's own dispatches.
  """

  use GenServer
  require Logger

  alias Glorbo.OpenAIProxy.Shape.{OpenAI, Anthropic, Gemini}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @type start_opts :: [
          name: GenServer.name(),
          company: String.t(),
          port: non_neg_integer()
        ]

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Return the actually-bound port (after ephemeral assignment by the OS).
  Used by `Glorbo.Agent.Dispatch` to construct the per-company
  `GLORBO_PROXY_BASE_URL`.
  """
  @spec port(GenServer.server()) :: pos_integer()
  def port(server), do: GenServer.call(server, :port)

  @doc """
  Lookup the shape adapter for an HTTP path. Returns `nil` when
  no adapter matches (the proxy will return `404 Not Found` for
  the request).
  """
  @spec adapter_for_path(String.t()) :: module() | nil
  def adapter_for_path(path) when is_binary(path) do
    Enum.find(adapters(), fn adapter -> adapter.route?(path) end)
  end

  def adapter_for_path(_), do: nil

  @doc """
  Enumerate the registered shape adapters. New adapters are
  added to this list; the proxy routes by walking it in order.
  """
  @spec adapters() :: [module()]
  def adapters, do: [OpenAI, Anthropic, Gemini]

  # ---------------------------------------------------------------------------
  # GenServer state
  # ---------------------------------------------------------------------------

  defmodule State do
    @moduledoc false
    defstruct [:listen_sock, :bound_port, :acceptor, :company]
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    requested_port = Keyword.get(opts, :port, 0)

    case :gen_tcp.listen(requested_port, [
           :binary,
           active: false,
           reuseaddr: true,
           # GEP-23 D7: bind to loopback only. The proxy is a
           # localhost-only service; binding to a public interface
           # would require auth we don't have.
           ifaddr: {127, 0, 0, 1}
         ]) do
      {:ok, listen_sock} ->
        {:ok, bound_port} = :inet.port(listen_sock)
        acceptor = start_acceptor(listen_sock, company)

        Logger.info("OpenAIProxy starting company=#{company} port=#{bound_port} (GEP-0055)")

        {:ok,
         %State{
           listen_sock: listen_sock,
           bound_port: bound_port,
           acceptor: acceptor,
           company: company
         }}

      {:error, reason} ->
        {:stop, {:listen_failed, reason}}
    end
  end

  @impl true
  def handle_call(:port, _from, %State{bound_port: port} = state) do
    {:reply, port, state}
  end

  @impl true
  def handle_info({:tcp_closed, _sock}, state), do: {:noreply, state}

  @impl true
  def handle_info({:tcp_error, _sock, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %State{acceptor: {pid, ref}} = state) do
    # Acceptor died. The listen socket is owned by this GenServer
    # (created in init/1), so it survives the acceptor — re-attach a
    # fresh acceptor to the SAME socket. The bound port must never
    # change mid-lifetime: every in-flight dispatch already carries
    # it in its *_BASE_URL env. If the socket is gone too (proxy
    # shutting down — the acceptor's accept loop ends normally when
    # the socket closes), stop instead of looping respawn.
    case :inet.port(state.listen_sock) do
      {:ok, _port} ->
        Logger.warning(
          "OpenAIProxy acceptor died company=#{state.company} reason=#{inspect(reason)}; respawning"
        )

        {:noreply, %State{state | acceptor: start_acceptor(state.listen_sock, state.company)}}

      {:error, _} ->
        {:stop, {:acceptor_died, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{listen_sock: sock}) do
    _ = sock && :gen_tcp.close(sock)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Acceptor — runs in a separate process so the GenServer stays responsive
  # ---------------------------------------------------------------------------

  # Spawns a long-lived process that accepts connections and hands
  # each one to a per-request handler process. The acceptor is
  # monitored; on death the GenServer re-attaches a new acceptor to
  # the existing listen socket (see the `:DOWN` handler above).
  defp start_acceptor(listen_sock, company) do
    spawn_monitor(fn -> accept_loop(listen_sock, company) end)
  end

  defp accept_loop(listen_sock, company) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, client_sock} ->
        # Per-request handler. Unlinked spawn: a crash in one
        # handler must not take the acceptor (and with it every
        # other in-flight request) down. Unexpected exceptions are
        # additionally caught inside `handle_request/2` and turned
        # into a 500. Socket ownership is transferred so the
        # client socket's lifetime is tied to its handler, not to
        # the acceptor.
        #
        # The handler is spawned WAITING: it must not touch the socket
        # until `controlling_process/2` has made it the owner, otherwise
        # an early `:gen_tcp.recv/3` races the ownership transfer and
        # fails intermittently with `:not_owner`. (PR #47 review: Copilot.)
        pid = spawn(fn -> await_handoff(client_sock, company) end)

        case :gen_tcp.controlling_process(client_sock, pid) do
          :ok ->
            send(pid, :socket_handed_off)

          {:error, _reason} ->
            # Transfer failed (socket already gone) — the acceptor still
            # owns it, so close here; the waiting handler times out and
            # exits without ever reading.
            :gen_tcp.close(client_sock)
        end

        accept_loop(listen_sock, company)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        # Don't busy-loop on a transient error; back off briefly
        # and try again. When the listen_sock goes away (proxy
        # shutdown), accept returns :closed and we exit cleanly.
        Process.sleep(50)
        accept_loop(listen_sock, company)
    end
  end

  # ---------------------------------------------------------------------------
  # Per-request handler (slice 4a: real upstream call, non-stream)
  # ---------------------------------------------------------------------------

  # Cap on request body size. Mirrors the GEP-8 D12 `reply_max_bytes`
  # default (1 MiB) but applies to the *request* — the body the
  # agent sent the proxy. A 1 MiB cap on the request body is more
  # than enough for any chat-completions payload; anything larger
  # is either a bug or a DoS attempt.
  @max_request_body_bytes 1_048_576

  # Cap on the request line + header block.
  @max_request_head_bytes 16_384

  # Wall-clock budget for reading the head. Bounds the slow-drip
  # window: without it a client trickling one byte per recv timeout
  # could hold a handler process for hours.
  @head_read_deadline_ms 15_000

  @body_read_timeout_ms 10_000
  @upstream_timeout_ms 30_000

  # Safety net for the handler's wait-for-ownership hand-off. Only reached
  # on the rare controlling_process/2 failure path (signal never arrives);
  # the handler exits rather than blocking forever.
  @handoff_timeout_ms 5_000

  # Per-request handler entry: block until the acceptor confirms socket
  # ownership has been transferred (see accept_loop/2), then process. The
  # handler never touches the socket before this signal, so it cannot race
  # the controlling_process/2 transfer.
  defp await_handoff(client_sock, company) do
    receive do
      :socket_handed_off -> handle_request(client_sock, company)
    after
      @handoff_timeout_ms -> :ok
    end
  end

  # Handles a single HTTP request on `client_sock`. The proxy
  # is request-scoped: one connection, one request, one
  # response, then close. (HTTP/1.1 keep-alive is a future
  # enhancement; not in scope.)
  #
  # The flow:
  #   1. Read the request line + headers (capped + deadlined),
  #      keeping any body bytes that arrived in the same TCP
  #      segments.
  #   2. Read the rest of the body, capped at 1 MiB.
  #   3. Resolve the per-dispatch token (`Authorization: Bearer`
  #      or `X-Glorbo-Token`), cross-check its company against
  #      this listener's company, and check the provider is
  #      actually `auth = via_proxy`.
  #   4. Match the path to a shape adapter.
  #   5. Adapter translates the request body to the upstream's
  #      wire format and attaches the upstream's auth header
  #      (key read from `System.get_env(provider.api_key_env)`).
  #   6. Proxy calls the upstream via `Req` and returns the
  #      translated response. (Audit row + usage.json: future
  #      slices.)
  defp handle_request(client_sock, company) do
    case read_request(client_sock) do
      {:ok, method, path, headers, body} ->
        process_request(client_sock, method, path, headers, body, company)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        send_error(client_sock, 408, "request_timeout", "request not received in time")

      {:error, :body_too_large} ->
        send_error(client_sock, 413, "body_too_large", "request body exceeds 1 MiB cap")

      {:error, reason} ->
        send_error(client_sock, 400, "bad_request", inspect(reason))
    end
  rescue
    e ->
      # Last-resort containment: a handler bug must surface as a
      # clean 500 to the agent, never as silence. Full detail
      # goes to the host log only.
      Logger.warning(
        "OpenAIProxy handler crashed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      send_error(client_sock, 500, "internal_error", "proxy internal error")
  after
    :gen_tcp.close(client_sock)
  end

  # Reads the HTTP request line, headers, and body. Returns
  # one of:
  #
  #   `{:ok, method, path, headers, body}` — success
  #   `{:error, :closed}` — peer disconnected mid-request
  #   `{:error, :timeout}` — head not complete within the deadline
  #   `{:error, :body_too_large | :bad_content_length | ...}`
  #
  # Implementation note: we read raw bytes in a loop, splitting on
  # the `\r\n\r\n` head terminator. Bytes after the terminator are
  # the start of the body and are carried into `read_body/3` — a
  # typical small JSON POST arrives headers+body in one segment.
  defp read_request(client_sock) do
    deadline = System.monotonic_time(:millisecond) + @head_read_deadline_ms

    with {:ok, head, rest} <- read_request_head(client_sock, "", deadline),
         {:ok, method, path, headers} <- parse_head(head),
         {:ok, body} <- read_body(client_sock, headers, rest) do
      {:ok, method, path, headers, body}
    end
  end

  # Read bytes into `acc` until the head terminator appears, then
  # split: everything before it is the head, everything after it is
  # early body bytes. The 16 KiB cap applies to a head that never
  # terminates; the deadline bounds total wall-clock.
  defp read_request_head(sock, acc, deadline) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, _len} when pos >= @max_request_head_bytes ->
        # A complete header block can arrive in a single read with the
        # terminator already present — the cap must be enforced here too,
        # not only on the still-unterminated `:nomatch` path, or an
        # oversized one-shot header block bypasses it. (PR #47 review:
        # codex + Copilot — oversized-header DoS.)
        {:error, :head_too_large}

      {pos, len} ->
        head = binary_part(acc, 0, pos)
        rest = binary_part(acc, pos + len, byte_size(acc) - pos - len)
        {:ok, head, rest}

      :nomatch ->
        remaining = deadline - System.monotonic_time(:millisecond)

        cond do
          byte_size(acc) >= @max_request_head_bytes ->
            {:error, :head_too_large}

          remaining <= 0 ->
            {:error, :timeout}

          true ->
            case :gen_tcp.recv(sock, 0, min(remaining, 5_000)) do
              {:ok, chunk} -> read_request_head(sock, acc <> chunk, deadline)
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  # Parses the head buffer into `{:ok, method, path, headers}`.
  # `headers` is a map of lowercase-name → trimmed-value.
  defp parse_head(head) do
    case String.split(head, "\r\n") do
      [request_line | header_lines] when request_line != "" ->
        with {:ok, method, path} <- parse_request_line(request_line) do
          {:ok, method, path, parse_header_lines(header_lines)}
        end

      _ ->
        {:error, :malformed_request_line}
    end
  end

  defp parse_header_lines(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case parse_header_line(line) do
        {name, value} -> Map.put(acc, name, value)
        :skip -> acc
      end
    end)
  end

  # Parses `Name: Value` into `{name, value}` (both strings,
  # trimmed, name lowercased for case-insensitive lookup).
  defp parse_header_line(line) when is_binary(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        {String.downcase(String.trim(name)), String.trim(value)}

      _ ->
        :skip
    end
  end

  defp parse_header_line(_), do: :skip

  # Parses an HTTP/1.x request line: `METHOD SP TARGET SP HTTP/x.y`.
  defp parse_request_line(line) when is_binary(line) do
    case String.split(line, " ", parts: 3) do
      [method, target, "HTTP/" <> _] -> {:ok, method, target}
      _ -> {:error, :malformed_request_line}
    end
  end

  defp parse_request_line(_), do: {:error, :malformed_request_line}

  # Reads the request body. `rest` is whatever arrived after the
  # head terminator. Honors `Content-Length` (the common case for
  # non-streaming requests); `Transfer-Encoding: chunked` is not
  # supported until the streaming slice.
  defp read_body(client_sock, headers, rest) do
    cond do
      raw = Map.get(headers, "content-length") ->
        case Integer.parse(raw) do
          {n, ""} when n >= 0 -> read_fixed_body(client_sock, n, rest)
          _ -> {:error, :bad_content_length}
        end

      Map.has_key?(headers, "transfer-encoding") ->
        {:error, :chunked_not_supported}

      true ->
        # No body.
        {:ok, ""}
    end
  end

  defp read_fixed_body(_sock, 0, _rest), do: {:ok, ""}

  defp read_fixed_body(_sock, n, _rest) when n > @max_request_body_bytes,
    do: {:error, :body_too_large}

  defp read_fixed_body(_sock, n, rest) when byte_size(rest) >= n,
    do: {:ok, binary_part(rest, 0, n)}

  defp read_fixed_body(sock, n, rest) do
    # Passive raw recv with an exact byte count blocks until that
    # many bytes arrive (or the timeout fires).
    case :gen_tcp.recv(sock, n - byte_size(rest), @body_read_timeout_ms) do
      {:ok, chunk} -> {:ok, rest <> chunk}
      {:error, reason} -> {:error, reason}
    end
  end

  # Route the request to the right adapter, call the upstream,
  # return the response. Errors map to OpenAI-shaped error bodies
  # so the agent's HTTP client gets a useful message instead of a
  # generic 502.
  defp process_request(client_sock, method, path, headers, body, company) do
    with :ok <- validate_method(method),
         {:ok, token} <- extract_token(headers),
         {:ok, token_entry} <- resolve_token(token),
         :ok <- check_company(token_entry, company),
         {:ok, provider} <- resolve_provider(token_entry),
         {:ok, adapter} <- fetch_adapter(path),
         {:ok, parsed_body} <- parse_json_body(body) do
      with {:ok, upstream_body, upstream_headers} <-
             adapter.translate_request(parsed_body, headers),
           {:ok, api_key} <- lookup_api_key(provider) do
        upstream_headers_with_auth = adapter.attach_auth(upstream_headers, api_key)

        with {:ok, upstream_response, status} <-
               call_upstream(provider, method, path, upstream_body, upstream_headers_with_auth),
             {:ok, translated_response} <-
               adapter.translate_response(upstream_response, parsed_body) do
          send_json(client_sock, status, translated_response)
        else
          {:error, :upstream_unreachable} ->
            send_error(client_sock, 502, "upstream_unreachable", "upstream could not be reached")

          {:error, :upstream_unexpected_status, status} ->
            send_error(
              client_sock,
              502,
              "upstream_unexpected_status",
              "upstream answered with status #{status}"
            )

          {:error, :upstream_4xx, status, body} ->
            send_json(client_sock, status, body)

          {:error, :upstream_5xx, status, body} ->
            send_json(client_sock, status, body)
        end
      else
        {:error, :api_key_missing} ->
          send_error(client_sock, 503, "upstream_credentials_missing", "host env var is unset")

        {:error, :bad_request, reason} ->
          send_error(client_sock, 400, "bad_request", reason)
      end
    else
      {:error, :method_not_allowed} ->
        send_error(client_sock, 405, "method_not_allowed", "only GET and POST are supported")

      {:error, :missing_authorization} ->
        send_error(client_sock, 401, "invalid_request_error", "missing Authorization header")

      {:error, :bad_bearer} ->
        send_error(
          client_sock,
          401,
          "invalid_request_error",
          "Authorization must be Bearer <token>"
        )

      {:error, :token_unknown} ->
        send_error(client_sock, 401, "invalid_request_error", "token unknown or expired")

      {:error, :cross_company} ->
        # GEP-0055 failure-mode table: `proxy.cross_company_blocked`.
        send_error(client_sock, 401, "invalid_request_error", "token company mismatch")

      {:error, :token_no_provider} ->
        send_error(client_sock, 401, "invalid_request_error", "token has no provider alias")

      {:error, :provider_not_found} ->
        send_error(client_sock, 401, "invalid_request_error", "provider not found in registry")

      {:error, :provider_not_via_proxy} ->
        send_error(
          client_sock,
          401,
          "invalid_request_error",
          "provider is not routed via the proxy"
        )

      {:error, :no_adapter} ->
        send_error(client_sock, 404, "not_found", "no adapter handles path #{path}")

      {:error, :invalid_json} ->
        send_error(client_sock, 400, "bad_request", "request body is not valid JSON")
    end
  end

  defp validate_method(method) when method in ["GET", "POST"], do: :ok
  defp validate_method(_), do: {:error, :method_not_allowed}

  # `nil` is an atom, so a bare `is_atom/1` guard cannot distinguish
  # "no adapter" — use a tagged tuple instead.
  defp fetch_adapter(path) do
    case adapter_for_path(path) do
      nil -> {:error, :no_adapter}
      adapter -> {:ok, adapter}
    end
  end

  # Bearer is the primary scheme; `X-Glorbo-Token` is the GEP-0055
  # fallback for clients that can't set an Authorization header.
  defp extract_token(headers) do
    case Map.get(headers, "authorization", "") do
      "Bearer " <> token -> {:ok, token}
      "bearer " <> token -> {:ok, token}
      "" -> extract_fallback_token(headers)
      _ -> {:error, :bad_bearer}
    end
  end

  defp extract_fallback_token(headers) do
    case Map.get(headers, "x-glorbo-token") do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_authorization}
    end
  end

  defp resolve_token(token) do
    case Glorbo.Network.ProxyTokens.resolve(token) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :token_unknown}
    end
  end

  # Defence-in-depth (GEP-0055 failure-mode table): the pasta netns
  # already prevents a sandboxed agent from reaching another
  # company's proxy port, but `ProxyTokens` is a single global
  # table — enforce company isolation at the application layer too
  # (CLAUDE.md both-layers invariant).
  defp check_company(%{company: token_company}, company) when token_company == company, do: :ok
  defp check_company(_entry, _company), do: {:error, :cross_company}

  # Look up the provider in the registry by the token's
  # `provider_alias`, and require it to actually be a `via_proxy`
  # provider — tokens minted for other auth modes (or GEP-23
  # CONNECT tokens, whose `provider_alias` is nil) get a clean 401.
  defp resolve_provider(%{provider_alias: alias}) when is_binary(alias) do
    case Glorbo.CLI.Registry.get(alias) do
      nil -> {:error, :provider_not_found}
      %Glorbo.CLI.Registry.Provider{auth: :via_proxy} = p -> {:ok, p}
      %Glorbo.CLI.Registry.Provider{} -> {:error, :provider_not_via_proxy}
    end
  end

  defp resolve_provider(_), do: {:error, :token_no_provider}

  defp parse_json_body(""), do: {:ok, %{}}

  defp parse_json_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      _ -> {:error, :invalid_json}
    end
  end

  defp parse_json_body(_), do: {:error, :invalid_json}

  defp lookup_api_key(%{api_key_env: env_var}) when is_binary(env_var) and env_var != "" do
    case System.get_env(env_var) do
      nil -> {:error, :api_key_missing}
      "" -> {:error, :api_key_missing}
      key -> {:ok, key}
    end
  end

  defp lookup_api_key(_), do: {:error, :api_key_missing}

  # Calls the upstream via Req (declared dep; pooled Finch under
  # the hood). Slice 4a: non-stream only; streaming lands in
  # slice 5. The error mapping is the failure-modes table from
  # GEP-0055 §Design.
  defp call_upstream(%{endpoint: endpoint}, method, path, body, headers) do
    url = upstream_url(endpoint, path)

    # Reuse the app-supervised Finch pool (Glorbo.Finch in the app tree)
    # rather than letting Req spin up its own default Finch instance.
    # (PR #47 review: Copilot.)
    result =
      case method do
        "GET" ->
          Req.get(url,
            finch: Glorbo.Finch,
            headers: headers,
            receive_timeout: @upstream_timeout_ms
          )

        _ ->
          Req.post(url,
            finch: Glorbo.Finch,
            json: body,
            headers: headers,
            receive_timeout: @upstream_timeout_ms
          )
      end

    case result do
      {:ok, %{status: status, body: resp_body}} when status >= 200 and status < 300 ->
        {:ok, resp_body, status}

      {:ok, %{status: status, body: resp_body}} when status >= 400 and status < 500 ->
        {:error, :upstream_4xx, status, resp_body}

      {:ok, %{status: status, body: resp_body}} when status >= 500 ->
        {:error, :upstream_5xx, status, resp_body}

      {:ok, %{status: status}} ->
        # 3xx that Req's redirect step didn't consume — we never
        # blind-follow redirects carrying upstream credentials.
        {:error, :upstream_unexpected_status, status}

      {:error, reason} ->
        Logger.warning("OpenAIProxy upstream call failed: #{inspect(reason)}")
        {:error, :upstream_unreachable}
    end
  end

  # Upstream URL: the provider endpoint's origin (scheme + host +
  # port) plus the agent's route-matched request target. The
  # endpoint's own path (e.g. the `/v1` in
  # `https://api.openai.com/v1`) is intentionally dropped — every
  # shape's wire paths already start at the API root
  # (`/v1/chat/completions`, `/v1/messages`, `/v1beta/models/...`),
  # so appending would double the prefix. Subpath-hosted upstreams
  # are a documented GEP-0055 limitation. The target is safe to
  # splice: it already passed an adapter's exact/anchored `route?/1`
  # match.
  defp upstream_url(endpoint, path) do
    endpoint |> URI.parse() |> URI.merge(path) |> URI.to_string()
  end

  # ---------------------------------------------------------------------------
  # Response writers
  # ---------------------------------------------------------------------------

  # Upstream bodies may arrive already-decoded (maps, via Req's JSON
  # step) or as raw binaries (non-JSON error pages). Pass binaries
  # through untouched instead of double-encoding them into a JSON
  # string.
  defp send_json(client_sock, status, body) when is_binary(body) do
    _ = :gen_tcp.send(client_sock, http_response(status, body))
    :ok
  end

  defp send_json(client_sock, status, body) do
    send_json(client_sock, status, Jason.encode!(body))
  end

  defp send_error(client_sock, status, code, message) do
    body = %{
      "error" => %{
        "type" => code,
        "message" => message
      }
    }

    send_json(client_sock, status, body)
  end

  defp http_response(status, body) do
    reason = http_reason(status)

    "HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
      body
  end

  defp http_reason(200), do: "OK"
  defp http_reason(400), do: "Bad Request"
  defp http_reason(401), do: "Unauthorized"
  defp http_reason(404), do: "Not Found"
  defp http_reason(405), do: "Method Not Allowed"
  defp http_reason(408), do: "Request Timeout"
  defp http_reason(413), do: "Payload Too Large"
  defp http_reason(500), do: "Internal Server Error"
  defp http_reason(502), do: "Bad Gateway"
  defp http_reason(503), do: "Service Unavailable"
  defp http_reason(s) when is_integer(s), do: "Unknown"
end
