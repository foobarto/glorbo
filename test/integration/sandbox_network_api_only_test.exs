defmodule Glorbo.Integration.SandboxNetworkApiOnlyTest do
  use ExUnit.Case, async: false

  @moduletag :bwrap

  alias Glorbo.Network.Proxy
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

  @doc """
  IP1: disallowed host via HTTPS_PROXY returns 403 (proxy denial).

  HAPPY-PATH contract: a sandboxed `curl -x $HTTPS_PROXY` to an
  out-of-allowlist host is rejected by the proxy. The sandbox remains
  kernel-isolated in the filesystem dimension while allowing the test
  proxy to enforce a hostname allowlist at the CONNECT-line level.

  This test validates the HAPPY PATH of HTTPS_PROXY enforcement. A
  determined attacker inside the sandbox could bypass by ignoring the
  env var (Pitfall 7, documented advisory-only).
  """
  test "IP1: disallowed host via HTTPS_PROXY returns 403 (proxy denial)" do
    # Start a proxy with an empty allowlist → every host is 403.
    {:ok, proxy_pid} =
      Proxy.start_link(
        company: "test",
        port: 0,
        allowlist_fun: fn _ -> ["api.anthropic.com"] end
      )

    on_exit(fn -> if Process.alive?(proxy_pid), do: Proxy.stop(proxy_pid) end)
    proxy_port = Proxy.port(proxy_pid)
    proxy_url = "http://localhost:#{proxy_port}"

    ctx = make_agent_dirs()

    opts = %{
      agent_workspace: ctx.workspace,
      inbox_path: ctx.inbox,
      outbox_path: ctx.outbox,
      company_path: ctx.company_path,
      permissions: [],
      network_policy: :api_only,
      cli_auth_binds: [],
      cli_env: %{},
      proxy_url: proxy_url,
      timeout_seconds: 15
    }

    # Sandboxed curl attempts to reach evil.example.com via the proxy →
    # the proxy returns 403 → curl reports "Received HTTP code 403".
    # We capture stdout + use --proxy explicitly; curl typically honours
    # HTTPS_PROXY env but some setups require an explicit -x flag.
    assert {:ok, result} =
             Bwrap.start(opts,
               cli_binary: "/bin/sh",
               cli_args: [
                 "-c",
                 "curl --silent --show-error --max-time 5 --proxy " <>
                   "$HTTPS_PROXY https://evil.example.com 2>&1; echo ---exit:$?---"
               ]
             )

    # Curl will report "CONNECT tunnel failed, response 403" + exit 56 on
    # proxy denial. The outer sh script echoes ---exit:<N>--- so we can
    # assert on curl's exit code via stdout inspection (the shell itself
    # exits 0 after `echo`).
    assert result.stdout =~ "403",
           "expected proxy to return 403 for disallowed host, got stdout: #{inspect(result.stdout)}"

    # Curl uses exit code 56 when the proxy returns a non-success CONNECT
    # response; confirm the captured exit line shows a non-zero curl status.
    refute result.stdout =~ "---exit:0---",
           "expected curl exit status to be non-zero, got stdout: #{inspect(result.stdout)}"
  end

  @doc """
  IP2 (documented limitation): with `--noproxy '*'`, curl bypasses
  HTTPS_PROXY and reaches the host directly. This test is informational
  — it does NOT pass a strict denial — it simply records that the
  advisory boundary is bypassable. Kept in the suite as a reminder that
  `api-only` is advisory in v0.0.1 and documented as such.
  """
  @tag :skip_in_ci
  test "IP2: HTTPS_PROXY is advisory (bypass documented; skipped unless manually enabled)" do
    # This test intentionally documents Pitfall 7. It's skipped by default
    # to avoid making external network calls from the test suite. The
    # integration-level proof of api-only enforcement is IP1 above; this
    # entry exists for documentation + manual verification.
    :ok
  end
end
