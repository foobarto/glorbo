defmodule Glorbo.Network.Proxy do
  @moduledoc """
  HTTPS CONNECT allowlist proxy for `network: proxy` agents (D-17;
  SEC-03; T-03-33).

  A small (~150 LOC target) OTP-native proxy that accepts HTTPS CONNECT
  tunnels to a hostname allowlist and rejects everything else. One proxy
  per company, listening on an ephemeral port. The port is passed via
  `HTTPS_PROXY` env into the sandbox (RESEARCH Pattern — sambaiz.net
  Claude Code sandbox reference).

  ## Why custom + OTP-native (not TinyProxy)

  TinyProxy's `FilterDefaultDeny` only covers plain HTTP — its filter does
  not inspect HTTPS CONNECT tunnel hostnames. Since all three supported CLI
  tools use HTTPS exclusively, tinyproxy would be a no-op. Mitmproxy-style
  TLS interception is off the table (it breaks cert pinning + OAuth
  flows). This custom proxy parses the CONNECT line itself, validates the
  hostname against an allowlist, then opens an upstream socket and splices
  bytes bidirectionally — no TLS termination, no payload inspection.

  ## Threat model (T-03-33, T-03-34)

    * **Mitigated:** hostname spoofing (exact-match, case-folded).
    * **Mitigated:** method abuse (CONNECT-only — 405 for GET/POST/etc).
    * **Mitigated:** port abuse (443-only; plain HTTP on :80 is rejected).
    * **Boundary note:** On Linux, GEP-31 now wraps `network: proxy`
      dispatches in a `pasta` netns so the proxy is the only reachable
      host listener. This module still owns only hostname allowlist /
      CONNECT semantics; the netns enforcement lives in
      `Glorbo.Sandbox.Bwrap`.

  ## Allowlist composition

  Base list from `config/network_policy.exs` (Plan 03-02):

      config :glorbo, :network_policy, %{
        proxy_base_allowlist: %{
          "claude-code" => ~w(api.anthropic.com ...),
          "gemini-cli" => ~w(generativelanguage.googleapis.com ...),
          "codex"      => ~w(api.openai.com ...)
        }
      }

  At proxy init, the base list is union'd across all providers (v0.0.1
  ships a single per-company proxy serving all agents). Per-company
  override via `companies/<co>/company.md`'s `network_allow:` field is
  supported — implemented at init via the dep-injected `:allowlist_fun`.
  """
  use GenServer

  require Logger
  import Bitwise, only: [band: 2]

  # Idle-tunnel ceiling. A CONNECT tunnel carrying no bytes for this long
  # gets torn down by relay_bytes/3's `after` clause. 5 minutes aligns
  # with common reverse-proxy defaults (nginx, haproxy) and the
  # bwrap-side timeout_seconds default (GEP-8 §7.4). Shortened from the
  # original 600s (TODO.md Minor #2).
  @tunnel_idle_timeout_ms 5 * 60 * 1_000

  @type start_opts :: [
          name: GenServer.name(),
          company: String.t(),
          port: non_neg_integer(),
          allowlist_fun: (String.t() -> [String.t()]),
          task_supervisor: GenServer.name() | pid(),
          # GEP-23 Phase 2: optional smart-mode fallthrough. When set,
          # hosts outside the company allowlist are passed to this
          # function for classification before the proxy responds.
          # `classifier_fun` signature:
          #
          #   (host :: String.t(), port :: pos_integer()) ::
          #     {:allow, reason :: atom()}
          #     | {:deny, reason :: atom()}
          #     | {:unknown, reason :: atom()}
          #
          # `:allow` verdicts open the tunnel; `:deny` and `:unknown`
          # both respond 403 (Phase 3 adds director-approval sentinels
          # for `:unknown`). Missing = legacy allowlist-only behaviour.
          classifier_fun:
            (String.t(), pos_integer() ->
               {:allow, atom()} | {:deny, atom()} | {:unknown, atom()})
            | nil
        ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Return the actually-bound port (after ephemeral assignment by the OS).
  """
  @spec port(GenServer.server()) :: pos_integer()
  def port(server), do: GenServer.call(server, :port)

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, :noproc -> :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.get(opts, :company, "_unknown")
    requested_port = Keyword.get(opts, :port, 0)

    allowlist_fun =
      Keyword.get(opts, :allowlist_fun, fn _co ->
        default_allowlist()
      end)

    allowlist = allowlist_fun.(company) |> Enum.map(&String.downcase/1) |> MapSet.new()

    classifier_fun = Keyword.get(opts, :classifier_fun)

    # GEP-23 §Proxy daemon — optional per-company decision cache. When
    # `:history_server` is supplied the proxy consults it on every
    # non-allowlist-hit and caches verdicts on the way back. `nil`
    # opts out; no cache interaction at all. Tests can pass the two
    # `fun` shortcuts directly when they don't want to wire a real
    # History GenServer.
    history_fun = Keyword.get(opts, :history_fun, build_history_fun(opts))
    history_put_fun = Keyword.get(opts, :history_put_fun, build_history_put_fun(opts))

    policy = %{
      allowlist: allowlist,
      classifier_fun: classifier_fun,
      history_fun: history_fun,
      history_put_fun: history_put_fun
    }

    {:ok, listen_sock} =
      :gen_tcp.listen(requested_port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    # Prefer a supervisor-wired sibling Task.Supervisor. When none is
    # injected, start one we own ourselves so the Proxy remains usable
    # standalone (test paths + early-integration callers). Owned task_sups
    # are unlinked (so the Proxy's own terminate doesn't receive their
    # shutdown EXIT) and explicitly stopped in terminate/2 to avoid leaking
    # tunnel tasks.
    {task_sup, owns_task_sup?} =
      case Keyword.get(opts, :task_supervisor) do
        nil ->
          {:ok, ts} = Task.Supervisor.start_link()
          true = Process.unlink(ts)
          {ts, true}

        ts ->
          {ts, false}
      end

    {acceptor_ref, acceptor_pid} = start_acceptor(listen_sock, policy, task_sup)

    {:ok, bound_port} = :inet.port(listen_sock)

    {:ok,
     %{
       company: company,
       policy: policy,
       listen_sock: listen_sock,
       task_sup: task_sup,
       owns_task_sup?: owns_task_sup?,
       acceptor_ref: acceptor_ref,
       acceptor_pid: acceptor_pid,
       port: bound_port
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    _ = safe_close(state.listen_sock)

    # When we spawned the Task.Supervisor ourselves, stop it explicitly so
    # any in-flight tunnel tasks are torn down (and their sockets closed)
    # instead of being abandoned as orphans.
    if state.owns_task_sup? and is_pid(state.task_sup) and Process.alive?(state.task_sup) do
      _ =
        try do
          Supervisor.stop(state.task_sup, :shutdown, 1_000)
        catch
          :exit, _ -> :ok
        end
    end

    :ok
  end

  # Acceptor died: re-arm it so the proxy keeps serving new connections.
  # This is the observable failure mode flagged by CR-02; without re-arming,
  # a tunnel-task crash that cascaded through the Task.Supervisor silently
  # stopped new-connection handling with no indication to the operator.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{acceptor_ref: ref} = state) do
    if reason not in [:normal, :shutdown, {:shutdown, :closed}] do
      Logger.warning("[network.proxy] acceptor died: #{inspect(reason)} — restarting acceptor")
    end

    {new_ref, new_pid} = start_acceptor(state.listen_sock, state.policy, state.task_sup)
    {:noreply, %{state | acceptor_ref: new_ref, acceptor_pid: new_pid}}
  end

  # Tunnel-task :DOWN — log abnormal exits so proxy failures are observable.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    if reason not in [:normal, :shutdown] do
      Logger.debug("[network.proxy] tunnel task exited: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Task result messages from async_nolink — discard.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Spawn the acceptor task under the Task.Supervisor using async_nolink so a
  # crash reaches us as a :DOWN (instead of an EXIT that would kill the
  # GenServer). Returns the ref we monitor for re-arming.
  defp start_acceptor(listen_sock, policy, task_sup) do
    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        accept_loop(listen_sock, policy, task_sup)
      end)

    {task.ref, task.pid}
  end

  # ---------------------------------------------------------------------------
  # Acceptor loop
  # ---------------------------------------------------------------------------

  defp accept_loop(listen_sock, policy, task_sup) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, client_sock} ->
        # async_nolink — a crash in handle_connection reaches the Proxy as a
        # :DOWN (logged + discarded). start_child used to link the failure to
        # the Task.Supervisor itself (see CR-02), which could cascade to the
        # acceptor and silently kill new-connection handling.
        {:ok, _pid} =
          Task.Supervisor.start_child(task_sup, fn ->
            handle_connection(client_sock, policy, task_sup)
          end)

        accept_loop(listen_sock, policy, task_sup)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[network.proxy] accept failed: #{inspect(reason)} — exiting loop")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Connection handler
  # ---------------------------------------------------------------------------

  defp handle_connection(client_sock, policy, task_sup) do
    case read_request_head(client_sock, <<>>) do
      {:ok, head} ->
        dispatch_request(head, client_sock, policy, task_sup)

      {:error, reason} ->
        Logger.debug("[network.proxy] read_request_head failed: #{inspect(reason)}")
        safe_close(client_sock)
    end
  end

  # Read until "\r\n\r\n" or the 16KB cap. The guard is on cumulative
  # `acc` size and fires on every recursive call (not just the first) —
  # a slow-drip chunking attack can only append until the running total
  # exceeds the cap, at which point the next recursion rejects. Bounded
  # at 16KB regardless of chunk size.
  defp read_request_head(_sock, acc) when byte_size(acc) >= 16_384 do
    Logger.debug("[network.proxy] request head > 16KB — rejecting")
    {:error, :too_large}
  end

  defp read_request_head(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} ->
        new_acc = acc <> chunk

        if String.contains?(new_acc, "\r\n\r\n") do
          {:ok, new_acc}
        else
          read_request_head(sock, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_request(head, client_sock, policy, task_sup) do
    [first_line | rest] = String.split(head, "\r\n", parts: 2)

    case parse_connect_line(first_line) do
      {:ok, host, port} ->
        # GEP-23 Phase 5: look up the per-dispatch caller context
        # from the `Proxy-Authorization: Basic <token>` header.
        # Token absent = legacy dispatch; proxy falls back to the
        # company-level allowlist (which is already scoped to this
        # proxy's company by the supervisor). Token present + valid
        # tags the decision with the specific agent + dispatch_id
        # so audit events can attribute the egress precisely.
        caller_ctx = resolve_caller_from_headers(rest)
        policy = Map.put(policy, :caller_ctx, caller_ctx)
        evaluate_and_tunnel(host, port, client_sock, policy, task_sup)

      {:error, :not_connect} ->
        write_response(client_sock, "HTTP/1.1 405 Method Not Allowed\r\n\r\n")
        safe_close(client_sock)

      {:error, :malformed} ->
        write_response(client_sock, "HTTP/1.1 400 Bad Request\r\n\r\n")
        safe_close(client_sock)
    end
  end

  # Pull `Proxy-Authorization: Basic <base64(token:)>` out of the
  # request head if present. Returns `{:ok, entry}` with the
  # ProxyTokens resolve result, or `:anonymous` when no valid token
  # accompanies the CONNECT. Invalid tokens (present but expired or
  # unknown) are treated as `:anonymous` so the proxy's company-
  # scoped allowlist is still the ultimate gate — the token
  # attaches AUDIT CONTEXT, not AUTHORISATION.
  defp resolve_caller_from_headers([]), do: :anonymous

  defp resolve_caller_from_headers([headers_blob]) do
    header_line = find_header(headers_blob, "proxy-authorization")

    with line when is_binary(line) <- header_line,
         {:ok, basic_payload} <- parse_basic_auth(line),
         {:ok, token} <- extract_token_from_basic(basic_payload),
         {:ok, ctx} <- Glorbo.Network.ProxyTokens.resolve(token) do
      {:ok, ctx}
    else
      _ -> :anonymous
    end
  end

  defp find_header(blob, want) do
    blob
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == want do
            String.trim(value)
          else
            nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_basic_auth("Basic " <> encoded), do: {:ok, String.trim(encoded)}
  defp parse_basic_auth("basic " <> encoded), do: {:ok, String.trim(encoded)}
  defp parse_basic_auth(_), do: :error

  # Our tokens are already url-safe base64, but the standard Basic
  # Auth scheme wraps `user:pass` in base64. Agents that put the
  # token in userinfo with no password produce `Basic
  # base64(<token>:)`. Accept both forms.
  defp extract_token_from_basic(encoded) do
    case Base.decode64(encoded) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [token, _pass] when token != "" -> {:ok, token}
          [token] when token != "" -> {:ok, token}
          _ -> :error
        end

      :error ->
        # Token passed raw, not Basic-wrapped. Accept as-is.
        {:ok, encoded}
    end
  end

  # "CONNECT host:port HTTP/1.1"
  defp parse_connect_line("CONNECT " <> rest) do
    with [host_port, _http_version] <- String.split(rest, " ", parts: 2),
         [host, port_str] when host != "" <- String.split(host_port, ":", parts: 2),
         {port, ""} when port > 0 and port <= 65_535 <- Integer.parse(port_str),
         :ok <- validate_connect_host(host) do
      {:ok, host |> String.trim_trailing(".") |> String.downcase(), port}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse_connect_line(_), do: {:error, :not_connect}

  # Reject non-ASCII hosts up front. IDN homographs
  # (e.g. `аpi.anthropic.com` with a Cyrillic `а`) would otherwise pass
  # allowlist lookup against the ASCII-punycoded form if naïvely
  # downcased. Full IDN/Punycode support needs an `:idna` library and
  # careful normalisation; until we take that on, only accept plain
  # ASCII DNS names so the allowlist's equality check is meaningful.
  # Also strip FQDN trailing dots (`example.com.` == `example.com`)
  # so operators can't be bypassed by appending a `.`.
  defp validate_connect_host(host) do
    cond do
      not String.printable?(host, :infinity) -> {:error, :non_printable_host}
      not ascii_only?(host) -> {:error, :non_ascii_host}
      true -> :ok
    end
  end

  defp ascii_only?(binary) when is_binary(binary) do
    Enum.all?(:binary.bin_to_list(binary), &(&1 < 128))
  end

  defp evaluate_and_tunnel(host, port, client_sock, policy, task_sup) do
    cond do
      port != 443 ->
        Logger.info("[network.proxy] reject non-443 CONNECT host=#{host} port=#{port}")
        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      MapSet.member?(policy.allowlist, host) ->
        Logger.debug(
          "[network.proxy] allowlist-allow host=#{host} #{format_caller(policy[:caller_ctx])}"
        )

        open_and_splice(host, port, client_sock, task_sup)

      true ->
        classify_unlisted(host, port, client_sock, policy, task_sup)
    end
  end

  # GEP-23 Phase 5: render the per-dispatch caller for logging +
  # audit. Returns a short tag the log pipeline can include.
  defp format_caller(:anonymous), do: "caller=anonymous"
  defp format_caller(nil), do: ""

  defp format_caller({:ok, %{company: co, agent: ag, dispatch_id: id}}) do
    "caller=#{co}/#{ag} dispatch=#{id}"
  end

  defp format_caller(_), do: "caller=unknown"

  # Host is not in the company allowlist. Without a classifier this
  # is the historic behaviour — 403 Forbidden. With a classifier
  # (GEP-23 Phase 2+), hand the decision off; allow opens the
  # tunnel, deny/unknown both 403 for now. Phase 3 makes :unknown
  # surface a director approval sentinel instead of an outright 403.
  #
  # GEP-23 §Proxy daemon — hit `Glorbo.Network.History` first so a
  # classifier-verdict cache entry short-circuits the (potentially
  # LLM-backed) classifier. `history_fun` is the per-company cache
  # handle (nil opts out of caching entirely; tests pass nil).
  defp classify_unlisted(host, port, client_sock, policy, task_sup) do
    case history_hit(policy, host, port) do
      {:hit, :allow, reason} ->
        Logger.debug("[network.proxy] cache-allow host=#{host} reason=#{reason}")
        open_and_splice(host, port, client_sock, task_sup)

      {:hit, :deny, reason} ->
        Logger.debug("[network.proxy] cache-deny host=#{host} reason=#{reason}")
        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      :miss ->
        run_classifier(host, port, client_sock, policy, task_sup)
    end
  end

  defp run_classifier(host, port, client_sock, policy, task_sup) do
    case policy.classifier_fun do
      nil ->
        Logger.info(
          "[network.proxy] reject host-not-in-allowlist host=#{host} #{format_caller(policy[:caller_ctx])}"
        )

        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      fun when is_function(fun, 2) ->
        case safe_classify(fun, host, port) do
          {:allow, reason} ->
            Logger.info("[network.proxy] smart-allow host=#{host} reason=#{reason}")
            history_put(policy, host, port, :allow, reason)
            open_and_splice(host, port, client_sock, task_sup)

          {:deny, reason} ->
            Logger.info("[network.proxy] smart-deny host=#{host} reason=#{reason}")
            history_put(policy, host, port, :deny, reason)
            write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
            safe_close(client_sock)

          {:unknown, reason} ->
            Logger.info(
              "[network.proxy] smart-unknown host=#{host} reason=#{reason} (treated as deny pending director sentinel)"
            )

            # Don't cache :unknown — Director approval is the
            # resolution path, and we want every request to surface
            # that sentinel trigger. Phase 3's sentinel handling
            # will flip the entry when the Director approves/denies.
            write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
            safe_close(client_sock)
        end
    end
  end

  defp history_hit(%{history_fun: fun}, host, port) when is_function(fun, 2),
    do: fun.(host, port)

  defp history_hit(_policy, _host, _port), do: :miss

  defp history_put(%{history_put_fun: fun}, host, port, verdict, reason)
       when is_function(fun, 4),
       do: fun.(host, port, verdict, reason)

  defp history_put(_policy, _host, _port, _verdict, _reason), do: :ok

  # Treat any classifier crash OR malformed return as `:unknown` —
  # fail-safe so a broken classifier never results in silently allowing
  # unknown hosts, AND never crashes `classify_unlisted/5` with a
  # CaseClauseError (threatmodel T14).
  defp safe_classify(fun, host, port) do
    fun.(host, port) |> normalise_classifier_result()
  rescue
    e ->
      Logger.warning("[network.proxy] classifier raised: #{inspect(e)} — treating as :unknown")

      {:unknown, :classifier_raised}
  catch
    :exit, reason ->
      Logger.warning(
        "[network.proxy] classifier exited: #{inspect(reason)} — treating as :unknown"
      )

      {:unknown, :classifier_exit}
  end

  defp normalise_classifier_result({verdict, _reason} = ok)
       when verdict in [:allow, :deny, :unknown],
       do: ok

  defp normalise_classifier_result(other) do
    Logger.warning(
      "[network.proxy] classifier returned malformed value: #{inspect(other)} — treating as :unknown"
    )

    {:unknown, :classifier_malformed}
  end

  # Threatmodel wave 25: DNS rebinding defense. The classifier
  # allowlists by HOSTNAME, but `:gen_tcp.connect/4` resolves the
  # name at connect-time. An attacker controlling DNS for an
  # allowlisted host can return loopback / RFC1918 / link-local /
  # ULA / unspecified addresses and reach host-internal services.
  # Resolve A/AAAA ourselves first, refuse private destinations,
  # and connect to the vetted IP literal.
  defp open_and_splice(host, port, client_sock, task_sup) do
    case resolve_public_ip(host) do
      {:ok, ip_charlist} ->
        do_connect(ip_charlist, host, port, client_sock, task_sup)

      {:error, :private_address} ->
        Logger.info(
          "[network.proxy] DNS-rebind block host=#{host} resolved to private/loopback/link-local"
        )

        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      {:error, reason} ->
        Logger.info("[network.proxy] DNS resolve failed host=#{host}: #{inspect(reason)}")
        write_response(client_sock, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
        safe_close(client_sock)
    end
  end

  defp do_connect(ip_charlist, host, port, client_sock, task_sup) do
    case :gen_tcp.connect(
           ip_charlist,
           port,
           [:binary, packet: :raw, active: false],
           5_000
         ) do
      {:ok, upstream_sock} ->
        write_response(client_sock, "HTTP/1.1 200 Connection Established\r\n\r\n")
        relay_bytes(client_sock, upstream_sock, task_sup)

      {:error, reason} ->
        Logger.info("[network.proxy] upstream connect failed host=#{host}: #{inspect(reason)}")
        write_response(client_sock, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
        safe_close(client_sock)
    end
  end

  # A/AAAA lookup; rejects loopback / RFC1918 / link-local / ULA /
  # unspecified addresses. Returns the first public IP as charlist.
  defp resolve_public_ip(host) do
    host_charlist = String.to_charlist(host)

    case :inet.getaddrs(host_charlist, :inet, 5_000) do
      {:ok, [_ | _] = addrs} ->
        case Enum.find(addrs, &public_ip?/1) do
          nil -> {:error, :private_address}
          ip -> {:ok, :inet.ntoa(ip)}
        end

      _ ->
        case :inet.getaddrs(host_charlist, :inet6, 5_000) do
          {:ok, [_ | _] = addrs} ->
            case Enum.find(addrs, &public_ip?/1) do
              nil -> {:error, :private_address}
              ip -> {:ok, :inet.ntoa(ip)}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Reject any IP we'd consider "internal":
  #   * 0.0.0.0 / ::                  unspecified
  #   * 127.0.0.0/8 / ::1             loopback
  #   * 10/8, 172.16/12, 192.168/16   RFC1918
  #   * 169.254/16 / fe80::/10        link-local
  #   * fc00::/7                      ULA (unique local)
  #   * 100.64.0.0/10                 CGNAT (technically private)
  defp public_ip?({0, 0, 0, 0}), do: false
  defp public_ip?({127, _, _, _}), do: false
  defp public_ip?({10, _, _, _}), do: false
  defp public_ip?({172, b, _, _}) when b in 16..31, do: false
  defp public_ip?({192, 168, _, _}), do: false
  defp public_ip?({169, 254, _, _}), do: false
  defp public_ip?({100, b, _, _}) when b in 64..127, do: false
  defp public_ip?({_, _, _, _}), do: true
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: false
  defp public_ip?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: false
  defp public_ip?({_, _, _, _, _, _, _, _}), do: true
  defp public_ip?(_), do: false

  # Bidirectional byte relay via two supervised tasks. Using async_nolink
  # (TODO.md Critical #3) so a pipe-task crash doesn't :EXIT-kill its
  # parent handler and leak the remaining socket. On timeout or either
  # side completing, we Task.shutdown both — :brutal_kill guarantees the
  # :gen_tcp owners are gone before we close, preventing leaked FDs
  # under concurrent-recv races.
  defp relay_bytes(client_sock, upstream_sock, task_sup) do
    caller = self()

    t1 =
      Task.Supervisor.async_nolink(task_sup, fn ->
        pipe(client_sock, upstream_sock)
        send(caller, {:pipe_done, :cu})
      end)

    t2 =
      Task.Supervisor.async_nolink(task_sup, fn ->
        pipe(upstream_sock, client_sock)
        send(caller, {:pipe_done, :uc})
      end)

    receive do
      {:pipe_done, _} -> :ok
    after
      @tunnel_idle_timeout_ms -> :ok
    end

    _ = Task.shutdown(t1, :brutal_kill)
    _ = Task.shutdown(t2, :brutal_kill)

    safe_close(client_sock)
    safe_close(upstream_sock)
  end

  defp pipe(src, dst) do
    case :gen_tcp.recv(src, 0, 60_000) do
      {:ok, data} ->
        case :gen_tcp.send(dst, data) do
          :ok -> pipe(src, dst)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp write_response(sock, payload), do: _ = :gen_tcp.send(sock, payload)
  defp safe_close(sock), do: _ = :gen_tcp.close(sock)

  # History-cache wiring: if a server name/pid was passed via the
  # `:history_server` opt, wrap the two cache ops; otherwise return
  # nils that `history_hit/3` + `history_put/5` no-op on.
  defp build_history_fun(opts) do
    case Keyword.get(opts, :history_server) do
      nil ->
        nil

      server ->
        fn host, port ->
          try do
            Glorbo.Network.History.fetch(server, host, port)
          rescue
            _ -> :miss
          catch
            _, _ -> :miss
          end
        end
    end
  end

  defp build_history_put_fun(opts) do
    case Keyword.get(opts, :history_server) do
      nil ->
        nil

      server ->
        fn host, port, verdict, reason ->
          try do
            Glorbo.Network.History.put(server, host, port, verdict, reason)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Allowlist default
  # ---------------------------------------------------------------------------

  @doc """
  Base proxy allowlist derived from `config :glorbo,
  :network_policy`. Public so `Glorbo.Company.Supervisor` can
  compose it with per-agent `network_allow:` extensions before
  passing the union to the Proxy init.
  """
  @spec default_allowlist() :: [String.t()]
  def default_allowlist do
    config = Application.get_env(:glorbo, :network_policy, %{})

    base =
      case Map.get(config, :proxy_base_allowlist) do
        %{} = by_provider -> by_provider |> Map.values() |> List.flatten()
        _ -> []
      end

    Enum.uniq(base)
  end
end
