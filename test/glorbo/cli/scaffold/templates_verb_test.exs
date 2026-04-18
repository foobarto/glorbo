defmodule Glorbo.CLI.Scaffold.TemplatesVerbTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Scaffold.TemplatesVerb

  describe "list" do
    test "bare list enumerates both agent + skill templates" do
      assert {:templates, 0, out} = TemplatesVerb.run(["list"])
      assert out =~ "AGENT TEMPLATES"
      assert out =~ "SKILL TEMPLATES"
      assert out =~ "ceo"
      assert out =~ "engineer"
      assert out =~ "researcher"
      assert out =~ "code-review"
      assert out =~ "web-search"
    end

    test "list agent limits to agent templates" do
      assert {:templates, 0, out} = TemplatesVerb.run(["list", "agent"])
      assert out =~ "AGENT TEMPLATES"
      refute out =~ "SKILL TEMPLATES"
    end

    test "list skill limits to skill templates" do
      assert {:templates, 0, out} = TemplatesVerb.run(["list", "skill"])
      assert out =~ "SKILL TEMPLATES"
      refute out =~ "AGENT TEMPLATES"
    end

    test "list with unknown kind returns exit 1" do
      assert {:templates, 1, out} = TemplatesVerb.run(["list", "bogus"])
      assert out =~ "Unknown kind"
    end
  end

  describe "show" do
    test "prints template contents with a header" do
      assert {:templates, 0, out} = TemplatesVerb.run(["show", "agent", "engineer"])
      assert out =~ "# source: builtin"
      assert out =~ "priv/templates/agents/engineer.md"
      assert out =~ "Software Engineer"
    end

    test "returns exit 1 for unknown template" do
      assert {:templates, 1, out} = TemplatesVerb.run(["show", "agent", "bogus"])
      assert out =~ "Template not found"
    end

    test "returns exit 1 for unknown kind" do
      assert {:templates, 1, out} = TemplatesVerb.run(["show", "bogus", "engineer"])
      assert out =~ "Unknown kind"
    end
  end

  describe "help" do
    test "--help returns help text" do
      assert {:templates, 0, out} = TemplatesVerb.run(["--help"])
      assert out =~ "glorbo templates"
      assert out =~ "USAGE"
    end

    test "no args defaults to help" do
      assert {:templates, 0, out} = TemplatesVerb.run([])
      assert out =~ "glorbo templates"
    end
  end
end
