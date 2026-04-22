defmodule GlorboWeb.MCP.ToolsWaveC1Test do
  @moduledoc """
  Integration tests for wave (c.1) write tools (GEP-29):
  approve_task, deny_task, post_message, capture_brain_dump.

  Each test drives the tool through the JSON-RPC dispatcher so we
  exercise the full CallToolResult wrapping path + context build,
  then asserts the observable filesystem effects (audit JSONL,
  frontmatter mutation, channel append).
  """
  use ExUnit.Case, async: true

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server

  # Minimal audit sink — Actions reaches through `AuditLog.append/2`
  # which is `GenServer.call(server, {:append, entry})`. A GenServer
  # that handles `{:append, _}` is all we need.
  defmodule FakeAudit do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])
    def entries(pid), do: GenServer.call(pid, :entries)
    @impl true
    def init(_), do: {:ok, []}
    @impl true
    def handle_call({:append, entry}, _from, state), do: {:reply, :ok, [entry | state]}
    def handle_call(:entries, _from, state), do: {:reply, Enum.reverse(state), state}
  end

  defp seed_company(base, company) do
    co_path = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join(co_path, "agents"))
    File.mkdir_p!(Path.join(co_path, "projects"))
    File.mkdir_p!(Path.join(co_path, "channels"))
    File.mkdir_p!(Path.join(co_path, "audit"))

    File.write!(Path.join(co_path, "company.md"), """
    ---
    kind: company/v1
    slug: #{company}
    name: Acme
    ---
    """)

    co_path
  end

  defp seed_pending_task(co_path, project, task_id, opts \\ []) do
    tasks_dir = Path.join([co_path, "projects", project, "tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([co_path, "projects", project, "project.md"]), """
    ---
    slug: #{project}
    name: #{project}
    ---
    """)

    assignee = Keyword.get(opts, :assigned_to, "engineer")

    File.write!(Path.join(tasks_dir, "#{task_id}.md"), """
    ---
    kind: task/v1
    title: Test task
    status: pending-approval
    assigned_to: director
    requires_approval: director
    requesting_agent: #{assignee}
    ---

    do the thing
    """)

    # Seed a sentinel so Actions.set_approval's lookup_requesting_agent
    # finds the requester and restores `assigned_to` on approval. This
    # matches what the Gate daemon writes in the live GEP-19 flow.
    state_dir = Path.join([co_path, "agents", assignee, "state"])
    File.mkdir_p!(state_dir)
    File.write!(Path.join(state_dir, "awaiting-approval-#{task_id}.md"), "")
  end

  defp call_tool(name, args, base, opts \\ []) do
    client = Keyword.get(opts, :client, "claude-code")
    audit = Keyword.get(opts, :audit)

    context =
      %{client: client, base: base}
      |> then(fn c -> if audit, do: Map.put(c, :audit, audit), else: c end)

    Server.dispatch("tools/call", %{"name" => name, "arguments" => args}, context)
  end

  defp setup_base do
    base = TmpGlorboHome.setup()
    {:ok, audit} = start_supervised(FakeAudit)
    {base, audit}
  end

  # ---------------------------------------------------------------------------
  # approve_task
  # ---------------------------------------------------------------------------

  describe "glorbo.approve_task" do
    test "flips frontmatter + emits approval.approved audit with mcp:<client> actor" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      seed_pending_task(co_path, "blog", "blog-1", assigned_to: "engineer")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.approve_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "blog-1"},
                 base,
                 client: "claude-code",
                 audit: audit
               )

      assert out["status"] == "approved"
      assert out["actor"] == "mcp:claude-code"

      # File mutation.
      task_content = File.read!(Path.join([co_path, "projects", "blog", "tasks", "blog-1.md"]))
      assert task_content =~ "status: approved"
      # Assignee restored from requesting_agent.
      assert task_content =~ "assigned_to: engineer"

      # Audit written with mcp: actor.
      entries = FakeAudit.entries(audit)
      approve_entry = Enum.find(entries, &(&1[:action] == "approval.approved"))
      assert approve_entry.actor == "mcp:claude-code"
      assert approve_entry.target == "projects/blog/tasks/blog-1.md"
    end

    test "isError when task file missing" do
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.approve_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "ghost"},
                 base,
                 audit: audit
               )

      assert reason =~ "approval_failed"
    end

    test "traversal in task_id rejected" do
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.approve_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "../../etc"},
                 base,
                 audit: audit
               )

      assert reason =~ "invalid_slug"
    end
  end

  # ---------------------------------------------------------------------------
  # deny_task
  # ---------------------------------------------------------------------------

  describe "glorbo.deny_task" do
    test "flips frontmatter with denial_reason + emits denial audit" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      seed_pending_task(co_path, "blog", "blog-2")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.deny_task",
                 %{
                   "company" => "acme",
                   "project" => "blog",
                   "task_id" => "blog-2",
                   "denial_reason" => "out of scope"
                 },
                 base,
                 client: "cursor",
                 audit: audit
               )

      assert out["status"] == "denied"
      assert out["actor"] == "mcp:cursor"
      assert out["denial_reason"] == "out of scope"

      content = File.read!(Path.join([co_path, "projects", "blog", "tasks", "blog-2.md"]))
      assert content =~ "status: denied"
      assert content =~ "denial_reason: \"out of scope\""

      entries = FakeAudit.entries(audit)
      denial = Enum.find(entries, &(&1[:action] == "approval.denied"))
      assert denial.actor == "mcp:cursor"
      # Fake sink snapshots the pre-serialization map (flat keys),
      # which is why we read :denial_reason directly here. The
      # on-disk JSONL shape folds non-core keys into `detail:` —
      # the query_audit tool (wave b.2) reads them from there.
      assert Map.get(denial, :denial_reason) == "out of scope"
    end

    test "empty denial_reason is rejected" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      seed_pending_task(co_path, "blog", "blog-3")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.deny_task",
                 %{
                   "company" => "acme",
                   "project" => "blog",
                   "task_id" => "blog-3",
                   "denial_reason" => "   "
                 },
                 base,
                 audit: audit
               )

      assert reason =~ "empty_denial_reason"
    end
  end

  # ---------------------------------------------------------------------------
  # post_message
  # ---------------------------------------------------------------------------

  describe "glorbo.post_message" do
    test "appends to channel with mcp:<client> header + emits chat.post audit" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "channels", "general.md"]), "")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.post_message",
                 %{"company" => "acme", "channel" => "general", "body" => "hello from cli"},
                 base,
                 client: "claude-code",
                 audit: audit
               )

      assert out["actor"] == "mcp:claude-code"

      channel = File.read!(Path.join([co_path, "channels", "general.md"]))
      assert channel =~ "hello from cli"
      # Header carries the actor verbatim so the UI can distinguish.
      assert channel =~ ~r/^## \d{4}-\d{2}-\d{2}T.*\| mcp:claude-code$/m

      entries = FakeAudit.entries(audit)
      post = Enum.find(entries, &(&1[:action] == "chat.post"))
      assert post.actor == "mcp:claude-code"
      assert Map.get(post, :channel) == "general"
    end

    test "empty body rejected" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "channels", "general.md"]), "")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.post_message",
                 %{"company" => "acme", "channel" => "general", "body" => "   "},
                 base,
                 audit: audit
               )

      assert reason =~ "empty_body"
    end

    test "channel file auto-created on first post" do
      # Actions.post_message creates the channels/<name>.md file if
      # missing (the channel dir is scaffolded with the company).
      # This regression test locks that behaviour so MCP clients can
      # create-on-post the same way the LV does.
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false}} =
               call_tool(
                 "glorbo.post_message",
                 %{"company" => "acme", "channel" => "newchan", "body" => "hi"},
                 base,
                 audit: audit
               )

      path = Path.join([base, "companies", "acme", "channels", "newchan.md"])
      assert File.exists?(path)
    end
  end

  # ---------------------------------------------------------------------------
  # capture_brain_dump
  # ---------------------------------------------------------------------------

  describe "glorbo.capture_brain_dump" do
    test "writes a capture to today's file and returns ts + title" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.capture_brain_dump",
                 %{"company" => "acme", "body" => "Remember to renew the domain"},
                 base
               )

      assert is_binary(out["ts"])
      assert is_binary(out["title"])
      # Lock the `day` field (YYYY-MM-DD) — the tool surfaces it to
      # MCP clients so a later BrainDump.capture regression that
      # dropped the key would silently leak nil on the wire without
      # this assertion.
      assert out["day"] == Date.utc_today() |> Date.to_string()

      day = Date.utc_today() |> Date.to_string()
      file = Path.join([base, "companies", "acme", "braindump", "#{day}.md"])
      assert File.exists?(file)
      assert File.read!(file) =~ "Remember to renew the domain"
    end

    test "empty body rejected" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.capture_brain_dump",
                 %{"company" => "acme", "body" => "   "},
                 base
               )

      assert reason =~ "capture_failed"
    end

    test "traversal in company rejected" do
      {base, _audit} = setup_base()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.capture_brain_dump",
                 %{"company" => "../etc", "body" => "x"},
                 base
               )

      assert reason =~ "invalid_slug"
    end
  end
end
