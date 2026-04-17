defmodule Glorbo.CLI.NewAgentTest do
  @moduledoc "Plan 05-02 Task 2 — `Glorbo.CLI.Scaffold.Agent`."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Scaffold.{Agent, Company}

  setup %{glorbo_home: home} do
    # Pre-seed an `acme` company for every test.
    assert {:new_company, 0, _} = Company.run(["acme"])
    {:ok, home: home}
  end

  describe "new agent" do
    test "valid <co>/<slug> scaffolds agents/<slug>/agent.md with defaults",
         %{home: home} do
      assert {:new_agent, 0, out} = Agent.run(["acme/ceo"])
      assert out =~ "✓ created agent"

      ag_path = Path.join([home, "companies/acme/agents/ceo"])
      assert File.dir?(ag_path)

      # Canonical sub-dirs.
      for sub <- ~w(inbox outbox workspace history state) do
        assert File.dir?(Path.join(ag_path, sub)), "missing: #{sub}"
      end

      # agent.md contains D-12 defaults.
      content = File.read!(Path.join(ag_path, "AGENT.md"))
      assert content =~ "slug: ceo"
      assert content =~ ~s(role: "Agent")
      assert content =~ "provider: claude-code"
      assert content =~ "model: claude-sonnet-4-5"
      assert content =~ "network: api-only"
      # Default permissions: read-only project + chat access so a fresh
       # agent can immediately see what's on disk (updated 2026-04-18).
       assert content =~ "projects:read:*"
       assert content =~ "chat:read:*"
      assert content =~ "monthly_usd: 10.0"
      assert content =~ "skills: []"
      assert content =~ "heartbeat: null"

      # Empty stdout.log is staged.
      assert File.exists?(Path.join(ag_path, "stdout.log"))
    end

    test "--role overrides default role", %{home: home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/ceo", "--role", "CEO"])

      content = File.read!(Path.join([home, "companies/acme/agents/ceo/AGENT.md"]))
      assert content =~ ~s(role: "CEO")
      refute content =~ ~s(role: "Agent")
    end

    test "--provider overrides default provider", %{home: home} do
      assert {:new_agent, 0, _} =
               Agent.run(["acme/ceo", "--provider", "gemini-cli"])

      content = File.read!(Path.join([home, "companies/acme/agents/ceo/AGENT.md"]))
      assert content =~ "provider: gemini-cli"
      refute content =~ "provider: claude-code"
    end

    test "missing company returns exit 1 with remediation" do
      assert {:new_agent, 1, out} = Agent.run(["bogus/ceo"])
      assert out =~ "Company 'bogus' not found"
      assert out =~ "glorbo new company bogus"
    end

    test "invalid agent slug returns exit 1" do
      assert {:new_agent, 1, out} = Agent.run(["acme/Foo"])
      assert out =~ "Invalid slug"
    end

    test "invalid co_slash_ag format returns usage" do
      assert {:new_agent, 1, out} = Agent.run(["acme"])
      assert out =~ "Usage: glorbo new agent"
    end

    test "re-run on existing agent returns idempotent marker", %{home: _home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/ceo"])
      assert {:new_agent, 0, out} = Agent.run(["acme/ceo"])
      assert out =~ "⏭ already exists"
    end

    test "--help returns help text" do
      assert {:new_agent, 0, out} = Agent.run(["--help"])
      assert out =~ "glorbo new agent"
      assert out =~ "DEFAULTS"
    end

    test "scaffolded agent.md is parseable by Glorbo.Agent.Parser",
         %{home: home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/ceo"])

      path = Path.join([home, "companies/acme/agents/ceo/AGENT.md"])

      # Parser must accept our generated frontmatter without error.
      assert {:ok, %Glorbo.Agent.Spec{} = spec} =
               Glorbo.Agent.Parser.parse_file(path)

      assert spec.slug == "ceo"
      assert spec.provider == "claude-code"
      assert spec.network == :api_only
      assert spec.permissions == [{"projects", "read", "*"}, {"chat", "read", "*"}]
      assert spec.model == "claude-sonnet-4-5"
    end
  end
end
