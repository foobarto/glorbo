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
