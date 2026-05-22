defmodule Glorbo.CLI.Harness.HTTPTest do
  # async: false — the module starts/stops a named :httpc profile and
  # binds a TCP listener, so it must not race other HTTP tests.
  use ExUnit.Case, async: false

  alias Glorbo.CLI.Harness.HTTP

  # C-034: web_fetch buffered the full HTTP response despite the
  # downstream 64 KB cap, because :httpc with body_format: :binary
  # fully buffered the body before returning. The fix streams the
  # response and aborts once the per-request cap is exceeded. These
  # tests drive the *real* HTTP module against a local TCP server.

  setup do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)

    test_pid = self()

    server =
      spawn_link(fn -> accept_loop(listen, test_pid) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port}
  end

  test "caps a body larger than the default cap instead of buffering it all", %{port: port} do
    # 5 MiB body, well over the 1 MiB default cap.
    register_response(port, 200, "OK", String.duplicate("A", 5 * 1_048_576))

    assert {:ok, %{status: 200, body: body}} =
             HTTP.request(%{method: :get, url: url(port, "/big"), timeout_ms: 5_000})

    assert byte_size(body) == 1_048_576
  end

  test "honours a per-request max_response_bytes below the default", %{port: port} do
    register_response(port, 200, "OK", String.duplicate("B", 5 * 1_048_576))

    assert {:ok, %{status: 200, body: body}} =
             HTTP.request(%{
               method: :get,
               url: url(port, "/big"),
               timeout_ms: 5_000,
               max_response_bytes: 64_000
             })

    assert byte_size(body) == 64_000
  end

  test "returns small bodies in full", %{port: port} do
    register_response(port, 200, "OK", "small ok")

    assert {:ok, %{status: 200, body: "small ok"}} =
             HTTP.request(%{method: :get, url: url(port, "/small"), timeout_ms: 5_000})
  end

  test "passes through non-2xx status codes with their real status", %{port: port} do
    register_response(port, 404, "Not Found", "nope")

    assert {:ok, %{status: 404, body: "nope"}} =
             HTTP.request(%{method: :get, url: url(port, "/missing"), timeout_ms: 5_000})
  end

  # ---- helpers ---------------------------------------------------------

  defp url(port, path), do: "http://127.0.0.1:#{port}#{path}"

  # Queue the next response on the server process (registered under
  # the listen port) before issuing the request.
  defp register_response(port, status, reason, body) do
    send(server_pid(port), {:response, status, reason, body})
    :ok
  end

  defp server_pid(port) do
    case :global.whereis_name({:http_test_server, port}) do
      :undefined ->
        Process.sleep(20)
        server_pid(port)

      pid ->
        pid
    end
  end

  defp accept_loop(listen, _test_pid) do
    {:ok, port} = :inet.port(listen)
    :yes = :global.register_name({:http_test_server, port}, self())
    loop(listen)
  end

  defp loop(listen) do
    receive do
      {:response, status, reason, body} ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, _req} = :gen_tcp.recv(sock, 0, 2_000)

        resp =
          "HTTP/1.1 #{status} #{reason}\r\n" <>
            "Content-Type: text/plain\r\n" <>
            "Content-Length: #{byte_size(body)}\r\n" <>
            "Connection: close\r\n\r\n" <> body

        :gen_tcp.send(sock, resp)
        :gen_tcp.close(sock)
        loop(listen)
    end
  end
end
