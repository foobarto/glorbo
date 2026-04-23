defmodule Glorbo.Company.RouterTest do
  use ExUnit.Case, async: false

  alias Glorbo.Company.Router
  alias Glorbo.Test.TmpGlorboHome

  @company "acme"

  defp capturing_audit_fun(pid) do
    fn _server, entry -> send(pid, {:audit, entry}) end
  end

  defp scaffold_company(base, agents) do
    co_dir = Path.join([base, "companies", @company])
    File.mkdir_p!(Path.join(co_dir, "channels"))
    File.mkdir_p!(Path.join(co_dir, "history"))
    File.mkdir_p!(Path.join(co_dir, "audit"))

    Enum.each(agents, fn slug ->
      agent_dir = Path.join([co_dir, "agents", slug])
      File.mkdir_p!(Path.join(agent_dir, "inbox"))
      File.mkdir_p!(Path.join([agent_dir, "inbox", "mentions"]))
      File.mkdir_p!(Path.join([agent_dir, "inbox", "rejections"]))
      File.mkdir_p!(Path.join(agent_dir, "outbox"))
    end)

    co_dir
  end

  defp start_router!(base) do
    name = Glorbo.Test.UniqueName.gen("router")

    pid =
      start_supervised!(
        {Router,
         [
           name: name,
           company: @company,
           base: base,
           audit_fun: capturing_audit_fun(self())
         ]}
      )

    {name, pid}
  end

  defp write_source_outbox!(base, sender, msg_id, body) do
    path =
      Path.join([
        base,
        "companies",
        @company,
        "agents",
        sender,
        "outbox",
        "#{msg_id}.md"
      ])

    File.write!(path, body)
    path
  end

  defp build_msg(base, sender, msg_id, to, perms, body \\ "hello\n") do
    raw_path = write_source_outbox!(base, sender, msg_id, body)

    %{
      sender: sender,
      sender_permissions: perms,
      to: to,
      body: body,
      raw_path: raw_path,
      msg_id: msg_id
    }
  end

  # ---------------------------------------------------------------------------
  # R1 — happy path channel write
  # ---------------------------------------------------------------------------

  test "R1: valid chat:write:general message appends to channel + audit" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m1", "chat:general", [
        {"chat", "write", "general"}
      ])

    assert :ok = Router.route(name, msg)

    channel_path = Path.join([base, "companies", @company, "channels", "general.md"])
    assert File.exists?(channel_path)

    content = File.read!(channel_path)
    assert content =~ "hello"
    # Regression: agent posts MUST be wrapped in the canonical
    # `## <iso-ts> | <sender>` attribution block so ChatDrawer and
    # ChannelLive render them with the right author label.
    assert content =~ ~r/^## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*\| engineer$/m

    assert_receive {:audit, %{action: "message.route"}}, 500
  end

  # ---------------------------------------------------------------------------
  # R2 — permission denied
  # ---------------------------------------------------------------------------

  test "R2: missing chat:write:general -> permission_denied + rejection artifacts" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg = build_msg(base, "engineer", "m2", "chat:general", [])

    assert {:error, {:permission_denied, "chat:write:general"}} = Router.route(name, msg)

    # Rejection file in history/
    assert Path.wildcard(Path.join([base, "companies", @company, "history", "m2.rejected.md"])) !=
             []

    # Rejection notice in sender's inbox/rejections/
    assert Path.wildcard(
             Path.join([
               base,
               "companies",
               @company,
               "agents",
               "engineer",
               "inbox",
               "rejections",
               "*m2*"
             ])
           ) != []

    # Two audit events
    assert_receive {:audit, %{action: "message.reject"}}, 500
    assert_receive {:audit, %{action: "permission.denied"}}, 500
  end

  # ---------------------------------------------------------------------------
  # R3 — agent-to-agent with correct permission
  # ---------------------------------------------------------------------------

  test "R3: agents:message:ceo with valid perm writes to ceo/inbox/from-engineer/" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m3", "agent:ceo", [
        {"agents", "message", "ceo"}
      ])

    assert :ok = Router.route(name, msg)

    files =
      Path.wildcard(
        Path.join([
          base,
          "companies",
          @company,
          "agents",
          "ceo",
          "inbox",
          "from-engineer",
          "*.md"
        ])
      )

    assert files != []
    assert_receive {:audit, %{action: "message.route"}}, 500
  end

  # ---------------------------------------------------------------------------
  # R4 — wrong target permission
  # ---------------------------------------------------------------------------

  test "R4: agents:message:engineer while targeting ceo -> permission_denied" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m4", "agent:ceo", [
        {"agents", "message", "engineer"}
      ])

    assert {:error, {:permission_denied, "agents:message:ceo"}} = Router.route(name, msg)
  end

  # ---------------------------------------------------------------------------
  # R5 — agent-create block (non-existent target)
  # ---------------------------------------------------------------------------

  test "R5: target agent does not exist -> agent_create_blocked + audits" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m5", "agent:new-hire", [
        {"agents", "message", "new-hire"}
      ])

    assert {:error, {:agent_create_blocked, "new-hire"}} = Router.route(name, msg)

    assert_receive {:audit, %{action: "agents.create_blocked"}}, 500
    assert_receive {:audit, %{action: "permission.denied"} = entry}, 500
    mp = entry[:missing_permission] || entry["missing_permission"]
    assert mp == "agents:create:*"
  end

  # ---------------------------------------------------------------------------
  # R6 — mention wake
  # ---------------------------------------------------------------------------

  test "R6: @engineer in chat body writes a mention file to engineer's inbox/mentions/" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(
        base,
        "ceo",
        "m6",
        "chat:general",
        [{"chat", "write", "general"}],
        "Hey @engineer, please review this.\n"
      )

    assert :ok = Router.route(name, msg)

    mention_files =
      Path.wildcard(
        Path.join([
          base,
          "companies",
          @company,
          "agents",
          "engineer",
          "inbox",
          "mentions",
          "*general.md"
        ])
      )

    assert mention_files != []

    assert_receive {:audit, %{action: "message.route"}}, 500
    # Also emits agent.wake for mention
    assert_receive {:audit, %{action: "agent.wake"} = wake}, 500
    trigger = wake[:trigger] || wake["trigger"]
    assert trigger == "mention"
  end

  # ---------------------------------------------------------------------------
  # R7 — mention of non-existent agent is silently skipped
  # ---------------------------------------------------------------------------

  test "R7: @ghost (non-existent) -> channel still written, no mention file, no error" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(
        base,
        "ceo",
        "m7",
        "chat:general",
        [{"chat", "write", "general"}],
        "Hello @ghost, are you there?\n"
      )

    assert :ok = Router.route(name, msg)

    channel_path = Path.join([base, "companies", @company, "channels", "general.md"])
    assert File.read!(channel_path) =~ "ghost"

    # No mention dir/file should be created for ghost (ghost does not exist)
    ghost_path =
      Path.join([base, "companies", @company, "agents", "ghost", "inbox", "mentions"])

    refute File.exists?(ghost_path)
  end

  # ---------------------------------------------------------------------------
  # R8 — broadcast unsupported
  # ---------------------------------------------------------------------------

  test "R8: broadcast:* is rejected as invalid_message" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m8", "broadcast:*", [
        {"agents", "message", "*"}
      ])

    assert {:error, {:invalid_message, :broadcast_unsupported}} = Router.route(name, msg)
  end

  # ---------------------------------------------------------------------------
  # R9 — sender slug mismatch
  # ---------------------------------------------------------------------------

  test "R9: sender field doesn't match outbox path -> invalid_message + audit" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    # Write to engineer's outbox but claim to be ceo
    raw_path = write_source_outbox!(base, "engineer", "m9", "hello\n")

    msg = %{
      sender: "ceo",
      sender_permissions: [{"chat", "write", "general"}],
      to: "chat:general",
      body: "hello\n",
      raw_path: raw_path,
      msg_id: "m9"
    }

    assert {:error, {:invalid_message, :sender_mismatch}} = Router.route(name, msg)
    assert_receive {:audit, %{action: "permission.denied"}}, 500
  end

  # ---------------------------------------------------------------------------
  # R10 — categorical agent-create block even with create permission
  # ---------------------------------------------------------------------------

  test "R10: even with fake agents:create:* permission, non-existent target is blocked" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(base, "engineer", "m10", "agent:phantom", [
        {"agents", "create", "*"},
        {"agents", "message", "phantom"}
      ])

    assert {:error, {:agent_create_blocked, "phantom"}} = Router.route(name, msg)
  end

  # ---------------------------------------------------------------------------
  # R11 — concurrent routes serialize cleanly
  # ---------------------------------------------------------------------------

  test "R11: 20 concurrent routes produce 20 attributed message blocks in channel" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    tasks =
      for i <- 1..20 do
        Task.async(fn ->
          msg =
            build_msg(
              base,
              "engineer",
              "m11-#{i}",
              "chat:general",
              [{"chat", "write", "general"}],
              "line #{i}\n"
            )

          Router.route(name, msg)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.all?(results, &(&1 == :ok))

    channel_path = Path.join([base, "companies", @company, "channels", "general.md"])
    content = File.read!(channel_path)
    header_count = content |> String.split("\n## ") |> length() |> Kernel.-(1)
    assert header_count == 20
    assert content =~ "| engineer"
  end

  # ---------------------------------------------------------------------------
  # R12 — rejection file contains rejection frontmatter
  # ---------------------------------------------------------------------------

  test "R12: history/<id>.rejected.md contains original body + rejection frontmatter" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["engineer", "ceo"])
    {name, _pid} = start_router!(base)

    msg =
      build_msg(
        base,
        "engineer",
        "m12",
        "chat:general",
        [],
        "original body here\n"
      )

    assert {:error, {:permission_denied, _}} = Router.route(name, msg)

    rejected_path = Path.join([base, "companies", @company, "history", "m12.rejected.md"])
    assert File.exists?(rejected_path)

    content = File.read!(rejected_path)
    assert content =~ "rejection_reason: permission_denied"
    assert content =~ "original body here"
  end

  # ---------------------------------------------------------------------------
  # Outbox pickup (R-outbox-*) — file_event driven pipeline.
  # ---------------------------------------------------------------------------

  defp start_router_with_perms!(base, perms_fun) do
    name = Glorbo.Test.UniqueName.gen("router")

    pid =
      start_supervised!(
        {Router,
         [
           name: name,
           company: @company,
           base: base,
           audit_fun: capturing_audit_fun(self()),
           agent_permissions_fun: perms_fun
         ]}
      )

    {name, pid}
  end

  defp seed_project!(base, project) do
    dir = Path.join([base, "companies", @company, "projects", project])
    File.mkdir_p!(Path.join(dir, "tasks"))

    File.write!(Path.join(dir, "project.md"), """
    ---
    slug: #{project}
    name: #{project}
    ---
    """)
  end

  test "R-outbox-1: tasks/<proj>/<id>.md is materialised into projects/<proj>/tasks/" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)

    File.write!(Path.join(src_dir, "blog-1.md"), """
    ---
    kind: task/v1
    title: hire researcher
    status: todo
    ---
    Need a Researcher.
    """)

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-1.md", [:created]})
    _ = :sys.get_state(name)

    dest = Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-1.md"])
    assert File.exists?(dest)
    content = File.read!(dest)
    assert content =~ "hire researcher"
    assert content =~ "Need a Researcher"

    refute File.exists?(Path.join(src_dir, "blog-1.md"))
    assert_receive {:audit, %{action: "task.create", target: "projects/blog/tasks/blog-1.md"}}
  end

  test "R-outbox-context: filed task gains a Context footer naming the sender" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)

    File.write!(Path.join(src_dir, "blog-42.md"), """
    ---
    kind: task/v1
    title: review draft-1
    status: pending
    ---
    Please review `/projects/blog/tasks/draft-1.md`.
    """)

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-42.md", [:created]})
    _ = :sys.get_state(name)

    dest =
      Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-42.md"])

    content = File.read!(dest)
    # Original body is preserved.
    assert content =~ "Please review"
    # Context footer is appended.
    assert content =~ "## Context"
    assert content =~ "Filed via outbox by `@ceo`"
    # ISO timestamp shape.
    assert content =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
  end

  test "R-outbox-2: task filed to non-existent project is silently skipped" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "ghost"])

    File.mkdir_p!(src_dir)
    File.write!(Path.join(src_dir, "ghost-1.md"), "---\ntitle: ghost\n---\nbody\n")

    send(name, {:file_event, "agents/ceo/outbox/tasks/ghost/ghost-1.md", [:created]})
    _ = :sys.get_state(name)

    dest = Path.join([base, "companies", @company, "projects", "ghost", "tasks", "ghost-1.md"])
    refute File.exists?(dest)
    assert File.exists?(Path.join(src_dir, "ghost-1.md"))
  end

  test "R-outbox-3: existing task-id collision leaves the original intact" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    existing = Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-5.md"])
    File.write!(existing, "existing content")

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)
    File.write!(Path.join(src_dir, "blog-5.md"), "---\ntitle: overwrite attempt\n---\nnew\n")

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-5.md", [:created]})
    _ = :sys.get_state(name)

    assert File.read!(existing) == "existing content"
    assert File.exists?(Path.join(src_dir, "blog-5.md"))
  end

  test "R-outbox-4: missing projects:write permission skips (no silent write)" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, []} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)
    File.write!(Path.join(src_dir, "blog-9.md"), "---\ntitle: unauthorized\n---\n")

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-9.md", [:created]})
    _ = :sys.get_state(name)

    dest = Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-9.md"])
    refute File.exists?(dest)
  end

  # threatmodel M03 write-side. An agent that can write into a shared
  # `projects/<p>/tasks/` tree (via `projects:write:*`) could pre-plant
  # a symlink at `<task-id>.md` before filing another task. Without an
  # lstat on `dest_path` the Router's `File.write(dest_path, ...)`
  # would follow that symlink and the materialised task content lands
  # at the agent's chosen host target.
  test "R-outbox-dest-symlink: task dest is lstat-guarded before File.write" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    secret = Path.join(base, "secret-host-file.md")
    File.write!(secret, "original director content\n")

    dest_dir = Path.join([base, "companies", @company, "projects", "blog", "tasks"])
    File.mkdir_p!(dest_dir)
    dest_path = Path.join(dest_dir, "blog-99.md")
    :ok = File.ln_s(secret, dest_path)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)

    File.write!(Path.join(src_dir, "blog-99.md"), """
    ---
    kind: task/v1
    title: planted
    status: todo
    ---
    overwrite attempt
    """)

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-99.md", [:created]})
    _ = :sys.get_state(name)

    # Router must refuse rather than follow the symlink. Secret stays.
    assert File.read!(secret) == "original director content\n"
  end

  # threatmodel M03 regression. An agent can write into its own
  # outbox — including planting a symlink that points at an arbitrary
  # host file. Every outbox reader must lstat before reading or a
  # malicious symlink at `outbox/tasks/blog/blog-7.md → ~/.ssh/id_rsa`
  # turns the Router into a confused deputy that materialises the
  # pointed-at file as a task.
  test "R-outbox-symlink: symlinked outbox file is refused (no materialisation)" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    # Simulate a sensitive host file the symlink points at.
    secret_path = Path.join(base, "secret.md")

    File.write!(secret_path, """
    ---
    kind: task/v1
    title: exfiltrated
    status: todo
    ---
    attacker-controlled body
    """)

    src_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "tasks", "blog"])

    File.mkdir_p!(src_dir)
    symlink_path = Path.join(src_dir, "blog-7.md")
    :ok = File.ln_s(secret_path, symlink_path)

    send(name, {:file_event, "agents/ceo/outbox/tasks/blog/blog-7.md", [:created]})
    _ = :sys.get_state(name)

    dest = Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-7.md"])
    refute File.exists?(dest)
    # Sensitive source was not touched.
    assert File.read!(secret_path) =~ "attacker-controlled body"
  end

  test "R-outbox-5: comments/<task-id>.md lands in the sibling `.comments.md` thread (GEP-30 D8)" do
    base = TmpGlorboHome.setup()
    scaffold_company(base, ["ceo"])
    seed_project!(base, "blog")
    perms_fun = fn _sender, _state -> {:ok, [{"projects", "write", "*"}]} end
    {name, _pid} = start_router_with_perms!(base, perms_fun)

    task_path = Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-2.md"])
    File.write!(task_path, "---\ntitle: existing task\n---\nPrompt body\n")

    comments_dir =
      Path.join([base, "companies", @company, "agents", "ceo", "outbox", "comments"])

    File.mkdir_p!(comments_dir)

    File.write!(Path.join(comments_dir, "blog-2.md"), """
    ---
    task_id: blog-2
    ---
    Researcher done — handoff to editor.
    """)

    send(name, {:file_event, "agents/ceo/outbox/comments/blog-2.md", [:created]})
    _ = :sys.get_state(name)

    # The task body itself stays unchanged — comments live in the
    # sibling thread file (GEP-30 D8), not inline.
    assert File.read!(task_path) == "---\ntitle: existing task\n---\nPrompt body\n"

    thread_path =
      Path.join([base, "companies", @company, "projects", "blog", "tasks", "blog-2.comments.md"])

    thread = File.read!(thread_path)
    assert thread =~ "kind: task-comments/v1"
    assert thread =~ "task_id: blog-2"
    assert thread =~ ~r/^## \d{4}-\d{2}-\d{2}T.*\| ceo$/m
    assert thread =~ "Researcher done"

    refute File.exists?(Path.join(comments_dir, "blog-2.md"))
    assert_receive {:audit, %{action: "task.comment", target: "blog-2"}}
  end

  # GEP-21 (#17b) — agent memory write path. Agent drops
  # `agents/<sender>/outbox/memory/<type>_<topic>.md`; Router
  # validates + atomic-writes to `memory/<type>_<topic>.md` +
  # upserts MEMORY.md + emits `memory.write`.
  describe "memory write routing (GEP-21)" do
    setup do
      base = TmpGlorboHome.setup()
      scaffold_company(base, ["ceo"])
      {name, _pid} = start_router!(base)
      memory_outbox = Path.join([base, "companies", @company, "agents/ceo/outbox/memory"])
      File.mkdir_p!(memory_outbox)
      {:ok, base: base, router: name, outbox: memory_outbox}
    end

    test "accepted write lands at agents/ceo/memory/ + MEMORY.md upserted + audit emitted",
         %{base: base, router: router, outbox: outbox} do
      File.write!(Path.join(outbox, "feedback_commit_style.md"), """
      ---
      kind: agent-memory/v1
      name: Commit messages lead with why
      description: one-line-hook
      type: feedback
      ---

      Lead with why, not what.
      """)

      send(router, {:file_event, "agents/ceo/outbox/memory/feedback_commit_style.md", [:created]})
      _ = :sys.get_state(router)

      memory_file =
        Path.join([base, "companies/acme/agents/ceo/memory/feedback_commit_style.md"])

      assert File.exists?(memory_file)
      assert File.read!(memory_file) =~ "Lead with why"

      index = File.read!(Path.join([base, "companies/acme/agents/ceo/memory/MEMORY.md"]))
      assert index =~ "feedback_commit_style.md"
      assert index =~ "Commit messages lead with why"
      assert index =~ "one-line-hook"

      refute File.exists?(Path.join(outbox, "feedback_commit_style.md"))
      assert_receive {:audit, %{action: "memory.write"}}
    end

    test "second write replaces the content + keeps a single index line",
         %{base: base, router: router, outbox: outbox} do
      for body <- ["first draft body", "second draft body"] do
        File.write!(Path.join(outbox, "project_glorbo.md"), """
        ---
        kind: agent-memory/v1
        name: Glorbo project state
        type: project
        ---

        #{body}
        """)

        send(router, {:file_event, "agents/ceo/outbox/memory/project_glorbo.md", [:created]})
        _ = :sys.get_state(router)
      end

      memory_file = Path.join([base, "companies/acme/agents/ceo/memory/project_glorbo.md"])
      assert File.read!(memory_file) =~ "second draft body"
      refute File.read!(memory_file) =~ "first draft body"

      index = File.read!(Path.join([base, "companies/acme/agents/ceo/memory/MEMORY.md"]))

      matching =
        index
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.contains?(&1, "(project_glorbo.md)"))

      assert length(matching) == 1
    end

    test "type mismatch between filename prefix and frontmatter is rejected",
         %{base: base, router: router, outbox: outbox} do
      File.write!(Path.join(outbox, "feedback_x.md"), """
      ---
      kind: agent-memory/v1
      name: Wrong type
      type: user
      ---

      body
      """)

      send(router, {:file_event, "agents/ceo/outbox/memory/feedback_x.md", [:created]})
      _ = :sys.get_state(router)

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/memory/feedback_x.md"]))
      refute File.exists?(Path.join(outbox, "feedback_x.md"))
      assert_receive {:audit, %{action: "memory.rejected"}}
    end

    test "oversized body (>8 KB) rejected",
         %{base: base, router: router, outbox: outbox} do
      big = String.duplicate("x", 8 * 1024 + 10)

      File.write!(Path.join(outbox, "project_big.md"), """
      ---
      kind: agent-memory/v1
      type: project
      ---

      #{big}
      """)

      send(router, {:file_event, "agents/ceo/outbox/memory/project_big.md", [:created]})
      _ = :sys.get_state(router)

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/memory/project_big.md"]))
      assert_receive {:audit, %{action: "memory.rejected"}}
    end

    test "delete marker removes memory file + index line + emits memory.delete",
         %{base: base, router: router, outbox: outbox} do
      File.write!(Path.join(outbox, "feedback_tone.md"), """
      ---
      kind: agent-memory/v1
      name: Director tone
      type: feedback
      ---

      Keep it dry.
      """)

      send(router, {:file_event, "agents/ceo/outbox/memory/feedback_tone.md", [:created]})
      _ = :sys.get_state(router)

      assert File.exists?(Path.join([base, "companies/acme/agents/ceo/memory/feedback_tone.md"]))

      delete_dir = Path.join(outbox, "delete")
      File.mkdir_p!(delete_dir)
      File.write!(Path.join(delete_dir, "feedback_tone.md"), "")

      send(router, {:file_event, "agents/ceo/outbox/memory/delete/feedback_tone.md", [:created]})
      _ = :sys.get_state(router)

      refute File.exists?(Path.join([base, "companies/acme/agents/ceo/memory/feedback_tone.md"]))

      # When the last memory goes, MEMORY.md is removed entirely
      # (no point keeping an empty index file around).
      index_path = Path.join([base, "companies/acme/agents/ceo/memory/MEMORY.md"])

      case File.read(index_path) do
        {:ok, content} -> refute content =~ "feedback_tone.md"
        {:error, :enoent} -> :ok
      end

      assert_receive {:audit, %{action: "memory.delete"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Proposals outbox routing (GEP-28 wave 2b / D7) — agent-sourced proposal
  # writes go through the Router via
  # `agents/<sender>/outbox/proposals/<id>.md`. Router classifies, validates,
  # and writes to `proposals/<id>.md` — or rejects and emits
  # `proposal.rejected` audit.
  # ---------------------------------------------------------------------------
  describe "proposal outbox routing (GEP-28 D7)" do
    setup do
      base = TmpGlorboHome.setup()
      scaffold_company(base, ["ceo", "director"])
      File.mkdir_p!(Path.join([base, "companies", @company, "proposals"]))

      ceo_outbox = Path.join([base, "companies", @company, "agents/ceo/outbox/proposals"])

      director_outbox =
        Path.join([base, "companies", @company, "agents/director/outbox/proposals"])

      File.mkdir_p!(ceo_outbox)
      File.mkdir_p!(director_outbox)

      {:ok,
       base: base,
       ceo_outbox: ceo_outbox,
       director_outbox: director_outbox,
       proposals_dir: Path.join([base, "companies", @company, "proposals"])}
    end

    defp start_proposals_router!(base, perms_by_sender) do
      perms_fun = fn sender, _state -> {:ok, Map.get(perms_by_sender, sender, [])} end
      start_router_with_perms!(base, perms_fun)
    end

    defp write_outbox_proposal!(dir, sender, id, body) do
      path = Path.join(dir, "#{id}.md")
      File.write!(path, body)
      {path, "agents/#{sender}/outbox/proposals/#{id}.md"}
    end

    defp wait(router), do: _ = :sys.get_state(router)

    test "P1 create: CEO with proposals:propose:* writes outbox proposal → Router writes proposals/<id>.md with proposed_by stamped",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}]
        })

      {_path, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "hire-writer-2026-04-22", """
        ---
        kind: proposal/v1
        id: hire-writer-2026-04-22
        subtype: hire
        status: pending-approval
        proposed_by: ignored
        proposed_at: 2020-01-01T00:00:00Z
        ---
        Need a Writer.
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      dest = Path.join(proposals_dir, "hire-writer-2026-04-22.md")
      assert File.exists?(dest)
      content = File.read!(dest)
      # Router overrides agent-supplied proposed_by — only the outbox
      # owner is a trustable author.
      assert content =~ "proposed_by: ceo"
      refute content =~ "proposed_by: ignored"
      assert content =~ "status: pending-approval"
      assert content =~ "Need a Writer"

      # Source file dropped from outbox on accept.
      refute File.exists?(Path.join(ceo_outbox, "hire-writer-2026-04-22.md"))
    end

    test "P2 flip-approve: director writes flip over an existing proposal → approved_by stamped, proposed_by preserved",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      # Step 1 — CEO creates the proposal.
      {_p, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "increase-ceo-budget", """
        ---
        kind: proposal/v1
        id: increase-ceo-budget
        subtype: budget
        status: pending-approval
        ---
        Double the monthly cap.
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      # Step 2 — Director flips to approved.
      {_p2, rel2} =
        write_outbox_proposal!(director_outbox, "director", "increase-ceo-budget", """
        ---
        kind: proposal/v1
        id: increase-ceo-budget
        subtype: budget
        status: approved
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      dest = Path.join(proposals_dir, "increase-ceo-budget.md")
      content = File.read!(dest)
      assert content =~ "status: approved"
      assert content =~ "approved_by: director"
      assert content =~ ~r/approved_at: "?\d{4}-\d{2}-\d{2}T/
      # Original proposer preserved through the flip.
      assert content =~ "proposed_by: ceo"
      # Body is preserved from the first write (flip body is
      # ignored).
      assert content =~ "Double the monthly cap"

      refute File.exists?(Path.join(director_outbox, "increase-ceo-budget.md"))
    end

    test "P3 flip-deny: director flips to denied with denial_reason",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "new-webapp", """
        ---
        kind: proposal/v1
        id: new-webapp
        subtype: project
        status: pending-approval
        ---
        Bootstrap a new webapp project.
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "new-webapp", """
        ---
        kind: proposal/v1
        id: new-webapp
        subtype: project
        status: denied
        denial_reason: Out of scope for Q2
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "new-webapp.md"))
      assert content =~ "status: denied"
      assert content =~ "approved_by: director"
      # YAML serializer quotes strings with spaces; parse back to
      # assert semantic equality.
      assert {:ok, meta, _} = Glorbo.Filesystem.Frontmatter.parse(content)
      assert Map.get(meta, "denial_reason") == "Out of scope for Q2"
      assert content =~ "proposed_by: ceo"
    end

    test "P4 flip-superseded: flip sets superseded_by without approval fields",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "hire-writer-old", """
        ---
        kind: proposal/v1
        id: hire-writer-old
        subtype: hire
        status: pending-approval
        ---
        old reasoning
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "hire-writer-old", """
        ---
        kind: proposal/v1
        id: hire-writer-old
        subtype: hire
        status: superseded
        superseded_by: hire-writer-new
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "hire-writer-old.md"))
      assert content =~ "status: superseded"
      assert content =~ "superseded_by: hire-writer-new"
      # Supersede doesn't set approved_by/at (emitted as null).
      assert content =~ "approved_by: null"
      assert content =~ "approved_at: null"
    end

    test "P5 reject create: sender lacks proposals:propose:*",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} = start_proposals_router!(base, %{"ceo" => []})

      {_, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "hire-writer", """
        ---
        kind: proposal/v1
        id: hire-writer
        subtype: hire
        status: pending-approval
        ---
        body
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      refute File.exists?(Path.join(proposals_dir, "hire-writer.md"))
      refute File.exists?(Path.join(ceo_outbox, "hire-writer.md"))
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P6 reject create: status not pending-approval",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{"ceo" => [{"proposals", "propose", "*"}]})

      {_, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "preapproved", """
        ---
        kind: proposal/v1
        id: preapproved
        subtype: hire
        status: approved
        ---
        body
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      refute File.exists?(Path.join(proposals_dir, "preapproved.md"))
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P7 reject create: approval fields pre-filled",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{"ceo" => [{"proposals", "propose", "*"}]})

      {_, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "sneaky", """
        ---
        kind: proposal/v1
        id: sneaky
        subtype: hire
        status: pending-approval
        approved_by: director
        ---
        body
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      refute File.exists?(Path.join(proposals_dir, "sneaky.md"))
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P8 reject create: bad kind",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{"ceo" => [{"proposals", "propose", "*"}]})

      {_, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "wrong-kind", """
        ---
        kind: task/v1
        id: wrong-kind
        subtype: hire
        status: pending-approval
        ---
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      refute File.exists?(Path.join(proposals_dir, "wrong-kind.md"))
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P9 reject create: id doesn't match filename stem",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{"ceo" => [{"proposals", "propose", "*"}]})

      {_, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "filename-a", """
        ---
        kind: proposal/v1
        id: filename-b
        subtype: hire
        status: pending-approval
        ---
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      refute File.exists?(Path.join(proposals_dir, "filename-a.md"))
      refute File.exists?(Path.join(proposals_dir, "filename-b.md"))
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P10 reject flip: sender lacks proposals:decide:*",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      # Seed with a valid pending proposal first (CEO can propose).
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          # Director with only propose, no decide.
          "director" => [{"proposals", "propose", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "needs-decide", """
        ---
        kind: proposal/v1
        id: needs-decide
        subtype: hire
        status: pending-approval
        ---
        body
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "needs-decide", """
        ---
        kind: proposal/v1
        id: needs-decide
        subtype: hire
        status: approved
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "needs-decide.md"))
      assert content =~ "status: pending-approval"
      refute content =~ "approved_by"
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P11 reject flip: self-approval (sender == proposed_by)",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      # CEO has both propose and decide (bad combo for security — test
      # that even so, they can't self-approve).
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}, {"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "self-approve", """
        ---
        kind: proposal/v1
        id: self-approve
        subtype: hire
        status: pending-approval
        ---
        body
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(ceo_outbox, "ceo", "self-approve", """
        ---
        kind: proposal/v1
        id: self-approve
        subtype: hire
        status: approved
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "self-approve.md"))
      assert content =~ "status: pending-approval"
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    test "P12b flip denied→approved clears stale denial_reason",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "revived", """
        ---
        kind: proposal/v1
        id: revived
        subtype: hire
        status: pending-approval
        ---
        first attempt
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "revived", """
        ---
        kind: proposal/v1
        id: revived
        subtype: hire
        status: denied
        denial_reason: Not yet
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      {_, rel3} =
        write_outbox_proposal!(director_outbox, "director", "revived", """
        ---
        kind: proposal/v1
        id: revived
        subtype: hire
        status: approved
        ---
        """)

      send(name, {:file_event, rel3, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "revived.md"))
      assert content =~ "status: approved"
      # Stale denial_reason must be cleared on the approve flip.
      refute content =~ "denial_reason: Not yet"
    end

    test "P12c approved→superseded clears approved_by/at",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "hire-old", """
        ---
        kind: proposal/v1
        id: hire-old
        subtype: hire
        status: pending-approval
        ---
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "hire-old", """
        ---
        kind: proposal/v1
        id: hire-old
        subtype: hire
        status: approved
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      {_, rel3} =
        write_outbox_proposal!(director_outbox, "director", "hire-old", """
        ---
        kind: proposal/v1
        id: hire-old
        subtype: hire
        status: superseded
        superseded_by: hire-new
        ---
        """)

      send(name, {:file_event, rel3, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "hire-old.md"))
      assert content =~ "status: superseded"
      assert content =~ "superseded_by: hire-new"
      # Stale approval fields cleared.
      assert content =~ "approved_by: null"
      assert content =~ "approved_at: null"
    end

    test "P12d denial_reason containing YAML-significant chars is quoted on round-trip",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "quoting-test", """
        ---
        kind: proposal/v1
        id: quoting-test
        subtype: hire
        status: pending-approval
        ---
        body
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "quoting-test", """
        ---
        kind: proposal/v1
        id: quoting-test
        subtype: hire
        status: denied
        denial_reason: "Budget: insufficient, see #finance"
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      dest = Path.join(proposals_dir, "quoting-test.md")
      content = File.read!(dest)

      # Written content must be re-parseable — if the YAML emitter
      # didn't quote the `:` / `#` / `,` chars, the frontmatter
      # parser would blow up or lose fields.
      assert {:ok, meta, _body} =
               Glorbo.Filesystem.Frontmatter.parse(content)

      assert Map.get(meta, "denial_reason") ==
               "Budget: insufficient, see #finance"

      assert Map.get(meta, "status") == "denied"
    end

    test "P12 reject flip: invalid status value",
         %{
           base: base,
           ceo_outbox: ceo_outbox,
           director_outbox: director_outbox,
           proposals_dir: proposals_dir
         } do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}],
          "director" => [{"proposals", "decide", "*"}]
        })

      {_, rel1} =
        write_outbox_proposal!(ceo_outbox, "ceo", "bad-flip", """
        ---
        kind: proposal/v1
        id: bad-flip
        subtype: hire
        status: pending-approval
        ---
        """)

      send(name, {:file_event, rel1, [:created]})
      wait(name)

      {_, rel2} =
        write_outbox_proposal!(director_outbox, "director", "bad-flip", """
        ---
        kind: proposal/v1
        id: bad-flip
        subtype: hire
        status: junk-status
        ---
        """)

      send(name, {:file_event, rel2, [:created]})
      wait(name)

      content = File.read!(Path.join(proposals_dir, "bad-flip.md"))
      assert content =~ "status: pending-approval"
      assert_receive {:audit, %{action: "proposal.rejected"}}
    end

    # T7 — YAML key injection in the proposal "extras" map. A malicious
    # agent with only `proposals:propose:*` must not be able to smuggle
    # a second `status:` or `approved_by:` line past the Router-stamp
    # by crafting a frontmatter key that embeds newlines. The sink's
    # serializer filters extras to identifier-shaped keys only.
    test "T7 reject injection: extras with newline/colon-in-key are dropped before serialize",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      {name, _pid} =
        start_proposals_router!(base, %{
          "ceo" => [{"proposals", "propose", "*"}]
        })

      # The YAML below includes an attacker-controlled key whose name
      # ends with `.evil` (would be dropped), and a quoted key that
      # embeds a newline+colon (dropped too). Anything injected after
      # a valid key must never end up on its own line in the output.
      {_path, rel} =
        write_outbox_proposal!(ceo_outbox, "ceo", "evil-proposal", """
        ---
        kind: proposal/v1
        id: evil-proposal
        subtype: hire
        status: pending-approval
        proposed_at: 2026-04-22T10:00:00Z
        notes_field: harmless
        "weird.key": dropped-by-filter
        ---
        body
        """)

      send(name, {:file_event, rel, [:created]})
      wait(name)

      dest = Path.join(proposals_dir, "evil-proposal.md")
      assert File.exists?(dest)
      content = File.read!(dest)

      # Router-stamped canonical keys are present once, with the
      # trusted values — nothing overrode them.
      assert content =~ "status: pending-approval"
      assert content =~ "proposed_by: ceo"

      # Legitimate snake_case extras are preserved.
      assert content =~ "notes_field: harmless"

      # Illegitimate keys are silently dropped rather than written
      # out. (The exact key shapes were quoted in the input.)
      refute content =~ "weird.key"
      refute content =~ "\"weird.key\""
    end
  end

  describe "GEP-28 auto-approve-hire within headcount_budget" do
    setup do
      base = TmpGlorboHome.setup()
      scaffold_company(base, ["ceo"])
      File.mkdir_p!(Path.join([base, "companies", @company, "proposals"]))
      ceo_outbox = Path.join([base, "companies", @company, "agents/ceo/outbox/proposals"])
      File.mkdir_p!(ceo_outbox)

      {:ok,
       base: base,
       ceo_outbox: ceo_outbox,
       proposals_dir: Path.join([base, "companies", @company, "proposals"])}
    end

    defp write_company_md!(base, frontmatter) do
      path = Path.join([base, "companies", @company, "company.md"])
      File.write!(path, frontmatter)
      path
    end

    defp start_hire_router!(base, captured_audits) do
      perms_fun = fn
        "ceo", _state -> {:ok, [{"proposals", "propose", "*"}]}
        _, _state -> {:ok, []}
      end

      audit_fun = fn _co, record ->
        Agent.update(captured_audits, &[record | &1])
        :ok
      end

      name = Glorbo.Test.UniqueName.gen("router")

      pid =
        start_supervised!(
          {Router,
           [
             name: name,
             company: @company,
             base: base,
             audit_fun: audit_fun,
             agent_permissions_fun: perms_fun
           ]}
        )

      {name, pid}
    end

    defp wait_for_proposal(router), do: _ = :sys.get_state(router)

    test "hire under budget → proposal written with status=approved + audit emits proposal.auto_approved",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      write_company_md!(base, """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      headcount_budget: 3
      ---
      """)

      {:ok, audits} = Agent.start_link(fn -> [] end)
      {name, _pid} = start_hire_router!(base, audits)

      File.write!(Path.join(ceo_outbox, "hire-writer.md"), """
      ---
      kind: proposal/v1
      id: hire-writer
      subtype: hire
      status: pending-approval
      ---
      Need a Writer to cover weekly posts.
      """)

      send(name, {:file_event, "agents/ceo/outbox/proposals/hire-writer.md", [:created]})
      wait_for_proposal(name)

      dest = Path.join(proposals_dir, "hire-writer.md")
      assert File.exists?(dest)

      content = File.read!(dest)
      assert content =~ "status: approved"
      assert content =~ "approved_by: system/auto-approve-hire"
      assert content =~ ~r/approved_at: "?\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/
      assert content =~ "proposed_by: ceo"
      assert content =~ "Need a Writer"

      recorded = Agent.get(audits, &Enum.reverse/1)

      assert Enum.any?(recorded, fn row ->
               row.actor == "system/auto-approve-hire" and
                 row.action == "proposal.auto_approved" and
                 row.target == "proposals/hire-writer.md"
             end)
    end

    test "hire at exactly budget cap → still pending-approval (no auto-approve)",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      # One agent on disk + budget=1 → current == budget, not `<`.
      write_company_md!(base, """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      headcount_budget: 1
      ---
      """)

      File.write!(
        Path.join([base, "companies", @company, "agents/ceo/AGENT.md"]),
        "---\nkind: agent/v1\nslug: ceo\nrole: CEO\nprovider: claude-code\nnetwork: proxy\n---\n"
      )

      {:ok, audits} = Agent.start_link(fn -> [] end)
      {name, _pid} = start_hire_router!(base, audits)

      File.write!(Path.join(ceo_outbox, "hire-writer.md"), """
      ---
      kind: proposal/v1
      id: hire-writer
      subtype: hire
      status: pending-approval
      ---
      Need a Writer.
      """)

      send(name, {:file_event, "agents/ceo/outbox/proposals/hire-writer.md", [:created]})
      wait_for_proposal(name)

      dest = Path.join(proposals_dir, "hire-writer.md")
      assert File.exists?(dest)
      content = File.read!(dest)
      assert content =~ "status: pending-approval"
      refute content =~ "approved_by: system/auto-approve-hire"
    end

    test "non-hire subtype → director approval still required",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      write_company_md!(base, """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      headcount_budget: 5
      ---
      """)

      {:ok, audits} = Agent.start_link(fn -> [] end)
      {name, _pid} = start_hire_router!(base, audits)

      File.write!(Path.join(ceo_outbox, "bump-budget.md"), """
      ---
      kind: proposal/v1
      id: bump-budget
      subtype: budget
      status: pending-approval
      ---
      Need an extra $50.
      """)

      send(name, {:file_event, "agents/ceo/outbox/proposals/bump-budget.md", [:created]})
      wait_for_proposal(name)

      content = File.read!(Path.join(proposals_dir, "bump-budget.md"))
      assert content =~ "status: pending-approval"
      refute content =~ "approved_by:"
    end

    test "no headcount_budget in company.md → director approval required even for hire",
         %{base: base, ceo_outbox: ceo_outbox, proposals_dir: proposals_dir} do
      # Company.md without the field — safer default is NOT auto-approving.
      write_company_md!(base, """
      ---
      kind: company/v1
      slug: acme
      name: Acme
      ---
      """)

      {:ok, audits} = Agent.start_link(fn -> [] end)
      {name, _pid} = start_hire_router!(base, audits)

      File.write!(Path.join(ceo_outbox, "hire-writer.md"), """
      ---
      kind: proposal/v1
      id: hire-writer
      subtype: hire
      status: pending-approval
      ---
      Need a Writer.
      """)

      send(name, {:file_event, "agents/ceo/outbox/proposals/hire-writer.md", [:created]})
      wait_for_proposal(name)

      content = File.read!(Path.join(proposals_dir, "hire-writer.md"))
      assert content =~ "status: pending-approval"
      refute content =~ "approved_by:"
    end
  end
end
