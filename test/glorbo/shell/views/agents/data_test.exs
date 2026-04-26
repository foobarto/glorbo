defmodule Glorbo.Shell.Views.Agents.DataTest do
  use ExUnit.Case, async: true

  alias Glorbo.Shell.Views.Agents.Data
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, body) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, body)
    full
  end

  defp seed_company(base, slug) do
    write!(base, "companies/#{slug}/company.md", "---\nkind: company/v1\nname: #{slug}\n---\n")
  end

  defp seed_agent(base, co, slug, opts \\ []) do
    fm =
      [{"kind", "agent/v1"}, {"name", Keyword.get(opts, :name, slug)}]
      |> Kernel.++(Keyword.get(opts, :extra, []))
      |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

    write!(
      base,
      "companies/#{co}/agents/#{slug}/AGENT.md",
      "---\n#{fm}\n---\n# #{slug}\n"
    )
  end

  test "empty agents dir → empty list" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    File.mkdir_p!(Path.join([base, "companies/acme/agents"]))
    assert Data.load_agents(base, "acme") == []
  end

  test "agent with full frontmatter populates every column" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")

    seed_agent(base, "acme", "ceo",
      extra: [
        {"role", "CEO"},
        {"provider", "ollama"},
        {"model", "qwen3:8b"},
        {"network", "outgoing"},
        {"reports_to", "director"}
      ]
    )

    [row] = Data.load_agents(base, "acme")
    assert row.slug == "ceo"
    assert row.name == "ceo"
    assert row.role == "CEO"
    assert row.provider == "ollama"
    assert row.model == "qwen3:8b"
    assert row.network == "outgoing"
    assert row.reports_to == "director"
  end

  test "agent with minimal frontmatter falls back to defaults" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_agent(base, "acme", "minimal")

    [row] = Data.load_agents(base, "acme")
    assert row.name == "minimal"
    assert row.role == "—"
    assert row.provider == "—"
    assert row.model == ""
    assert row.network == "loopback"
    assert row.reports_to == nil
  end

  test "agent without AGENT.md is hidden (not bootable)" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    File.mkdir_p!(Path.join([base, "companies/acme/agents/ghost"]))

    assert Data.load_agents(base, "acme") == []
  end

  test "legacy lowercase agent.md is also accepted" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")

    write!(
      base,
      "companies/acme/agents/legacy/agent.md",
      "---\nkind: agent/v1\nname: Legacy Agent\nrole: Worker\n---\n"
    )

    [row] = Data.load_agents(base, "acme")
    assert row.slug == "legacy"
    assert row.name == "Legacy Agent"
    assert row.role == "Worker"
  end

  test "multiple agents sorted alphabetically by slug" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_agent(base, "acme", "engineer")
    seed_agent(base, "acme", "ceo")
    seed_agent(base, "acme", "researcher")

    rows = Data.load_agents(base, "acme")
    assert Enum.map(rows, & &1.slug) == ["ceo", "engineer", "researcher"]
  end

  test ".archive/ and other dotfile entries are skipped" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_agent(base, "acme", "active")
    File.mkdir_p!(Path.join([base, "companies/acme/agents/.archive/retired"]))

    write!(
      base,
      "companies/acme/agents/.archive/retired/AGENT.md",
      "---\nkind: agent/v1\nname: Retired\n---\n"
    )

    rows = Data.load_agents(base, "acme")
    assert Enum.map(rows, & &1.slug) == ["active"]
  end

  test "non-directory entries under agents/ are skipped" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    seed_agent(base, "acme", "ceo")
    File.mkdir_p!(Path.join([base, "companies/acme/agents"]))
    File.write!(Path.join([base, "companies/acme/agents/stray.md"]), "junk\n")

    rows = Data.load_agents(base, "acme")
    assert Enum.map(rows, & &1.slug) == ["ceo"]
  end

  test "missing agents/ dir → empty list" do
    base = TmpGlorboHome.setup()
    seed_company(base, "acme")
    assert Data.load_agents(base, "acme") == []
  end

  describe "Phase 3d-revisit — budget columns" do
    test "no budget block in frontmatter → cap nil, used 0" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_agent(base, "acme", "ceo")

      [row] =
        Data.load_agents(base, "acme", ledger_fetch_fn: fn _co, _ag, _ym -> nil end)

      assert row.budget_cap_cents == nil
      assert row.budget_used_cents == 0
    end

    test "cap declared as integer dollars converts to cents" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")

      write!(
        base,
        "companies/acme/agents/ceo/AGENT.md",
        "---\nkind: agent/v1\nname: ceo\nbudget:\n  monthly_usd: 25\n---\n"
      )

      [row] =
        Data.load_agents(base, "acme", ledger_fetch_fn: fn _co, _ag, _ym -> nil end)

      assert row.budget_cap_cents == 2500
    end

    test "cap declared as float dollars rounds to cents" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")

      write!(
        base,
        "companies/acme/agents/ceo/AGENT.md",
        "---\nkind: agent/v1\nname: ceo\nbudget:\n  monthly_usd: 12.345\n---\n"
      )

      [row] =
        Data.load_agents(base, "acme", ledger_fetch_fn: fn _co, _ag, _ym -> nil end)

      # 12.345 → 1234.5 → round → 1235 cents
      assert row.budget_cap_cents == 1235
    end

    test "ledger fetch result populates budget_used_cents" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")

      write!(
        base,
        "companies/acme/agents/ceo/AGENT.md",
        "---\nkind: agent/v1\nname: ceo\nbudget:\n  monthly_usd: 10\n---\n"
      )

      ledger_fetch_fn = fn _co, _ag, _ym -> %{cost_usd_cents: 547} end

      [row] = Data.load_agents(base, "acme", ledger_fetch_fn: ledger_fetch_fn)
      assert row.budget_used_cents == 547
      assert row.budget_cap_cents == 1000
    end

    test "ledger fetch raising → fail open with used 0 (no Repo on shell boot)" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_agent(base, "acme", "ceo")

      ledger_fetch_fn = fn _co, _ag, _ym -> raise "no Repo connection" end

      [row] = Data.load_agents(base, "acme", ledger_fetch_fn: ledger_fetch_fn)
      assert row.budget_used_cents == 0
    end

    test ":year_month opt is forwarded to the ledger lookup" do
      base = TmpGlorboHome.setup()
      seed_company(base, "acme")
      seed_agent(base, "acme", "ceo")

      ref = make_ref()
      Process.put({:ledger_args, ref}, nil)

      ledger_fetch_fn = fn co, ag, ym ->
        Process.put({:ledger_args, ref}, {co, ag, ym})
        nil
      end

      _ =
        Data.load_agents(base, "acme",
          ledger_fetch_fn: ledger_fetch_fn,
          year_month: "2024-01"
        )

      assert Process.get({:ledger_args, ref}) == {"acme", "ceo", "2024-01"}
    end
  end
end
