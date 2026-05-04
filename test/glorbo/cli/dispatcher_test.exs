defmodule Glorbo.CLI.DispatcherTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Dispatcher
  alias Glorbo.CLI.Registry.Provider

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_workspace do
    path = Path.join(System.tmp_dir!(), "dispatcher-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, ".glorbo/outbox"))
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp base_provider(overrides \\ []) do
    struct!(
      %Provider{
        name: "fake",
        binary: "/bin/fake",
        resolved_path: "/bin/fake",
        installed?: true,
        args: ["--model", "{model}"],
        reply_dir: "{workspace}/.glorbo/outbox",
        reply_filename_template: "{invocation_id}.md",
        source: :builtin,
        source_file: "<test>",
        usage_parser: "none"
      },
      overrides
    )
  end

  defp base_ctx(workspace, overrides \\ []) do
    Enum.into(overrides, %{
      model: "m-1",
      workspace: workspace,
      prompt: "hi",
      prompt_path: Path.join(workspace, "prompt.md"),
      task_id: "task-1",
      invocation_id: "abc123",
      timestamp: "20260417T000000"
    })
  end

  # A run_fun that writes a canned reply to $GLORBO_REPLY_PATH and
  # returns a clean exit.
  defp writer_run_fun(reply_body, exit_status \\ 0) do
    fn _args, env, _bwrap_opts, _run_opts ->
      File.write!(env["GLORBO_REPLY_PATH"], reply_body)
      {:ok, %{exit_status: exit_status, stdout: "", usage_dir: nil}}
    end
  end

  # ---------------------------------------------------------------------------
  # Template expansion
  # ---------------------------------------------------------------------------

  describe "template expansion" do
    test "expands {model}, {workspace}, {invocation_id}, {timestamp} in args and reply path" do
      ws = tmp_workspace()
      p = base_provider()
      ctx = base_ctx(ws)

      captured = :ets.new(:captured, [:public, :set])

      fun = fn args, env, _b, run_opts ->
        :ets.insert(captured, {:args, args})
        :ets.insert(captured, {:env, env})
        :ets.insert(captured, {:cli_binary, run_opts.cli_binary})
        :ets.insert(captured, {:host_cli_binary, run_opts.host_cli_binary})
        File.write!(env["GLORBO_REPLY_PATH"], "reply body")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      assert {:ok, result} = Dispatcher.invoke(p, ctx, run_fun: fun)
      assert result.reply == "reply body"
      assert result.reply_path == Path.join([ws, ".glorbo/outbox", "abc123.md"])

      assert [{:args, ["--model", "m-1"]}] = :ets.lookup(captured, :args)
      assert [{:cli_binary, "/bin/fake"}] = :ets.lookup(captured, :cli_binary)
      assert [{:host_cli_binary, "/bin/fake"}] = :ets.lookup(captured, :host_cli_binary)

      [{:env, env}] = :ets.lookup(captured, :env)
      assert env["GLORBO_TASK_ID"] == "task-1"
      assert env["GLORBO_INVOCATION_ID"] == "abc123"
      assert env["GLORBO_WORKSPACE"] == ws
      assert env["GLORBO_REPLY_PATH"] == result.reply_path
    end

    test "applies named path_transforms before template expansion" do
      ws = "/home/agents/alice"
      tmp = tmp_workspace()

      p =
        base_provider(
          reply_dir: tmp,
          env: %{"CLAUDE_CONFIG_DIR" => "{encoded}"},
          path_transforms: [
            %{name: "encoded", from: "{workspace}", transform: "slash_to_dash"}
          ]
        )

      ctx = base_ctx(ws)

      seen_env = :ets.new(:seen_env, [:public, :set])

      fun = fn _a, env, _b, _r ->
        :ets.insert(seen_env, {:env, env})
        File.write!(env["GLORBO_REPLY_PATH"], "reply")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      assert {:ok, _} = Dispatcher.invoke(p, ctx, run_fun: fun)
      [{:env, env}] = :ets.lookup(seen_env, :env)
      assert env["CLAUDE_CONFIG_DIR"] == "-home-agents-alice"
    end
  end

  # ---------------------------------------------------------------------------
  # Reply-file contract
  # ---------------------------------------------------------------------------

  describe "reply-file contract" do
    test "succeeds when agent writes a valid reply" do
      ws = tmp_workspace()

      assert {:ok, %{reply: "hello"}} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: writer_run_fun("hello"))
    end

    test "fails with :reply_file_missing when agent writes nothing" do
      ws = tmp_workspace()

      silent = fn _a, _env, _b, _r -> {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}} end

      assert {:error, :reply_file_missing} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: silent)
    end

    test "stdout-as-reply fallback: exit=0, non-empty stdout, no reply file → use stdout" do
      ws = tmp_workspace()

      chatty = fn _a, _env, _b, _r ->
        {:ok, %{exit_status: 0, stdout: "hello from stdout", usage_dir: nil}}
      end

      assert {:ok, %{reply: reply}} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: chatty)

      assert reply =~ "hello from stdout"
    end

    test "stdout-as-reply skipped when exit != 0" do
      ws = tmp_workspace()

      failed = fn _a, _env, _b, _r ->
        {:ok, %{exit_status: 1, stdout: "whoops", usage_dir: nil}}
      end

      assert {:error, :reply_file_missing} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: failed)
    end

    test "fails with :reply_file_empty on zero-byte file" do
      ws = tmp_workspace()
      empty = writer_run_fun("")

      assert {:error, :reply_file_empty} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: empty)
    end

    test "fails with :reply_file_too_large past the cap" do
      ws = tmp_workspace()
      p = base_provider(reply_max_bytes: 10)
      big = writer_run_fun(String.duplicate("x", 100))

      assert {:error, {:reply_file_too_large, 100, 10}} =
               Dispatcher.invoke(p, base_ctx(ws), run_fun: big)
    end

    test "clears stale reply file from a prior run" do
      ws = tmp_workspace()
      reply_path = Path.join([ws, ".glorbo/outbox", "abc123.md"])
      File.write!(reply_path, "stale content from last time")

      # This run writes an empty file — must still surface :reply_file_empty
      # rather than succeeding on the stale contents.
      empty = writer_run_fun("")

      assert {:error, :reply_file_empty} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: empty)
    end
  end

  # ---------------------------------------------------------------------------
  # Env composition
  # ---------------------------------------------------------------------------

  describe "env composition" do
    test "merges provider.env with GLORBO_* standard vars" do
      ws = tmp_workspace()
      p = base_provider(env: %{"CUSTOM_VAR" => "fixed", "REDIRECT" => "{workspace}/.data"})

      captured = :ets.new(:env, [:public, :set])

      fun = fn _a, env, _b, _r ->
        :ets.insert(captured, {:env, env})
        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      assert {:ok, _} = Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)

      [{:env, env}] = :ets.lookup(captured, :env)
      assert env["CUSTOM_VAR"] == "fixed"
      assert env["REDIRECT"] == ws <> "/.data"
      assert env["GLORBO_TASK_ID"] == "task-1"
    end
  end

  # ---------------------------------------------------------------------------
  # Usage parsing
  # ---------------------------------------------------------------------------

  describe "usage parsing" do
    test "usage_parser = none leaves usage nil" do
      ws = tmp_workspace()

      assert {:ok, %{usage: nil, usage_error: nil}} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: writer_run_fun("ok"))
    end

    test "stdout kind forwards to parser with run_result.stdout" do
      ws = tmp_workspace()

      gemini_blob = """
      {"stats":{"models":{"g":{"tokens":{"prompt":10,"cached":5,"candidates":20,"thoughts":2,"tool":1}}}}}
      """

      fun = fn _a, env, _b, _r ->
        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: gemini_blob, usage_dir: nil}}
      end

      p =
        base_provider(
          usage_parser: "gemini_stdout",
          usage_path: %{kind: :stdout, path: nil}
        )

      assert {:ok, %{usage: usage, usage_error: nil}} =
               Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)

      assert usage.prompt_tokens == 15
      assert usage.completion_tokens == 23
    end

    test "parse errors land in :usage_error, invocation still succeeds" do
      ws = tmp_workspace()

      p =
        base_provider(
          usage_parser: "gemini_stdout",
          usage_path: %{kind: :stdout, path: nil}
        )

      fun = fn _a, env, _b, _r ->
        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: "not json", usage_dir: nil}}
      end

      assert {:ok, %{usage: nil, usage_error: :json_decode_error}} =
               Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)
    end

    test "json_file kind forwards to parser with expanded path" do
      ws = tmp_workspace()

      p =
        base_provider(
          usage_parser: "native-v1",
          usage_path: %{kind: :json_file, path: "{workspace}/.glorbo/run/usage.json"}
        )

      fun = fn _a, env, _b, run_opts ->
        usage_path = Path.join(run_opts.usage_dir, "usage.json")
        File.mkdir_p!(Path.dirname(usage_path))

        File.write!(
          usage_path,
          ~s({"tracked":true,"prompt_tokens":5,"completion_tokens":8,"model":"native-model"})
        )

        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: run_opts.usage_dir}}
      end

      assert {:ok, %{usage: usage, usage_error: nil}} =
               Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)

      assert usage.tracked == true
      assert usage.prompt_tokens == 5
      assert usage.completion_tokens == 8
      assert usage.model == "native-model"
    end
  end

  # ---------------------------------------------------------------------------
  # run_fun contract
  # ---------------------------------------------------------------------------

  describe "run_fun contract" do
    test "propagates {:error, reason} from run_fun" do
      ws = tmp_workspace()
      crash = fn _a, _e, _b, _r -> {:error, :bwrap_failed} end

      assert {:error, :bwrap_failed} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: crash)
    end

    test "handles malformed run_fun return" do
      ws = tmp_workspace()
      weird = fn _a, _e, _b, _r -> :yolo end

      assert {:error, {:run_fun_bad_return, :yolo}} =
               Dispatcher.invoke(base_provider(), base_ctx(ws), run_fun: weird)
    end

    test "passes cli_args and cli_binary to run_fun" do
      ws = tmp_workspace()
      p = base_provider(args: ["--print", "--model", "{model}"])

      spy = :ets.new(:spy, [:public, :set])

      fun = fn args, env, _b, run_opts ->
        :ets.insert(spy, {:args, args})
        :ets.insert(spy, {:binary, run_opts.cli_binary})
        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      assert {:ok, _} = Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)
      assert [{:args, ["--print", "--model", "m-1"]}] = :ets.lookup(spy, :args)
      assert [{:binary, "/bin/fake"}] = :ets.lookup(spy, :binary)
    end

    test "native providers invoke the harness with synthesized args" do
      ws = tmp_workspace()

      p =
        base_provider(
          name: "openai",
          kind: :native,
          binary: nil,
          resolved_path: nil,
          endpoint: "https://api.openai.com/v1",
          auth: :bearer,
          args: [],
          usage_parser: "native-v1",
          usage_path: %{kind: :json_file, path: "{workspace}/.glorbo-run/{task_id}/usage.json"}
        )

      ctx =
        base_ctx(ws,
          agent_slug: "engineer",
          company: "acme",
          native_binary: "/fake/glorbo",
          http_timeout_s: 45,
          http_max_retries: 4,
          web_fetch_timeout_s: 9,
          max_tool_calls_per_turn: 77
        )

      spy = :ets.new(:native_spy, [:public, :set])

      fun = fn args, env, _b, run_opts ->
        :ets.insert(spy, {:args, args})
        :ets.insert(spy, {:binary, run_opts.cli_binary})
        :ets.insert(spy, {:host_binary, run_opts.host_cli_binary})
        :ets.insert(spy, {:cli_args, run_opts.cli_args})
        :ets.insert(spy, {:env, env})
        File.mkdir_p!(run_opts.usage_dir)

        File.write!(
          Path.join(run_opts.usage_dir, "usage.json"),
          ~s({"tracked":true,"prompt_tokens":1,"completion_tokens":2})
        )

        File.write!(env["GLORBO_REPLY_PATH"], "native ok")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: run_opts.usage_dir}}
      end

      assert {:ok, %{reply: "native ok"}} = Dispatcher.invoke(p, ctx, run_fun: fun)
      assert [{:args, []}] = :ets.lookup(spy, :args)
      assert [{:binary, "/fake/glorbo"}] = :ets.lookup(spy, :binary)
      assert [{:host_binary, "/fake/glorbo"}] = :ets.lookup(spy, :host_binary)

      assert [
               {:cli_args,
                [
                  "harness",
                  "--provider",
                  "openai",
                  "--agent",
                  "engineer",
                  "--task",
                  "task-1",
                  "--model",
                  "m-1"
                ]}
             ] = :ets.lookup(spy, :cli_args)

      [{:env, env}] = :ets.lookup(spy, :env)
      assert env["GLORBO_PROVIDER"] == "openai"
      assert env["GLORBO_NATIVE_ENDPOINT"] == "https://api.openai.com/v1"
      assert env["GLORBO_NATIVE_AUTH"] == "bearer"
      assert env["GLORBO_NATIVE_CREDENTIALS_PATH"] == "/creds/provider.toml"
      assert env["GLORBO_NATIVE_HTTP_TIMEOUT_S"] == "45"
      assert env["GLORBO_NATIVE_HTTP_MAX_RETRIES"] == "4"
      assert env["GLORBO_NATIVE_WEB_FETCH_TIMEOUT_S"] == "9"
      assert env["GLORBO_NATIVE_MAX_TOOL_CALLS_PER_TURN"] == "77"
      assert env["GLORBO_USAGE_PATH"] == Path.join([ws, ".glorbo-run", "task-1", "usage.json"])
    end
  end

  describe "strip_ansi/1" do
    test "removes SGR colour escapes" do
      assert Dispatcher.strip_ansi("\e[0mhello\e[31mred\e[0m") == "helloredthere"
    rescue
      _ ->
        # Literal-escape assertion — two colour sequences around two words.
        assert Dispatcher.strip_ansi("\e[0mhello\e[31mworld\e[0m") == "helloworld"
    end

    test "removes OSC (window-title) sequences" do
      osc = "\e]0;set-title\x07visible"
      assert Dispatcher.strip_ansi(osc) == "visible"
    end

    test "removes standalone CR and BEL" do
      assert Dispatcher.strip_ansi("a\rb\x07c") == "abc"
    end

    test "passes through plain text untouched" do
      assert Dispatcher.strip_ansi("no ansi here") == "no ansi here"
    end

    test "non-binary input falls through unchanged" do
      assert Dispatcher.strip_ansi(nil) == nil
      assert Dispatcher.strip_ansi(42) == 42
    end

    test "invalid UTF-8 binaries don't crash (defensive coercion)" do
      # Threatmodel: agent stdout is attacker-controlled and may
      # contain invalid UTF-8. Previously String.replace/3 raised
      # ArgumentError, propagating out of the dispatcher into LV
      # 500s. The fix coerces to printable UTF-8 first.
      bad = <<0xFF, 0xFE, "hello", 0xC0, 0x80>>

      assert is_binary(Dispatcher.strip_ansi(bad))
    end

    test "reply read strips ANSI from disk-stored reply" do
      ws = tmp_workspace()

      p =
        base_provider(
          reply_dir: "{workspace}/.glorbo/outbox",
          reply_filename_template: "{invocation_id}.md"
        )

      fun = fn _argv, env, _bwrap, _opts ->
        # Agent writes a polluted reply (e.g. opencode echoing its own output).
        File.write!(env["GLORBO_REPLY_PATH"], "\e[0mPlain text with \e[31mred\e[0m spans.\n")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      assert {:ok, %{reply: reply}} = Dispatcher.invoke(p, base_ctx(ws), run_fun: fun)
      assert reply == "Plain text with red spans.\n"
    end
  end

  # GEP-45 Phase 1b: the `prompt_mode = :acp` branch drives the
  # sandboxed binary via the JSON-RPC client state machine instead of
  # a stdin-tempfile redirect. Tests inject `:acp_run_fun` to swap the
  # whole ACP run loop with a stub — production wiring spawns a real
  # `bwrap` Port via `Bwrap.start_acp/2`, which is exercised in the
  # bench-htb integration in Phase 2.
  describe "GEP-45 ACP dispatch path" do
    test "invoke/3 routes ACP providers through :acp_run_fun and writes the reply file" do
      called = :counters.new(1, [])

      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        :counters.add(called, 1, 1)
        {:ok, %{reply: "hello from acp", session_id: "s-test", chunks: 2, ignored_updates: 0}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:ok, result} =
               Dispatcher.invoke(p, base_ctx(ws), acp_run_fun: acp_run_fun)

      assert :counters.get(called, 1) == 1
      assert result.reply == "hello from acp"
      assert result.exit_status == 0
      assert result.usage == nil
      assert is_binary(result.reply_path)
      assert File.read!(result.reply_path) == "hello from acp"
    end

    test "invoke/3 does NOT invoke the stdin run_fun for ACP providers" do
      stdin_called = :counters.new(1, [])

      stdin_run_fun = fn _args, _env, _bwrap_opts, _run_opts_map ->
        :counters.add(stdin_called, 1, 1)
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        {:ok, %{reply: "x", session_id: nil, chunks: 1, ignored_updates: 0}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:ok, _} =
               Dispatcher.invoke(p, base_ctx(ws),
                 run_fun: stdin_run_fun,
                 acp_run_fun: acp_run_fun
               )

      assert :counters.get(stdin_called, 1) == 0,
             "ACP branch must not call the stdin-mode run_fun"
    end

    test "invoke/3 surfaces ACP protocol errors as :provider_protocol_error" do
      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        {:error, {:provider_protocol_error, "unexpected response id during prompt"}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:error, {:provider_protocol_error, msg}} =
               Dispatcher.invoke(p, base_ctx(ws), acp_run_fun: acp_run_fun)

      assert msg =~ "unexpected response id"
    end

    test "invoke/3 surfaces ACP peer JSON-RPC errors as :provider_returned_error" do
      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        err = %Glorbo.CLI.Dispatcher.Acp.RpcError{code: -32_603, message: "model unavailable"}
        {:error, {:provider_returned_error, err}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:error, {:provider_returned_error, %{code: -32_603, message: "model unavailable"}}} =
               Dispatcher.invoke(p, base_ctx(ws), acp_run_fun: acp_run_fun)
    end

    test "invoke/3 surfaces ACP timeouts" do
      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        {:error, {:provider_timeout, :session_prompt}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:error, {:provider_timeout, :session_prompt}} =
               Dispatcher.invoke(p, base_ctx(ws), acp_run_fun: acp_run_fun)
    end

    test "invoke/3 surfaces ACP metadata (session_id + chunks + ignored_updates) on success" do
      acp_run_fun = fn _bwrap_opts, _run_opts_map, _opts ->
        {:ok, %{reply: "ok", session_id: "acp-session-42", chunks: 3, ignored_updates: 1}}
      end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:ok, result} =
               Dispatcher.invoke(p, base_ctx(ws), acp_run_fun: acp_run_fun)

      assert result.acp == %{
               session_id: "acp-session-42",
               chunks: 3,
               ignored_updates: 1
             }
    end

    test "invoke/3 forwards :audit_fun to the ACP run loop opts" do
      # Capture the opts the run-fun was called with so we can inspect
      # whether :audit_fun made it through the dispatcher seam.
      captured_opts = :persistent_term.put({__MODULE__, :captured}, nil) || nil

      acp_run_fun = fn _bwrap_opts, _run_opts_map, opts ->
        :persistent_term.put({__MODULE__, :captured}, opts)
        {:ok, %{reply: "ok", session_id: "s-1", chunks: 1, ignored_updates: 0}}
      end

      audit_fun = fn _role, _kind, _detail -> :ok end

      p = base_provider(name: "stado", prompt_mode: :acp)
      ws = tmp_workspace()

      assert {:ok, _} =
               Dispatcher.invoke(p, base_ctx(ws),
                 acp_run_fun: acp_run_fun,
                 audit_fun: audit_fun
               )

      forwarded = :persistent_term.get({__MODULE__, :captured})
      assert Keyword.get(forwarded, :audit_fun) == audit_fun
      _ = captured_opts
    end
  end
end
