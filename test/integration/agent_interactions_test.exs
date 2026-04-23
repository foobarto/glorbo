defmodule Glorbo.Integration.AgentInteractionsTest do
  @moduledoc """
  End-to-end tests for the Director ↔ agent interaction surface.

  Each test case models a specific user journey:

    - `@mention` in channel → agent wake → reply routes back to channel
    - Task assignment → agent comment appears on task file
    - ACTIONS DSL → task frontmatter mutates
    - Multiple agents, single target — siblings don't wake spuriously
    - Failure modes (non-existent target, malformed payload) → no crash

  Covers the regression surface for bugs reported in UAT 2026-04-19/20:
  "agent commented but didn't reassign", "chat reply not attributed",
  "mention doesn't wake agent immediately".
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Glorbo.Agent.Registry, as: AgentRegistry
  alias Glorbo.Agent.Server, as: AgentServer
  alias Glorbo.Agent.Spec

  defp make_spec(company, slug, opts) do
    %Spec{
      slug: slug,
      company: company,
      role: Keyword.get(opts, :role, "role-#{slug}"),
      provider: Keyword.get(opts, :provider, "claude-code"),
      model: Keyword.get(opts, :model, "claude-sonnet-4-5"),
      permissions: Keyword.get(opts, :permissions, []),
      heartbeat: nil,
      network: :proxy,
      skills: [],
      budget_usd_cents_month: nil,
      timeout_seconds: 60,
      file_path: "/tmp/fake-#{slug}.md"
    }
  end

  # Boot one in-process agent server wired to the Application's
  # Registry + PubSub. `dispatch_fun` returns a canned result so we
  # don't actually shell out to claude-code.
  defp boot_agent(company, slug, dispatch_fun, opts) do
    spec = make_spec(company, slug, opts)
    task_sup_name = {:via, Registry, {AgentRegistry, {:agent_task_sup, company, slug}}}

    case Task.Supervisor.start_link(name: task_sup_name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    server_name = {:via, Registry, {AgentRegistry, {:agent_server, company, slug}}}

    case AgentServer.start_link(
           spec: spec,
           company: company,
           task_supervisor: task_sup_name,
           name: server_name,
           dispatch_fun: dispatch_fun,
           base: Keyword.fetch!(opts, :base)
         ) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  setup do
    Application.ensure_all_started(:glorbo)

    # Each test gets a private filesystem + company slug so Router
    # subscriptions don't cross-contaminate.
    base = Path.join(System.tmp_dir!(), "gi_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    company = "co#{System.unique_integer([:positive])}"
    co_root = Path.join([base, "companies", company])

    on_exit(fn ->
      File.rm_rf!(base)
    end)

    {:ok, base: base, company: company, co_root: co_root}
  end

  # Helper: drop the inbox-mention file the Filesystem Watcher / Actions
  # path would normally produce, and broadcast the `:file_event` that
  # Agent.Server subscribes to.
  defp deliver_mention(base, company, target_slug, channel, body) do
    mentions = Path.join([base, "companies", company, "agents", target_slug, "inbox", "mentions"])
    File.mkdir_p!(mentions)
    ts = System.system_time(:millisecond)
    path = Path.join(mentions, "#{ts}-#{channel}.md")

    File.write!(path, """
    ---
    channel: #{channel}
    from: director
    source_msg: "2026-04-20T00:00:00Z"
    delivered_at: "2026-04-20T00:00:00Z"
    ---

    #{body}
    """)

    rel = Path.relative_to(path, Path.join([base, "companies", company]))

    Phoenix.PubSub.broadcast(
      Glorbo.PubSub,
      "company:#{company}:inbox",
      {:file_event, rel, [:created]}
    )

    path
  end

  # Helper: drop a `kind: task_assignment` inbox file + the matching
  # projects/demo/tasks/<id>.md. Returns {inbox_path, task_path}.
  defp deliver_task_assignment(base, company, target_slug, task_id, body) do
    co_root = Path.join([base, "companies", company])

    inbox_dir = Path.join([co_root, "agents", target_slug, "inbox"])
    File.mkdir_p!(inbox_dir)
    ts = System.system_time(:millisecond)
    inbox_path = Path.join(inbox_dir, "#{ts}-task-#{task_id}.md")

    File.write!(inbox_path, """
    ---
    from: director
    task_id: "#{task_id}"
    kind: task_assignment
    delivered_at: "2026-04-20T00:00:00Z"
    ---

    #{body}
    """)

    tasks_dir = Path.join([co_root, "projects", "demo", "tasks"])
    File.mkdir_p!(tasks_dir)
    task_path = Path.join(tasks_dir, "#{task_id}.md")

    File.write!(task_path, """
    ---
    kind: task/v1
    title: "Seed"
    status: "todo"
    assigned_to: "#{target_slug}"
    priority: "low"
    ---

    Original.
    """)

    {inbox_path, task_path}
  end

  # =====================================================================
  # II-1: Mention → wake → dispatch
  # =====================================================================

  describe "II-1: @mention wakes exactly the target agent" do
    test "broadcasting a mention file_event fires dispatch with trigger=:mention", ctx do
      test_pid = self()

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task.trigger, task.task_path})
        {:ok, %{exit_status: 0, reply: "pong", duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      deliver_mention(ctx.base, ctx.company, "ceo", "general", "@ceo ping")

      assert_receive {:dispatched, :mention, path}, 2_000
      assert path =~ "mentions/"
      assert path =~ "-general.md"
    end
  end

  # =====================================================================
  # II-2: A second agent does NOT wake on a mention of the first
  # =====================================================================

  describe "II-2: sibling agents don't wake on each other's mentions" do
    test "mention of @ceo leaves @engineer idle", ctx do
      test_pid = self()

      ceo_dispatch = fn _spec, task, _opts ->
        send(test_pid, {:ceo_dispatched, task.trigger})
        {:ok, %{exit_status: 0, reply: "ok", duration_ms: 0, usage: %{model: "m"}}}
      end

      eng_dispatch = fn _spec, task, _opts ->
        send(test_pid, {:eng_dispatched, task.trigger})
        {:ok, %{exit_status: 0, reply: "ok", duration_ms: 0, usage: %{model: "m"}}}
      end

      _ceo = boot_agent(ctx.company, "ceo", ceo_dispatch, base: ctx.base)
      _eng = boot_agent(ctx.company, "engineer", eng_dispatch, base: ctx.base)

      deliver_mention(ctx.base, ctx.company, "ceo", "general", "@ceo hi")

      assert_receive {:ceo_dispatched, :mention}, 2_000
      refute_receive {:eng_dispatched, _}, 300
    end
  end

  # =====================================================================
  # II-3: Task-assignment → agent reply appends comment + ACTIONS apply
  # =====================================================================

  describe "II-3: task-assignment round trip with ACTIONS DSL" do
    test "agent reply with ACTIONS block updates task frontmatter", ctx do
      reply = """
      Done. Handing back.

      ACTIONS:
      - reassign_to: director
      - status: todo
      """

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply, duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t01", "Please review.")

      # Drive the wake that would normally come from inotify
      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      # Wait for the task file to be mutated (frontmatter) AND the
      # sibling comment file to exist (GEP-30 D8 — comments live in
      # `<task-id>.comments.md` now, not inline).
      await_file_change(task_path, "assigned_to: director", 2_000)

      content = File.read!(task_path)
      assert content =~ ~r/^assigned_to: "?director"?$/m
      assert content =~ ~r/^status: "?todo"?$/m
      refute content =~ "reassign_to:"

      comments_path = Glorbo.TaskComments.path_for(task_path)
      await_file_change(comments_path, "Done. Handing back.", 2_000)
      assert File.read!(comments_path) =~ "Done. Handing back."
    end

    test "plain reply (no ACTIONS) appends comment but leaves frontmatter alone", ctx do
      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: "Reviewed.", duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t02", "Take a look.")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      comments_path = Glorbo.TaskComments.path_for(task_path)
      await_file_change(comments_path, "Reviewed.", 2_000)

      # Comment landed in the sibling thread.
      comments_content = File.read!(comments_path)
      assert comments_content =~ " | ceo\n"
      assert comments_content =~ "Reviewed."

      # Task file frontmatter unchanged (no ACTIONS).
      content = File.read!(task_path)
      assert content =~ ~r/^assigned_to: "?ceo"?$/m
      assert content =~ ~r/^status: "?todo"?$/m
    end

    test "malformed ACTIONS block doesn't crash or prevent the comment", ctx do
      # Missing leading dash + wrong indent; parser should skip it
      # and still append the comment body.
      reply = """
      Done.

      ACTIONS:
        status = done
        delete everything
      """

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply, duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t03", "check")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      comments_path = Glorbo.TaskComments.path_for(task_path)
      await_file_change(comments_path, "Done.", 2_000)

      # Task frontmatter unchanged.
      assert File.read!(task_path) =~ ~r/^status: "?todo"?$/m
      # Comment landed in sibling file despite malformed ACTIONS.
      assert File.read!(comments_path) =~ "Done."
    end
  end

  # =====================================================================
  # II-5: ACTIONS on a task whose file is missing — no crash
  # =====================================================================

  describe "II-5: stale / missing task_id" do
    test "reply to a task whose file was deleted mid-flight: no crash", ctx do
      reply = """
      Ok.

      ACTIONS:
      - status: done
      """

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply, duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t-missing", "x")

      # Delete the task file BEFORE the reply lands
      File.rm!(task_path)

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      # Give the Server a moment to process and NOT crash
      Process.sleep(300)

      # Agent.Server still alive on the same name
      name = {:via, Registry, {AgentRegistry, {:agent_server, ctx.company, "ceo"}}}
      assert %{state: _} = AgentServer.status(name)
    end
  end

  # =====================================================================
  # II-10: Chatty prose BEFORE and AFTER ACTIONS block
  # =====================================================================

  describe "II-10: mixed prose + ACTIONS" do
    test "prose that comes after ACTIONS is ignored; comment body is pre-ACTIONS only",
         ctx do
      reply = """
      Got it, marking done.

      ACTIONS:
      - status: done

      Also here's some chatty trailing prose the model added.
      """

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply, duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t-mixed", "x")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      await_file_change(task_path, "status: done", 2_000)

      # Status updated on the task file itself.
      assert File.read!(task_path) =~ ~r/^status: "?done"?$/m

      # Comment lands in the sibling thread (GEP-30 D8).
      comments_path = Glorbo.TaskComments.path_for(task_path)
      await_file_change(comments_path, "Got it, marking done.", 2_000)
      comments_content = File.read!(comments_path)

      # Comment body is the PRE-ACTIONS section only
      assert comments_content =~ "Got it, marking done."
      # Post-ACTIONS chatter should NOT leak into the comment
      refute comments_content =~ "chatty trailing prose"
    end
  end

  # =====================================================================
  # II-6: ACTIONS at end-of-reply with no trailing newline parses
  # =====================================================================

  describe "II-6: ACTIONS parser edge cases" do
    test "reply ends exactly on the last action line (no trailing newline)", ctx do
      reply = "Noted.\n\nACTIONS:\n- status: done"

      dispatch_fun = fn _spec, _task, _opts ->
        {:ok, %{exit_status: 0, reply: reply, duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      {inbox_path, task_path} =
        deliver_task_assignment(ctx.base, ctx.company, "ceo", "t-eol", "x")

      Phoenix.PubSub.broadcast(
        Glorbo.PubSub,
        "company:#{ctx.company}:inbox",
        {:file_event, Path.relative_to(inbox_path, ctx.co_root), [:created]}
      )

      await_file_change(task_path, "status: done", 2_000)
      content = File.read!(task_path)
      assert content =~ ~r/^status: "?done"?$/m
      # Frontmatter merge: other keys survive
      assert content =~ ~r/^title:/m
      assert content =~ ~r/^assigned_to:/m
    end
  end

  # =====================================================================
  # II-9: Multi-mention in one message wakes all mentioned agents
  # =====================================================================

  describe "II-9: multi-mention routing" do
    test "@ceo @engineer in one message wakes both", ctx do
      test_pid = self()

      ceo_dispatch = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, "ceo", task.trigger})
        {:ok, %{exit_status: 0, reply: "", duration_ms: 0, usage: %{model: "m"}}}
      end

      eng_dispatch = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, "engineer", task.trigger})
        {:ok, %{exit_status: 0, reply: "", duration_ms: 0, usage: %{model: "m"}}}
      end

      _ceo = boot_agent(ctx.company, "ceo", ceo_dispatch, base: ctx.base)
      _eng = boot_agent(ctx.company, "engineer", eng_dispatch, base: ctx.base)

      channels_dir = Path.join([ctx.co_root, "channels"])
      File.mkdir_p!(channels_dir)
      File.write!(Path.join(channels_dir, "general.md"), "# general\n")

      File.mkdir_p!(Path.join([ctx.co_root, "agents", "ceo", "inbox", "mentions"]))
      File.mkdir_p!(Path.join([ctx.co_root, "agents", "engineer", "inbox", "mentions"]))

      audit_pid = spawn_link(fn -> noop_audit_loop() end)

      :ok =
        GlorboWeb.Actions.post_message(
          ctx.company,
          "general",
          "@ceo @engineer — standup in 5",
          base: ctx.base,
          audit: audit_pid
        )

      assert_receive {:dispatched, "ceo", :mention}, 2_000
      assert_receive {:dispatched, "engineer", :mention}, 2_000
    end
  end

  # =====================================================================
  # II-7: Actions.post_message with @mention fires a mention wake
  # =====================================================================

  describe "II-7: Director chat → @mention → agent wake" do
    test "posting a message containing @<slug> wakes the agent via direct-wake",
         ctx do
      test_pid = self()

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task.trigger, task.task_path})
        {:ok, %{exit_status: 0, reply: "pong", duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      # Seed the channel file so post_message's ensure_regular_file passes
      channels_dir = Path.join([ctx.co_root, "channels"])
      File.mkdir_p!(channels_dir)
      File.write!(Path.join(channels_dir, "general.md"), "# general\n")

      # Actions.write_director_mention gates on File.dir?(<agent dir>),
      # so the directory has to exist before post_message is called.
      File.mkdir_p!(Path.join([ctx.co_root, "agents", "ceo", "inbox", "mentions"]))

      audit_pid = spawn_link(fn -> noop_audit_loop() end)

      :ok =
        GlorboWeb.Actions.post_message(ctx.company, "general", "@ceo ping",
          base: ctx.base,
          audit: audit_pid
        )

      # Dispatch fires from the safe_wake_mention Registry path, not
      # just inotify — so it's reliable in tests even without watcher.
      assert_receive {:dispatched, :mention, _path}, 2_000
    end
  end

  # =====================================================================
  # II-8: Actions.post_task_comment wakes the assigned agent
  # =====================================================================

  describe "II-8: Director task-comment → wakes assigned agent" do
    test "post_task_comment on a task assigned to @ceo wakes ceo", ctx do
      test_pid = self()

      dispatch_fun = fn _spec, task, _opts ->
        send(test_pid, {:dispatched, task.trigger, task.task_path})
        {:ok, %{exit_status: 0, reply: "ok", duration_ms: 0, usage: %{model: "m"}}}
      end

      _pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      # Same gate as II-7 — agent dir must exist for the mention write
      File.mkdir_p!(Path.join([ctx.co_root, "agents", "ceo", "inbox", "mentions"]))

      # Seed the task file with assigned_to: ceo
      tasks_dir = Path.join([ctx.co_root, "projects", "demo", "tasks"])
      File.mkdir_p!(tasks_dir)
      rel = "projects/demo/tasks/review-1.md"
      abs = Path.join(ctx.co_root, rel)

      File.write!(abs, """
      ---
      kind: task/v1
      title: "Review"
      status: "todo"
      assigned_to: "ceo"
      ---

      Please review.
      """)

      audit_pid = spawn_link(fn -> noop_audit_loop() end)

      :ok =
        GlorboWeb.Actions.post_task_comment(ctx.company, rel, "any updates?",
          base: ctx.base,
          audit: audit_pid
        )

      assert_receive {:dispatched, :mention, _path}, 2_000
    end
  end

  # =====================================================================
  # II-4: PubSub `company:<co>:agents:status` broadcasts on idle↔busy
  # =====================================================================

  describe "II-4: agent status PubSub contract" do
    test "broadcast fires on :busy and again on :idle", ctx do
      # Dispatch that blocks until we release it
      release = fn -> receive do: ({:release} -> :ok) end

      dispatch_fun = fn _spec, _task, _opts ->
        release.()
        {:ok, %{exit_status: 0, reply: "done", duration_ms: 0, usage: %{model: "m"}}}
      end

      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{ctx.company}:agents:status")

      pid = boot_agent(ctx.company, "ceo", dispatch_fun, base: ctx.base)

      task = %{task_id: "s1", task_path: nil, prompt: "x", trigger: :director_request}
      :ok = AgentServer.wake(pid, :director_request, task)

      assert_receive {:agent_status, "ceo", :busy, _}, 1_000

      # Release the blocking dispatch
      dispatch_task_pid = find_agent_task_pid(pid)
      if is_pid(dispatch_task_pid), do: send(dispatch_task_pid, {:release})

      assert_receive {:agent_status, "ceo", :idle, _}, 2_000
    end
  end

  # =====================================================================
  # Helpers
  # =====================================================================

  # Poll the file for a specific substring with a deadline. Avoids a
  # flaky `assert_receive` for the :file_event PubSub (we're the
  # producer anyway).
  defp await_file_change(path, substr, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_loop(path, substr, deadline)
  end

  defp await_loop(path, substr, deadline) do
    case File.read(path) do
      {:ok, content} ->
        if String.contains?(content, substr) do
          :ok
        else
          if System.monotonic_time(:millisecond) >= deadline do
            flunk("timeout waiting for #{inspect(substr)} in #{path}\nlast content: #{content}")
          else
            Process.sleep(50)
            await_loop(path, substr, deadline)
          end
        end

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timeout; file missing: #{path}")
        else
          Process.sleep(50)
          await_loop(path, substr, deadline)
        end
    end
  end

  defp find_agent_task_pid(agent_pid) do
    %{current_task_pid: pid} = AgentServer.status(agent_pid)
    pid
  end

  # Stand-in GenServer-like process that swallows {:append, _entry}
  # calls. Actions.post_message / post_task_comment route audit events
  # through AuditLog.append which calls GenServer.call; our pid just
  # replies :ok and ignores the payload.
  defp noop_audit_loop do
    receive do
      {:"$gen_call", from, {:append, _entry}} ->
        GenServer.reply(from, :ok)
        noop_audit_loop()

      _ ->
        noop_audit_loop()
    end
  end
end
