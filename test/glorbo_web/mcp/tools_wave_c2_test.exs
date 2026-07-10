defmodule GlorboWeb.MCP.ToolsWaveC2Test do
  @moduledoc """
  Integration tests for wave (c.2) write tools (GEP-29):
  force_agent_heartbeat, create_company, create_agent, create_channel,
  create_proposal, decide_proposal.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Test.TmpGlorboHome
  alias GlorboWeb.MCP.Server

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

  defp setup_base do
    base = TmpGlorboHome.setup()
    {:ok, audit} = start_supervised(FakeAudit)
    {base, audit}
  end

  defp seed_company(base, slug) do
    co_path = Path.join([base, "companies", slug])
    File.mkdir_p!(Path.join(co_path, "agents"))
    File.mkdir_p!(Path.join(co_path, "projects"))
    File.mkdir_p!(Path.join(co_path, "channels"))
    File.mkdir_p!(Path.join(co_path, "audit"))
    File.mkdir_p!(Path.join(co_path, "proposals"))

    File.write!(Path.join(co_path, "company.md"), """
    ---
    kind: company/v1
    slug: #{slug}
    name: #{String.capitalize(slug)}
    ---
    """)

    co_path
  end

  defp call_tool(name, args, base, opts \\ []) do
    client = Keyword.get(opts, :client, "claude-code")
    audit = Keyword.get(opts, :audit)

    context =
      %{client: client, base: base}
      |> then(fn c -> if audit, do: Map.put(c, :audit, audit), else: c end)

    Server.dispatch("tools/call", %{"name" => name, "arguments" => args}, context)
  end

  # ---------------------------------------------------------------------------
  # force_agent_heartbeat
  # ---------------------------------------------------------------------------

  describe "glorbo.force_agent_heartbeat" do
    test "writes wake-request sentinel + emits agent.wake_request audit" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.mkdir_p!(Path.join([co_path, "agents", "engineer", "state"]))

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.force_agent_heartbeat",
                 %{"company" => "acme", "agent" => "engineer", "reason" => "test wake"},
                 base,
                 audit: audit
               )

      assert out["agent"] == "engineer"
      assert out["actor"] == "mcp:claude-code"

      sentinel = Path.join([co_path, "agents", "engineer", "state", "wake-request.md"])
      assert File.exists?(sentinel)
      assert File.read!(sentinel) =~ "test wake"

      entries = FakeAudit.entries(audit)
      wake = Enum.find(entries, &(&1[:action] == "agent.wake_request"))
      assert wake.actor == "mcp:claude-code"
      assert wake.target == "agents/engineer"
    end

    test "traversal in agent slug rejected" do
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.force_agent_heartbeat",
                 %{"company" => "acme", "agent" => "../etc"},
                 base,
                 audit: audit
               )

      assert reason =~ "invalid_slug"
    end
  end

  # ---------------------------------------------------------------------------
  # create_company
  # ---------------------------------------------------------------------------

  describe "glorbo.create_company" do
    test "scaffolds a new company directory" do
      {base, _audit} = setup_base()

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool("glorbo.create_company", %{"slug" => "newco"}, base)

      assert out["slug"] == "newco"
      assert out["status"] == "created"

      co_path = Path.join([base, "companies", "newco"])
      assert File.dir?(co_path)
      assert File.exists?(Path.join(co_path, "company.md"))
      # Canonical subtree.
      for sub <- ~w(agents projects channels audit proposals) do
        assert File.dir?(Path.join(co_path, sub))
      end
    end

    test "idempotent — scaffolding existing slug returns status=existed" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false, "structuredContent" => %{"status" => "existed"}}} =
               call_tool("glorbo.create_company", %{"slug" => "acme"}, base)
    end

    test "invalid slug rejected before touching disk" do
      {base, _audit} = setup_base()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool("glorbo.create_company", %{"slug" => "../etc"}, base)

      assert reason =~ "invalid_slug"
      refute File.dir?(Path.join([base, "companies", "etc"]))
    end
  end

  # ---------------------------------------------------------------------------
  # create_agent
  # ---------------------------------------------------------------------------

  describe "glorbo.create_agent" do
    test "scaffolds agent directory with defaults" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "acme", "slug" => "writer"},
                 base
               )

      assert out["status"] == "created"
      assert File.dir?(Path.join([base, "companies", "acme", "agents", "writer"]))
      assert File.exists?(Path.join([base, "companies", "acme", "agents", "writer", "AGENT.md"]))
    end

    test "accepts the canonical underscore agent slug" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "acme", "slug" => "backend_engineer"},
                 base
               )

      assert File.dir?(Path.join([base, "companies", "acme", "agents", "backend_engineer"]))
    end

    test "refuses reserved slug director (codex L57)" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "acme", "slug" => "director"},
                 base
               )

      assert reason =~ "reserved_slug"
      refute File.exists?(Path.join([base, "companies", "acme", "agents", "director"]))
    end

    test "honors role/provider/model opts" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false}} =
               call_tool(
                 "glorbo.create_agent",
                 %{
                   "company" => "acme",
                   "slug" => "custom",
                   "role" => "Research Lead",
                   "provider" => "claude-code",
                   "model" => "claude-opus-4-7"
                 },
                 base
               )

      agent_md =
        File.read!(Path.join([base, "companies", "acme", "agents", "custom", "AGENT.md"]))

      assert agent_md =~ "Research Lead"
      assert agent_md =~ "claude-opus-4-7"
    end

    test "isError on missing company" do
      {base, _audit} = setup_base()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "nocompany", "slug" => "ag"},
                 base
               )

      assert reason =~ "scaffold_failed"
    end

    # T2 — YAML frontmatter injection via untrusted MCP args. A malicious
    # client that can reach /mcp must not be able to sneak additional
    # keys (permissions, network, heartbeat) into AGENT.md by embedding
    # newlines, frontmatter fences, or closing quotes in role/provider/
    # model/reports_to/template.

    test "T2: rejects role with embedded newline" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      evil = "Agent\"\n- permissions\n  - projects:write:*\nrole: \""

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "acme", "slug" => "evil", "role" => evil},
                 base
               )

      assert reason =~ "invalid_yaml_scalar"
      refute File.exists?(Path.join([base, "companies", "acme", "agents", "evil"]))
    end

    test "T2: rejects role with `---` frontmatter fence" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true}} =
               call_tool(
                 "glorbo.create_agent",
                 %{"company" => "acme", "slug" => "evil2", "role" => "x---y"},
                 base
               )

      refute File.exists?(Path.join([base, "companies", "acme", "agents", "evil2"]))
    end

    test "T2: rejects provider containing newline" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_agent",
                 %{
                   "company" => "acme",
                   "slug" => "evil3",
                   "provider" => "claude-code\nnetwork: open"
                 },
                 base
               )

      assert reason =~ "invalid_identifier"
    end

    test "T2: rejects model with control char" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true}} =
               call_tool(
                 "glorbo.create_agent",
                 %{
                   "company" => "acme",
                   "slug" => "evil4",
                   "model" => "claude-sonnet-4-5\r\npermissions: []"
                 },
                 base
               )
    end

    test "T2: accepts legitimate role + identifiers" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false}} =
               call_tool(
                 "glorbo.create_agent",
                 %{
                   "company" => "acme",
                   "slug" => "ok",
                   "role" => "Senior Staff Engineer (remote)",
                   "provider" => "claude-code",
                   "model" => "claude-opus-4-7"
                 },
                 base
               )

      assert File.exists?(Path.join([base, "companies", "acme", "agents", "ok", "AGENT.md"]))
    end
  end

  # ---------------------------------------------------------------------------
  # create_channel
  # ---------------------------------------------------------------------------

  describe "glorbo.create_channel" do
    test "creates channel file with canonical frontmatter" do
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.create_channel",
                 %{"company" => "acme", "channel" => "engineering"},
                 base,
                 audit: audit
               )

      assert out["status"] == "created"

      content =
        File.read!(Path.join([base, "companies", "acme", "channels", "engineering.md"]))

      assert content =~ "kind: channel-log/v1"
      assert content =~ "channel: engineering"
      assert content =~ "# #engineering"

      assert Enum.any?(FakeAudit.entries(audit), fn entry ->
               entry.action == "channel.create" and entry.actor == "mcp:claude-code"
             end)
    end

    test "idempotent — existing channel returns status=existed" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "channels", "general.md"]), "original\n")

      assert {:reply, %{"isError" => false, "structuredContent" => %{"status" => "existed"}}} =
               call_tool(
                 "glorbo.create_channel",
                 %{"company" => "acme", "channel" => "general"},
                 base,
                 audit: audit
               )

      # File contents untouched.
      assert File.read!(Path.join([co_path, "channels", "general.md"])) == "original\n"
    end
  end

  # ---------------------------------------------------------------------------
  # create_proposal — drops outbox file; Router pickup is exercised in
  # the Router integration tests. Here we just assert the MCP layer
  # writes the right outbox payload.
  # ---------------------------------------------------------------------------

  describe "glorbo.create_proposal" do
    test "writes agents/mcp/outbox/proposals/<id>.md with canonical frontmatter" do
      {base, audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.create_proposal",
                 %{
                   "company" => "acme",
                   "id" => "hire-writer",
                   "subtype" => "hire",
                   "body" => "Need a Writer."
                 },
                 base,
                 audit: audit
               )

      assert out["id"] == "hire-writer"
      assert out["outbox_path"] == "agents/mcp/outbox/proposals/hire-writer.md"

      content =
        File.read!(
          Path.join([
            base,
            "companies",
            "acme",
            "agents",
            "mcp",
            "outbox",
            "proposals",
            "hire-writer.md"
          ])
        )

      assert content =~ "kind: proposal/v1"
      assert content =~ "id: hire-writer"
      assert content =~ "subtype: hire"
      assert content =~ "status: pending-approval"
      assert content =~ "Need a Writer."

      assert Enum.any?(FakeAudit.entries(audit), fn entry ->
               entry.action == "proposal.submit" and entry.actor == "mcp:claude-code"
             end)
    end

    test "isError on missing company" do
      {base, audit} = setup_base()

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_proposal",
                 %{
                   "company" => "ghost",
                   "id" => "x",
                   "subtype" => "hire",
                   "body" => "body"
                 },
                 base,
                 audit: audit
               )

      assert reason =~ "company_not_found"
    end

    test "empty body rejected" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_proposal",
                 %{
                   "company" => "acme",
                   "id" => "x",
                   "subtype" => "hire",
                   "body" => "  "
                 },
                 base
               )

      assert reason =~ "empty"
    end

    test "slug traversal in id rejected" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.create_proposal",
                 %{
                   "company" => "acme",
                   "id" => "../evil",
                   "subtype" => "hire",
                   "body" => "x"
                 },
                 base
               )

      assert reason =~ "invalid_slug"
    end
  end

  # ---------------------------------------------------------------------------
  # decide_proposal
  # ---------------------------------------------------------------------------

  describe "glorbo.decide_proposal" do
    test "drops outbox flip file with status + denial_reason" do
      {base, audit} = setup_base()
      co_path = seed_company(base, "acme")

      # Seed an existing proposal on disk (pretend it was already
      # validated by a prior Router pass).
      File.write!(Path.join([co_path, "proposals", "p1.md"]), """
      ---
      kind: proposal/v1
      id: p1
      subtype: hire
      status: pending-approval
      proposed_by: ceo
      ---
      body
      """)

      assert {:reply, %{"isError" => false, "structuredContent" => out}} =
               call_tool(
                 "glorbo.decide_proposal",
                 %{
                   "company" => "acme",
                   "id" => "p1",
                   "decision" => "denied",
                   "denial_reason" => "out of scope"
                 },
                 base,
                 audit: audit
               )

      assert out["decision"] == "denied"
      assert out["outbox_path"] == "agents/mcp/outbox/proposals/p1.md"

      content =
        File.read!(Path.join([co_path, "agents", "mcp", "outbox", "proposals", "p1.md"]))

      assert content =~ "status: denied"
      assert content =~ "denial_reason: \"out of scope\""

      assert Enum.any?(FakeAudit.entries(audit), fn entry ->
               entry.action == "proposal.decision_submit" and
                 entry.actor == "mcp:claude-code"
             end)
    end

    test "isError on nonexistent proposal" do
      {base, _audit} = setup_base()
      _ = seed_company(base, "acme")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.decide_proposal",
                 %{"company" => "acme", "id" => "ghost", "decision" => "approved"},
                 base
               )

      assert reason =~ "proposal_not_found"
    end

    test "invalid decision rejected" do
      {base, _audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "proposals", "p1.md"]), "---\nid: p1\n---\n")

      assert {:reply, %{"isError" => true, "structuredContent" => %{"reason" => reason}}} =
               call_tool(
                 "glorbo.decide_proposal",
                 %{"company" => "acme", "id" => "p1", "decision" => "maybe"},
                 base
               )

      assert reason =~ "invalid_decision"
    end

    test "supersede decision carries superseded_by" do
      {base, _audit} = setup_base()
      co_path = seed_company(base, "acme")
      File.write!(Path.join([co_path, "proposals", "old.md"]), "---\nid: old\n---\n")

      assert {:reply, %{"isError" => false}} =
               call_tool(
                 "glorbo.decide_proposal",
                 %{
                   "company" => "acme",
                   "id" => "old",
                   "decision" => "superseded",
                   "superseded_by" => "new"
                 },
                 base
               )

      content = File.read!(Path.join([co_path, "agents", "mcp", "outbox", "proposals", "old.md"]))
      assert content =~ "status: superseded"
      assert content =~ "superseded_by: new"
    end
  end
end
