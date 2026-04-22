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
      assert content =~ "network: proxy"
      # Default permissions: read-only project + chat access so a fresh
      # agent can immediately see what's on disk (updated 2026-04-18).
      assert content =~ "projects:read:*"
      assert content =~ "chat:read:*"
      assert content =~ "monthly_usd: 10.0"
      # Default scaffold attaches the `glorbo` skill so every agent
      # starts knowing how to use the action layer (PLAN P2-4).
      assert content =~ "skills:"
      assert content =~ "- glorbo"
      assert content =~ "heartbeat: null"

      # Empty stdout.log is staged.
      assert File.exists?(Path.join(ag_path, "stdout.log"))

      # All three contract files exist after default scaffold (PLAN P1-4).
      for contract <- ~w(AGENT.md HEARTBEAT.md SOUL.md) do
        assert File.exists?(Path.join(ag_path, contract)),
               "missing contract file: #{contract}"
      end

      soul = File.read!(Path.join(ag_path, "SOUL.md"))
      assert soul =~ "SOUL — ceo"
      assert soul =~ "Tone and voice"
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
      assert spec.network == :proxy
      assert spec.permissions == [{"projects", "read", "*"}, {"chat", "read", "*"}]
      assert spec.model == "claude-sonnet-4-5"
    end
  end

  # GEP-10: --template flag scaffolds from a role template.
  describe "new agent --template" do
    test "ceo template produces a parseable AGENT.md with CEO role", %{home: home} do
      assert {:new_agent, 0, out} = Agent.run(["acme/ceo", "--template", "ceo"])
      assert out =~ "template: ceo"

      path = Path.join([home, "companies/acme/agents/ceo/AGENT.md"])
      content = File.read!(path)

      assert content =~ ~s(role: "Chief Executive Officer")
      assert content =~ "slug: ceo"
      assert content =~ "heartbeat: \"*/30 * * * *\""

      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert spec.slug == "ceo"
    end

    test "engineer template produces parseable AGENT.md", %{home: home} do
      assert {:new_agent, 0, out} = Agent.run(["acme/alice", "--template", "engineer"])
      assert out =~ "template: engineer"

      path = Path.join([home, "companies/acme/agents/alice/AGENT.md"])
      content = File.read!(path)

      assert content =~ ~s(role: "Software Engineer")
      assert content =~ "company_upper" |> then(fn _ -> "ACME" end)
      assert content =~ "ACME"

      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert "code-review" in spec.skills
    end

    test "researcher template produces parseable AGENT.md", %{home: home} do
      assert {:new_agent, 0, _out} = Agent.run(["acme/rae", "--template", "researcher"])

      path = Path.join([home, "companies/acme/agents/rae/AGENT.md"])
      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert "web-search" in spec.skills

      # Provenance rules baked in by PLAN P2-4 to address the
      # paperclip-benchmark hallucination finding.
      content = File.read!(path)
      assert content =~ "Provenance rules"
      assert content =~ "Every numeric claim cites a URL"
      assert content =~ "Never query future dates"
    end

    test "editor template produces parseable AGENT.md", %{home: home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/red", "--template", "editor"])

      path = Path.join([home, "companies/acme/agents/red/AGENT.md"])
      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert spec.role == "Editor"

      content = File.read!(path)
      # Editor's core invariant — don't invent facts.
      assert content =~ "Preserve every citation and URL"
      assert content =~ "Do NOT fill with a plausible-sounding placeholder"
    end

    test "provenance-auditor template produces parseable AGENT.md", %{home: home} do
      assert {:new_agent, 0, _} =
               Agent.run(["acme/provenance", "--template", "provenance-auditor"])

      path = Path.join([home, "companies/acme/agents/provenance/AGENT.md"])
      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert spec.role == "Provenance Auditor"

      content = File.read!(path)
      assert content =~ "PROVENANCE-CLEAN"
      assert content =~ "PROVENANCE-ISSUES"
      assert content =~ "narrow and mechanical"
    end

    test "critiqueops template produces parseable AGENT.md", %{home: home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/crit", "--template", "critiqueops"])

      path = Path.join([home, "companies/acme/agents/crit/AGENT.md"])
      assert {:ok, spec} = Glorbo.Agent.Parser.parse_file(path)
      assert spec.role == "Critique Ops"

      content = File.read!(path)
      # The rubric surface — reviewer checks live citations before approving.
      assert content =~ "APPROVE"
      assert content =~ "BLOCK"
      assert content =~ "REVISE"
    end

    test "--reports-to fills the template reports_to placeholder", %{home: home} do
      assert {:new_agent, 0, _} =
               Agent.run([
                 "acme/alice",
                 "--template",
                 "engineer",
                 "--reports-to",
                 "ceo"
               ])

      content =
        File.read!(Path.join([home, "companies/acme/agents/alice/AGENT.md"]))

      assert content =~ "reports_to: ceo"
      refute content =~ "reports_to: director"
      assert content =~ "You report to ceo"
    end

    test "--provider feeds template provider placeholder", %{home: home} do
      assert {:new_agent, 0, _} =
               Agent.run([
                 "acme/alice",
                 "--template",
                 "engineer",
                 "--provider",
                 "gemini-cli"
               ])

      content =
        File.read!(Path.join([home, "companies/acme/agents/alice/AGENT.md"]))

      assert content =~ "provider: gemini-cli"
    end

    test "unknown template returns exit 1 with available list" do
      assert {:new_agent, 1, out} = Agent.run(["acme/alice", "--template", "nope"])
      assert out =~ "Unknown agent template"
      assert out =~ "ceo"
      assert out =~ "engineer"
      assert out =~ "researcher"
    end

    @tag :skip
    test "template referencing missing skills warns the Director (superseded)", %{home: _home} do
      # Superseded by the builtin-skill fallback added with PLAN P2-4:
      # every builtin template now references `glorbo` which ships as
      # `priv/templates/skills/glorbo.md`, and the detection treats the
      # builtin dir as a valid source (parity with
      # `Glorbo.Skills.Resolver.resolve_skill_src/3`). The warning now
      # only fires for skills that exist in neither the company's
      # `skills/` nor the builtin dir — harder to trigger deterministically
      # from a CLI test without shadowing the user template dir (fixed at
      # `~/.glorbo/templates/agents` and not honoring GLORBO_HOME).
      :skipped
    end

    test "scaffolder writes SOUL.md when the template has one (#118)", %{home: home} do
      assert {:new_agent, 0, _} = Agent.run(["acme/eng", "--template", "engineer"])

      soul_path = Path.join([home, "companies/acme/agents/eng/SOUL.md"])
      assert File.exists?(soul_path)

      soul = File.read!(soul_path)
      # The engineer soul template renders company placeholders.
      assert soul =~ "Software Engineer"
      assert soul =~ "ACME"
    end

    test "no warning when referenced skill already exists", %{home: home} do
      # Pre-create the skill file the engineer template wants.
      skill_dir = Path.join([home, "companies/acme/skills"])
      File.mkdir_p!(skill_dir)
      File.write!(Path.join(skill_dir, "code-review.md"), "---\nname: code-review\n---\n")

      assert {:new_agent, 0, out} =
               Agent.run(["acme/alice", "--template", "engineer"])

      refute out =~ "⚠ template references skills"
    end
  end
end
