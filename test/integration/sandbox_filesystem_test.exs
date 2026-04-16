defmodule Glorbo.Integration.SandboxFilesystemTest do
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

  defp make_company(co \\ "acme") do
    base = TmpGlorboHome.setup()
    root = Path.join([base, "companies", co])

    for sub <-
          ~w(projects channels agents/engineer/workspace agents/engineer/inbox agents/engineer/outbox) do
      File.mkdir_p!(Path.join(root, sub))
    end

    %{
      base: base,
      company: co,
      company_path: root,
      workspace: Path.join([root, "agents/engineer/workspace"]),
      inbox: Path.join([root, "agents/engineer/inbox"]),
      outbox: Path.join([root, "agents/engineer/outbox"])
    }
  end

  defp base_invocation_opts(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        agent_workspace: ctx.workspace,
        inbox_path: ctx.inbox,
        outbox_path: ctx.outbox,
        company_path: ctx.company_path,
        permissions: [],
        network_policy: :none,
        cli_auth_binds: [],
        cli_env: %{},
        proxy_url: nil,
        timeout_seconds: 15
      },
      overrides
    )
  end

  describe "BS1: baseline invocation round-trip" do
    test "bwrap echo hello → stdout contains 'hello'" do
      ctx = make_company()
      opts = base_invocation_opts(ctx)

      assert {:ok, %{exit_status: 0, stdout: out}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/echo",
                 cli_args: ["hello"],
                 prompt: ""
               )

      assert String.contains?(out, "hello")
    end
  end

  describe "BS2: VFS invisibility — unmounted projects are not visible (SEC-02)" do
    test "listing a non-mounted project returns HIDDEN" do
      ctx = make_company()
      # Create projects/other/ on the host, but don't grant a permission for it.
      File.mkdir_p!(Path.join(ctx.company_path, "projects/other"))
      File.write!(Path.join(ctx.company_path, "projects/other/secret.txt"), "top secret")

      opts = base_invocation_opts(ctx)

      assert {:ok, %{exit_status: 0, stdout: out}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: [
                   "-c",
                   "test -e /projects/other && echo VISIBLE || echo HIDDEN"
                 ]
               )

      assert String.contains?(out, "HIDDEN"),
             "expected /projects/other to be HIDDEN in sandbox, got stdout: #{inspect(out)}"
    end
  end

  describe "BS3: sandbox can write to permitted paths" do
    test "projects:write:foo lets the sandbox write to /projects/foo/" do
      ctx = make_company()
      File.mkdir_p!(Path.join(ctx.company_path, "projects/foo"))

      opts =
        base_invocation_opts(ctx, %{
          permissions: [{"projects", "write", "foo"}]
        })

      assert {:ok, %{exit_status: 0}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: [
                   "-c",
                   "touch /projects/foo/created-by-sandbox"
                 ]
               )

      host_path = Path.join(ctx.company_path, "projects/foo/created-by-sandbox")

      assert File.exists?(host_path),
             "expected host-visible file at #{host_path} (sandbox wrote to /projects/foo/)"
    end
  end
end
