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

      # Use the real default_inbox_scan through a 3-arity wrapper,
      # simulating what resolve_task/3 passes.
      spec = ctx.spec

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
end
