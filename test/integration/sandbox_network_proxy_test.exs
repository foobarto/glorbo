defmodule Glorbo.Integration.SandboxNetworkProxyTest do
  use ExUnit.Case, async: false

  @moduletag :bwrap

  alias Glorbo.Network.Proxy
  alias Glorbo.Sandbox.Bwrap
  alias Glorbo.Test.BwrapHelpers
  alias Glorbo.Test.TmpGlorboHome

  setup do
    cond do
      not BwrapHelpers.bwrap_available?() ->
        {:skip, "bwrap not available on host"}

      not BwrapHelpers.pasta_available?() ->
        {:skip, "pasta not available on host"}

      true ->
        :ok
    end
  end

  defp start_loopback_http_server(body) when is_binary(body) do
    {:ok, listen_sock} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen_sock)

    task =
      Task.async(fn ->
        case :gen_tcp.accept(listen_sock) do
          {:ok, sock} ->
            _ = :gen_tcp.recv(sock, 0, 1_000)

            response =
              [
                "HTTP/1.1 200 OK\r\n",
                "Content-Length: ",
                Integer.to_string(byte_size(body)),
                "\r\nConnection: close\r\n\r\n",
                body
              ]

            _ = :gen_tcp.send(sock, response)
            :gen_tcp.close(sock)
            :ok

          {:error, :closed} ->
            :ok

          other ->
            other
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listen_sock)
      if Process.alive?(task.pid), do: Process.exit(task.pid, :kill)
    end)

    port
  end

  defp proxy_opts(ctx, proxy_port) do
    %{
      agent_workspace: ctx.workspace,
      inbox_path: ctx.inbox,
      outbox_path: ctx.outbox,
      company_path: ctx.company_path,
      permissions: [],
      network_policy: :proxy,
      cli_auth_binds: [],
      cli_env: %{},
      proxy_url: "http://127.0.0.1:#{proxy_port}",
      timeout_seconds: 15
    }
  end

  @doc """
  IP1: disallowed host via HTTPS_PROXY returns 403 (proxy denial).

  The proxy itself stays reachable from the sandbox, but only through the
  forwarded proxy port. A disallowed hostname still gets a 403 from the
  proxy.
  """
  test "IP1: disallowed host via HTTPS_PROXY returns 403 (proxy denial)" do
    {:ok, proxy_pid} =
      Proxy.start_link(
        company: "test",
        port: 0,
        allowlist_fun: fn _ -> ["api.anthropic.com"] end
      )

    on_exit(fn -> if Process.alive?(proxy_pid), do: Proxy.stop(proxy_pid) end)
    proxy_port = Proxy.port(proxy_pid)

    ctx = make_agent_dirs()

    assert {:ok, result} =
             Bwrap.start(proxy_opts(ctx, proxy_port),
               cli_binary: "/bin/sh",
               cli_args: [
                 "-c",
                 "curl --silent --show-error --max-time 5 --proxy " <>
                   "$HTTPS_PROXY https://evil.example.com 2>&1; echo ---exit:$?---"
               ]
             )

    assert result.stdout =~ "403",
           "expected proxy to return 403 for disallowed host, got stdout: #{inspect(result.stdout)}"

    refute result.stdout =~ "---exit:0---",
           "expected curl exit status to be non-zero, got stdout: #{inspect(result.stdout)}"
  end

  @doc """
  IP2: direct access to arbitrary host loopback ports is blocked.

  Under enforced `network: proxy`, the sandbox should only be able to
  reach the forwarded proxy port, not unrelated host listeners on
  127.0.0.1.
  """
  test "IP2: direct access to unrelated host loopback ports is blocked" do
    {:ok, proxy_pid} =
      Proxy.start_link(
        company: "test",
        port: 0,
        allowlist_fun: fn _ -> ["api.anthropic.com"] end
      )

    on_exit(fn -> if Process.alive?(proxy_pid), do: Proxy.stop(proxy_pid) end)
    proxy_port = Proxy.port(proxy_pid)
    blocked_port = start_loopback_http_server("host-loopback")

    ctx = make_agent_dirs()

    assert {:ok, result} =
             Bwrap.start(proxy_opts(ctx, proxy_port),
               cli_binary: "/bin/sh",
               cli_args: [
                 "-c",
                 "curl --silent --show-error --max-time 3 http://127.0.0.1:#{blocked_port} 2>&1; " <>
                   "echo ---direct:$?---; " <>
                   "curl --silent --show-error --max-time 5 --proxy " <>
                   "$HTTPS_PROXY https://evil.example.com 2>&1; echo ---proxy:$?---"
               ]
             )

    refute result.stdout =~ "host-loopback",
           "sandbox unexpectedly reached host loopback service: #{inspect(result.stdout)}"

    refute result.stdout =~ "---direct:0---",
           "expected direct loopback access to fail, got stdout: #{inspect(result.stdout)}"

    assert result.stdout =~ "403",
           "expected proxy path to remain reachable, got stdout: #{inspect(result.stdout)}"
  end

  defp make_agent_dirs do
    base = TmpGlorboHome.setup()
    root = Path.join([base, "companies", "acme"])

    for sub <- ~w(agents/engineer/workspace agents/engineer/inbox agents/engineer/outbox) do
      File.mkdir_p!(Path.join(root, sub))
    end

    %{
      base: base,
      company_path: root,
      workspace: Path.join([root, "agents/engineer/workspace"]),
      inbox: Path.join([root, "agents/engineer/inbox"]),
      outbox: Path.join([root, "agents/engineer/outbox"])
    }
  end
end
