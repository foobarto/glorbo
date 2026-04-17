defmodule Glorbo.Init.ExampleCompanyTest do
  use ExUnit.Case, async: true

  alias Glorbo.Init.ExampleCompany
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()
    {:ok, base: base}
  end

  describe "scaffold!/1 (Tests 1-3, D-10)" do
    test "Test 1: creates company.md + ceo agent.md + general channel + goal", %{base: base} do
      assert :ok = ExampleCompany.scaffold!(base: base)

      company_dir = Path.join([base, "companies", "acme"])
      assert File.exists?(Path.join(company_dir, "company.md"))
      assert File.exists?(Path.join(company_dir, "agents/ceo/agent.md"))
      assert File.exists?(Path.join(company_dir, "channels/general.md"))
      assert File.exists?(Path.join(company_dir, "goals/q3-2026.md"))

      for sub <- [
            "agents/ceo/inbox",
            "agents/ceo/outbox",
            "agents/ceo/workspace",
            "agents/ceo/history",
            "projects",
            "skills",
            "audit"
          ] do
        assert File.dir?(Path.join(company_dir, sub)), "missing dir: #{sub}"
      end
    end

    test "Test 2: company.md and ceo agent.md carry the expected frontmatter", %{base: base} do
      :ok = ExampleCompany.scaffold!(base: base)
      company_md = File.read!(Path.join([base, "companies", "acme", "company.md"]))
      ceo_md = File.read!(Path.join([base, "companies", "acme", "agents/ceo/agent.md"]))

      assert company_md =~ "name: acme"
      assert company_md =~ "mission:"
      assert ceo_md =~ "name: ceo"
      assert ceo_md =~ "provider: claude-code"
      assert ceo_md =~ "network: none"
      assert ceo_md =~ "model:"
    end

    test "Test 3: scaffold!/1 is idempotent — second call returns :already_exists", %{
      base: base
    } do
      assert :ok = ExampleCompany.scaffold!(base: base)

      # Poison one file; idempotent re-run must NOT overwrite.
      path = Path.join([base, "companies", "acme", "company.md"])
      File.write!(path, "USER-EDITED\n")

      assert :already_exists = ExampleCompany.scaffold!(base: base)
      assert File.read!(path) == "USER-EDITED\n"
    end
  end
end
