defmodule GlorboWeb.MCP.ToolsWaveB2Test do
  @moduledoc """
  Integration tests for the wave (b.2) read-only MCP tools
  (GEP-29): get_proposal, list_channels, get_channel,
  list_pending_approvals, query_audit, get_company_health.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server

  defp seed_company(base, company) do
    co_path = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join(co_path, "agents"))
    File.mkdir_p!(Path.join(co_path, "projects"))
    File.mkdir_p!(Path.join(co_path, "proposals"))
    File.mkdir_p!(Path.join(co_path, "channels"))
    File.mkdir_p!(Path.join(co_path, "audit"))

    File.write!(Path.join(co_path, "company.md"), """
    ---
    kind: company/v1
    slug: #{company}
    name: #{String.capitalize(company)}
    headcount_budget: 3
    ---

    mission
    """)

    co_path
  end

  defp call_tool(name, args, base) do
    Server.dispatch(
      "tools/call",
      %{"name" => name, "arguments" => args},
      %{client: "test", base: base}
    )
  end

  # ---------------------------------------------------------------------------
  # get_proposal
  # ---------------------------------------------------------------------------

  describe "glorbo.get_proposal" do
    test "returns full frontmatter + body" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      File.write!(Path.join([co_path, "proposals", "hire-writer.md"]), """
      ---
      kind: proposal/v1
      id: hire-writer
      subtype: hire
      status: pending-approval
      proposed_by: ceo
      proposed_at: 2026-04-22T10:00:00Z
      requires_approval: director
      ---

      We need a Writer. Workload: 7 articles.
      """)

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.get_proposal",
                 %{"company" => "acme", "id" => "hire-writer"},
                 base
               )

      assert out["id"] == "hire-writer"
      assert out["frontmatter"]["subtype"] == "hire"
      assert out["frontmatter"]["proposed_by"] == "ceo"
      assert out["body"] =~ "Writer"
    end

    test "isError when id missing" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_proposal",
                 %{"company" => "acme", "id" => "nope"},
                 base
               )

      assert reason =~ "proposal_not_found"
    end

    test "traversal id rejected" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_proposal",
                 %{"company" => "acme", "id" => "../agents"},
                 base
               )

      assert reason =~ "invalid_slug"
    end
  end

  # ---------------------------------------------------------------------------
  # list_channels
  # ---------------------------------------------------------------------------

  describe "glorbo.list_channels" do
    test "excludes DMs by default and returns sizes" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      File.write!(Path.join([co_path, "channels", "general.md"]), "hi\n")
      File.write!(Path.join([co_path, "channels", "random.md"]), "lorem\n")
      File.write!(Path.join([co_path, "channels", "dm-director--engineer.md"]), "dm\n")

      assert {:reply, %{"structuredContent" => %{"channels" => channels}}} =
               call_tool("glorbo.list_channels", %{"company" => "acme"}, base)

      names = Enum.map(channels, & &1["name"])
      assert "general" in names
      assert "random" in names
      refute "dm-director--engineer" in names

      general = Enum.find(channels, &(&1["name"] == "general"))
      assert is_integer(general["size_bytes"])
    end

    test "include_dms=true surfaces DMs too" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "channels", "general.md"]), "hi\n")
      File.write!(Path.join([co_path, "channels", "dm-director--engineer.md"]), "dm\n")

      assert {:reply, %{"structuredContent" => %{"channels" => channels}}} =
               call_tool(
                 "glorbo.list_channels",
                 %{"company" => "acme", "include_dms" => true},
                 base
               )

      names = Enum.map(channels, & &1["name"])
      assert "general" in names
      assert "dm-director--engineer" in names
    end

    test "empty when channels/ missing" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      File.rm_rf!(Path.join(co_path, "channels"))

      assert {:reply, %{"structuredContent" => %{"channels" => []}}} =
               call_tool("glorbo.list_channels", %{"company" => "acme"}, base)
    end
  end

  # ---------------------------------------------------------------------------
  # get_channel
  # ---------------------------------------------------------------------------

  describe "glorbo.get_channel" do
    defp seed_channel(co_path, name, entries) do
      body =
        Enum.map_join(entries, "\n", fn {ts, author, text} ->
          "## #{ts} | #{author}\n#{text}\n"
        end)

      File.write!(Path.join([co_path, "channels", "#{name}.md"]), body)
    end

    test "returns newest-first messages with timestamp + author + body" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      seed_channel(co_path, "general", [
        {"2026-04-22T09:00:00Z", "ceo", "morning check-in"},
        {"2026-04-22T10:00:00Z", "engineer", "shipped the thing"},
        {"2026-04-22T11:00:00Z", "director", "nice"}
      ])

      assert {:reply, %{"structuredContent" => %{"messages" => messages}}} =
               call_tool(
                 "glorbo.get_channel",
                 %{"company" => "acme", "channel" => "general"},
                 base
               )

      assert length(messages) == 3
      # Newest-first ordering.
      assert Enum.map(messages, & &1["author"]) == ["director", "engineer", "ceo"]
      assert List.first(messages)["body"] == "nice"
    end

    test "fractional-second since is compared as DateTime, not string (regression)" do
      # Same regression as query_audit: `10:00:00.123Z > 10:00:00Z`
      # is false as strings but true as DateTimes. Make sure a
      # boundary `since` includes fractional-second messages
      # published strictly after it.
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      seed_channel(co_path, "general", [
        {"2026-04-22T10:00:00Z", "ceo", "exactly at"},
        {"2026-04-22T10:00:00.123Z", "engineer", "just after"}
      ])

      assert {:reply, %{"structuredContent" => %{"messages" => messages}}} =
               call_tool(
                 "glorbo.get_channel",
                 %{
                   "company" => "acme",
                   "channel" => "general",
                   "since" => "2026-04-22T10:00:00Z"
                 },
                 base
               )

      # Only strictly-after should survive — the boundary message
      # ("exactly at") is excluded because `since` is strict.
      assert [%{"body" => "just after"}] = messages
    end

    test "since filter drops older entries" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      seed_channel(co_path, "general", [
        {"2026-04-22T09:00:00Z", "ceo", "old"},
        {"2026-04-22T10:00:00Z", "engineer", "middle"},
        {"2026-04-22T11:00:00Z", "director", "new"}
      ])

      assert {:reply, %{"structuredContent" => %{"messages" => messages}}} =
               call_tool(
                 "glorbo.get_channel",
                 %{
                   "company" => "acme",
                   "channel" => "general",
                   "since" => "2026-04-22T09:30:00Z"
                 },
                 base
               )

      assert Enum.map(messages, & &1["body"]) == ["new", "middle"]
    end

    test "limit caps the count" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      entries =
        for i <- 1..10,
            do: {"2026-04-22T#{String.pad_leading("#{i}", 2, "0")}:00:00Z", "a", "msg#{i}"}

      seed_channel(co_path, "general", entries)

      assert {:reply, %{"structuredContent" => %{"messages" => messages}}} =
               call_tool(
                 "glorbo.get_channel",
                 %{"company" => "acme", "channel" => "general", "limit" => 3},
                 base
               )

      assert length(messages) == 3
    end

    test "isError when channel absent" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_channel",
                 %{"company" => "acme", "channel" => "nope"},
                 base
               )

      assert reason =~ "channel_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # list_pending_approvals
  # ---------------------------------------------------------------------------

  describe "glorbo.list_pending_approvals" do
    test "finds sentinels and pairs with task titles" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      # Seed an agent with a pending sentinel.
      agent_state = Path.join([co_path, "agents", "engineer", "state"])
      File.mkdir_p!(agent_state)
      File.write!(Path.join(agent_state, "awaiting-approval-blog-1.md"), "reason: needs review\n")

      # Seed the referenced task.
      tasks_dir = Path.join([co_path, "projects", "blog", "tasks"])
      File.mkdir_p!(tasks_dir)

      File.write!(Path.join([co_path, "projects", "blog", "project.md"]), """
      ---
      slug: blog
      name: blog
      ---
      """)

      File.write!(Path.join(tasks_dir, "blog-1.md"), """
      ---
      kind: task/v1
      title: Publish spring post
      status: pending-approval
      assigned_to: engineer
      ---

      body
      """)

      assert {:reply, %{"structuredContent" => %{"pending" => pending}}} =
               call_tool("glorbo.list_pending_approvals", %{"company" => "acme"}, base)

      assert [entry] = pending
      assert entry["task_id"] == "blog-1"
      assert entry["title"] == "Publish spring post"
      assert entry["requesting_agent"] == "engineer"
      assert entry["task_path"] == "projects/blog/tasks/blog-1.md"
    end

    test "empty when no sentinels exist" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"structuredContent" => %{"pending" => []}}} =
               call_tool("glorbo.list_pending_approvals", %{"company" => "acme"}, base)
    end

    test "sentinel without matching task surfaces error entry" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      agent_state = Path.join([co_path, "agents", "engineer", "state"])
      File.mkdir_p!(agent_state)
      File.write!(Path.join(agent_state, "awaiting-approval-ghost-1.md"), "")

      assert {:reply, %{"structuredContent" => %{"pending" => [entry]}}} =
               call_tool("glorbo.list_pending_approvals", %{"company" => "acme"}, base)

      assert entry["task_id"] == "ghost-1"
      assert entry["error"] == "task_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # query_audit
  # ---------------------------------------------------------------------------

  describe "glorbo.query_audit" do
    defp seed_audit(co_path, ym, entries) do
      body = Enum.map_join(entries, "\n", &Jason.encode!/1)
      File.write!(Path.join([co_path, "audit", "#{ym}.jsonl"]), body <> "\n")
    end

    defp current_ym, do: Date.utc_today() |> Date.to_string() |> String.slice(0, 7)

    test "returns current month entries newest-first" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(co_path, ym, [
        %{
          "ts" => "#{ym}-22T09:00:00Z",
          "action" => "task.create",
          "actor" => "ceo",
          "target" => "projects/blog/tasks/blog-1.md"
        },
        %{
          "ts" => "#{ym}-22T10:00:00Z",
          "action" => "task.approve",
          "actor" => "director",
          "target" => "projects/blog/tasks/blog-1.md"
        }
      ])

      assert {:reply, %{"structuredContent" => %{"entries" => entries}}} =
               call_tool("glorbo.query_audit", %{"company" => "acme"}, base)

      assert length(entries) == 2
      assert List.first(entries)["action"] == "task.approve"
    end

    test "actor filter narrows" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(co_path, ym, [
        %{"ts" => "#{ym}-22T09:00:00Z", "action" => "x", "actor" => "ceo"},
        %{"ts" => "#{ym}-22T10:00:00Z", "action" => "y", "actor" => "engineer"}
      ])

      assert {:reply, %{"structuredContent" => %{"entries" => [%{"actor" => "engineer"}]}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "actor" => "engineer"},
                 base
               )
    end

    test "action filter narrows" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(co_path, ym, [
        %{"ts" => "#{ym}-22T09:00:00Z", "action" => "task.create", "actor" => "ceo"},
        %{"ts" => "#{ym}-22T10:00:00Z", "action" => "task.approve", "actor" => "director"}
      ])

      assert {:reply, %{"structuredContent" => %{"entries" => [%{"action" => "task.approve"}]}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "action" => "task.approve"},
                 base
               )
    end

    test "substring q matches against target + detail" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(co_path, ym, [
        %{
          "ts" => "#{ym}-22T09:00:00Z",
          "action" => "proposal.requested",
          "actor" => "ceo",
          "target" => "proposals/hire-writer.md",
          "detail" => %{"subtype" => "hire"}
        },
        %{
          "ts" => "#{ym}-22T10:00:00Z",
          "action" => "task.create",
          "actor" => "ceo",
          "target" => "projects/blog/tasks/blog-1.md"
        }
      ])

      assert {:reply, %{"structuredContent" => %{"entries" => matched}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "q" => "hire-writer"},
                 base
               )

      assert [%{"action" => "proposal.requested"}] = matched
    end

    test "empty when no audit dir" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      File.rm_rf!(Path.join(co_path, "audit"))

      assert {:reply, %{"structuredContent" => %{"entries" => []}}} =
               call_tool("glorbo.query_audit", %{"company" => "acme"}, base)
    end

    test "fractional-second timestamps are compared correctly (regression: string >= was broken)" do
      # Regression: `"2026-04-22T10:00:00.123Z" >= "2026-04-22T10:00:00Z"`
      # is false as strings (`.` < `Z` in ASCII). This tool must use
      # proper DateTime.compare so the newer fractional-second entry
      # isn't wrongly dropped.
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(co_path, ym, [
        %{"ts" => "#{ym}-22T10:00:00Z", "action" => "x", "actor" => "ceo"},
        %{"ts" => "#{ym}-22T10:00:00.123Z", "action" => "y", "actor" => "engineer"}
      ])

      # since is at the boundary — naive string compare would drop
      # the fractional entry even though it's strictly later.
      assert {:reply, %{"structuredContent" => %{"entries" => entries}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "since" => "#{ym}-22T09:59:59Z"},
                 base
               )

      assert length(entries) == 2
    end

    test "audit entries use the canonical `ts` key (not `timestamp`)" do
      # Regression: prior revision keyed off `"timestamp"`, which
      # made time filtering a silent no-op against real audit files.
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      # Seed with `ts` (canonical) and `timestamp` (wrong). The
      # wrong-key entry should still appear (filter is permissive on
      # missing ts), but the `since` filter must target `ts`.
      seed_audit(co_path, ym, [
        %{"ts" => "#{ym}-22T05:00:00Z", "action" => "old", "actor" => "ceo"},
        %{"ts" => "#{ym}-22T15:00:00Z", "action" => "new", "actor" => "ceo"}
      ])

      assert {:reply, %{"structuredContent" => %{"entries" => entries}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "since" => "#{ym}-22T10:00:00Z"},
                 base
               )

      assert [%{"action" => "new"}] = entries
    end

    test "limit caps result size" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      ym = current_ym()

      seed_audit(
        co_path,
        ym,
        for i <- 1..20 do
          %{"ts" => "#{ym}-22T#{String.pad_leading("#{i}", 2, "0")}:00:00Z", "actor" => "a"}
        end
      )

      assert {:reply, %{"structuredContent" => %{"entries" => entries}}} =
               call_tool(
                 "glorbo.query_audit",
                 %{"company" => "acme", "limit" => 5},
                 base
               )

      assert length(entries) == 5
    end
  end

  # ---------------------------------------------------------------------------
  # get_company_health
  # ---------------------------------------------------------------------------

  describe "glorbo.get_company_health" do
    test "returns counts + pending + latest audit timestamp" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      # Agent with pending sentinel.
      state_dir = Path.join([co_path, "agents", "engineer", "state"])
      File.mkdir_p!(state_dir)
      File.write!(Path.join(state_dir, "awaiting-approval-blog-1.md"), "")

      # Project + task.
      File.mkdir_p!(Path.join([co_path, "projects", "blog", "tasks"]))

      File.write!(Path.join([co_path, "projects", "blog", "tasks", "blog-1.md"]), """
      ---
      kind: task/v1
      title: First
      status: in-progress
      ---
      """)

      # Proposal + channel.
      File.write!(Path.join([co_path, "proposals", "p1.md"]), """
      ---
      kind: proposal/v1
      id: p1
      status: pending-approval
      ---
      """)

      File.write!(Path.join([co_path, "channels", "general.md"]), "")

      # Audit entry.
      ym = Date.utc_today() |> Date.to_string() |> String.slice(0, 7)

      File.write!(Path.join([co_path, "audit", "#{ym}.jsonl"]), """
      {"ts":"#{ym}-22T09:00:00Z","action":"x","actor":"ceo"}
      {"ts":"#{ym}-22T10:00:00Z","action":"y","actor":"ceo"}
      """)

      assert {:reply, %{"isError" => false, "structuredContent" => h}} =
               call_tool("glorbo.get_company_health", %{"company" => "acme"}, base)

      assert h["company_exists"] == true
      assert h["counts"]["agents"] == 1
      assert h["counts"]["projects"] == 1
      assert h["counts"]["proposals"] == 1
      assert h["counts"]["channels"] == 1
      assert h["counts"]["tasks_by_status"]["in-progress"] == 1
      assert h["pending_approvals"] == 1
      assert h["audit_last_entry_at"] == "#{ym}-22T10:00:00Z"
      assert h["headcount_budget"] == 3
    end

    test "isError when company dir missing" do
      base = TmpGlorboHome.setup()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool("glorbo.get_company_health", %{"company" => "nope"}, base)

      assert reason =~ "company_not_found"
    end
  end
end
