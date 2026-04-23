defmodule Glorbo.Agent.DispatchTest do
  @moduledoc """
  Post-GEP-8: exercises the full dispatch pipeline with a fake Provider
  and run_fun. Provider resolution bypasses the real Registry via the
  :provider_fun dep-inject seam.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Dispatch
  alias Glorbo.Agent.Spec
  alias Glorbo.CLI.Registry.Provider
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    pid = self()

    # GEP-27: ensure the ETS grant store exists for dispatch tests
    Glorbo.PathGrantStore.ensure_started()

    spec = %Spec{
      slug: "engineer",
      company: "acme",
      role: "x",
      provider: "claude-code",
      model: "claude-opus-4-6",
      permissions: [],
      heartbeat: nil,
      network: :none,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 300,
      allow_untracked_budget: false,
      file_path: Path.join([base, "companies", "acme", "agents", "engineer", "AGENT.md"])
    }

    task = %{
      task_id: "t-001",
      task_path: "projects/foo/tasks/t-001.md",
      prompt: "do the thing",
      trigger: :inbox
    }

    audit_fun = fn _company, entry -> send(pid, {:audit, entry}) end

    {:ok, base: base, spec: spec, task: task, audit_fun: audit_fun}
  end

  defp stub_provider(overrides \\ []) do
    struct!(
      %Provider{
        name: "claude-code",
        binary: "/fake/claude",
        resolved_path: "/fake/claude",
        installed?: true,
        args: ["--print"],
        reply_dir: "{workspace}/.glorbo/outbox",
        reply_filename_template: "{invocation_id}.md",
        usage_parser: "gemini_stdout",
        usage_path: %{kind: :stdout, path: nil},
        source: :builtin,
        source_file: "<test>"
      },
      overrides
    )
  end

  # A run_fun that writes a canned reply and returns exit 0 + stdout.
  defp writer(stdout \\ "") do
    fn _args, env, _bwrap, _run_opts ->
      File.write!(env["GLORBO_REPLY_PATH"], "reply body")
      {:ok, %{exit_status: 0, stdout: stdout, usage_dir: nil}}
    end
  end

  # ---------------------------------------------------------------------------
  # D1 — happy path
  # ---------------------------------------------------------------------------

  test "D1: successful dispatch returns {:ok, %{exit_status, usage, duration_ms}}", ctx do
    record_pid = self()

    record_fun = fn _spec, _task, usage ->
      send(record_pid, {:recorded, usage})
      :ok
    end

    gemini_blob =
      ~s|{"stats":{"models":{"claude":{"tokens":{"prompt":42,"candidates":7}}}}}|

    assert {:ok, %{exit_status: 0, duration_ms: d, usage: usage}} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: writer(gemini_blob),
               provider_fun: fn "claude-code" -> stub_provider() end,
               audit_fun: ctx.audit_fun,
               record_usage_fun: record_fun,
               clock_fun: seq_clock([100, 250])
             )

    assert d == 150
    assert usage.prompt_tokens == 42
    assert usage.completion_tokens == 7
    assert_received {:recorded, %{prompt_tokens: 42}}
    assert_received {:audit, %{action: "agent.dispatch"}}
    assert_received {:audit, %{action: "agent.complete", duration_ms: 150}}
  end

  # ---------------------------------------------------------------------------
  # D2 — budget hard-stop short-circuits before dispatch
  # ---------------------------------------------------------------------------

  test "D2: budget hard-stop returns {:stopped, :budget_hard_stop}, no run", ctx do
    called = :ets.new(:called, [:public, :set])

    run_fun = fn _a, _e, _b, _r ->
      :ets.insert(called, {:ran, true})
      {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
    end

    assert {:stopped, :budget_hard_stop} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> stub_provider() end,
               budget_tracker_fun: fn _ -> {:stop, 500, 500} end,
               audit_fun: ctx.audit_fun
             )

    refute :ets.member(called, :ran)
  end

  # ---------------------------------------------------------------------------
  # D3 — skills flow: materialise pre-dispatch, cleanup post-dispatch
  # ---------------------------------------------------------------------------

  test "D3: skills materialised + cleanup runs on success", ctx do
    File.mkdir_p!(Path.join(ctx.base, "skills"))
    File.write!(Path.join([ctx.base, "skills", "test-skill.md"]), "# test-skill\n\nBody\n")

    spec = %{ctx.spec | skills: ["test-skill"]}

    run_dir =
      Path.join([
        ctx.base,
        "companies",
        "acme",
        "agents",
        "engineer",
        "workspace",
        ".glorbo-run",
        ctx.task.task_id
      ])

    run_fun = fn _a, env, _b, _r ->
      assert File.exists?(Path.join([run_dir, ".glorbo-skills", "test-skill.md"]))
      assert File.exists?(Path.join([run_dir, ".glorbo-skills", "INDEX.md"]))
      File.write!(env["GLORBO_REPLY_PATH"], "ok")
      {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
    end

    assert {:ok, _} =
             Dispatch.execute(spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> stub_provider() end,
               audit_fun: ctx.audit_fun
             )

    refute File.exists?(run_dir)
  end

  test "D3b: cleanup runs even when Dispatcher returns error", ctx do
    run_dir =
      Path.join([
        ctx.base,
        "companies",
        "acme",
        "agents",
        "engineer",
        "workspace",
        ".glorbo-run",
        ctx.task.task_id
      ])

    # Silent run_fun → reply file missing → Dispatcher errors
    silent = fn _a, _e, _b, _r -> {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}} end

    assert {:error, :reply_file_missing} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: silent,
               provider_fun: fn _ -> stub_provider() end,
               audit_fun: ctx.audit_fun
             )

    refute File.exists?(run_dir)
  end

  # ---------------------------------------------------------------------------
  # D4 — prompt size cap
  # ---------------------------------------------------------------------------

  test "D4: prompt larger than 5MB returns {:error, :prompt_too_large}", ctx do
    big = :binary.copy("A", 5 * 1024 * 1024 + 1)
    task = %{ctx.task | prompt: big}

    assert {:error, :prompt_too_large} =
             Dispatch.execute(ctx.spec, task,
               base: ctx.base,
               provider_fun: fn _ -> stub_provider() end,
               audit_fun: ctx.audit_fun
             )
  end

  test "prompt file is written to run_dir before run_fun is called", ctx do
    parent = self()

    run_fun = fn _a, env, _b, _r ->
      run_dir =
        Path.join([
          ctx.base,
          "companies",
          "acme",
          "agents",
          "engineer",
          "workspace",
          ".glorbo-run",
          ctx.task.task_id
        ])

      send(parent, {:prompt_exists, File.exists?(Path.join(run_dir, "task-prompt.md"))})
      File.write!(env["GLORBO_REPLY_PATH"], "ok")
      {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
    end

    assert {:ok, _} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> stub_provider() end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:prompt_exists, true}
  end

  # T3 — symlink-swap defense on the run_dir path. A malicious agent could
  # pre-create `.glorbo-run/<task_id>/` as a symlink to a sensitive host
  # directory (e.g. ~/.glorbo/) so that the subsequent prompt write
  # escapes the sandbox. The dispatch pipeline must refuse to use a
  # non-directory run_dir.
  test "T3: pre-existing run_dir symlink is rejected before prompt write", ctx do
    workspace_run =
      Path.join([
        ctx.base,
        "companies",
        "acme",
        "agents",
        "engineer",
        "workspace",
        ".glorbo-run"
      ])

    File.mkdir_p!(workspace_run)

    # Point `.glorbo-run/t-001` at a "sensitive" directory the attacker
    # shouldn't be able to influence.
    sensitive = Path.join(ctx.base, "sensitive-dir")
    File.mkdir_p!(sensitive)
    File.write!(Path.join(sensitive, "config.md"), "secret: keep-me\n")

    File.ln_s!(sensitive, Path.join(workspace_run, "t-001"))

    run_fun = fn _a, _e, _b, _r ->
      flunk("run_fun must not be called when run_dir is a symlink")
    end

    assert_raise File.Error, ~r/not_a_regular_directory|prepare run_dir/, fn ->
      Dispatch.execute(ctx.spec, ctx.task,
        base: ctx.base,
        run_fun: run_fun,
        provider_fun: fn _ -> stub_provider() end,
        audit_fun: ctx.audit_fun
      )
    end

    # Sensitive target was not written to.
    assert File.read!(Path.join(sensitive, "config.md")) == "secret: keep-me\n"
    refute File.exists?(Path.join(sensitive, "task-prompt.md"))
  end

  # T3 — paired defense: even when run_dir itself is a real directory,
  # a symlinked `task-prompt.md` inside it would still redirect the
  # write. Reject it.
  test "T3: pre-existing prompt-file symlink inside run_dir is rejected",
       ctx do
    run_dir =
      Path.join([
        ctx.base,
        "companies",
        "acme",
        "agents",
        "engineer",
        "workspace",
        ".glorbo-run",
        "t-001"
      ])

    File.mkdir_p!(run_dir)

    sensitive = Path.join(ctx.base, "outside.md")
    File.write!(sensitive, "do not touch")

    File.ln_s!(sensitive, Path.join(run_dir, "task-prompt.md"))

    run_fun = fn _a, _e, _b, _r ->
      flunk("run_fun must not be called when task-prompt.md is a symlink")
    end

    assert_raise File.Error, ~r/not_a_regular_file|prepare task-prompt/, fn ->
      Dispatch.execute(ctx.spec, ctx.task,
        base: ctx.base,
        run_fun: run_fun,
        provider_fun: fn _ -> stub_provider() end,
        audit_fun: ctx.audit_fun
      )
    end

    assert File.read!(sensitive) == "do not touch"
  end

  # ---------------------------------------------------------------------------
  # D5 — model fallback when parsed usage has model=nil
  # ---------------------------------------------------------------------------

  test "D5: model fallback to spec.model when parsed usage has model=nil", ctx do
    parent = self()

    record_fun = fn _spec, _task, usage ->
      send(parent, {:recorded, usage})
      :ok
    end

    # Parser returns {:ok, %{..., model: nil}} (e.g. codex)
    # We stub with codex-shaped provider where the parser would return nil.
    # Simpler: use a fake stdout blob that leaves model unset in output.
    no_model_blob = ~s|{"stats":{"models":{}}}|

    provider =
      stub_provider(
        usage_parser: "gemini_stdout",
        usage_path: %{kind: :stdout, path: nil}
      )

    # usage will be {:error, :no_stats}; finalize_usage falls back to zeros +
    # spec.model. Matches the D5 invariant: record with spec.model.
    assert {:ok, _} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: writer(no_model_blob),
               provider_fun: fn _ -> provider end,
               audit_fun: ctx.audit_fun,
               record_usage_fun: record_fun
             )

    assert_received {:recorded, %{model: "claude-opus-4-6"}}
  end

  # ---------------------------------------------------------------------------
  # D6 — audit emissions bracket the run
  # ---------------------------------------------------------------------------

  test "D6: agent.dispatch + agent.complete audits emitted", ctx do
    spec = %{ctx.spec | allow_untracked_budget: true}

    assert {:ok, _} =
             Dispatch.execute(spec, ctx.task,
               base: ctx.base,
               run_fun: writer("{}"),
               provider_fun: fn _ -> stub_provider(usage_parser: "none") end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:audit, %{action: "agent.dispatch", provider: "claude-code"}}
    assert_received {:audit, %{action: "agent.complete"}}
  end

  # ---------------------------------------------------------------------------
  # D7 — timeout returns error, cleanup still runs
  # ---------------------------------------------------------------------------

  test "D7: run_fun error is surfaced, cleanup still runs", ctx do
    run_fun = fn _a, _e, _b, _r -> {:error, :timeout} end

    run_dir =
      Path.join([
        ctx.base,
        "companies",
        "acme",
        "agents",
        "engineer",
        "workspace",
        ".glorbo-run",
        ctx.task.task_id
      ])

    assert {:error, :timeout} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> stub_provider() end,
               audit_fun: ctx.audit_fun
             )

    refute File.exists?(run_dir)
  end

  # ---------------------------------------------------------------------------
  # D8 — provider.unavailable when provider isn't installed
  # ---------------------------------------------------------------------------

  test "D8: missing CLI binary → provider.unavailable audit + {:error, :provider_unavailable}",
       ctx do
    run_called = :ets.new(:run_called, [:public, :set])

    run_fun = fn _a, _e, _b, _r ->
      :ets.insert(run_called, {:x, true})
      {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
    end

    missing_provider = stub_provider(installed?: false, resolved_path: nil)

    assert {:error, :provider_unavailable} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> missing_provider end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:audit, %{action: "provider.unavailable", provider: "claude-code"}}
    refute :ets.member(run_called, :x)
  end

  test "D8b: native providers do not require resolved_path once installed", ctx do
    native_provider =
      stub_provider(
        name: "openai",
        kind: :native,
        binary: nil,
        resolved_path: nil,
        usage_parser: "native-v1",
        usage_path: %{kind: :json_file, path: "{workspace}/.glorbo-run/{task_id}/usage.json"}
      )

    run_fun = fn _args, env, _bwrap, run_opts ->
      assert run_opts.cli_binary == "/fake/glorbo"

      assert run_opts.cli_args == [
               "harness",
               "--provider",
               "openai",
               "--agent",
               "engineer",
               "--task",
               "t-001",
               "--model",
               "claude-opus-4-6"
             ]

      assert env["GLORBO_NATIVE_ENDPOINT"] == ""
      assert env["GLORBO_NATIVE_AUTH"] == ""
      assert env["GLORBO_NATIVE_CREDENTIALS_PATH"] == "/creds/provider.toml"

      usage_path = Path.join(run_opts.usage_dir, "usage.json")
      File.mkdir_p!(Path.dirname(usage_path))
      File.write!(usage_path, ~s({"tracked":true,"prompt_tokens":2,"completion_tokens":3}))
      File.write!(env["GLORBO_REPLY_PATH"], "native ok")
      {:ok, %{exit_status: 0, stdout: "", usage_dir: run_opts.usage_dir}}
    end

    assert {:ok, %{reply: "native ok", usage: %{prompt_tokens: 2, completion_tokens: 3}}} =
             Dispatch.execute(%{ctx.spec | provider: "openai"}, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> native_provider end,
               self_binary_fun: fn -> "/fake/glorbo" end,
               audit_fun: ctx.audit_fun
             )
  end

  # ---------------------------------------------------------------------------
  # D9 — unknown provider (not in registry)
  # ---------------------------------------------------------------------------

  test "D9: provider_fun returns nil → {:error, :unknown_provider}", ctx do
    assert {:error, :unknown_provider} =
             Dispatch.execute(%{ctx.spec | provider: "nonesuch"}, ctx.task,
               base: ctx.base,
               provider_fun: fn _ -> nil end,
               audit_fun: ctx.audit_fun
             )
  end

  # ---------------------------------------------------------------------------
  # D10 — untracked provider requires agent opt-in
  # ---------------------------------------------------------------------------

  test "D10: untracked provider without allow_untracked_budget refuses", ctx do
    untracked = stub_provider(usage_parser: "none", usage_path: nil)

    assert {:error, :untracked_disallowed} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: writer(),
               provider_fun: fn _ -> untracked end,
               audit_fun: ctx.audit_fun
             )
  end

  test "D10b: untracked provider with allow_untracked_budget: true routes", ctx do
    untracked = stub_provider(usage_parser: "none", usage_path: nil)
    spec = %{ctx.spec | allow_untracked_budget: true}

    assert {:ok, %{usage: %{prompt_tokens: 0, completion_tokens: 0}}} =
             Dispatch.execute(spec, ctx.task,
               base: ctx.base,
               run_fun: writer(),
               provider_fun: fn _ -> untracked end,
               audit_fun: ctx.audit_fun
             )
  end

  test "runtime tracked:false still requires allow_untracked_budget for native providers", ctx do
    native_provider =
      stub_provider(
        name: "openai",
        kind: :native,
        binary: nil,
        resolved_path: nil,
        usage_parser: "native-v1",
        usage_path: %{kind: :json_file, path: "{workspace}/.glorbo-run/{task_id}/usage.json"}
      )

    run_fun = fn _args, env, _bwrap, run_opts ->
      usage_path = Path.join(run_opts.usage_dir, "usage.json")
      File.mkdir_p!(Path.dirname(usage_path))
      File.write!(usage_path, ~s({"tracked":false,"prompt_tokens":0,"completion_tokens":0}))
      File.write!(env["GLORBO_REPLY_PATH"], "native ok")
      {:ok, %{exit_status: 0, stdout: "", usage_dir: run_opts.usage_dir}}
    end

    assert {:error, :untracked_disallowed} =
             Dispatch.execute(%{ctx.spec | provider: "openai"}, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               provider_fun: fn _ -> native_provider end,
               self_binary_fun: fn -> "/fake/glorbo" end,
               audit_fun: ctx.audit_fun
             )
  end

  # ---------------------------------------------------------------------------
  # Reply file is readable via result.reply
  # ---------------------------------------------------------------------------

  test "reply body is surfaced in the result", ctx do
    spec = %{ctx.spec | allow_untracked_budget: true}

    assert {:ok, %{reply: "reply body", reply_path: path}} =
             Dispatch.execute(spec, ctx.task,
               base: ctx.base,
               run_fun: writer(),
               provider_fun: fn _ -> stub_provider(usage_parser: "none") end,
               audit_fun: ctx.audit_fun
             )

    assert path =~ ".glorbo/outbox/"
  end

  # ---------------------------------------------------------------------------
  # #235 — per-task model/provider override
  # ---------------------------------------------------------------------------

  describe "task-level overrides (#235)" do
    test "task.model overrides spec.model in audit + usage", ctx do
      task = Map.put(ctx.task, :model, "claude-haiku-4-5")
      record_pid = self()

      record_fun = fn _s, _t, u ->
        send(record_pid, {:recorded, u})
        :ok
      end

      assert {:ok, _} =
               Dispatch.execute(ctx.spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: fn "claude-code" -> stub_provider() end,
                 audit_fun: ctx.audit_fun,
                 record_usage_fun: record_fun
               )

      assert_received {:audit, %{action: "agent.dispatch", model: "claude-haiku-4-5"}}
      assert_received {:recorded, %{model: "claude-haiku-4-5"}}
    end

    test "task.provider mismatch is ignored (threatmodel M10)", ctx do
      # threatmodel M10: honouring an agent-authored task.provider
      # let an agent with tasks:write swap to a more-privileged
      # provider whose auth_binds mount host secrets. The resolver
      # now pins to the agent spec's provider and logs the mismatch.
      task = Map.put(ctx.task, :provider, "codex")
      pid = self()

      provider_fun = fn name ->
        send(pid, {:resolved, name})
        stub_provider(name: name)
      end

      assert {:ok, _} =
               Dispatch.execute(ctx.spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: provider_fun,
                 audit_fun: ctx.audit_fun
               )

      # Spec pins `claude-code`; mismatched `codex` is ignored.
      assert_received {:resolved, "claude-code"}
      assert_received {:audit, %{action: "agent.dispatch", provider: "claude-code"}}
    end

    test "task.provider matching spec.provider resolves as before", ctx do
      task = Map.put(ctx.task, :provider, "claude-code")
      pid = self()

      provider_fun = fn name ->
        send(pid, {:resolved, name})
        stub_provider(name: name)
      end

      assert {:ok, _} =
               Dispatch.execute(ctx.spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: provider_fun,
                 audit_fun: ctx.audit_fun
               )

      assert_received {:resolved, "claude-code"}
    end

    test "blank task.model/provider falls back to spec", ctx do
      task = Map.merge(ctx.task, %{model: "", provider: nil})

      assert {:ok, _} =
               Dispatch.execute(ctx.spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: fn "claude-code" -> stub_provider() end,
                 audit_fun: ctx.audit_fun
               )

      assert_received {:audit,
                       %{
                         action: "agent.dispatch",
                         model: "claude-opus-4-6",
                         provider: "claude-code"
                       }}
    end

    test "unknown task.provider surfaces {:unknown_provider, name}", ctx do
      task = Map.put(ctx.task, :provider, "ghost")

      assert {:error, :unknown_provider} =
               Dispatch.execute(ctx.spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: fn _ -> nil end,
                 audit_fun: ctx.audit_fun
               )
    end

    # ---------------------------------------------------------------------
    # #236 — model aliases in spec.models
    # ---------------------------------------------------------------------

    test "#236: task.model matching a spec alias expands to the concrete model", ctx do
      spec = %{
        ctx.spec
        | models: %{
            "fast" => "claude-haiku-4-5",
            "reasoning" => "claude-opus-4-7"
          }
      }

      task = Map.put(ctx.task, :model, "fast")

      assert {:ok, _} =
               Dispatch.execute(spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: fn _ -> stub_provider() end,
                 audit_fun: ctx.audit_fun
               )

      assert_received {:audit, %{action: "agent.dispatch", model: "claude-haiku-4-5"}}
    end

    test "#236: concrete model names still pass through when no alias matches", ctx do
      spec = %{ctx.spec | models: %{"fast" => "claude-haiku-4-5"}}
      task = Map.put(ctx.task, :model, "claude-sonnet-4-6")

      assert {:ok, _} =
               Dispatch.execute(spec, task,
                 base: ctx.base,
                 run_fun: writer(""),
                 provider_fun: fn _ -> stub_provider() end,
                 audit_fun: ctx.audit_fun
               )

      assert_received {:audit, %{action: "agent.dispatch", model: "claude-sonnet-4-6"}}
    end
  end

  # ---------------------------------------------------------------------------
  # #248 T1-A — session resilience (auto-continue on timeout)
  # ---------------------------------------------------------------------------

  describe "retry-on-timeout (#248)" do
    test "retries :timeout failure up to max_retries, then surfaces the error",
         ctx do
      pid = self()

      # run_fun raises `:timeout` style error: stdout empty + no reply
      # file. Dispatcher sees `reply_file_missing`; that's retryable.
      silent = fn _a, _e, _b, _r ->
        send(pid, :attempted)
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      spec = %{ctx.spec | max_retries: 2}

      assert {:error, :reply_file_missing} =
               Dispatch.execute(spec, ctx.task,
                 base: ctx.base,
                 run_fun: silent,
                 provider_fun: fn _ -> stub_provider() end,
                 audit_fun: ctx.audit_fun
               )

      # Initial + 2 retries = 3 attempts.
      assert_received :attempted
      assert_received :attempted
      assert_received :attempted
      refute_received :attempted
    end

    test "max_retries: 0 means no retry", ctx do
      pid = self()

      silent = fn _a, _e, _b, _r ->
        send(pid, :attempted)
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      spec = %{ctx.spec | max_retries: 0}

      assert {:error, :reply_file_missing} =
               Dispatch.execute(spec, ctx.task,
                 base: ctx.base,
                 run_fun: silent,
                 provider_fun: fn _ -> stub_provider() end,
                 audit_fun: ctx.audit_fun
               )

      assert_received :attempted
      refute_received :attempted
    end

    test "non-retryable errors bubble up immediately without retry", ctx do
      pid = self()

      spec = %{ctx.spec | max_retries: 3}

      _result =
        Dispatch.execute(spec, ctx.task,
          base: ctx.base,
          provider_fun: fn _ ->
            send(pid, :provider_checked)
            nil
          end,
          audit_fun: ctx.audit_fun
        )

      # Only one provider check: unknown_provider is not retryable.
      assert_received :provider_checked
      refute_received :provider_checked
    end

    test "emits agent.retry audit per retry attempt", ctx do
      silent = fn _a, _e, _b, _r ->
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      spec = %{ctx.spec | max_retries: 2}

      Dispatch.execute(spec, ctx.task,
        base: ctx.base,
        run_fun: silent,
        provider_fun: fn _ -> stub_provider() end,
        audit_fun: ctx.audit_fun
      )

      # 2 retries = 2 `agent.retry` audit entries, each with a
      # growing `attempt` counter.
      assert_received {:audit, %{action: "agent.retry", attempt: 1}}
      assert_received {:audit, %{action: "agent.retry", attempt: 2}}
    end

    test "successful dispatch with no retry doesn't emit agent.retry", ctx do
      parent = self()

      writer_fun = fn _a, env, _b, _r ->
        File.write!(env["GLORBO_REPLY_PATH"], "ok")
        {:ok, %{exit_status: 0, stdout: "", usage_dir: nil}}
      end

      audit_fun = fn _company, entry ->
        if Map.get(entry, :action) == "agent.retry" do
          send(parent, :retry_audit)
        end
      end

      assert {:ok, _} =
               Dispatch.execute(ctx.spec, ctx.task,
                 base: ctx.base,
                 run_fun: writer_fun,
                 provider_fun: fn _ -> stub_provider() end,
                 audit_fun: audit_fun
               )

      refute_received :retry_audit
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seq_clock(values) do
    {:ok, agent} = Agent.start_link(fn -> values end)

    fn ->
      Agent.get_and_update(agent, fn
        [] -> {0, []}
        [h | t] -> {h, t}
      end)
    end
  end
end
