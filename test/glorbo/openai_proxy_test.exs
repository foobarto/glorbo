defmodule Glorbo.OpenAIProxyTest do
  @moduledoc """
  GEP-0055 slice 4a: the in-process inference proxy listener — path
  routing, token auth (incl. the company cross-check and the
  provider `via_proxy` check), request parsing (headers + body in
  one TCP segment), and the real upstream call against a stub
  upstream.

  Mirrors `Glorbo.Network.ProxyTest` in shape and helpers so
  the GEP-23 / GEP-0055 proxy tests read the same way.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Network.ProxyTokens
  alias Glorbo.OpenAIProxy
  alias Glorbo.OpenAIProxy.Shape.{OpenAI, Anthropic, Gemini}

  @company "test-co"
  @upstream_key_env "GLORBO_TEST_UPSTREAM_KEY"

  # ---------------------------------------------------------------------------
  # Shape behaviour routing
  # ---------------------------------------------------------------------------

  describe "Glorbo.OpenAIProxy.adapter_for_path/1" do
    test "routes /v1/chat/completions to OpenAI" do
      assert OpenAIProxy.adapter_for_path("/v1/chat/completions") == OpenAI
    end

    test "routes /v1/models to OpenAI" do
      assert OpenAIProxy.adapter_for_path("/v1/models") == OpenAI
    end

    test "routes /v1/messages to Anthropic" do
      assert OpenAIProxy.adapter_for_path("/v1/messages") == Anthropic
    end

    test "routes /v1beta/models/<model>:generateContent to Gemini" do
      assert OpenAIProxy.adapter_for_path("/v1beta/models/gemini-1.5-pro:generateContent") ==
               Gemini
    end

    test "routes /v1beta/models/<model>:streamGenerateContent to Gemini" do
      assert OpenAIProxy.adapter_for_path("/v1beta/models/gemini-1.5-pro:streamGenerateContent") ==
               Gemini
    end

    test "returns nil for paths no adapter owns" do
      assert OpenAIProxy.adapter_for_path("/") == nil
      assert OpenAIProxy.adapter_for_path("/v1/unknown") == nil
      assert OpenAIProxy.adapter_for_path("/healthz") == nil
    end

    test "returns nil for non-binary input" do
      assert OpenAIProxy.adapter_for_path(nil) == nil
      assert OpenAIProxy.adapter_for_path(123) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Shape behaviour callbacks
  # ---------------------------------------------------------------------------

  describe "OpenAI shape" do
    test "extract_usage on non-stream with usage block returns GEP-32 D12 shape" do
      body = %{
        "usage" => %{"prompt_tokens" => 13, "completion_tokens" => 7, "total_tokens" => 20}
      }

      assert {:ok, usage} = OpenAI.extract_usage({:non_stream, body})
      assert usage.tracked == true
      assert usage.prompt_tokens == 13
      assert usage.completion_tokens == 7
    end

    test "extract_usage on non-stream without usage block returns :no_usage" do
      body = %{"choices" => []}
      assert OpenAI.extract_usage({:non_stream, body}) == :no_usage
    end

    test "attach_auth sets Bearer token" do
      headers = OpenAI.attach_auth(%{}, "sk-test")
      assert headers["authorization"] == "Bearer sk-test"
    end
  end

  describe "Anthropic shape" do
    test "extract_usage maps input_tokens/output_tokens to GEP-32 D12 shape" do
      body = %{"usage" => %{"input_tokens" => 13, "output_tokens" => 7}}
      assert {:ok, usage} = Anthropic.extract_usage({:non_stream, body})
      assert usage.tracked == true
      assert usage.prompt_tokens == 13
      assert usage.completion_tokens == 7
    end

    test "attach_auth sets x-api-key + anthropic-version" do
      headers = Anthropic.attach_auth(%{}, "sk-ant-test")
      assert headers["x-api-key"] == "sk-ant-test"
      assert headers["anthropic-version"] == "2023-06-01"
    end
  end

  describe "Gemini shape" do
    test "extract_usage maps promptTokenCount/candidatesTokenCount" do
      body = %{
        "usageMetadata" => %{
          "promptTokenCount" => 13,
          "candidatesTokenCount" => 7,
          "totalTokenCount" => 20
        }
      }

      assert {:ok, usage} = Gemini.extract_usage({:non_stream, body})
      assert usage.tracked == true
      assert usage.prompt_tokens == 13
      assert usage.completion_tokens == 7
    end

    test "attach_auth is a no-op (Gemini auth is ?key= query param; slice 9)" do
      assert Gemini.attach_auth(%{}, "goog-key") == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Listener — auth, parsing, routing, upstream
  # ---------------------------------------------------------------------------

  describe "translate_request upstream-header allowlist (PR #47 review)" do
    # Inbound headers carry the proxy loopback Host, content-length, and
    # the per-dispatch proxy bearer token (Authorization / X-Glorbo-Token).
    # None may reach the real provider — every shape must return an EMPTY
    # upstream-header map and leave auth/host/content-type to attach_auth/2
    # + Req. Anthropic (adds x-api-key, never overwrites authorization) and
    # Gemini (attach_auth no-op) would otherwise leak the proxy token.
    @dirty_headers %{
      "host" => "127.0.0.1:65000",
      "authorization" => "Bearer glorbo-proxy-token-secret",
      "content-length" => "123",
      "x-glorbo-token" => "glorbo-proxy-token-secret"
    }

    test "OpenAI drops all inbound headers" do
      assert {:ok, %{"model" => "m"}, %{}} =
               OpenAI.translate_request(%{"model" => "m"}, @dirty_headers)
    end

    test "Anthropic drops all inbound headers" do
      assert {:ok, %{"model" => "m"}, %{}} =
               Anthropic.translate_request(%{"model" => "m"}, @dirty_headers)
    end

    test "Gemini drops all inbound headers" do
      assert {:ok, %{"model" => "m"}, %{}} =
               Gemini.translate_request(%{"model" => "m"}, @dirty_headers)
    end
  end

  describe "Glorbo.OpenAIProxy listener" do
    setup do
      # Unnamed on purpose: per-test listeners don't need a name,
      # and dynamic atom names trip the runtime-atom-creation check.
      {:ok, pid} = OpenAIProxy.start_link(company: @company, port: 0)

      on_exit(fn ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      %{proxy: pid, port: OpenAIProxy.port(pid)}
    end

    test "rejects a request without Authorization with 401", %{port: port} do
      response = request(port, "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
      assert response =~ "HTTP/1.1 401"
      assert response =~ "missing Authorization"
    end

    test "binds to 127.0.0.1 only — 127.0.0.2 on the same loopback /8 refuses", %{port: port} do
      assert {:ok, client} =
               :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

      :gen_tcp.close(client)

      # An INADDR_ANY bind would accept this too; the ifaddr-pinned
      # bind must refuse it.
      assert {:error, :econnrefused} =
               :gen_tcp.connect(~c"127.0.0.2", port, [:binary, packet: :raw, active: false])
    end

    test "parses headers+body arriving in one TCP segment (typical JSON POST)", %{port: port} do
      # Token without provider_alias (the GEP-23 CONNECT shape) —
      # passes token resolution, fails the provider lookup. Getting
      # the 401 `token has no provider alias` (and not a stall or a
      # body-read timeout) proves the head/body split handled body
      # bytes in the same segment as the headers.
      {:ok, token} = register_token(%{})

      response = request(port, post_chat_completions(port, token, ~s({"model":"gpt-test"})))
      assert response =~ "HTTP/1.1 401"
      assert response =~ "token has no provider alias"
    end

    test "accepts the token via X-Glorbo-Token as a Bearer alternative", %{port: port} do
      {:ok, token} = register_token(%{})
      body = ~s({"model":"gpt-test"})

      raw =
        "POST /v1/chat/completions HTTP/1.1\r\n" <>
          "Host: 127.0.0.1:#{port}\r\n" <>
          "X-Glorbo-Token: #{token}\r\n" <>
          "Content-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n" <>
          "Connection: close\r\n\r\n" <> body

      response = request(port, raw)
      # Same depth as the Bearer variant: token resolved, then the
      # nil provider_alias is rejected.
      assert response =~ "HTTP/1.1 401"
      assert response =~ "token has no provider alias"
    end

    test "rejects a token minted for another company with 401 (cross-company)", %{port: port} do
      {:ok, token} = register_token(%{company: "other-co"})

      response = request(port, post_chat_completions(port, token, ~s({})))
      assert response =~ "HTTP/1.1 401"
      assert response =~ "token company mismatch"
    end

    test "rejects a token whose provider is not via_proxy with 401", %{port: port} do
      with_registry_provider(stub_provider(auth: :bearer), fn provider ->
        {:ok, token} = register_token(%{provider_alias: provider.name})

        response = request(port, post_chat_completions(port, token, ~s({})))
        assert response =~ "HTTP/1.1 401"
        assert response =~ "provider is not routed via the proxy"
      end)
    end

    test "rejects an unknown provider alias with 401", %{port: port} do
      {:ok, token} = register_token(%{provider_alias: "no-such-provider-#{rand()}"})

      response = request(port, post_chat_completions(port, token, ~s({})))
      assert response =~ "HTTP/1.1 401"
      assert response =~ "provider not found in registry"
    end

    test "returns 404 (not a crash) for a path no adapter owns", %{port: port} do
      with_registry_provider(stub_provider(auth: :via_proxy), fn provider ->
        {:ok, token} = register_token(%{provider_alias: provider.name})
        body = ~s({})

        raw =
          "POST /v1/embeddings HTTP/1.1\r\n" <>
            "Host: 127.0.0.1:#{port}\r\n" <>
            "Authorization: Bearer #{token}\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "Connection: close\r\n\r\n" <> body

        response = request(port, raw)
        assert response =~ "HTTP/1.1 404"
        assert response =~ "no adapter handles path /v1/embeddings"
      end)
    end

    test "returns 400 on malformed Content-Length and keeps accepting on the same port", %{
      port: port
    } do
      raw =
        "POST /v1/chat/completions HTTP/1.1\r\n" <>
          "Host: x\r\nContent-Length: banana\r\nConnection: close\r\n\r\n"

      response = request(port, raw)
      assert response =~ "HTTP/1.1 400"
      assert response =~ "bad_content_length"

      # The acceptor must survive the bad request and the port must
      # not change (no listener re-bind).
      response2 = request(port, "GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
      assert response2 =~ "HTTP/1.1 401"
    end

    test "returns 400 on a garbage request line", %{port: port} do
      response = request(port, "NOT-AN-HTTP-REQUEST\r\n\r\n")
      assert response =~ "HTTP/1.1 400"
    end

    test "returns 405 for unsupported methods", %{port: port} do
      response = request(port, "DELETE /v1/models HTTP/1.1\r\nHost: x\r\n\r\n")
      assert response =~ "HTTP/1.1 405"
    end

    test "returns 400 for a body that is not valid JSON", %{port: port} do
      with_registry_provider(stub_provider(auth: :via_proxy), fn provider ->
        {:ok, token} = register_token(%{provider_alias: provider.name})
        response = request(port, post_chat_completions(port, token, "not-json{"))
        assert response =~ "HTTP/1.1 400"
        assert response =~ "not valid JSON"
      end)
    end

    test "returns 503 when the provider's api_key_env is unset on the host", %{port: port} do
      System.delete_env(@upstream_key_env)

      with_registry_provider(stub_provider(auth: :via_proxy), fn provider ->
        {:ok, token} = register_token(%{provider_alias: provider.name})
        response = request(port, post_chat_completions(port, token, ~s({})))
        assert response =~ "HTTP/1.1 503"
        assert response =~ "upstream_credentials_missing"
      end)
    end

    test "rejects an oversized complete header block (cap enforced on the terminated path), keeps accepting",
         %{port: port} do
      # PR #47 review (codex/Copilot): a full header block whose terminator
      # (\r\n\r\n) is already present but which exceeds the 16 KiB head cap
      # must be rejected, not parsed — the cap applied only on the
      # still-unterminated path before this fix.
      big = String.duplicate("x", 20_000)

      raw =
        "POST /v1/chat/completions HTTP/1.1\r\n" <>
          "Host: 127.0.0.1:#{port}\r\n" <>
          "X-Filler: #{big}\r\n" <>
          "Connection: close\r\n\r\n"

      assert request(port, raw, 5_000) =~ "HTTP/1.1 400"

      # The listener must remain usable on the same port afterwards.
      assert request(port, "GET /v1/models HTTP/1.1\r\nConnection: close\r\n\r\n", 5_000) =~
               "HTTP/1.1 401"
    end

    test "full round trip: POST reaches the stub upstream with the real key and path", %{
      port: port
    } do
      System.put_env(@upstream_key_env, "sk-upstream-real")
      on_exit(fn -> System.delete_env(@upstream_key_env) end)

      {:ok, upstream_port} =
        start_stub_upstream(%{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => "hi"}}],
          "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 2}
        })

      provider = stub_provider(auth: :via_proxy, endpoint: "http://127.0.0.1:#{upstream_port}")

      with_registry_provider(provider, fn provider ->
        {:ok, token} = register_token(%{provider_alias: provider.name})

        response =
          request(port, post_chat_completions(port, token, ~s({"model":"gpt-test"})), 15_000)

        assert response =~ "HTTP/1.1 200"
        assert response =~ ~s("content":"hi")

        assert_receive {:upstream_request, upstream_raw}, 5_000
        # The proxy attached the REAL upstream key (read host-side
        # from api_key_env) and preserved the request target.
        assert upstream_raw =~ "POST /v1/chat/completions"
        assert upstream_raw =~ "authorization: Bearer sk-upstream-real"
        assert upstream_raw =~ ~s("model":"gpt-test")

        # PR #47 review (codex/Copilot): inbound headers are NOT forwarded.
        # The proxy's loopback Host and the per-dispatch proxy token must
        # never reach the real provider — upstream Host is the provider's,
        # set by Req, and the only credential is the real upstream key.
        refute upstream_raw =~ "127.0.0.1:#{port}"
        refute upstream_raw =~ token
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp rand, do: System.unique_integer([:positive])

  defp register_token(overrides) do
    ProxyTokens.register(
      Map.merge(
        %{
          company: @company,
          agent: "tester",
          dispatch_id: "disp-#{rand()}",
          expires_in_ms: 60_000
        },
        overrides
      )
    )
  end

  defp stub_provider(overrides) do
    name = Keyword.get(overrides, :name, "gep55-test-prov-#{rand()}")

    struct!(
      %Glorbo.CLI.Registry.Provider{
        name: name,
        kind: :native,
        endpoint: Keyword.get(overrides, :endpoint, "http://127.0.0.1:9"),
        auth: Keyword.fetch!(overrides, :auth),
        api_key_env: @upstream_key_env,
        usage_parser: "native-v1",
        source: :builtin,
        source_file: "<test>"
      },
      Keyword.drop(overrides, [:auth, :endpoint, :name])
    )
  end

  # Injects a provider into the app-wide Registry (an Agent keyed by
  # name) for the duration of `fun`. async: false file, unique
  # per-test names — no cross-test interference.
  defp with_registry_provider(provider, fun) do
    Agent.update(Glorbo.CLI.Registry, &Map.put(&1, provider.name, provider))

    try do
      fun.(provider)
    after
      Agent.update(Glorbo.CLI.Registry, &Map.delete(&1, provider.name))
    end
  end

  defp post_chat_completions(port, token, body) do
    "POST /v1/chat/completions HTTP/1.1\r\n" <>
      "Host: 127.0.0.1:#{port}\r\n" <>
      "Authorization: Bearer #{token}\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <> body
  end

  # One request, one response, connection closed by the proxy.
  defp request(port, raw, timeout \\ 5_000) do
    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :raw, active: false])

    :ok = :gen_tcp.send(client, raw)
    response = recv_all(client, "", timeout)
    :gen_tcp.close(client)
    response
  end

  defp recv_all(sock, acc, timeout) do
    case :gen_tcp.recv(sock, 0, timeout) do
      {:ok, chunk} -> recv_all(sock, acc <> chunk, timeout)
      {:error, :closed} -> acc
      {:error, _} -> acc
    end
  end

  # Minimal one-shot HTTP upstream: accepts a single connection,
  # reads the full request (head + Content-Length body), reports it
  # to the test process, and answers 200 with `response_body` JSON.
  defp start_stub_upstream(response_body) do
    parent = self()

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ifaddr: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(lsock)

    spawn_link(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 10_000)
      raw = read_http_request(sock, "")
      send(parent, {:upstream_request, normalize_headers(raw)})

      json = Jason.encode!(response_body)

      :gen_tcp.send(
        sock,
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n" <> json
      )

      :gen_tcp.close(sock)
      :gen_tcp.close(lsock)
    end)

    {:ok, port}
  end

  defp read_http_request(sock, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {pos, len} ->
        body_sofar = byte_size(acc) - pos - len
        head = binary_part(acc, 0, pos)

        needed =
          case Regex.run(~r/content-length:\s*(\d+)/i, head) do
            [_, n] -> String.to_integer(n) - body_sofar
            _ -> 0
          end

        if needed > 0 do
          {:ok, more} = :gen_tcp.recv(sock, needed, 5_000)
          acc <> more
        else
          acc
        end

      :nomatch ->
        case :gen_tcp.recv(sock, 0, 5_000) do
          {:ok, chunk} -> read_http_request(sock, acc <> chunk)
          {:error, _} -> acc
        end
    end
  end

  # Lowercase header names so assertions don't depend on Req's
  # header casing.
  defp normalize_headers(raw) do
    case :binary.match(raw, "\r\n\r\n") do
      {pos, len} ->
        {head, rest} =
          {binary_part(raw, 0, pos), binary_part(raw, pos + len, byte_size(raw) - pos - len)}

        head
        |> String.split("\r\n")
        |> Enum.map_join("\r\n", fn line ->
          case String.split(line, ":", parts: 2) do
            [name, value] -> String.downcase(name) <> ":" <> value
            _ -> line
          end
        end)
        |> Kernel.<>("\r\n\r\n" <> rest)

      :nomatch ->
        raw
    end
  end
end
