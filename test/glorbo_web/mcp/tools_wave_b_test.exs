defmodule GlorboWeb.MCP.ToolsWaveBTest do
  @moduledoc """
  Integration tests for the wave (b.1) read-only MCP tools
  (GEP-29). Each test seeds a tmp `GLORBO_HOME` with minimal
  fixture files and calls the tool through the JSON-RPC dispatcher
  so we exercise the same path external clients hit.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server

  defp seed_company(base, company, opts \\ []) do
    co_path = Path.join([base, "companies", company])
    File.mkdir_p!(Path.join(co_path, "agents"))
    File.mkdir_p!(Path.join(co_path, "projects"))
    File.mkdir_p!(Path.join(co_path, "proposals"))

    File.write!(Path.join(co_path, "company.md"), """
    ---
    kind: company/v1
    slug: #{company}
    name: #{Keyword.get(opts, :name, String.capitalize(company))}
    headcount_budget: #{Keyword.get(opts, :budget, 3)}
    ---

    mission
    """)

    co_path
  end

  defp seed_agent(co_path, slug, opts \\ []) do
    agent_dir = Path.join([co_path, "agents", slug])
    File.mkdir_p!(agent_dir)

    File.write!(Path.join(agent_dir, "AGENT.md"), """
    ---
    kind: agent/v1
    slug: #{slug}
    name: #{Keyword.get(opts, :name, String.capitalize(slug))}
    role: #{Keyword.get(opts, :role, "Engineer")}
    provider: #{Keyword.get(opts, :provider, "claude-code")}
    model: #{Keyword.get(opts, :model, "claude-haiku-4-5")}
    network: #{Keyword.get(opts, :network, "api-only")}
    reports_to: #{Keyword.get(opts, :reports_to, "director")}
    heartbeat: "*/15 * * * *"
    budget:
      monthly_usd: 0.0
    allow_untracked_budget: true
    permissions:
      - #{Keyword.get(opts, :permission, "tasks:read:*")}
    ---

    # #{slug}

    seeded
    """)

    agent_dir
  end

  defp seed_task(co_path, project, task_id, opts \\ []) do
    tasks_dir = Path.join([co_path, "projects", project, "tasks"])
    File.mkdir_p!(tasks_dir)

    File.write!(Path.join([co_path, "projects", project, "project.md"]), """
    ---
    slug: #{project}
    name: #{project}
    ---
    """)

    File.write!(Path.join(tasks_dir, "#{task_id}.md"), """
    ---
    kind: task/v1
    title: #{Keyword.get(opts, :title, "Test task")}
    status: #{Keyword.get(opts, :status, "todo")}
    assigned_to: #{Keyword.get(opts, :assigned_to, "engineer")}
    ---

    #{Keyword.get(opts, :body, "Do the thing.")}
    """)
  end

  defp seed_proposal(co_path, id, opts \\ []) do
    File.write!(Path.join([co_path, "proposals", "#{id}.md"]), """
    ---
    kind: proposal/v1
    id: #{id}
    subtype: #{Keyword.get(opts, :subtype, "hire")}
    status: #{Keyword.get(opts, :status, "pending-approval")}
    proposed_by: #{Keyword.get(opts, :proposed_by, "ceo")}
    requires_approval: director
    proposed_at: 2026-04-22T00:00:00Z
    ---

    body
    """)
  end

  defp call_tool(name, args, base) do
    Server.dispatch(
      "tools/call",
      %{"name" => name, "arguments" => args},
      %{client: "test", base: base}
    )
  end

  # ---------------------------------------------------------------------------
  # get_company
  # ---------------------------------------------------------------------------

  describe "glorbo.get_company" do
    test "returns frontmatter + counts for existing company" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme", name: "Acme Corp", budget: 5)
      seed_agent(co_path, "ceo")
      seed_agent(co_path, "engineer")
      seed_task(co_path, "blog", "blog-1")
      seed_proposal(co_path, "hire-writer")

      assert {:reply, %{"isError" => false, "structuredContent" => result}} =
               call_tool("glorbo.get_company", %{"company" => "acme"}, base)

      assert result["slug"] == "acme"
      assert result["frontmatter"]["name"] == "Acme Corp"
      assert result["frontmatter"]["headcount_budget"] == 5
      assert result["counts"] == %{"agents" => 2, "projects" => 1, "proposals" => 1}
    end

    test "returns isError=true when company dir missing" do
      base = TmpGlorboHome.setup()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool("glorbo.get_company", %{"company" => "nope"}, base)

      assert reason =~ "company_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # list_agents
  # ---------------------------------------------------------------------------

  describe "glorbo.list_agents" do
    test "returns all agents with parsed metadata" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_agent(co_path, "ceo", role: "CEO", provider: "claude-code")
      seed_agent(co_path, "engineer", role: "Engineer", provider: "codex")

      assert {:reply, %{"isError" => false, "structuredContent" => %{"agents" => agents}}} =
               call_tool("glorbo.list_agents", %{"company" => "acme"}, base)

      assert length(agents) == 2
      slugs = Enum.map(agents, & &1["slug"])
      assert "ceo" in slugs
      assert "engineer" in slugs

      ceo = Enum.find(agents, &(&1["slug"] == "ceo"))
      assert ceo["role"] == "CEO"
      assert ceo["provider"] == "claude-code"
      assert is_list(ceo["permissions"])
    end

    test "returns empty list when agents/ missing" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")
      File.rm_rf!(Path.join([base, "companies", "acme", "agents"]))

      assert {:reply, %{"isError" => false, "structuredContent" => %{"agents" => []}}} =
               call_tool("glorbo.list_agents", %{"company" => "acme"}, base)
    end
  end

  # ---------------------------------------------------------------------------
  # get_agent
  # ---------------------------------------------------------------------------

  describe "glorbo.get_agent" do
    test "returns full spec for existing agent" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_agent(co_path, "ceo", role: "CEO", model: "claude-opus-4-7")

      assert {:reply, %{"isError" => false, "structuredContent" => spec}} =
               call_tool(
                 "glorbo.get_agent",
                 %{"company" => "acme", "agent" => "ceo"},
                 base
               )

      assert spec["slug"] == "ceo"
      assert spec["role"] == "CEO"
      assert spec["model"] == "claude-opus-4-7"
      assert spec["network"] == "api-only"
      assert is_list(spec["permissions"])
    end

    test "returns isError on missing agent" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_agent",
                 %{"company" => "acme", "agent" => "ghost"},
                 base
               )

      assert reason =~ "parse_failed"
    end
  end

  # ---------------------------------------------------------------------------
  # list_tasks + filters
  # ---------------------------------------------------------------------------

  describe "glorbo.list_tasks" do
    setup do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_task(co_path, "blog", "blog-1", status: "todo", assigned_to: "writer")
      seed_task(co_path, "blog", "blog-2", status: "in-progress", assigned_to: "writer")
      seed_task(co_path, "web", "web-1", status: "done", assigned_to: "engineer")
      {:ok, base: base}
    end

    test "unfiltered returns all three tasks", %{base: base} do
      assert {:reply, %{"structuredContent" => %{"tasks" => tasks}}} =
               call_tool("glorbo.list_tasks", %{"company" => "acme"}, base)

      assert length(tasks) == 3
    end

    test "filter by project narrows to matching project", %{base: base} do
      assert {:reply, %{"structuredContent" => %{"tasks" => tasks}}} =
               call_tool(
                 "glorbo.list_tasks",
                 %{"company" => "acme", "project" => "blog"},
                 base
               )

      assert length(tasks) == 2
      assert Enum.all?(tasks, &(&1["project"] == "blog"))
    end

    test "filter by status", %{base: base} do
      assert {:reply, %{"structuredContent" => %{"tasks" => tasks}}} =
               call_tool(
                 "glorbo.list_tasks",
                 %{"company" => "acme", "status" => "in-progress"},
                 base
               )

      assert [%{"task_id" => "blog-2", "status" => "in-progress"}] = tasks
    end

    test "filter by assigned_to", %{base: base} do
      assert {:reply, %{"structuredContent" => %{"tasks" => tasks}}} =
               call_tool(
                 "glorbo.list_tasks",
                 %{"company" => "acme", "assigned_to" => "writer"},
                 base
               )

      assert length(tasks) == 2
      assert Enum.all?(tasks, &(&1["assigned_to"] == "writer"))
    end
  end

  # ---------------------------------------------------------------------------
  # get_task
  # ---------------------------------------------------------------------------

  describe "glorbo.get_task" do
    test "returns full task with body" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_task(co_path, "blog", "blog-1", title: "Write post", body: "Draft the intro.")

      assert {:reply, %{"isError" => false, "structuredContent" => task}} =
               call_tool(
                 "glorbo.get_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "blog-1"},
                 base
               )

      assert task["task_id"] == "blog-1"
      assert task["title"] == "Write post"
      assert task["body"] =~ "Draft the intro"
    end

    test "isError when task file absent" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "nope"},
                 base
               )

      assert reason =~ "task_not_found"
    end
  end

  # ---------------------------------------------------------------------------
  # list_proposals + status filter
  # ---------------------------------------------------------------------------

  describe "glorbo.list_proposals" do
    test "returns all proposals with metadata" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_proposal(co_path, "hire-writer", status: "pending-approval")
      seed_proposal(co_path, "increase-budget", status: "approved", subtype: "budget")

      assert {:reply, %{"isError" => false, "structuredContent" => %{"proposals" => proposals}}} =
               call_tool("glorbo.list_proposals", %{"company" => "acme"}, base)

      assert length(proposals) == 2
      ids = Enum.map(proposals, & &1["id"])
      assert "hire-writer" in ids
      assert "increase-budget" in ids
    end

    test "filter by status narrows" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_proposal(co_path, "p1", status: "pending-approval")
      seed_proposal(co_path, "p2", status: "approved")

      assert {:reply, %{"structuredContent" => %{"proposals" => [%{"id" => "p1"}]}}} =
               call_tool(
                 "glorbo.list_proposals",
                 %{"company" => "acme", "status" => "pending-approval"},
                 base
               )
    end

    test "empty when no proposals dir" do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")
      File.rm_rf!(Path.join([base, "companies", "acme", "proposals"]))

      assert {:reply, %{"structuredContent" => %{"proposals" => []}}} =
               call_tool("glorbo.list_proposals", %{"company" => "acme"}, base)
    end
  end

  # ---------------------------------------------------------------------------
  # Path-traversal defense — every slug-bearing arg must be gated
  # ---------------------------------------------------------------------------

  describe "slug validation (path-traversal defense)" do
    setup do
      base = TmpGlorboHome.setup()
      _ = seed_company(base, "acme")
      {:ok, base: base}
    end

    test "company arg with path traversal is rejected by every tool", %{base: base} do
      bad = "acme/../other"

      tools = [
        {"glorbo.get_company", %{"company" => bad}},
        {"glorbo.list_agents", %{"company" => bad}},
        {"glorbo.get_agent", %{"company" => bad, "agent" => "ceo"}},
        {"glorbo.list_tasks", %{"company" => bad}},
        {"glorbo.get_task", %{"company" => bad, "project" => "x", "task_id" => "x-1"}},
        {"glorbo.list_proposals", %{"company" => bad}}
      ]

      for {name, args} <- tools do
        assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
                 call_tool(name, args, base)

        assert reason =~ "invalid_slug",
               "#{name}: expected invalid_slug error for company=#{bad}, got #{reason}"
      end
    end

    test "wildcard in company arg is rejected (glob-expansion defense for list_tasks)",
         %{base: base} do
      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool("glorbo.list_tasks", %{"company" => "*"}, base)

      assert reason =~ "invalid_slug"
    end

    test "dotfile in task_id is rejected", %{base: base} do
      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.get_task",
                 %{"company" => "acme", "project" => "blog", "task_id" => "../etc"},
                 base
               )

      assert reason =~ "invalid_slug"
    end

    test "uppercase / whitespace / symbols in agent slug are rejected", %{base: base} do
      for bad <- ["CEO", "ceo agent", "ceo!", "ceo/x"] do
        assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
                 call_tool(
                   "glorbo.get_agent",
                   %{"company" => "acme", "agent" => bad},
                   base
                 )

        assert reason =~ "invalid_slug", "expected reject for agent=#{inspect(bad)}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Malformed-entry contract — surfaced in-band, not silently dropped
  # ---------------------------------------------------------------------------

  describe "malformed-entry handling" do
    test "list_agents includes an error entry for unparseable AGENT.md" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")
      seed_agent(co_path, "good")

      # Seed a broken agent dir (no/corrupt frontmatter).
      File.mkdir_p!(Path.join([co_path, "agents", "broken"]))
      File.write!(Path.join([co_path, "agents", "broken", "AGENT.md"]), "not yaml")

      assert {:reply, %{"structuredContent" => %{"agents" => agents}}} =
               call_tool("glorbo.list_agents", %{"company" => "acme"}, base)

      assert length(agents) == 2
      broken = Enum.find(agents, &(&1["slug"] == "broken"))
      assert Map.has_key?(broken, "error")
      good = Enum.find(agents, &(&1["slug"] == "good"))
      assert good["role"] == "Engineer"
    end

    test "list_proposals surfaces malformed frontmatter as an error entry" do
      base = TmpGlorboHome.setup()
      co_path = seed_company(base, "acme")

      # Corrupt proposal — unterminated YAML.
      File.write!(Path.join([co_path, "proposals", "broken.md"]), """
      ---
      kind: proposal/v1
      status: [unclosed
      ---
      body
      """)

      # Good proposal to ensure both branches land in the same result.
      seed_proposal(co_path, "good")

      assert {:reply, %{"structuredContent" => %{"proposals" => proposals}}} =
               call_tool("glorbo.list_proposals", %{"company" => "acme"}, base)

      assert length(proposals) == 2
      broken = Enum.find(proposals, &(&1["id"] == "broken"))
      assert broken["error"] == "malformed frontmatter"
      good = Enum.find(proposals, &(&1["id"] == "good"))
      assert good["status"] == "pending-approval"
    end
  end
end
