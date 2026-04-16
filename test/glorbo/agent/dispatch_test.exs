defmodule Glorbo.Agent.DispatchTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Dispatch
  alias Glorbo.Agent.Spec
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
      file_path: Path.join([base, "companies", "acme", "agents", "engineer", "agent.md"])
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

  defp stub_adapter_module do
    Glorbo.Agent.DispatchTest.StubAdapter
  end

  defp stub_registry do
    %{"claude-code" => stub_adapter_module()}
  end

  # ---------------------------------------------------------------------------
  # D1 — happy path via dep-injected run_fun
  # ---------------------------------------------------------------------------

  test "D1: successful dispatch returns {:ok, %{exit_status, usage, duration_ms}}", ctx do
    run_fun = fn argv, env, _spec ->
      send(self(), {:ran, argv, env})
      {:ok, %{exit_status: 0, stdout: "stdout_bytes"}}
    end

    record_pid = self()

    record_fun = fn _spec, _task, usage ->
      send(record_pid, {:recorded, usage})
      :ok
    end

    assert {:ok, %{exit_status: 0, duration_ms: d, usage: usage}} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun,
               record_usage_fun: record_fun,
               clock_fun: seq_clock([100, 250])
             )

    assert d == 150
    assert usage.prompt_tokens == 42
    assert_received {:recorded, %{prompt_tokens: 42}}
    assert_received {:audit, %{action: "agent.dispatch"}}
    assert_received {:audit, %{action: "agent.complete", duration_ms: 150}}
  end

  # ---------------------------------------------------------------------------
  # D2 — budget hard-stop short-circuits before run_fun
  # ---------------------------------------------------------------------------

  test "D2: budget hard-stop returns {:stopped, :budget_hard_stop}, no run", ctx do
    called = :ets.new(:called, [:public, :set])

    run_fun = fn _argv, _env, _spec ->
      :ets.insert(called, {:ran, true})
      {:ok, %{exit_status: 0}}
    end

    assert {:stopped, :budget_hard_stop} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               budget_tracker_fun: fn _ -> {:stop, 500, 500} end,
               audit_fun: ctx.audit_fun
             )

    refute :ets.member(called, :ran)
  end

  # ---------------------------------------------------------------------------
  # D3 — skills flow: materialise pre-dispatch, cleanup post-dispatch
  # ---------------------------------------------------------------------------

  test "D3: skills materialised + cleanup runs on success", ctx do
    # Place a real skill on disk
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

    run_fun = fn _argv, _env, _spec ->
      # Assert skills are materialised while run_fun is running
      assert File.exists?(Path.join([run_dir, ".glorbo-skills", "test-skill.md"]))
      assert File.exists?(Path.join([run_dir, ".glorbo-skills", "INDEX.md"]))
      {:ok, %{exit_status: 0}}
    end

    assert {:ok, _} =
             Dispatch.execute(spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )

    # After dispatch, run_dir must be cleaned up
    refute File.exists?(run_dir)
  end

  test "D3b: cleanup runs even when run_fun returns error", ctx do
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

    run_fun = fn _argv, _env, _spec -> {:error, :fake_failure} end

    assert {:error, :fake_failure} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )

    refute File.exists?(run_dir)
  end

  # ---------------------------------------------------------------------------
  # D4 — prompt size cap (Pitfall 8 / T-03-23)
  # ---------------------------------------------------------------------------

  test "D4: prompt larger than 5MB returns {:error, :prompt_too_large}", ctx do
    big = :binary.copy("A", 5 * 1024 * 1024 + 1)
    task = %{ctx.task | prompt: big}

    assert {:error, :prompt_too_large} =
             Dispatch.execute(ctx.spec, task,
               base: ctx.base,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )
  end

  test "prompt file is written to run_dir before run_fun is called", ctx do
    parent = self()

    run_fun = fn _argv, _env, _spec ->
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
      {:ok, %{exit_status: 0}}
    end

    assert {:ok, _} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:prompt_exists, true}
  end

  # ---------------------------------------------------------------------------
  # D5 — model fallback when adapter returns nil
  # ---------------------------------------------------------------------------

  test "D5: model fallback to spec.model when parsed usage has model=nil", ctx do
    parent = self()

    record_fun = fn _spec, _task, usage ->
      send(parent, {:recorded, usage})
      :ok
    end

    run_fun = fn _argv, _env, _spec -> {:ok, %{exit_status: 0, stdout: "x"}} end

    assert {:ok, _} =
             Dispatch.execute(%{ctx.spec | provider: "nm"}, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: %{"nm" => Glorbo.Agent.DispatchTest.NilModelAdapter},
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun,
               record_usage_fun: record_fun
             )

    assert_received {:recorded, %{model: "claude-opus-4-6"}}
  end

  # ---------------------------------------------------------------------------
  # D6 — audit emissions bracket the run
  # ---------------------------------------------------------------------------

  test "D6: agent.dispatch + agent.complete audits emitted", ctx do
    run_fun = fn _argv, _env, _spec -> {:ok, %{exit_status: 0, stdout: "x"}} end

    assert {:ok, _} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:audit, %{action: "agent.dispatch", provider: "claude-code"}}
    assert_received {:audit, %{action: "agent.complete"}}
  end

  # ---------------------------------------------------------------------------
  # D7 — timeout returns error, cleanup still runs
  # ---------------------------------------------------------------------------

  test "D7: run_fun timeout is surfaced, cleanup still runs", ctx do
    run_fun = fn _argv, _env, _spec -> {:error, :timeout} end

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
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )

    refute File.exists?(run_dir)
  end

  # ---------------------------------------------------------------------------
  # D8 — provider.unavailable when adapter binary is nil
  # ---------------------------------------------------------------------------

  test "D8: missing CLI binary → provider.unavailable audit + {:error, :provider_unavailable}",
       ctx do
    run_called = :ets.new(:run_called, [:public, :set])

    run_fun = fn _argv, _env, _spec ->
      :ets.insert(run_called, {:x, true})
      {:ok, %{}}
    end

    assert {:error, :provider_unavailable} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               run_fun: run_fun,
               adapter_registry: stub_registry(),
               # Simulate missing binary
               binary_fun: fn _ -> nil end,
               audit_fun: ctx.audit_fun
             )

    assert_received {:audit, %{action: "provider.unavailable", provider: "claude-code"}}
    refute :ets.member(run_called, :x)
  end

  # ---------------------------------------------------------------------------
  # Bwrap-not-wired default
  # ---------------------------------------------------------------------------

  test "default run_fun returns :bwrap_not_wired (Plan 03-05 hook point)", ctx do
    assert {:error, :bwrap_not_wired} =
             Dispatch.execute(ctx.spec, ctx.task,
               base: ctx.base,
               adapter_registry: stub_registry(),
               binary_fun: fn _ -> "/fake/bin" end,
               audit_fun: ctx.audit_fun
             )
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
