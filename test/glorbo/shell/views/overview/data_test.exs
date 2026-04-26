defmodule Glorbo.Shell.Views.Overview.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Overview.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  defp seed_company(base, slug, name \\ nil) do
    fm_name = name || slug

    write!(
      base,
      "companies/#{slug}/company.md",
      "---\nkind: company/v1\nname: #{fm_name}\n---\n# #{fm_name}\n"
    )
  end

  defp seed_agent(base, slug, agent) do
    write!(
      base,
      "companies/#{slug}/agents/#{agent}/AGENT.md",
      "---\nkind: agent/v1\nname: #{agent}\n---\n# #{agent}\n"
    )
  end

  defp seed_alert(base, slug, agent) do
    write!(
      base,
      "companies/#{slug}/alerts/#{agent}-budget.md",
      "---\nagent: \"#{agent}\"\nmonth: \"2026-04\"\n---\n"
    )
  end

  test "empty companies dir → empty list" do
    base = TmpGlorboHome.setup()
    File.mkdir_p!(Path.join(base, "companies"))
    assert Data.load_companies(base) == []
  end

  test "single seeded company → row with name + zero counts" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme", "Acme Co")

    [row] = Data.load_companies(base)
    assert row.slug == "acme"
    assert row.name == "Acme Co"
    assert row.agent_count == 0
    assert row.alert_count == 0
  end

  test "agent_count counts AGENT.md files (case-insensitive)" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_agent(base, "acme", "ceo")
    seed_agent(base, "acme", "engineer")

    # Lowercase agent.md should also count.
    write!(
      base,
      "companies/acme/agents/legacy/agent.md",
      "---\nkind: agent/v1\nname: legacy\n---\n"
    )

    [row] = Data.load_companies(base)
    assert row.agent_count == 3
  end

  test "alert_count counts alerts/*-budget.md" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_alert(base, "acme", "ceo")
    seed_alert(base, "acme", "editor")

    [row] = Data.load_companies(base)
    assert row.alert_count == 2
  end

  test "name falls back to slug when company.md is missing" do
    base = TmpGlorboHome.setup()
    File.mkdir_p!(Path.join([base, "companies", "ghost"]))

    [row] = Data.load_companies(base)
    assert row.slug == "ghost"
    assert row.name == "ghost"
  end

  test "name falls back to slug when company.md frontmatter has no name" do
    base = TmpGlorboHome.setup()

    write!(
      base,
      "companies/acme/company.md",
      "---\nkind: company/v1\n---\n# acme\n"
    )

    [row] = Data.load_companies(base)
    assert row.name == "acme"
  end

  test "multiple companies sorted alphabetically by slug" do
    base = TmpGlorboHome.setup()
    seed_company(base, "delta")
    seed_company(base, "acme")
    seed_company(base, "beta")

    rows = Data.load_companies(base)
    assert Enum.map(rows, & &1.slug) == ["acme", "beta", "delta"]
  end

  test "non-directory entries under companies/ are skipped" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    # A stray file masquerading as a company dir.
    File.mkdir_p!(Path.join(base, "companies"))
    File.write!(Path.join([base, "companies", "stray-file"]), "hello\n")

    rows = Data.load_companies(base)
    assert Enum.map(rows, & &1.slug) == ["acme"]
  end

  test "missing companies/ dir → empty list" do
    base = TmpGlorboHome.setup()
    # No `companies/` subdir created at all.
    assert Data.load_companies(base) == []
  end
end
