defmodule Glorbo.Integration.SandboxNetworkNoneTest do
  use ExUnit.Case, async: false

  @moduletag :bwrap

  alias Glorbo.Sandbox.Bwrap
  alias Glorbo.Test.BwrapHelpers
  alias Glorbo.Test.TmpGlorboHome

  setup do
    if BwrapHelpers.bwrap_available?() do
      :ok
    else
      {:skip, "bwrap not available on host"}
    end
  end

  describe "BS4: --unshare-net kernel-enforced egress block (SEC-03)" do
    test "network: :loopback blocks curl to any external host" do
      base = TmpGlorboHome.setup()
      root = Path.join([base, "companies", "acme"])

      for sub <- ~w(agents/engineer/workspace agents/engineer/inbox agents/engineer/outbox) do
        File.mkdir_p!(Path.join(root, sub))
      end

      opts = %{
        agent_workspace: Path.join([root, "agents/engineer/workspace"]),
        inbox_path: Path.join([root, "agents/engineer/inbox"]),
        outbox_path: Path.join([root, "agents/engineer/outbox"]),
        company_path: root,
        permissions: [],
        network_policy: :loopback,
        cli_auth_binds: [],
        cli_env: %{},
        proxy_url: nil,
        timeout_seconds: 10
      }

      # Two ways curl fails under --unshare-net:
      #   - getaddrinfo: "Could not resolve host"
      #   - pre-resolved IP (DNS cache): "Network unreachable" / "Connection refused"
      # Either way, exit status is non-zero and stdout contains NO_NET (our fallback echo).
      assert {:ok, result} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: [
                   "-c",
                   "curl --max-time 3 --silent --show-error https://api.anthropic.com || echo NO_NET"
                 ]
               )

      assert String.contains?(result.stdout, "NO_NET"),
             "expected curl to fail under --unshare-net, got stdout: #{inspect(result.stdout)}"
    end
  end
end
