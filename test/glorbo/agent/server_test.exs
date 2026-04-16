defmodule Glorbo.Agent.ServerTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.Server, as: AgentServer
  alias Glorbo.Agent.Spec

  setup do
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
      file_path: "/tmp/agent.md"
    }

    reg_name = :"srv_reg_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: reg_name})

    task_sup_name = :"srv_task_sup_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: task_sup_name})

    {:ok, test_pid: pid, spec: spec, registry: reg_name, task_supervisor: task_sup_name}
  end

  # Dispatch fun that sends the Task's own pid to the test process and blocks
  # until the test sends `{:finish, result}` to that pid. Gives tests precise
  # control over completion ordering.
  defp blocking_dispatch(test_pid) do
    fn _spec, task, _opts ->
      send(test_pid, {:dispatch_started, task.task_id, self()})

      receive do
        {:finish, result} -> result
      after
        5_000 -> {:error, :timeout}
      end
    end
  end

  defp start_server(ctx, extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          spec: ctx.spec,
          company: "acme",
          task_supervisor: ctx.task_supervisor,
          registry: ctx.registry,
          name: :"srv_#{System.unique_integer([:positive])}"
        ],
        extra_opts
      )

    start_supervised!({AgentServer, opts})
  end

  defp sample_task(id \\ "t-001") do
    %{task_id: id, task_path: "projects/foo/t.md", prompt: "x", trigger: :inbox}
  end

  # Poll the server status until it reaches the desired state, up to ~2s.
  # Robust against system-load-induced jitter in :DOWN propagation.
  defp await_state(pid, desired_state, attempts \\ 100) do
    status = AgentServer.status(pid)

    cond do
      status.state == desired_state ->
        status

      attempts <= 0 ->
        status

      true ->
        Process.sleep(20)
        await_state(pid, desired_state, attempts - 1)
    end
  end

  # ---------------------------------------------------------------------------
  # A1 — register via registry
  # ---------------------------------------------------------------------------

  test "A1: start_link registers in the configured registry", ctx do
    reg_name = ctx.registry

    _pid =
      start_supervised!(
        {AgentServer,
         spec: ctx.spec,
         company: "acme",
         task_supervisor: ctx.task_supervisor,
         registry: reg_name,
         name: {:via, Registry, {reg_name, {:agent_server, "acme", "engineer"}}}}
      )

    assert [{_pid, _}] = Registry.lookup(reg_name, {:agent_server, "acme", "engineer"})
  end

  # ---------------------------------------------------------------------------
  # A2 — initial status
  # ---------------------------------------------------------------------------

  test "A2: status/1 on fresh server shows :idle", ctx do
    pid = start_server(ctx)

    assert %{state: :idle, current_task: nil, pending_wake: nil, last_exit_status: nil} =
             AgentServer.status(pid)
  end

  # ---------------------------------------------------------------------------
  # A3 — wake(:inbox, task) dispatches
  # ---------------------------------------------------------------------------

  test "A3: wake with an explicit task starts a dispatch and returns :busy", ctx do
    pid = start_server(ctx, dispatch_fun: blocking_dispatch(ctx.test_pid))

    assert :ok = AgentServer.wake(pid, :inbox, sample_task())

    assert_receive {:dispatch_started, "t-001", task_pid}, 1_000
    assert is_pid(task_pid)
    assert %{state: :busy, current_task: "t-001"} = AgentServer.status(pid)
  end

  # ---------------------------------------------------------------------------
  # A4, A5 — queue dedup while busy
  # ---------------------------------------------------------------------------

  test "A4: second wake while busy sets pending_wake", ctx do
    pid = start_server(ctx, dispatch_fun: blocking_dispatch(ctx.test_pid))

    :ok = AgentServer.wake(pid, :inbox, sample_task())
    assert_receive {:dispatch_started, "t-001", _}, 1_000

    :ok = AgentServer.wake(pid, :heartbeat, nil)

    status = AgentServer.status(pid)
    assert match?({:heartbeat, %DateTime{}}, status.pending_wake)
  end

  test "A5: third wake replaces pending_wake trigger (most-recent wins)", ctx do
    pid = start_server(ctx, dispatch_fun: blocking_dispatch(ctx.test_pid))

    :ok = AgentServer.wake(pid, :inbox, sample_task())
    assert_receive {:dispatch_started, "t-001", _}, 1_000

    :ok = AgentServer.wake(pid, :heartbeat, nil)
    :ok = AgentServer.wake(pid, :mention, nil)

    status = AgentServer.status(pid)
    assert match?({:mention, %DateTime{}}, status.pending_wake)
  end

  # ---------------------------------------------------------------------------
  # A6 — completion pops pending_wake + runs next dispatch
  # ---------------------------------------------------------------------------

  test "A6: dispatch completion pops pending wake and runs next dispatch", ctx do
    inbox_fun = fn _spec -> sample_task("t-002") end

    pid =
      start_server(ctx,
        dispatch_fun: blocking_dispatch(ctx.test_pid),
        inbox_scan_fun: inbox_fun
      )

    :ok = AgentServer.wake(pid, :inbox, sample_task("t-001"))
    assert_receive {:dispatch_started, "t-001", first_task_pid}, 1_000

    :ok = AgentServer.wake(pid, :heartbeat, nil)

    # Complete the first dispatch precisely.
    send(first_task_pid, {:finish, {:ok, %{exit_status: 0}}})

    # Next dispatch should start automatically.
    assert_receive {:dispatch_started, "t-002", _}, 1_000
  end

  # ---------------------------------------------------------------------------
  # A7 — dispatch error path returns to idle and records status
  # ---------------------------------------------------------------------------

  test "A7: dispatch error updates last_exit_status and returns to idle", ctx do
    pid = start_server(ctx, dispatch_fun: blocking_dispatch(ctx.test_pid))

    :ok = AgentServer.wake(pid, :inbox, sample_task())
    assert_receive {:dispatch_started, "t-001", task_pid}, 1_000

    send(task_pid, {:finish, {:error, :fake_failure}})

    status = await_state(pid, :idle)
    assert status.state == :idle
    assert status.last_exit_status == {:error, :fake_failure}
  end

  # ---------------------------------------------------------------------------
  # A8 — unknown trigger
  # ---------------------------------------------------------------------------

  test "A8: wake with unknown trigger returns {:error, :unknown_trigger}", ctx do
    pid = start_server(ctx)
    assert {:error, :unknown_trigger} = AgentServer.wake(pid, :bogus, sample_task())
    assert %{state: :idle} = AgentServer.status(pid)
  end

  # ---------------------------------------------------------------------------
  # A9 — Task crash does NOT take down Agent.Server (async_nolink)
  # ---------------------------------------------------------------------------

  test "A9: dispatch Task crash leaves Agent.Server alive and transitions to idle", ctx do
    dispatch_fun = fn _spec, _task, _opts -> raise "kaboom" end
    pid = start_server(ctx, dispatch_fun: dispatch_fun)

    :ok = AgentServer.wake(pid, :inbox, sample_task())

    # Poll up to 2s for the :DOWN to propagate — under full-suite load the
    # raise → crash → monitor-DOWN chain can take >50ms.
    assert Process.alive?(pid)
    status = await_state(pid, :idle)
    assert status.state == :idle
    assert match?({:crashed, _}, status.last_exit_status)
  end

  # ---------------------------------------------------------------------------
  # A10 — heartbeat wake with no task uses inbox_scan_fun
  # ---------------------------------------------------------------------------

  test "A10: heartbeat with no task uses inbox_scan_fun", ctx do
    inbox_fun = fn _spec -> sample_task("from-inbox-scan") end

    pid =
      start_server(ctx,
        dispatch_fun: blocking_dispatch(ctx.test_pid),
        inbox_scan_fun: inbox_fun
      )

    :ok = AgentServer.wake(pid, :heartbeat, nil)

    assert_receive {:dispatch_started, "from-inbox-scan", _}, 1_000
  end

  test "A10b: heartbeat wake with empty inbox stays idle", ctx do
    pid = start_server(ctx, inbox_scan_fun: fn _ -> nil end)
    :ok = AgentServer.wake(pid, :heartbeat, nil)
    Process.sleep(20)
    assert %{state: :idle} = AgentServer.status(pid)
  end
end
