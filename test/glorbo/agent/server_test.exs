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
      network: :loopback,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 300,
      file_path: "/tmp/agent.md"
    }

    reg_name = Glorbo.Test.UniqueName.gen("srv_reg")
    start_supervised!({Registry, keys: :unique, name: reg_name})

    task_sup_name = Glorbo.Test.UniqueName.gen("srv_task_sup")
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
          name: Glorbo.Test.UniqueName.gen("srv")
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

  # ---------------------------------------------------------------------------
  # A11 — inbox drain after successful dispatch (task #123)
  #
  # E2E testing on 2026-04-18 found that completed inbox messages were never
  # removed, causing default_inbox_scan to re-pick the same oldest file on
  # every subsequent wake → infinite redispatch loop burning provider budget.
  # The fix: on successful completion of an :inbox/:mention-triggered
  # dispatch, move the file to history/processed/ so the next wake advances.
  # ---------------------------------------------------------------------------

  describe "A11 — inbox drain after successful dispatch" do
    defp setup_inbox_file(_ctx, filename, content \\ "---\nfrom: director\n---\n\nhi") do
      base = Path.join(System.tmp_dir!(), "drain-test-#{System.unique_integer([:positive])}")
      inbox_dir = Path.join([base, "companies", "acme", "agents", "engineer", "inbox"])
      File.mkdir_p!(inbox_dir)
      path = Path.join(inbox_dir, filename)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
      on_exit(fn -> File.rm_rf!(base) end)

      rel_path = Path.relative_to(path, Path.join([base, "companies", "acme"]))
      {base, rel_path, path}
    end

    test "successful :inbox dispatch moves file to history/processed/", ctx do
      {base, rel_path, src} = setup_inbox_file(ctx, "msg1.md")

      dispatch_fun = fn _spec, _task, _opts -> {:ok, %{exit_status: 0}} end
      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "msg1", task_path: rel_path, prompt: "hi", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      refute File.exists?(src), "inbox file must be removed after success"

      processed_dir =
        Path.join([base, "companies/acme/agents/engineer/history/processed"])

      assert {:ok, [moved]} = File.ls(processed_dir)
      assert String.ends_with?(moved, "-msg1.md")
    end

    test "successful :mention dispatch drains the mention file", ctx do
      {base, rel_path, src} = setup_inbox_file(ctx, "mentions/5-general.md")

      dispatch_fun = fn _spec, _task, _opts -> {:ok, %{exit_status: 0}} end
      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{
        task_id: "5-general",
        task_path: rel_path,
        prompt: "hi",
        trigger: :mention
      }

      :ok = AgentServer.wake(pid, :mention, task)
      await_state(pid, :idle)

      refute File.exists?(src)
      assert File.exists?(Path.dirname(src))

      processed = Path.join([base, "companies/acme/agents/engineer/history/processed"])
      assert {:ok, [_file]} = File.ls(processed)
    end

    test "non-zero exit leaves inbox file in place (retry-safe)", ctx do
      {base, rel_path, src} = setup_inbox_file(ctx, "oopsie.md")

      dispatch_fun = fn _spec, _task, _opts -> {:ok, %{exit_status: 1}} end
      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "oopsie", task_path: rel_path, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      assert File.exists?(src), "failed dispatch must preserve the inbox file"
    end

    test ":heartbeat trigger does not drain (task_path may belong elsewhere)", ctx do
      {base, rel_path, src} = setup_inbox_file(ctx, "keepme.md")

      dispatch_fun = fn _spec, _task, _opts -> {:ok, %{exit_status: 0}} end
      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      # Simulate a heartbeat that happens to have the inbox task_path —
      # drain still must not fire because the trigger isn't :inbox/:mention.
      task = %{task_id: "keepme", task_path: rel_path, prompt: "x", trigger: :heartbeat}
      :ok = AgentServer.wake(pid, :heartbeat, task)
      await_state(pid, :idle)

      assert File.exists?(src)
    end

    test "successful :director_request (no task_path) is a no-op", ctx do
      {base, _rel, _src} = setup_inbox_file(ctx, "other.md")

      dispatch_fun = fn _spec, _task, _opts -> {:ok, %{exit_status: 0}} end
      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "dir-1", task_path: nil, prompt: "tick", trigger: :director_request}
      :ok = AgentServer.wake(pid, :director_request, task)
      await_state(pid, :idle)

      # Nothing moved, nothing broken.
      processed_dir =
        Path.join([base, "companies/acme/agents/engineer/history/processed"])

      refute File.dir?(processed_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # A11b — C-076: poison inbox message (invalid derived task_id) must not
  # crash-loop the agent. A msg_id with uppercase/spaces yields a task_id
  # that Dispatch.validate_task_id! rejects by RAISING. The server must
  # quarantine + drain the poison file instead of dispatching it.
  # ---------------------------------------------------------------------------

  describe "A11b — poison inbox task_id (C-076)" do
    test "invalid task_id is quarantined, not dispatched, and agent stays idle", ctx do
      {base, rel_path, src} = setup_inbox_file(ctx, "1770000000000-BAD.md")

      # If a dispatch were ever started for the poison task it would crash;
      # this fun would mark that we got that far.
      test_pid = ctx.test_pid

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:should_not_dispatch, task.task_id})
        {:ok, %{exit_status: 0}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{
        task_id: "1770000000000-BAD",
        task_path: rel_path,
        prompt: "hi",
        trigger: :inbox
      }

      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      refute_received {:should_not_dispatch, _}
      assert Process.alive?(pid)
      assert %{state: :idle} = AgentServer.status(pid)

      # Poison file moved out of the inbox so the next wake advances.
      refute File.exists?(src), "poison file must be quarantined out of the inbox"

      rejections =
        Path.join([base, "companies/acme/agents/engineer/history/rejections"])

      assert {:ok, [moved]} = File.ls(rejections)
      assert String.ends_with?(moved, "-1770000000000-BAD.md")
    end
  end

  # ---------------------------------------------------------------------------
  # A11c — C-129: a throttled inbox dispatch must not spin in a retry loop.
  # The throttle result must re-queue into pending_wake (retry on next
  # slot-free) instead of immediately re-draining the same inbox file.
  # ---------------------------------------------------------------------------

  describe "A11c — throttled inbox dispatch (C-129)" do
    test "throttle does not immediately re-dispatch the same file", ctx do
      {base, rel_path, _src} = setup_inbox_file(ctx, "throttled.md")

      counter = :counters.new(1, [:atomics])
      test_pid = ctx.test_pid

      dispatch_fun = fn _spec, task, _opts ->
        :counters.add(counter, 1, 1)
        send(test_pid, {:dispatched, task.task_id, :counters.get(counter, 1)})
        {:throttled, :company_dispatch_cap}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "throttled", task_path: rel_path, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)

      assert_receive {:dispatched, "throttled", 1}, 1_000
      # No tight re-dispatch loop: the same file must NOT be re-dispatched
      # immediately while the cap is still saturated.
      refute_receive {:dispatched, "throttled", _}, 300

      assert Process.alive?(pid)
      # The file stays in the inbox (throttle is not a successful drain).
      assert File.exists?(Path.join([base, "companies", "acme", rel_path]))

      # And the work is re-queued for the next slot-free signal.
      assert %{pending_wake: {:inbox, _}} = :sys.get_state(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # A12 — reply routing after successful dispatch (task #124)
  #
  # On :inbox or :mention trigger with exit_status 0 and a reply, the server
  # synthesizes a Router-routable outbox envelope at agents/<slug>/outbox/
  # with a `to:` field derived from the source file's frontmatter. Without
  # this, replies land at GEP-8's {workspace}/.glorbo/outbox/ which Router
  # doesn't watch, and bidirectional chat breaks silently.
  # ---------------------------------------------------------------------------

  describe "A12 — reply routing to Router outbox" do
    defp setup_source_with_from(_ctx, filename, from_field) do
      base = Path.join(System.tmp_dir!(), "route-test-#{System.unique_integer([:positive])}")
      inbox_dir = Path.join([base, "companies", "acme", "agents", "engineer", "inbox"])
      File.mkdir_p!(inbox_dir)
      path = Path.join(inbox_dir, filename)
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      ---
      from: #{from_field}
      ---

      body
      """)

      on_exit(fn -> File.rm_rf!(base) end)
      rel = Path.relative_to(path, Path.join([base, "companies", "acme"]))
      {base, rel}
    end

    defp setup_mention_source(_ctx, filename, channel) do
      base = Path.join(System.tmp_dir!(), "route-test-#{System.unique_integer([:positive])}")
      inbox_dir = Path.join([base, "companies", "acme", "agents", "engineer", "inbox"])
      File.mkdir_p!(Path.dirname(Path.join(inbox_dir, filename)))
      path = Path.join(inbox_dir, filename)

      File.write!(path, """
      ---
      channel: #{channel}
      from: director
      ---

      body
      """)

      on_exit(fn -> File.rm_rf!(base) end)
      rel = Path.relative_to(path, Path.join([base, "companies", "acme"]))
      {base, rel}
    end

    test ":inbox reply to an agent writes outbox envelope with to: agent:<from>", ctx do
      {base, rel} = setup_source_with_from(ctx, "greet.md", "ceo")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: "HELLO BACK"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "greet", task_path: rel, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])
      assert {:ok, files} = File.ls(outbox)
      assert [file] = Enum.filter(files, &String.ends_with?(&1, ".md"))

      content = File.read!(Path.join(outbox, file))
      assert content =~ ~s(to: "agent:ceo")
      assert content =~ "HELLO BACK"
    end

    test ":inbox reply from Director is skipped (no outbox write)", ctx do
      # Director isn't an agent; replying to "agent:director" would be
      # rejected by Router. Director reads replies via the dashboard.
      {base, rel} = setup_source_with_from(ctx, "dir-msg.md", "director")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: "reply body"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "dir-msg", task_path: rel, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])

      files =
        case File.ls(outbox),
          do: (
            {:ok, f} -> f
            _ -> []
          )

      assert Enum.filter(files, &String.ends_with?(&1, ".md")) == []
    end

    test ":mention reply writes outbox envelope with to: chat:<channel>", ctx do
      {base, rel} = setup_mention_source(ctx, "mentions/1-general.md", "general")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: "CHAT ACK"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "1-general", task_path: rel, prompt: "x", trigger: :mention}
      :ok = AgentServer.wake(pid, :mention, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])
      assert {:ok, files} = File.ls(outbox)
      assert [file] = Enum.filter(files, &String.ends_with?(&1, ".md"))

      content = File.read!(Path.join(outbox, file))
      assert content =~ ~s(to: "chat:general")
      assert content =~ "CHAT ACK"
    end

    test "no reply content → no outbox write", ctx do
      {base, rel} = setup_source_with_from(ctx, "nore.md", "ceo")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: ""}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "nore", task_path: rel, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])
      # outbox dir may or may not exist; either way, no .md files
      files =
        case File.ls(outbox),
          do: (
            {:ok, f} -> f
            _ -> []
          )

      assert Enum.filter(files, &String.ends_with?(&1, ".md")) == []
    end

    test "non-zero exit → no outbox write", ctx do
      {base, rel} = setup_source_with_from(ctx, "fail.md", "ceo")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 1, reply: "would-be reply"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "fail", task_path: rel, prompt: "x", trigger: :inbox}
      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])

      files =
        case File.ls(outbox),
          do: (
            {:ok, f} -> f
            _ -> []
          )

      assert Enum.filter(files, &String.ends_with?(&1, ".md")) == []
    end

    test "inbox scan skips rejections/ subdir (task #130)", ctx do
      # Router writes rejection notices to inbox/rejections/. Those are
      # notifications, not new work — a wake that picks them up would
      # dispatch, produce a reply, get rejected again, and loop.
      base = Path.join(System.tmp_dir!(), "reject-test-#{System.unique_integer([:positive])}")
      inbox = Path.join([base, "companies/acme/agents/engineer/inbox"])
      rejections = Path.join(inbox, "rejections")
      File.mkdir_p!(rejections)
      File.write!(Path.join(rejections, "1-oops.md"), "---\nrejected: true\n---\nno good")

      on_exit(fn -> File.rm_rf!(base) end)

      dispatch_fun = fn _spec, task, _opts ->
        send(ctx.test_pid, {:dispatched, task.task_path})
        {:ok, %{exit_status: 0}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)
      :ok = AgentServer.wake(pid, :inbox, nil)

      refute_receive {:dispatched, _}, 200
      assert %{state: :idle} = AgentServer.status(pid)
    end

    test ":mention wake prefers inbox/mentions/ over older top-level files", ctx do
      # Seed both a stale top-level file AND a newer mention file.
      # Pre-fix: the oldest top-level would win even for mention wakes,
      # meaning the agent ignored the @mention that woke it. Post-fix:
      # trigger==:mention should pick the mentions/ file.
      base = Path.join(System.tmp_dir!(), "mention-test-#{System.unique_integer([:positive])}")
      inbox = Path.join([base, "companies/acme/agents/engineer/inbox"])
      mentions = Path.join(inbox, "mentions")
      File.mkdir_p!(mentions)

      stale_path = Path.join(inbox, "stale-top-level.md")
      File.write!(stale_path, "---\nfrom: ceo\n---\n\nold body")
      File.touch!(stale_path, {{2020, 1, 1}, {0, 0, 0}})

      mention_path = Path.join(mentions, "5-general.md")
      File.write!(mention_path, "---\nchannel: general\nfrom: director\n---\n\nrecent body")

      on_exit(fn -> File.rm_rf!(base) end)

      # Drive through start_server so the full flow runs:
      # wake(:mention, nil) → resolve_task → call_inbox_scan(state, :mention)
      dispatch_fun = fn _spec, task, _opts ->
        send(ctx.test_pid, {:dispatched, task.task_path})
        {:ok, %{exit_status: 0, reply: "ok"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)
      :ok = AgentServer.wake(pid, :mention, nil)

      # The mention file should be dispatched, NOT the stale top-level.
      assert_receive {:dispatched, dispatched_path}, 2_000
      assert dispatched_path =~ "mentions/5-general.md"
    end

    test ":heartbeat trigger → no outbox write", ctx do
      {base, rel} = setup_source_with_from(ctx, "hb.md", "ceo")

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: "tick"}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{task_id: "hb", task_path: rel, prompt: "x", trigger: :heartbeat}
      :ok = AgentServer.wake(pid, :heartbeat, task)
      await_state(pid, :idle)

      outbox = Path.join([base, "companies/acme/agents/engineer/outbox"])

      files =
        case File.ls(outbox),
          do: (
            {:ok, f} -> f
            _ -> []
          )

      assert Enum.filter(files, &String.ends_with?(&1, ".md")) == []
    end
  end

  describe "A13 — stop_inflight" do
    test "returns :idle when nothing is running", ctx do
      pid = start_server(ctx)
      assert :idle == AgentServer.stop_inflight(pid)
    end

    test "kills the in-flight Task and leaves agent idle", ctx do
      pid = start_server(ctx, dispatch_fun: blocking_dispatch(ctx.test_pid))

      task = %{task_id: "t1", prompt: "x"}
      :ok = AgentServer.wake(pid, :director_request, task)
      assert_receive {:dispatch_started, "t1", _task_pid}, 1_000

      status = AgentServer.status(pid)
      assert status.state == :busy
      assert status.current_task == "t1"

      assert :ok == AgentServer.stop_inflight(pid)

      status2 = await_state(pid, :idle)
      assert status2.state == :idle
      assert status2.current_task == nil
      assert status2.last_exit_status == "stopped_by_director"
    end
  end

  # End-to-end regression: the Actions-driven path writes a mention
  # file under `agents/<slug>/inbox/mentions/` and fires an inotify
  # event. Watcher broadcasts `{:file_event, rel, events}` on
  # `company:<co>:inbox`. The Agent.Server's handle_info should
  # filter by slug, classify as :mention, and dispatch.
  #
  # Before this test existed, the chain was only tested in pieces
  # — `AgentServer.wake(pid, :mention, nil)` verified the wake
  # semantics, but the PubSub entry point was untested. User bug
  # "agents not processing chat messages where mentioned by
  # director" landed precisely in that untested seam.
  describe "PubSub-driven :mention wake" do
    setup %{test_pid: test_pid} = ctx do
      # Start a test-scoped PubSub so broadcasts don't escape
      # into Glorbo.PubSub (which might not be running under bare
      # mix test). `Glorbo.Test.UniqueName.gen/1` uses
      # `String.to_atom` via a known-bounded prefix — same pattern
      # the rest of this file uses for per-test registry names.
      pubsub = Glorbo.Test.UniqueName.gen("test_pubsub")
      start_supervised!({Phoenix.PubSub, name: pubsub})

      base =
        Path.join(
          System.tmp_dir!(),
          "mention-pubsub-#{System.unique_integer([:positive])}"
        )

      slug = ctx.spec.slug
      company = "acme"
      mentions = Path.join([base, "companies", company, "agents", slug, "inbox/mentions"])
      File.mkdir_p!(mentions)
      on_exit(fn -> File.rm_rf!(base) end)

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task.trigger, task.task_path})
        {:ok, %{exit_status: 0, reply: "ack"}}
      end

      pid =
        start_server(ctx,
          base: base,
          pubsub: pubsub,
          dispatch_fun: dispatch_fun
        )

      {:ok,
       pubsub: pubsub, base: base, slug: slug, company: company, mentions: mentions, pid: pid}
    end

    test "broadcast {:file_event, agents/<slug>/inbox/mentions/X, [:created]} wakes + dispatches",
         %{pubsub: pubsub, company: company, slug: slug, mentions: mentions} do
      # Seed the actual file so call_inbox_scan(:mention) can read it.
      path = Path.join(mentions, "1-general.md")

      File.write!(path, """
      ---
      channel: general
      from: director
      ---

      @#{slug} please respond
      """)

      # Simulate what the Filesystem.Watcher would broadcast.
      rel = "agents/#{slug}/inbox/mentions/1-general.md"
      Phoenix.PubSub.broadcast(pubsub, "company:#{company}:inbox", {:file_event, rel, [:created]})

      assert_receive {:dispatched, :mention, dispatched_path}, 2_000
      assert dispatched_path =~ "mentions/1-general.md"
    end

    test "event for a DIFFERENT agent's mentions is ignored",
         %{pubsub: pubsub, company: company} do
      rel = "agents/otheragent/inbox/mentions/1-general.md"
      Phoenix.PubSub.broadcast(pubsub, "company:#{company}:inbox", {:file_event, rel, [:created]})

      refute_receive {:dispatched, _, _}, 300
    end
  end

  # ---------------------------------------------------------------------------
  # Task-assignment reply handling (regression suite for the
  # "agent commented but didn't reassign" UAT class of bugs)
  # ---------------------------------------------------------------------------

  describe "task-assignment reply" do
    # Setup: company/agents/<slug>/inbox/<ts>-task-<id>.md + a real
    # project with a task file. The Server runs the dispatch, the test
    # fakes the CLI reply, and we assert on the task file contents.
    defp setup_task_assignment(ctx, task_id, reply_body) do
      base = Path.join(System.tmp_dir!(), "srv_task_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)

      slug = ctx.spec.slug
      co = ctx.spec.company
      co_root = Path.join([base, "companies", co])

      # Inbox file (what kanban's maybe_notify_assignee would write)
      inbox_dir = Path.join([co_root, "agents", slug, "inbox"])
      File.mkdir_p!(inbox_dir)
      inbox_file = Path.join(inbox_dir, "1-task-#{task_id}.md")

      File.write!(inbox_file, """
      ---
      from: director
      task_id: "#{task_id}"
      kind: task_assignment
      delivered_at: "2026-04-20T00:00:00Z"
      ---

      Please take a look and reassign back.
      """)

      # Task file the agent's reply should comment on / mutate
      tasks_dir = Path.join([co_root, "projects", "demo", "tasks"])
      File.mkdir_p!(tasks_dir)
      task_path = Path.join(tasks_dir, "#{task_id}.md")

      File.write!(task_path, """
      ---
      kind: task/v1
      title: "Demo"
      status: "todo"
      assigned_to: "#{slug}"
      priority: "low"
      ---

      Original task body.
      """)

      rel = "agents/#{slug}/inbox/1-task-#{task_id}.md"

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply_body}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{
        task_id: "t-#{task_id}",
        task_path: rel,
        prompt: "x",
        trigger: :inbox
      }

      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      on_exit(fn -> File.rm_rf!(base) end)

      %{task_path: task_path, base: base}
    end

    test "TA-1: plain reply appends `## ts | slug` comment block to sibling (GEP-30 D8)",
         ctx do
      %{task_path: path} = setup_task_assignment(ctx, "t-01", "Got it.")

      comments_path = Glorbo.TaskComments.path_for(path)
      content = File.read!(comments_path)
      assert content =~ "## "
      assert content =~ " | #{ctx.spec.slug}"
      assert content =~ "Got it."
    end

    test "TA-2: ACTIONS/reassign_to rewrites assigned_to frontmatter", ctx do
      reply = """
      Handing back.

      ACTIONS:
      - reassign_to: director
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-02", reply)

      task_content = File.read!(path)
      assert task_content =~ ~r/^assigned_to: "?director"?$/m
      refute task_content =~ "reassign_to:"

      # Comment body preserved (sans ACTIONS block) in the sibling thread.
      comments_content = File.read!(Glorbo.TaskComments.path_for(path))
      assert comments_content =~ "Handing back."
      refute comments_content =~ "reassign_to:"
    end

    test "TA-3: ACTIONS/status rewrites status frontmatter", ctx do
      reply = """
      Finished.

      ACTIONS:
      - status: done
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-03", reply)

      content = File.read!(path)
      assert content =~ ~r/^status: "?done"?$/m
    end

    test "TA-4: multiple ACTIONS apply together", ctx do
      reply = """
      Reviewed. Back to you.

      ACTIONS:
      - reassign_to: director
      - status: todo
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-04", reply)

      content = File.read!(path)
      assert content =~ ~r/^assigned_to: "?director"?$/m
      assert content =~ ~r/^status: "?todo"?$/m
    end

    test "TA-4c: many reassign_to directives are capped to a single reassign (C-067)", ctx do
      # C-067: an attacker-controlled reply can pack the ACTIONS block
      # with thousands of `reassign_to` directives. The unbounded loop
      # applied every one — each a frontmatter rewrite + handoff_chain
      # append + audit event — flooding the task file and audit log.
      # Alternating two valid slugs dodges the `:noop` same-assignee
      # guard, so the cap must be enforced independently.
      directives =
        1..50
        |> Enum.map_join("\n", fn i ->
          slug = if rem(i, 2) == 0, do: "director", else: "otheragent"
          "- reassign_to: #{slug}"
        end)

      reply = """
      Handing off a lot.

      ACTIONS:
      #{directives}
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-04c", reply)

      content = File.read!(path)

      # handoff_chain serializes one `from:` per appended entry. The cap
      # is one reassign per reply, so at most one chain entry is written.
      chain_entries = content |> String.split("from:") |> length() |> Kernel.-(1)
      assert chain_entries <= 1, "expected <= 1 handoff_chain entry, got #{chain_entries}"
    end

    test "TA-4b: verdict directive routes through record_peer_review_verdict/4 (GEP-41)",
         ctx do
      base = Path.join(System.tmp_dir!(), "srv_verdict_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)

      slug = ctx.spec.slug
      co = ctx.spec.company
      co_root = Path.join([base, "companies", co])

      inbox_dir = Path.join([co_root, "agents", slug, "inbox"])
      File.mkdir_p!(inbox_dir)
      inbox_file = Path.join(inbox_dir, "1-task-verdict.md")

      File.write!(inbox_file, """
      ---
      from: director
      task_id: "demo-99"
      kind: task_assignment
      delivered_at: "2026-04-20T00:00:00Z"
      ---

      Please review.
      """)

      tasks_dir = Path.join([co_root, "projects", "demo", "tasks"])
      File.mkdir_p!(tasks_dir)
      task_path = Path.join(tasks_dir, "demo-99.md")

      File.write!(task_path, """
      ---
      kind: task/v1
      title: "needs review"
      status: "pending-approval"
      assigned_to: "engineer"
      severity: "major"
      peer_review_required: true
      reviewer: "#{slug}"
      ---

      Body.
      """)

      reply = """
      Looks solid, all checks pass.

      ACTIONS:
      - verdict: approve
      - note: spot-checked 4 claims
      """

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply}}
      end

      pid = start_server(ctx, base: base, dispatch_fun: dispatch_fun)

      task = %{
        task_id: "demo-99",
        task_path: "agents/#{slug}/inbox/1-task-verdict.md",
        prompt: "x",
        trigger: :inbox
      }

      :ok = AgentServer.wake(pid, :inbox, task)
      await_state(pid, :idle)

      content = File.read!(task_path)
      assert content =~ ~r/^peer_review_verdict: approve$/m
      assert content =~ ~r/^peer_review_verdict_by: #{slug}$/m
      assert content =~ ~s(peer_review_verdict_note: "spot-checked 4 claims")

      on_exit(fn -> File.rm_rf!(base) end)
    end

    test "TA-5a: empty ACTIONS block (all non-matching lines) no-op but comment retained",
         ctx do
      reply = """
      Just noting.

      ACTIONS:

      """

      %{task_path: path} = setup_task_assignment(ctx, "t-empty", reply)
      # Frontmatter unchanged
      assert File.read!(path) =~ ~r/^status: "?todo"?$/m
      # Comment lands in the sibling thread (GEP-30 D8).
      assert File.read!(Glorbo.TaskComments.path_for(path)) =~ "Just noting."
    end

    test "TA-5: unknown ACTIONS keys are ignored (comment still appended)", ctx do
      reply = """
      Noted.

      ACTIONS:
      - delete_task: true
      - nonsense: 42
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-05", reply)

      # Original frontmatter untouched
      assert File.read!(path) =~ ~r/^status: "?todo"?$/m
      # Comment still appended — to the sibling thread.
      assert File.read!(Glorbo.TaskComments.path_for(path)) =~ "Noted."
    end

    test "TA-5b: duplicate ACTIONS blocks — only first is used; subsequent prose ignored",
         ctx do
      reply = """
      First note.

      ACTIONS:
      - status: in-progress

      Second note.

      ACTIONS:
      - status: done
      """

      %{task_path: path} = setup_task_assignment(ctx, "t-dup", reply)
      content = File.read!(path)

      # `String.split(..., parts: 2)` means everything after the FIRST
      # `ACTIONS:` header goes into the actions block. Both `status`
      # lines are in scope; Enum.reduce → last-write-wins → final
      # status is "done".
      assert content =~ ~r/^status: "?done"?$/m
    end

    test "TA-6: prose containing 'status:' in a sentence is NOT parsed as action",
         ctx do
      reply = "The current status: unclear. Leaving alone."

      %{task_path: path} = setup_task_assignment(ctx, "t-06", reply)

      content = File.read!(path)
      # Status frontmatter unchanged (no ACTIONS block = no parse)
      assert content =~ ~r/^status: "?todo"?$/m
    end
  end

  # ---------------------------------------------------------------------------
  # GEP-46 — per-agent max_concurrency
  # ---------------------------------------------------------------------------

  describe "GEP-46 max_concurrency > 1" do
    test "fills slots concurrently up to max_concurrency", ctx do
      spec = %{ctx.spec | max_concurrency: 3}
      # Inbox-scan stub: returns successive tasks so drain_on_free has
      # something to dispatch when slots free up. Most realistic
      # production analogue (inbox-on-disk feeding the agent).
      counter = :counters.new(1, [])

      inbox_scan_fun = fn _spec, _base, _trigger ->
        n = :counters.add(counter, 1, 1) && :counters.get(counter, 1)
        if n <= 5, do: %{task_id: "scan-#{n}", task_path: nil, prompt: "x", trigger: :inbox}
      end

      pid =
        start_server(%{ctx | spec: spec},
          dispatch_fun: blocking_dispatch(ctx.test_pid),
          inbox_scan_fun: inbox_scan_fun
        )

      :ok = AgentServer.wake(pid, :inbox, sample_task("t1"))
      :ok = AgentServer.wake(pid, :inbox, sample_task("t2"))
      :ok = AgentServer.wake(pid, :inbox, sample_task("t3"))

      assert_receive {:dispatch_started, "t1", p1}, 1_000
      assert_receive {:dispatch_started, "t2", p2}, 1_000
      assert_receive {:dispatch_started, "t3", p3}, 1_000

      status = AgentServer.status(pid)
      assert status.state == :busy
      assert status.at_cap? == true
      assert length(status.in_flight) == 3

      ids = status.in_flight |> Enum.map(& &1.task_id) |> Enum.sort()
      assert ids == ["t1", "t2", "t3"]

      # Free up t1 — finish/2 fires drain_on_free → maybe_auto_drain_inbox
      # (because the completed trigger was :inbox) → inbox_scan returns
      # the next stub task, which dispatches.
      send(p1, {:finish, {:ok, %{exit_status: 0, reply: ""}}})

      assert_receive {:dispatch_started, "scan-1", _p4}, 1_000

      _ = {p2, p3}
    end

    test "max_concurrency=1 reproduces today's exact single-instance behaviour", ctx do
      spec = %{ctx.spec | max_concurrency: 1}
      # Same as today: explicit task on first wake; coalesced wakes on
      # busy fall back to inbox_scan resolution. We stub the scan
      # to return a deterministic next task so the post-completion
      # drain has something to pick up.
      inbox_scan_fun = fn _spec, _base, _trigger ->
        %{task_id: "from-inbox", task_path: nil, prompt: "x", trigger: :inbox}
      end

      pid =
        start_server(%{ctx | spec: spec},
          dispatch_fun: blocking_dispatch(ctx.test_pid),
          inbox_scan_fun: inbox_scan_fun
        )

      :ok = AgentServer.wake(pid, :inbox, sample_task("a"))
      assert_receive {:dispatch_started, "a", pa}, 1_000

      status = AgentServer.status(pid)
      assert status.state == :busy
      assert status.at_cap? == true

      # Second wake while busy → coalesce. The explicit-task arg is
      # discarded by the busy path (matches today's contract); the
      # next dispatch comes from inbox_scan.
      :ok = AgentServer.wake(pid, :inbox, sample_task("b"))
      refute_received {:dispatch_started, "from-inbox", _}

      send(pa, {:finish, {:ok, %{exit_status: 0, reply: ""}}})
      assert_receive {:dispatch_started, "from-inbox", _next}, 1_000
    end

    test "in_flight is sorted by started_at (oldest first)", ctx do
      spec = %{ctx.spec | max_concurrency: 2}
      pid = start_server(%{ctx | spec: spec}, dispatch_fun: blocking_dispatch(ctx.test_pid))

      :ok = AgentServer.wake(pid, :inbox, sample_task("first"))
      assert_receive {:dispatch_started, "first", _p1}, 1_000

      :ok = AgentServer.wake(pid, :inbox, sample_task("second"))
      assert_receive {:dispatch_started, "second", _p2}, 1_000

      status = AgentServer.status(pid)
      assert [%{task_id: "first"}, %{task_id: "second"}] = status.in_flight
      # Legacy `current_task` reflects the OLDEST in-flight invocation.
      assert status.current_task == "first"
    end
  end
end
