defmodule Glorbo.CLI.Scaffold.RendererTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Scaffold.Renderer

  describe "build_vars/1" do
    test "fills defaults for everything except slug + company" do
      vars = Renderer.build_vars(slug: "alice", company: "acme")

      assert vars.slug == "alice"
      assert vars.company == "acme"
      assert vars.company_upper == "ACME"
      assert vars.name == "ALICE"
      assert vars.reports_to == "director"
      assert vars.provider == "claude-code"
      assert vars.model == "claude-sonnet-4-5"
      assert vars.date =~ ~r/\A\d{4}-\d{2}-\d{2}\z/
    end

    test "accepts overrides" do
      vars =
        Renderer.build_vars(
          slug: "bob",
          company: "acme",
          name: "Bob the Builder",
          provider: "gemini-cli",
          model: "gemini-2.5-pro",
          reports_to: "ceo",
          date: "2026-04-18"
        )

      assert vars.name == "Bob the Builder"
      assert vars.provider == "gemini-cli"
      assert vars.model == "gemini-2.5-pro"
      assert vars.reports_to == "ceo"
      assert vars.date == "2026-04-18"
    end

    test "nil-override falls back to default" do
      vars = Renderer.build_vars(slug: "alice", company: "acme", provider: nil)
      assert vars.provider == "claude-code"
    end
  end

  describe "render/2" do
    test "substitutes every supported variable" do
      template = """
      name: {{ name }}
      slug: {{ slug }}
      company: {{ company }}
      upper: {{ company_upper }}
      reports: {{ reports_to }}
      provider: {{ provider }}
      model: {{ model }}
      date: {{ date }}
      """

      vars = Renderer.build_vars(slug: "alice", company: "acme", date: "2026-04-18")

      rendered = Renderer.render(template, vars)

      assert rendered =~ "name: ALICE"
      assert rendered =~ "slug: alice"
      assert rendered =~ "company: acme"
      assert rendered =~ "upper: ACME"
      assert rendered =~ "reports: director"
      assert rendered =~ "provider: claude-code"
      assert rendered =~ "model: claude-sonnet-4-5"
      assert rendered =~ "date: 2026-04-18"
    end

    test "tolerates whitespace variations inside braces" do
      vars = Renderer.build_vars(slug: "alice", company: "acme")

      assert Renderer.render("{{name}}", vars) == "ALICE"
      assert Renderer.render("{{ name }}", vars) == "ALICE"
      assert Renderer.render("{{   name   }}", vars) == "ALICE"
    end

    test "leaves unknown placeholders untouched" do
      vars = Renderer.build_vars(slug: "alice", company: "acme")
      assert Renderer.render("{{ unknown }}", vars) == "{{ unknown }}"
    end

    test "substitutes the same variable multiple times" do
      vars = Renderer.build_vars(slug: "alice", company: "acme")
      assert Renderer.render("{{ slug }}-{{ slug }}", vars) == "alice-alice"
    end
  end
end
