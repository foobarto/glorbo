defmodule GlorboWeb.ActionsTest do
  @moduledoc """
  Plan 04-01 Task 2: `GlorboWeb.Actions` Director write-actions.

  Each action is asserted on two dimensions:
    1. **Filesystem effect** — the correct file is appended/rewritten
       with the expected shape.
    2. **Audit emission** — after a successful write, exactly one
       audit event with the correct `action:` key is captured via a
       fake audit sink injected through `opts[:audit]`.

  A write failure (invalid slug, symlink target, oversize body) must
  produce NO audit event.
  """
  use ExUnit.Case, async: false

  alias GlorboWeb.Actions
  alias Glorbo.Test.TmpGlorboHome

  # Fake audit sink — a registered GenServer that records every call it
  # receives from `AuditLog.append/2`. Because `AuditLog.append/2` calls
  # `GenServer.call(server, {:append, entry})`, the fake just needs to
  # handle `{:append, entry}` and stash the entry.
  defmodule FakeAudit do
    use GenServer

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    def calls(pid), do: GenServer.call(pid, :calls)

    @impl true
    def init(_opts), do: {:ok, []}

    @impl true
    def handle_call({:append, entry}, _from, state),
      do: {:reply, :ok, [entry | state]}

    def handle_call(:calls, _from, state),
      do: {:reply, Enum.reverse(state), state}
  end

  setup do
    base = TmpGlorboHome.setup()
    co_dir = Path.join([base, "companies", "acme"])
    File.mkdir_p!(co_dir)
    File.mkdir_p!(Path.join(co_dir, "channels"))
    File.write!(Path.join([co_dir, "channels", "general.md"]), "# general\n")

    {:ok, audit} = start_supervised(FakeAudit)
    %{base: base, audit: audit}
  end

  # ---------------------------------------------------------------------------
  # post_message/4
  # ---------------------------------------------------------------------------

  describe "post_message/4" do
    test "appends Director message with ISO timestamp + writes chat.post audit", %{
      base: base,
      audit: audit
    } do
      assert :ok =
               Actions.post_message("acme", "general", "hello world", base: base, audit: audit)

      content = File.read!(Path.join([base, "companies", "acme", "channels", "general.md"]))
      assert content =~ "# general\n"
      assert content =~ "| director"
      assert content =~ "hello world"
      # ISO 8601 timestamp shape
      assert content =~ ~r/## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "chat.post"
      assert event[:actor] == "director"
      assert event[:company] == "acme"
      assert event[:target] == "channels/general.md"
      assert event[:channel] == "general"
    end

    test "rejects invalid channel slug (T-04-08 path traversal)", %{base: base, audit: audit} do
      assert {:error, :invalid_slug} =
               Actions.post_message("acme", "../evil", "x", base: base, audit: audit)

      # No audit event emitted on validation failure.
      assert FakeAudit.calls(audit) == []
    end

    test "rejects empty body", %{base: base, audit: audit} do
      assert {:error, :empty_body} =
               Actions.post_message("acme", "general", "", base: base, audit: audit)

      assert FakeAudit.calls(audit) == []
    end

    test "rejects oversize body (> 10 KiB)", %{base: base, audit: audit} do
      huge = String.duplicate("x", 10_241)

      assert {:error, :body_too_large} =
               Actions.post_message("acme", "general", huge, base: base, audit: audit)

      assert FakeAudit.calls(audit) == []
    end

    test "rejects symlink target (T-04-01 symlink attack defense)", %{base: base, audit: audit} do
      # Replace general.md with a symlink pointing elsewhere.
      chan = Path.join([base, "companies", "acme", "channels", "general.md"])
      File.rm!(chan)
      decoy = Path.join(base, "decoy.md")
      File.write!(decoy, "# decoy\n")
      :ok = File.ln_s(decoy, chan)

      assert {:error, :not_a_regular_file} =
               Actions.post_message("acme", "general", "hi", base: base, audit: audit)

      assert FakeAudit.calls(audit) == []
    end

    test "@mention of an existing agent writes inbox/mentions file + agent.wake audit",
         %{base: base, audit: audit} do
      # Create the target agent directory so the Director mention has
      # somewhere to land.
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ceo can you take a look?",
                 base: base,
                 audit: audit
               )

      mentions_dir = Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])
      assert File.dir?(mentions_dir)
      files = File.ls!(mentions_dir)
      assert Enum.any?(files, &String.ends_with?(&1, "-general.md"))

      [content] =
        files
        |> Enum.map(&File.read!(Path.join(mentions_dir, &1)))
        |> Enum.take(1)

      assert content =~ ~s(channel: "general")
      assert content =~ ~s(from: "director")
      assert content =~ "can you take a look?"

      # Expect both chat.post and agent.wake audit events.
      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "chat.post" in actions
      assert "agent.wake" in actions
    end

    test "@mention of unknown agent is a no-op", %{base: base, audit: audit} do
      assert :ok =
               Actions.post_message(
                 "acme",
                 "general",
                 "@ghostagent you there?",
                 base: base,
                 audit: audit
               )

      # chat.post still fires; agent.wake does NOT.
      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "chat.post" in actions
      refute "agent.wake" in actions
    end
  end

  # ---------------------------------------------------------------------------
  # post_task_comment/4
  # ---------------------------------------------------------------------------

  describe "post_task_comment/4" do
    setup %{base: base} do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "ceo", "inbox"]))

      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)

      File.write!(Path.join(tasks_dir, "t-01.md"), """
      ---
      title: "Ship v2"
      status: todo
      assigned_to: ceo
      ---

      Initial prompt.
      """)

      %{task_path: "projects/web/tasks/t-01.md"}
    end

    test "appends `## <ts> | director\\n<body>` to the task file", %{
      base: base,
      audit: audit,
      task_path: tp
    } do
      assert :ok =
               Actions.post_task_comment("acme", tp, "Looks good.",
                 base: base,
                 audit: audit
               )

      abs = Path.join([base, "companies", "acme", tp])
      content = File.read!(abs)

      assert content =~ "Initial prompt."
      assert content =~ ~r/## \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.* \| director/
      assert content =~ "Looks good."
    end

    test "wakes the assignee even without an @mention", %{
      base: base,
      audit: audit,
      task_path: tp
    } do
      assert :ok =
               Actions.post_task_comment("acme", tp, "Please review.",
                 base: base,
                 audit: audit
               )

      mentions_dir =
        Path.join([base, "companies", "acme", "agents", "ceo", "inbox", "mentions"])

      assert File.dir?(mentions_dir)
      assert File.ls!(mentions_dir) != []

      actions = audit |> FakeAudit.calls() |> Enum.map(& &1[:action])
      assert "task.comment" in actions
      assert "agent.wake" in actions
    end

    test "@mention in comment wakes that agent too", %{
      base: base,
      audit: audit,
      task_path: tp
    } do
      File.mkdir_p!(Path.join([base, "companies", "acme", "agents", "cto", "inbox"]))

      assert :ok =
               Actions.post_task_comment("acme", tp, "@cto can you weigh in?",
                 base: base,
                 audit: audit
               )

      cto_mentions =
        Path.join([base, "companies", "acme", "agents", "cto", "inbox", "mentions"])

      assert File.dir?(cto_mentions)
      assert File.ls!(cto_mentions) != []
    end

    test "rejects a traversal task_path", %{base: base, audit: audit} do
      assert {:error, :invalid_task_path} =
               Actions.post_task_comment(
                 "acme",
                 "../../etc/passwd",
                 "x",
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects empty body", %{base: base, audit: audit, task_path: tp} do
      assert {:error, :empty_body} =
               Actions.post_task_comment("acme", tp, "   ", base: base, audit: audit)

      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # set_approval/4
  # ---------------------------------------------------------------------------

  describe "set_approval/4" do
    setup %{base: base} do
      tasks_dir = Path.join([base, "companies", "acme", "projects", "web", "tasks"])
      File.mkdir_p!(tasks_dir)
      task = Path.join(tasks_dir, "t-01.md")

      File.write!(task, """
      ---
      title: "Deploy"
      status: pending
      assigned_to: ceo
      requires_approval: director
      ---

      Ship it.
      """)

      %{task_path: "projects/web/tasks/t-01.md"}
    end

    test ":approved rewrites status: approved + writes approval.approved audit", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      assert :ok = Actions.set_approval("acme", task_path, :approved, base: base, audit: audit)

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: approved"
      assert content =~ "title: \"Deploy\""

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.approved"
      assert event[:actor] == "director"
      assert event[:target] == task_path
    end

    test ":denied rewrites status: denied + writes approval.denied audit", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      assert :ok = Actions.set_approval("acme", task_path, :denied, base: base, audit: audit)

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.denied"
    end

    test "rejects task path with .. segments", %{base: base, audit: audit} do
      assert {:error, :invalid_task_path} =
               Actions.set_approval(
                 "acme",
                 "projects/../../etc/passwd.md",
                 :approved,
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "rejects task path not starting with projects/", %{base: base, audit: audit} do
      assert {:error, :invalid_task_path} =
               Actions.set_approval("acme", "agents/ceo/inbox/evil.md", :approved,
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end

    test "approved restores assigned_to from matching sentinel", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      # Task was reassigned to director by the request-flow; sentinel
      # preserves the original agent. Approve should swap it back.
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      title: "Deploy"
      status: pending
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok = Actions.set_approval("acme", task_path, :approved, base: base, audit: audit)

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: approved"
      assert content =~ "assigned_to: ceo"
      refute content =~ "assigned_to: director"
    end

    test "denied carries requesting agent in audit entry", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 denial_reason: "scope creep"
               )

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "approval.denied"
      assert event[:agent] == "ceo"
      assert event[:denial_reason] == "scope creep"
    end

    test "denied restores assigned_to from sentinel (with reason)", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      # Task was reassigned to director by request-flow; on deny the
      # task stays in the live tree (UI path), so assigned_to should
      # swap back to the requester so they see the denial on their lane.
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      title: "Deploy"
      status: pending-approval
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok =
               Actions.set_approval("acme", task_path, :denied,
                 base: base,
                 audit: audit,
                 denial_reason: "too risky"
               )

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"
      assert content =~ "assigned_to: ceo"
      refute content =~ "assigned_to: director"
      assert content =~ "denial_reason:"
    end

    test "denied without reason restores assigned_to from sentinel", %{
      base: base,
      audit: audit,
      task_path: task_path
    } do
      File.write!(Path.join([base, "companies", "acme", task_path]), """
      ---
      title: "Deploy"
      status: pending-approval
      assigned_to: director
      requires_approval: director
      ---

      Ship it.
      """)

      sentinel_dir = Path.join([base, "companies", "acme", "agents", "ceo", "state"])
      File.mkdir_p!(sentinel_dir)

      File.write!(Path.join(sentinel_dir, "awaiting-approval-t-01.md"), """
      ---
      agent: ceo
      task_id: t-01
      ---

      awaiting
      """)

      assert :ok = Actions.set_approval("acme", task_path, :denied, base: base, audit: audit)

      content = File.read!(Path.join([base, "companies", "acme", task_path]))
      assert content =~ "status: denied"
      assert content =~ "assigned_to: ceo"
    end
  end

  # ---------------------------------------------------------------------------
  # wake_agent/3
  # ---------------------------------------------------------------------------

  describe "wake_agent/3" do
    test "writes state/wake-request.md with frontmatter + audit agent.wake_request", %{
      base: base,
      audit: audit
    } do
      assert :ok = Actions.wake_agent("acme", "ceo", "deploy ready", base: base, audit: audit)

      path = Path.join([base, "companies", "acme", "agents", "ceo", "state", "wake-request.md"])
      assert File.exists?(path)

      body = File.read!(path)
      assert body =~ "---\n"
      assert body =~ "requested_at: "
      assert body =~ "reason: \"deploy ready\""
      assert body =~ "Director wake request."

      [event] = FakeAudit.calls(audit)
      assert event[:action] == "agent.wake_request"
      assert event[:actor] == "director"
      assert event[:target] == "agents/ceo"
      assert event[:reason] == "deploy ready"
    end

    test "nil reason writes empty reason string", %{base: base, audit: audit} do
      assert :ok = Actions.wake_agent("acme", "ceo", nil, base: base, audit: audit)

      path = Path.join([base, "companies", "acme", "agents", "ceo", "state", "wake-request.md"])
      assert File.read!(path) =~ ~s(reason: "")
    end

    test "rejects invalid agent slug", %{base: base, audit: audit} do
      assert {:error, :invalid_slug} =
               Actions.wake_agent("acme", "../evil", "oops", base: base, audit: audit)

      assert FakeAudit.calls(audit) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Write-first / audit-second ordering
  # ---------------------------------------------------------------------------

  describe "audit-after-write ordering" do
    test "set_approval on a missing task file emits NO audit event", %{
      base: base,
      audit: audit
    } do
      # Task path is valid shape but the file doesn't exist — TaskDefinition.write
      # should fail first, and no audit event may be emitted.
      assert {:error, _reason} =
               Actions.set_approval("acme", "projects/ghost/tasks/t-00.md", :approved,
                 base: base,
                 audit: audit
               )

      assert FakeAudit.calls(audit) == []
    end
  end
end
