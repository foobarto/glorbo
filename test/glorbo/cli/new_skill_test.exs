defmodule Glorbo.CLI.NewSkillTest do
  @moduledoc "GEP-10 `glorbo new skill` scaffolder."
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Scaffold.{Company, Skill}

  setup %{glorbo_home: home} do
    assert {:new_company, 0, _} = Company.run(["acme"])
    {:ok, home: home}
  end

  describe "new skill (default)" do
    test "scaffolds a stub skill file", %{home: home} do
      assert {:new_skill, 0, out} = Skill.run(["acme", "code-review"])
      assert out =~ "✓ created skill"

      path = Path.join([home, "companies/acme/skills/code-review.md"])
      assert File.exists?(path)

      content = File.read!(path)
      assert content =~ "name: code-review"
      assert content =~ "tags: []"
      assert content =~ "[EDIT:"
    end

    test "idempotent on re-run", %{home: _home} do
      assert {:new_skill, 0, _} = Skill.run(["acme", "code-review"])
      assert {:new_skill, 0, out} = Skill.run(["acme", "code-review"])
      assert out =~ "⏭ already exists"
    end

    test "missing company returns exit 1 with remediation" do
      assert {:new_skill, 1, out} = Skill.run(["bogus", "code-review"])
      assert out =~ "Company 'bogus' not found"
      assert out =~ "glorbo new company bogus"
    end

    test "invalid slug returns exit 1" do
      assert {:new_skill, 1, out} = Skill.run(["acme", "InvalidCase"])
      assert out =~ "Invalid slug"
    end

    test "missing args returns usage" do
      assert {:new_skill, 1, out} = Skill.run(["acme"])
      assert out =~ "Usage: glorbo new skill"
    end
  end

  describe "new skill --template" do
    test "code-review template renders placeholders", %{home: home} do
      assert {:new_skill, 0, out} =
               Skill.run(["acme", "code-review", "--template", "code-review"])

      assert out =~ "template: code-review"

      path = Path.join([home, "companies/acme/skills/code-review.md"])
      content = File.read!(path)

      # Template substitutes {{ company_upper }} → ACME
      assert content =~ "ACME"
      # Canonical frontmatter present
      assert content =~ "name: code-review"
      # Output structure rubric survives rendering
      assert content =~ "APPROVE"
      assert content =~ "REQUEST_CHANGES"
    end

    test "web-search template renders placeholders", %{home: home} do
      assert {:new_skill, 0, _} =
               Skill.run(["acme", "web-search", "--template", "web-search"])

      content =
        File.read!(Path.join([home, "companies/acme/skills/web-search.md"]))

      assert content =~ "name: web-search"
      assert content =~ "ACME"
      assert content =~ "confidence: high|medium|low"
    end

    test "unknown template returns exit 1 with available list" do
      assert {:new_skill, 1, out} =
               Skill.run(["acme", "code-review", "--template", "nope"])

      assert out =~ "Unknown skill template"
      assert out =~ "code-review"
      assert out =~ "web-search"
    end
  end
end
