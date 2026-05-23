defmodule Glorbo.Sandbox.BwrapTest do
  # async: false — test "B13: prompt tempfile is cleaned up after
  # invocation (no leak)" enumerates `/tmp` for `glorbo_bwrap_prompt_*`
  # files before and after a Bwrap.start/2 call. Sibling tests in this
  # module also create real tempfiles in the same /tmp dir; if they run
  # concurrently with B13, B13's `after_files` can pick up a sibling's
  # in-flight tempfile and report a false leak. CI run 24944610056
  # showed exactly this. The whole module is sync; correctness of the
  # leak assertion matters more than the milliseconds saved.
  use ExUnit.Case, async: false

  alias Glorbo.Sandbox.Bwrap

  defp base_opts(overrides \\ %{}) do
    Map.merge(
      %{
        agent_workspace: "/tmp/ws",
        inbox_path: "/tmp/in",
        outbox_path: "/tmp/out",
        company_path: "/tmp/co",
        permissions: [],
        network_policy: :loopback,
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

  defp refute_subsequence(argv, slice) do
    refute Enum.empty?(slice), "empty slice is meaningless"

    found? =
      argv
      |> Enum.chunk_every(length(slice), 1, :discard)
      |> Enum.any?(&(&1 == slice))

    refute found?,
           "expected argv to NOT contain in-order slice #{inspect(slice)}\n" <>
             "argv=#{inspect(argv)}"
  end

  describe "build_argv/1 — baseline flags (B1, D-08)" do
    test "B1: minimal invocation emits every D-08 baseline flag + root FS + agent-owned + env" do
      argv = Bwrap.build_argv(base_opts())

      # Namespace flags (D-08). No `-try` fallbacks — every supported
      # kernel implements user + cgroup namespaces; silent fallback would
      # convert a kernel boundary into a best-effort one.
      assert "--die-with-parent" in argv
      assert "--unshare-user" in argv
      assert "--unshare-ipc" in argv
      assert "--unshare-pid" in argv
      assert "--unshare-uts" in argv
      assert "--unshare-cgroup" in argv
      assert "--new-session" in argv
      assert_subsequence(argv, ["--cap-drop", "ALL"])
      # Inherited BEAM env is wiped before any --setenv.
      assert "--clearenv" in argv

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
      # Minimum env after --clearenv wipes everything else.
      assert_subsequence(argv, ["--setenv", "PATH", "/usr/bin:/bin"])
      assert_subsequence(argv, ["--setenv", "LANG", "C.UTF-8"])
      assert_subsequence(argv, ["--setenv", "LC_ALL", "C.UTF-8"])
      assert_subsequence(argv, ["--setenv", "TERM", "dumb"])
      assert_subsequence(argv, ["--setenv", "TMPDIR", "/tmp"])
    end
  end

  describe "build_argv/1 — network policy (B2, B3; D-15, D-17)" do
    test "network: :loopback → --unshare-net present, no HTTP_PROXY env" do
      argv = Bwrap.build_argv(base_opts(%{network_policy: :loopback}))
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

    test "B3: network: :full → neither --unshare-net nor HTTP_PROXY" do
      argv = Bwrap.build_argv(base_opts(%{network_policy: :full}))
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

    # GEP-23 Phase 5: the per-dispatch proxy URL carries the auth token in
    # its userinfo (`http://<token>@127.0.0.1:<port>`). Validation must
    # accept it — rejecting userinfo (the old behaviour) hard-failed every
    # `network: proxy` dispatch with `:invalid_proxy_url`.
    test "start/2 accepts a loopback proxy URL carrying an auth token" do
      result =
        Bwrap.start(
          base_opts(%{network_policy: :proxy, proxy_url: "http://tok-abc123@127.0.0.1:9999"}),
          cli_binary: "/bin/true",
          bwrap_binary: "/nonexistent/bwrap-stub"
        )

      refute match?({:error, {:invalid_proxy_url, _}}, result)
    end

    # The token must survive normalisation into HTTPS_PROXY so the CLI's
    # CONNECT can send Proxy-Authorization; host is normalised to 127.0.0.1.
    test "build_argv preserves the proxy auth token in HTTPS_PROXY" do
      argv =
        Bwrap.build_argv(
          base_opts(%{network_policy: :proxy, proxy_url: "http://tok-abc123@127.0.0.1:9999"})
        )

      assert_subsequence(argv, ["--setenv", "HTTPS_PROXY", "http://tok-abc123@127.0.0.1:9999"])
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
            cli_auth_binds: [{"/home/user/.claude", "/workspace/.claude"}]
          })
        )

      assert_subsequence(argv, ["--ro-bind", "/home/user/.claude", "/workspace/.claude"])
    end

    test "B5b: 3-tuple cli_auth_binds with :rw mode emit --bind not --ro-bind" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            cli_auth_binds: [
              {"/h/rw", "/workspace/.rw-dir", :rw},
              {"/h/ro", "/workspace/.ro-dir", :ro}
            ]
          })
        )

      assert_subsequence(argv, ["--bind", "/h/rw", "/workspace/.rw-dir"])
      assert_subsequence(argv, ["--ro-bind", "/h/ro", "/workspace/.ro-dir"])
    end

    test "B5c: 4-tuple cli_auth_binds with :dir type emit --dir before the bind" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            cli_auth_binds: [
              {"/h/datadir", "/workspace/.project", :rw, :dir},
              {"/h/cli", "/workspace/.cli-bin", :ro, :file}
            ]
          })
        )

      assert_subsequence(argv, [
        "--dir",
        "/workspace/.project",
        "--bind",
        "/h/datadir",
        "/workspace/.project"
      ])

      assert_subsequence(argv, ["--ro-bind", "/h/cli", "/workspace/.cli-bin"])
      refute_subsequence(argv, ["--dir", "/workspace/.cli-bin"])
    end

    # Codex deep-dive F1: cli_auth_bind paths previously flowed into
    # bwrap argv with no validation. A config-influencer (untrusted
    # provider registry contribution, malicious copy-paste, etc.)
    # could mount `host="/"` at `sandbox="/etc"`, exfiltrating host
    # creds through the sandbox surface or shadowing critical mounts
    # inside the namespace. These cases now raise.
    test "B5d (codex-F1): unsafe auth-bind paths raise" do
      bad_cases = [
        # host: not absolute
        [{"relative/path", "/workspace/.x"}],
        # host: contains ..
        [{"/etc/../passwd", "/workspace/.x"}],
        [{"/foo/..", "/workspace/.x"}],
        # host: contains NUL
        [{"/etc\0/passwd", "/workspace/.x"}],
        # sandbox: not absolute
        [{"/home/user/.claude", "relative/sandbox"}],
        # sandbox: EXACTLY shadows the workspace mount
        [{"/home/user/.claude", "/workspace"}],
        # sandbox: EXACTLY shadows other critical mounts
        [{"/home/user/.claude", "/"}],
        [{"/home/user/.claude", "/etc"}],
        [{"/home/user/.claude", "/usr"}],
        [{"/home/user/.claude", "/inbox"}],
        # sandbox: contains ..
        [{"/home/user/.claude", "/workspace/../etc"}],
        # sandbox: NUL
        [{"/home/user/.claude", "/workspace/\0evil"}]
      ]

      for binds <- bad_cases do
        assert_raise ArgumentError, fn ->
          Bwrap.build_argv(base_opts(%{cli_auth_binds: binds}))
        end
      end
    end

    # Negative cases: legit mount points used in the codebase that
    # were previously broken by an over-strict allowlist.
    test "B5e (codex-F1): legit non-/workspace sandbox prefixes are accepted" do
      ok_cases = [
        # CLI-binary bind used by dispatch.ex `cli_binary_bind/1` —
        # intentionally under /tmp so agents can't enumerate the host
        # binary's parent dir.
        [{"/usr/bin/claude", "/tmp/glorbo-cli-claude-code", :ro, :file}],
        # Other legitimate /workspace/ subpaths (shipped providers).
        [{"/home/u/.claude", "/workspace/.claude"}],
        [{"/home/u/.gemini", "/workspace/.gemini", :rw}]
      ]

      for binds <- ok_cases do
        argv = Bwrap.build_argv(base_opts(%{cli_auth_binds: binds}))
        # If validation rejected, build_argv would have raised — just
        # assert it produced some argv.
        assert is_list(argv) and argv != []
      end
    end

    # B8: auth_bind `mode = "rw"` whose sandbox path is a sub-path of
    # `/workspace` (the agent_workspace mount) must still emit
    # `--bind`, not `--ro-bind`. bwrap applies binds in argv order so
    # the rw sub-path correctly overlays the rw `/workspace` parent.
    # Verifies cli_auth_bind_flags doesn't accidentally demote :rw to
    # :ro for sub-paths (the reported field-time symptom).
    test "B8: cli_auth_binds with :rw + /workspace sub-path emit --bind, not --ro-bind" do
      argv =
        Bwrap.build_argv(
          base_opts(%{
            cli_auth_binds: [
              {"/host/writable", "/workspace/project", :rw, :dir}
            ]
          })
        )

      assert_subsequence(argv, [
        "--dir",
        "/workspace/project",
        "--bind",
        "/host/writable",
        "/workspace/project"
      ])

      refute_subsequence(argv, ["--ro-bind", "/host/writable", "/workspace/project"])
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

    test "B10: bare `--unshare-user` + `--unshare-cgroup`, never `-try` fallbacks" do
      argv = Bwrap.build_argv(base_opts())
      assert "--unshare-user" in argv
      assert "--unshare-cgroup" in argv
      refute "--unshare-user-try" in argv
      refute "--unshare-cgroup-try" in argv
    end

    test "B11: --clearenv wipes BEAM env, then explicit --setenv whitelist only" do
      argv = Bwrap.build_argv(base_opts())
      # --clearenv must come before any --setenv or those setenvs get cleared.
      clearenv_idx = Enum.find_index(argv, &(&1 == "--clearenv"))
      first_setenv_idx = Enum.find_index(argv, &(&1 == "--setenv"))
      assert is_integer(clearenv_idx)
      assert is_integer(first_setenv_idx)
      assert clearenv_idx < first_setenv_idx
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
          network_policy: :loopback,
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

    test "C-103: stdout.log tee is capped at the per-dispatch byte ceiling", %{ctx: ctx} do
      # Generous timeout: draining ~24 MiB through the BEAM port can take
      # several seconds under parallel test load — we are testing the
      # byte cap, not the time cap.
      opts = run_opts_for(ctx, %{timeout_seconds: 60})
      stdout_log = Path.join(ctx.workspace, "stdout.log")

      # Emit ~24 MiB to stdout (> the 16 MiB tee cap). `tr` reading
      # /dev/zero translates NULs to 'a'; `head -c` bounds the total and
      # exits, so the dispatch returns. `head` closing the pipe makes
      # `tr` exit on SIGPIPE — both acceptable terminal states.
      assert {:ok, %{exit_status: status}} =
               Bwrap.start(opts,
                 cli_binary: "/bin/sh",
                 cli_args: ["-c", "tr '\\0' 'a' < /dev/zero | head -c 25165824"],
                 prompt: "",
                 stdout_log: stdout_log
               )

      assert status == 0

      %File.Stat{size: size} = File.stat!(stdout_log)
      cap = 16 * 1024 * 1024

      # Header + capped payload + truncation marker + footer — a few
      # hundred bytes of framing over the cap, never the full 24 MiB.
      assert size <= cap + 4_096,
             "expected stdout.log capped near #{cap} bytes, got #{size}"

      assert String.contains?(File.read!(stdout_log), "truncated: per-dispatch"),
             "expected a truncation marker in the capped stdout.log"
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

  # GEP-45 Phase 1b sub-slice 1b.5: `start_acp/2` opens the bwrap'd CLI
  # as a long-running Port without the stdin-tempfile redirect. The
  # tests below drive a tiny `/bin/sh` script standing in for an ACP
  # server: it reads JSON-RPC frames from stdin and emits canned ones
  # back. Confirms the wiring (Port.command + receive) works end-to-end
  # before stado lands on the host.
  describe "start_acp/2 — long-running Port without stdin redirect (GEP-45)" do
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

    defp acp_run_opts_for(ctx, overrides \\ %{}) do
      Map.merge(
        %{
          agent_workspace: ctx.workspace,
          inbox_path: ctx.inbox,
          outbox_path: ctx.outbox,
          company_path: ctx.company_path,
          permissions: [],
          network_policy: :loopback,
          cli_auth_binds: [],
          cli_env: %{},
          proxy_url: nil,
          timeout_seconds: 10
        },
        overrides
      )
    end

    test "returns a live Port that echoes stdin via Port.command + receive", %{ctx: ctx} do
      opts = acp_run_opts_for(ctx)

      assert {:ok, port} =
               Bwrap.start_acp(opts,
                 cli_binary: "/bin/sh",
                 # `cat` reads stdin and writes to stdout. Anything we push
                 # via Port.command/2 should round-trip back as a port
                 # message.
                 cli_args: ["-c", "cat"]
               )

      assert is_port(port)

      try do
        assert true = Port.command(port, "ping-acp\n")

        # Drain at least one chunk containing our marker.
        assert_receive {^port, {:data, chunk}}, 2_000
        assert is_binary(chunk)
        assert String.contains?(chunk, "ping-acp")
      after
        Port.close(port)
      end
    end

    test "drives a fake ACP server end-to-end through PortIO + Client", %{ctx: ctx} do
      # The shell script reads framed JSON one line at a time and emits
      # the matching response sequence. Crude but enough to confirm the
      # full Port → PortIO → Client → Bwrap loop is wired correctly.
      script = """
      #!/bin/sh
      # Initialize
      read line
      printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{},"agentInfo":{"name":"fake","version":"0"}}}\\n'
      # session/new
      read line
      printf '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-fake"}}\\n'
      # session/prompt → emit one chunk + terminal response
      read line
      printf '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-fake","update":{"kind":"agent_message_chunk","text":"hi-from-fake"}}}\\n'
      printf '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\\n'
      # shutdown
      read line
      printf '{"jsonrpc":"2.0","id":4,"result":{}}\\n'
      """

      opts = acp_run_opts_for(ctx)

      assert {:ok, port} =
               Bwrap.start_acp(opts,
                 cli_binary: "/bin/sh",
                 cli_args: ["-c", script]
               )

      io = Glorbo.CLI.Dispatcher.Acp.PortIO.wrap(port)

      assert {:ok, %{reply: "hi-from-fake", session_id: "s-fake", chunks: 1}} =
               Glorbo.CLI.Dispatcher.Acp.Client.run(io, "say hi", phase_timeout_ms: 2_000)
    end
  end
end
