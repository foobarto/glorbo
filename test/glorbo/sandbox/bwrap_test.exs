defmodule Glorbo.Sandbox.BwrapTest do
  use ExUnit.Case, async: true

  alias Glorbo.Sandbox.Bwrap

  defp base_opts(overrides \\ %{}) do
    Map.merge(
      %{
        agent_workspace: "/tmp/ws",
        inbox_path: "/tmp/in",
        outbox_path: "/tmp/out",
        company_path: "/tmp/co",
        permissions: [],
        network_policy: :none,
        cli_auth_binds: [],
        cli_env: %{},
        proxy_url: nil,
        timeout_seconds: 30
      },
      overrides
    )
  end

  # Helper: assert an argv slice appears in the argv list (in-order).
  defp assert_subsequence(argv, slice) do
    refute Enum.empty?(slice), "empty slice is meaningless"

    found? =
      argv
      |> Enum.chunk_every(length(slice), 1, :discard)
      |> Enum.any?(&(&1 == slice))

    assert found?,
           "expected argv to contain in-order slice #{inspect(slice)}\n" <>
             "argv=#{inspect(argv)}"
  end

  describe "build_argv/1 — baseline flags (B1, D-08)" do
    test "B1: minimal invocation emits every D-08 baseline flag + root FS + agent-owned + env" do
      argv = Bwrap.build_argv(base_opts())

      # Namespace flags (D-08)
      assert "--die-with-parent" in argv
      assert "--unshare-user-try" in argv
      assert "--unshare-ipc" in argv
      assert "--unshare-pid" in argv
      assert "--unshare-uts" in argv
      assert "--unshare-cgroup-try" in argv
      assert "--new-session" in argv
      assert_subsequence(argv, ["--cap-drop", "ALL"])

      # Root FS (D-09)
      assert_subsequence(argv, ["--ro-bind", "/usr", "/usr"])
      assert_subsequence(argv, ["--symlink", "usr/bin", "/bin"])
      assert_subsequence(argv, ["--symlink", "usr/lib", "/lib"])
      assert_subsequence(argv, ["--symlink", "usr/lib64", "/lib64"])
      assert_subsequence(argv, ["--symlink", "usr/sbin", "/sbin"])
      # /etc is minimally mounted (WR-04): tmpfs baseline + selective binds of
      # only files the CLI tools need (TLS trust, DNS, user-group lookup).
      # /etc/shadow, /etc/sudoers, /etc/ssh/*, /etc/cron.* must NOT appear.
      assert_subsequence(argv, ["--tmpfs", "/etc"])
      assert_subsequence(argv, ["--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf"])
      assert_subsequence(argv, ["--ro-bind", "/etc/hosts", "/etc/hosts"])
      assert_subsequence(argv, ["--ro-bind", "/etc/passwd", "/etc/passwd"])
      assert_subsequence(argv, ["--ro-bind", "/etc/group", "/etc/group"])

      # No full /etc bind — leaking shadow/sudoers/ssh would be a regression.
      refute argv
             |> Enum.chunk_every(3, 1, :discard)
             |> Enum.any?(&(&1 == ["--ro-bind", "/etc", "/etc"]))

      assert_subsequence(argv, ["--proc", "/proc"])
      assert_subsequence(argv, ["--dev", "/dev"])
      assert_subsequence(argv, ["--tmpfs", "/tmp"])

      # Agent-owned dirs
      assert_subsequence(argv, ["--bind", "/tmp/ws", "/workspace"])
      assert_subsequence(argv, ["--bind", "/tmp/out", "/outbox"])
      assert_subsequence(argv, ["--ro-bind", "/tmp/in", "/inbox"])

      # Working dir + env
      assert_subsequence(argv, ["--chdir", "/workspace"])
      assert_subsequence(argv, ["--setenv", "HOME", "/workspace"])
    end
  end

  describe "build_argv/1 — network policy (B2, B3; D-15, D-17)" do
    test "network: :none → --unshare-net present, no HTTP_PROXY env" do
      argv = Bwrap.build_argv(base_opts(%{network_policy: :none}))
      assert "--unshare-net" in argv
      refute Enum.any?(argv, &(&1 == "HTTPS_PROXY"))
      refute Enum.any?(argv, &(&1 == "HTTP_PROXY"))
    end

    test "B2: network: :proxy → --unshare-net ABSENT + HTTPS_PROXY + HTTP_PROXY env" do
      argv =
        Bwrap.build_argv(base_opts(%{network_policy: :proxy, proxy_url: "http://localhost:9999"}))

      refute "--unshare-net" in argv
      assert_subsequence(argv, ["--setenv", "HTTPS_PROXY", "http://localhost:9999"])
      assert_subsequence(argv, ["--setenv", "HTTP_PROXY", "http://localhost:9999"])
    end

    test "B3: network: :open → neither --unshare-net nor HTTP_PROXY" do
      argv = Bwrap.build_argv(base_opts(%{network_policy: :open}))
      refute "--unshare-net" in argv
      refute Enum.any?(argv, &(&1 == "HTTPS_PROXY"))
      refute Enum.any?(argv, &(&1 == "HTTP_PROXY"))
    end

    test "start/2 rejects network: :proxy without proxy_url" do
      assert {:error, :proxy_url_missing} =
               Bwrap.start(base_opts(%{network_policy: :proxy, proxy_url: nil}),
                 cli_binary: "/bin/true"
               )
    end

    test "start/2 rejects non-loopback proxy URLs" do
      assert {:error, {:invalid_proxy_url, "http://example.com:9999"}} =
               Bwrap.start(
                 base_opts(%{network_policy: :proxy, proxy_url: "http://example.com:9999"}),
                 cli_binary: "/bin/true"
               )
    end
  end

  describe "build_argv/1 — permissions + auth binds + env (B4, B5, B6)" do
    test "B4: permissions delegate to PermissionMapper in composition" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            permissions: [{"projects", "write", "a"}, {"projects", "read", "b"}]
          })
        )

      assert_subsequence(argv, ["--bind", "/tmp/co/projects/a", "/projects/a"])
      assert_subsequence(argv, ["--ro-bind", "/tmp/co/projects/b", "/projects/b"])
    end

    test "B5: cli_auth_binds emit --ro-bind entries" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            cli_auth_binds: [{"/home/user/.claude", "/host-claude"}]
          })
        )

      assert_subsequence(argv, ["--ro-bind", "/home/user/.claude", "/host-claude"])
    end

    test "B6: cli_env entries emit --setenv flags" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            cli_env: %{"CLAUDE_CONFIG_DIR" => "/workspace/.glorbo-claude"}
          })
        )

      assert_subsequence(argv, ["--setenv", "CLAUDE_CONFIG_DIR", "/workspace/.glorbo-claude"])
    end
  end

  describe "build_argv/1 — anti-patterns (B7–B10; T-03-30)" do
    test "B7: no `--ro-bind / /` full-root mount" do
      argv = Bwrap.build_argv(base_opts())

      refute argv
             |> Enum.chunk_every(3, 1, :discard)
             |> Enum.any?(&(&1 == ["--ro-bind", "/", "/"]))
    end

    test "B8: no `--privileged` flag" do
      argv = Bwrap.build_argv(base_opts())
      refute "--privileged" in argv
    end

    test "B9: no `--cap-add` flags (only drop)" do
      argv = Bwrap.build_argv(base_opts())
      refute "--cap-add" in argv
    end

    test "B10: `--unshare-user-try` used, never bare `--unshare-user`" do
      argv = Bwrap.build_argv(base_opts())
      assert "--unshare-user-try" in argv
      refute "--unshare-user" in argv
    end
  end

  describe "default_binary/0" do
    test "returns a path string on hosts that have bwrap, or raises otherwise" do
      if System.find_executable("bwrap") do
        assert is_binary(Bwrap.default_binary())
      else
        assert_raise RuntimeError, ~r/bwrap not found/, fn -> Bwrap.default_binary() end
      end
    end
  end

  # B11-B13 exercise start/2's stdin-EOF contract (GAP-1 regression test).
  # Every supported CLI (claude --print, codex exec -, gemini -p) waits on
  # stdin EOF before processing the prompt; a dispatch that fails to close
  # stdin will block until timeout. These tests use a `cat; echo DONE`
  # script inside the sandbox to verify:
  #   - stdin IS delivered to the child process
  #   - stdin IS closed (EOF reached) so the child can exit normally
  describe "start/2 — stdin EOF contract (B11–B13; GAP-1)" do
    @describetag :bwrap

    setup do
      if Glorbo.Test.BwrapHelpers.bwrap_available?() do
        base = Glorbo.Test.TmpGlorboHome.setup()
        co_root = Path.join([base, "companies", "acme"])

        for sub <- ~w(agents/engineer/workspace agents/engineer/inbox agents/engineer/outbox) do
          File.mkdir_p!(Path.join(co_root, sub))
        end

        {:ok,
         ctx: %{
           base: base,
           company_path: co_root,
           workspace: Path.join(co_root, "agents/engineer/workspace"),
           inbox: Path.join(co_root, "agents/engineer/inbox"),
           outbox: Path.join(co_root, "agents/engineer/outbox")
         }}
      else
        {:skip, "bwrap not available on host"}
      end
    end

    defp run_opts_for(ctx, overrides \\ %{}) do
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
          timeout_seconds: 10
        },
        overrides
      )
    end

    test "B11: prompt is delivered on stdin and EOFs (cat echoes it then exits)", %{ctx: ctx} do
      opts = run_opts_for(ctx)

      # `sh -c 'cat; echo DONE'`: cat reads stdin until EOF, echoes it, then
      # `echo DONE` runs. If stdin never EOFs, cat blocks forever and the
      # shell never reaches `echo DONE` — the test would time out.
      assert {:ok, %{exit_status: 0, stdout: out}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: ["-c", "cat; echo DONE"],
                 prompt: "hello-stdin\n"
               )

      assert String.contains?(out, "hello-stdin"),
             "expected prompt to arrive on stdin, stdout was: #{inspect(out)}"

      assert String.contains?(out, "DONE"),
             "expected DONE marker (stdin must EOF for echo to run), stdout was: #{inspect(out)}"
    end

    test "B12: empty prompt still EOFs (child exits cleanly with no input)", %{ctx: ctx} do
      opts = run_opts_for(ctx)

      # Empty prompt: cat should immediately see EOF and exit, then echo DONE.
      assert {:ok, %{exit_status: 0, stdout: out}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: ["-c", "cat; echo DONE"],
                 prompt: ""
               )

      assert String.contains?(out, "DONE"),
             "expected DONE marker with empty prompt, stdout was: #{inspect(out)}"
    end

    test "B13: prompt tempfile is cleaned up after invocation (no leak)", %{ctx: ctx} do
      opts = run_opts_for(ctx)

      before_files =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "glorbo_bwrap_prompt_"))
        |> MapSet.new()

      assert {:ok, _} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: ["-c", "cat"],
                 prompt: "leak-test"
               )

      after_files =
        System.tmp_dir!()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "glorbo_bwrap_prompt_"))
        |> MapSet.new()

      assert MapSet.difference(after_files, before_files) == MapSet.new(),
             "expected no new glorbo_bwrap_prompt_* tempfiles after Bwrap.start/2"
    end
  end
end
