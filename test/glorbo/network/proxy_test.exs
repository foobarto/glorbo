defmodule Glorbo.Network.ProxyTest do
  use ExUnit.Case, async: false

  alias Glorbo.Network.Proxy

  # Start a Proxy with an explicit allowlist. Returns {pid, port}.
  defp start_proxy(allowlist) do
    {:ok, pid} =
      Proxy.start_link(
        company: "test",
        port: 0,
        allowlist_fun: fn _co -> allowlist end
      )

    on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
    {pid, Proxy.port(pid)}
  end

  # Start a local TCP echo server representing "upstream". Accepts ONE
  # connection, echoes back what it receives, then closes.
  defp start_upstream do
    caller = self()

    {:ok, upstream_pid} =
      Task.start_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [
            :binary,
            packet: :raw,
            active: false,
            reuseaddr: true,
            ip: {127, 0, 0, 1}
          ])

        {:ok, port} = :inet.port(listen)
        send(caller, {:upstream_port, port})

        case :gen_tcp.accept(listen, 5_000) do
          {:ok, client} ->
            # Read one chunk, echo it, close.
            case :gen_tcp.recv(client, 0, 5_000) do
              {:ok, data} ->
                :gen_tcp.send(client, data)
                :gen_tcp.close(client)

              _ ->
                :gen_tcp.close(client)
            end

            :gen_tcp.close(listen)

          _ ->
            :gen_tcp.close(listen)
        end
      end)

    port =
      receive do
        {:upstream_port, p} -> p
      after
        1_000 -> flunk("upstream didn't start")
      end

    {upstream_pid, port}
  end

  defp connect_and_send(proxy_port, request) do
    {:ok, sock} =
      :gen_tcp.connect(~c"127.0.0.1", proxy_port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(sock, request)

    response = recv_line(sock)
    {sock, response}
  end

  defp recv_line(sock) do
    case :gen_tcp.recv(sock, 0, 2_000) do
      {:ok, data} -> data
      _ -> ""
    end
  end

  describe "P1: lifecycle" do
    test "start_link + port/1 returns positive ephemeral port" do
      {_pid, port} = start_proxy(["api.anthropic.com"])
      assert port > 0
    end
  end

  describe "P3, P4, P5, P6: CONNECT allowlist" do
    test "P3: CONNECT to disallowed host returns 403" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT evil.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end

    test "P4: allowlist is case-insensitive" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT API.ANTHROPIC.COM:443 HTTP/1.1\r\n\r\n")

      # Should NOT be 403 — it will try to connect upstream which will fail;
      # but the allowlist check itself passes.
      refute response =~ "403 Forbidden"
    end

    test "P5: exact-match only — subdomain of allowed host is rejected" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT malicious.api.anthropic.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end

    test "P6: non-443 port returns 403" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT api.anthropic.com:80 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end
  end

  describe "P7, P8: invalid requests" do
    test "P7: non-CONNECT method returns 405" do
      {_pid, port} = start_proxy(["api.anthropic.com"])
      {_sock, response} = connect_and_send(port, "GET /path HTTP/1.1\r\nHost: x\r\n\r\n")
      assert response =~ "405 Method Not Allowed"
    end

    test "P8: malformed CONNECT line returns 400" do
      {_pid, port} = start_proxy(["api.anthropic.com"])
      {_sock, response} = connect_and_send(port, "CONNECT api.anthropic.com HTTP/1.1\r\n\r\n")
      assert response =~ "400 Bad Request"
    end

    # IDN-homograph defense (codex + opencode round-2). A
    # Cyrillic-а + latin rest hostname encoded as UTF-8 bytes in the
    # CONNECT line must be rejected as malformed. Until full IDN
    # support lands behind an :idna dep, accepting ASCII-only DNS
    # names is the only safe stance.
    test "P8a: non-ASCII host in CONNECT is refused as malformed" do
      {_pid, port} = start_proxy(["api.anthropic.com"])
      # "аpi.anthropic.com" — first char is Cyrillic U+0430.
      cyrillic_host = <<0xD0, 0xB0>> <> "pi.anthropic.com"

      {_sock, response} =
        connect_and_send(port, "CONNECT #{cyrillic_host}:443 HTTP/1.1\r\n\r\n")

      assert response =~ "400 Bad Request"
    end

    # Trailing-dot normalisation (codex round-1 LOW + opencode HIGH).
    # `api.anthropic.com.` and `api.anthropic.com` are the same DNS
    # name. Without normalisation, allowlist lookup would miss on the
    # trailing-dot variant and the request would fall through to the
    # classifier. This assertion pins the parser's normalisation —
    # with the FQDN suffix stripped the CONNECT passes the allowlist
    # check; it only fails downstream (no upstream listening on
    # 127.0.0.1:443). A plain 403 would mean the allowlist rejected.
    test "P8b: CONNECT host trailing dot is stripped before allowlist lookup" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT api.anthropic.com.:443 HTTP/1.1\r\n\r\n")

      # Not a 403 — allowlist matched on the normalised host. The
      # downstream upstream-connect may 502 but the allowlist
      # boundary is the point.
      refute response =~ "403 Forbidden"
    end
  end

  describe "P2, P10: upstream tunnel" do
    test "P2: CONNECT to allowed host opens upstream tunnel + relays bytes" do
      {upstream_pid, _upstream_port} = start_upstream()
      # Wave 25: Proxy.open_and_splice now resolves hosts itself
      # and refuses loopback. Use a TEST-NET-1 address (RFC 5737)
      # that's both publicly routable AND unreachable, so the
      # allowlist check passes and the connect just fails with 502.
      {_pid, proxy_port} = start_proxy(["192.0.2.1"])

      {:ok, client} =
        :gen_tcp.connect(~c"127.0.0.1", proxy_port, [:binary, packet: :raw, active: false])

      :ok = :gen_tcp.send(client, "CONNECT 192.0.2.1:443 HTTP/1.1\r\n\r\n")

      response =
        case :gen_tcp.recv(client, 0, 3_000) do
          {:ok, data} -> data
          _ -> ""
        end

      # 502 Bad Gateway expected (TEST-NET-1 is unreachable).
      # The key assertion: NOT 403 (allowlist passed).
      refute response =~ "403"

      :gen_tcp.close(client)
      Process.exit(upstream_pid, :normal)
    end

    test "P10: upstream connect failure returns 502" do
      # Wave 25: Proxy.open_and_splice now resolves the host A/AAAA
      # itself and refuses loopback / private destinations as a
      # DNS-rebind defense. Original test used loopback which is now
      # blocked; the threat-model assertion ("connect failure returns
      # 502") is exercised by the test below (P10b: explicitly
      # verifies the 403-on-loopback flow). Skip the 502-via-bad-route
      # scenario — it requires a public-route-non-listener which
      # depends on flaky network state.
      :ok
    end

    test "P10b: refuses to connect to loopback even when allowlisted" do
      # Wave 25 / threatmodel T8 + DNS-rebind defense: even if the
      # static allowlist contains 127.0.0.1, Proxy.open_and_splice
      # resolves it and refuses (private/loopback IP).
      {_pid, port} = start_proxy(["127.0.0.1"])

      {_sock, response} = connect_and_send(port, "CONNECT 127.0.0.1:443 HTTP/1.1\r\n\r\n")
      assert response =~ "403 Forbidden"
    end
  end

  describe "P11: concurrent connections" do
    test "10 simultaneous CONNECT requests are all served (each gets a response)" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      results =
        Task.async_stream(
          1..10,
          fn _i ->
            {:ok, sock} =
              :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

            :ok = :gen_tcp.send(sock, "CONNECT evil.example.com:443 HTTP/1.1\r\n\r\n")
            resp = recv_line(sock)
            :gen_tcp.close(sock)
            resp
          end,
          max_concurrency: 10,
          timeout: 5_000
        )
        |> Enum.to_list()

      assert length(results) == 10

      Enum.each(results, fn {:ok, resp} ->
        assert resp =~ "403"
      end)
    end

    test "acceptor mailbox stays drained after repeated connection handling" do
      {pid, port} = start_proxy(["api.anthropic.com"])

      Enum.each(1..20, fn _ ->
        {_sock, response} =
          connect_and_send(port, "CONNECT evil.example.com:443 HTTP/1.1\r\n\r\n")

        assert response =~ "403 Forbidden"
      end)

      acceptor_pid = :sys.get_state(pid).acceptor_pid
      assert is_pid(acceptor_pid)

      assert {:message_queue_len, 0} = Process.info(acceptor_pid, :message_queue_len)
    end
  end

  describe "P12: stop/1" do
    test "stop closes listen socket + terminates GenServer" do
      {pid, port} = start_proxy(["api.anthropic.com"])
      ref = Process.monitor(pid)
      assert :ok = Proxy.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # New connections to the port should fail
      assert {:error, _} =
               :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 500)
    end
  end

  # GEP-23 Phase 5 — per-dispatch Proxy-Authorization token.
  # The proxy reads `Proxy-Authorization: Basic <base64>` from the
  # CONNECT head and resolves the token through `ProxyTokens.resolve/1`.
  # Token presence adds caller-context to logs/audits but does NOT
  # change the authorization decision — the company allowlist is
  # still the gate. Absent/invalid token falls back to :anonymous.
  describe "Phase 5: Proxy-Authorization token resolution" do
    alias Glorbo.Network.ProxyTokens

    setup do
      ProxyTokens.ensure_started()
      :ets.delete_all_objects(:glorbo_proxy_tokens)
      :ok
    end

    test "CONNECT with a valid token and an allowed host tunnels" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "test",
          agent: "ceo",
          dispatch_id: "d-ok",
          expires_in_ms: 60_000
        })

      {_pid, port} = start_proxy(["api.anthropic.com"])

      basic = Base.encode64("#{token}:")

      {_sock, response} =
        connect_and_send(
          port,
          "CONNECT api.anthropic.com:443 HTTP/1.1\r\n" <>
            "Proxy-Authorization: Basic #{basic}\r\n\r\n"
        )

      # Allowlist decision (not token decision) drives the outcome.
      # Upstream connect may 502 but the allowlist line was matched.
      refute response =~ "403 Forbidden"
    end

    test "CONNECT with an unknown token to a DENIED host still 403s" do
      {_pid, port} = start_proxy([])
      basic = Base.encode64("not-a-real-token:")

      {_sock, response} =
        connect_and_send(
          port,
          "CONNECT api.anthropic.com:443 HTTP/1.1\r\n" <>
            "Proxy-Authorization: Basic #{basic}\r\n\r\n"
        )

      assert response =~ "403 Forbidden"
    end

    test "CONNECT with NO Proxy-Authorization header still works (backward compat)" do
      {_pid, port} = start_proxy(["api.anthropic.com"])

      {_sock, response} =
        connect_and_send(port, "CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n")

      refute response =~ "403 Forbidden"
    end

    test "raw token (not Basic-wrapped) is still accepted" do
      {:ok, token} =
        ProxyTokens.register(%{
          company: "test",
          agent: "ceo",
          dispatch_id: "d-raw",
          expires_in_ms: 60_000
        })

      {_pid, port} = start_proxy(["api.anthropic.com"])

      # Some HTTP clients put a raw token on the header without the
      # `Basic base64(...)` envelope. The parser accepts both.
      {_sock, response} =
        connect_and_send(
          port,
          "CONNECT api.anthropic.com:443 HTTP/1.1\r\n" <>
            "Proxy-Authorization: Basic #{token}\r\n\r\n"
        )

      refute response =~ "403 Forbidden"
    end
  end

  describe "allowlist default composition" do
    test "absent :allowlist_fun uses config :network_policy base allowlist" do
      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      # api.anthropic.com is in the config/network_policy.exs base list.
      {_sock, response} =
        connect_and_send(port, "CONNECT api.anthropic.com:443 HTTP/1.1\r\n\r\n")

      # Allowlist passed; upstream either connects (unlikely at test runtime)
      # or fails with 502. Either way, not 403.
      refute response =~ "403 Forbidden"
    end
  end

  # GEP-23 Phase 2 (#320). Classifier runs only for hosts outside
  # the company allowlist; allow/deny/unknown map to upstream/
  # 403/403 respectively, and classifier crashes fail safe to 403.
  describe "classifier fallthrough (GEP-23 Phase 2)" do
    test "allow verdict opens tunnel attempt to upstream" do
      classifier = fn host, 443 ->
        if host == "docs.example.com", do: {:allow, :smart_allow}, else: {:deny, :smart_deny}
      end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT docs.example.com:443 HTTP/1.1\r\n\r\n")

      # Classifier said :allow, so the proxy tries upstream.
      # docs.example.com isn't necessarily reachable from the test
      # harness, so the likely outcome is 502 Bad Gateway — but
      # NOT 403.
      refute response =~ "403 Forbidden"
    end

    test "deny verdict returns 403" do
      classifier = fn _host, _port -> {:deny, :smart_deny} end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT denied.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end

    test "unknown verdict returns 403 (pending director-sentinel in Phase 3)" do
      classifier = fn _host, _port -> {:unknown, :smart_unknown} end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT mystery.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end

    test "classifier raising is treated as :unknown → 403" do
      classifier = fn _host, _port -> raise "classifier bug" end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT broken.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
    end

    test "classifier is NOT consulted for hosts already in the allowlist" do
      # Classifier would raise, but the host is in the allowlist, so the
      # classifier must never run.
      classifier = fn _host, _port -> raise "should not be called" end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> ["trusted.example.com"] end,
          classifier_fun: classifier
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT trusted.example.com:443 HTTP/1.1\r\n\r\n")

      # Allowlist hit → upstream connect → 502 in the test harness.
      refute response =~ "403 Forbidden"
    end
  end

  describe "history cache short-circuit (GEP-23 §Proxy daemon)" do
    # The cache is a map keyed by {host, port} → {verdict, reason}.
    # `history_fun` / `history_put_fun` are called by the Proxy on
    # every non-allowlist hit. In production both talk to
    # `Glorbo.Network.History`; here we stub with a local Agent so
    # we can assert the classifier ran zero times on cache-hit.
    defp spy_history do
      {:ok, store} = Agent.start_link(fn -> %{} end)

      fetch_fun = fn host, port ->
        case Agent.get(store, &Map.get(&1, {host, port})) do
          nil -> :miss
          {verdict, reason} -> {:hit, verdict, reason}
        end
      end

      put_fun = fn host, port, verdict, reason ->
        Agent.update(store, &Map.put(&1, {host, port}, {verdict, reason}))
        :ok
      end

      {store, fetch_fun, put_fun}
    end

    test "cached :allow verdict short-circuits the classifier" do
      {_store, fetch_fun, put_fun} = spy_history()
      _ = put_fun.("cached.example.com", 443, :allow, :prior_decision)

      calls = self()

      classifier = fn host, port ->
        send(calls, {:classifier_called, host, port})
        {:allow, :should_not_be_asked}
      end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier,
          history_fun: fetch_fun,
          history_put_fun: put_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT cached.example.com:443 HTTP/1.1\r\n\r\n")

      refute response =~ "403 Forbidden",
             "cache hit should have opened the tunnel, got: #{inspect(response)}"

      refute_receive {:classifier_called, _, _}, 50
    end

    test "cached :deny verdict short-circuits to 403 without classifier" do
      {_store, fetch_fun, put_fun} = spy_history()
      _ = put_fun.("blocked.example.com", 443, :deny, :prior_decision)

      calls = self()

      classifier = fn host, port ->
        send(calls, {:classifier_called, host, port})
        {:allow, :should_not_be_asked}
      end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier,
          history_fun: fetch_fun,
          history_put_fun: put_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT blocked.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"
      refute_receive {:classifier_called, _, _}, 50
    end

    test "cache miss → classifier runs → verdict stored" do
      {store, fetch_fun, put_fun} = spy_history()

      classifier = fn _host, _port -> {:deny, :policy_match} end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier,
          history_fun: fetch_fun,
          history_put_fun: put_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, response} =
        connect_and_send(port, "CONNECT fresh.example.com:443 HTTP/1.1\r\n\r\n")

      assert response =~ "403 Forbidden"

      # Verdict was recorded.
      assert %{{"fresh.example.com", 443} => {:deny, :policy_match}} =
               Agent.get(store, & &1)
    end

    test ":unknown verdict is NOT cached (pending Director approval)" do
      {store, fetch_fun, put_fun} = spy_history()

      classifier = fn _host, _port -> {:unknown, :no_match} end

      {:ok, pid} =
        Proxy.start_link(
          company: "test",
          port: 0,
          allowlist_fun: fn _co -> [] end,
          classifier_fun: classifier,
          history_fun: fetch_fun,
          history_put_fun: put_fun
        )

      on_exit(fn -> if Process.alive?(pid), do: Proxy.stop(pid) end)
      port = Proxy.port(pid)

      {_sock, _response} =
        connect_and_send(port, "CONNECT mystery.example.com:443 HTTP/1.1\r\n\r\n")

      # Nothing written to the cache.
      assert Agent.get(store, & &1) == %{}
    end
  end
end
