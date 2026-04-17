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
    assert File.read!(channel_path) =~ "hello"

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

  test "R11: 20 concurrent routes produce 20 appended lines in channel" do
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
    lines = channel_path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 20
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
end
