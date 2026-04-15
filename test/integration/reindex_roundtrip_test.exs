defmodule Glorbo.Integration.ReindexRoundtripTest do
  @moduledoc """
  FS-04 proof: deleting the SQLite state and re-running `reindex` reconstructs
  an identical view of companies + agents + reindex_state from disk.

  W2: audit_events is NOT part of FS-04 roundtrip in Phase 2 — JSONL on disk
  is the source of truth and the `audit_events` SQLite table is not rebuilt
  by reindex during Phase 2. This test deliberately avoids touching the
  audit-events schema module to honour that scope boundary.
  """
  use Glorbo.DataCase, async: false

  @moduletag :integration

  alias Glorbo.{Agent, Company}
  alias Glorbo.Filesystem.{Reindex, ReindexState}
  alias Glorbo.Test.TmpGlorboHome

  defp write!(base, rel, content) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  # Snapshot shape: keyed by file_path for stable comparison.
  defp snapshot do
    companies =
      Company
      |> Repo.all()
      |> Enum.map(&{&1.file_path, {&1.name, &1.mission}})
      |> Enum.sort()

    agents =
      Agent
      |> Repo.all()
      |> Enum.map(&{&1.file_path, {&1.name, &1.role, &1.provider, &1.model}})
      |> Enum.sort()

    states =
      ReindexState
      |> Repo.all()
      |> Enum.map(&{&1.file_path, {&1.md5, &1.size}})
      |> Enum.sort()

    %{companies: companies, agents: agents, states: states}
  end

  test "round-trip: tree → SQLite → delete rows → reindex → identical snapshot" do
    base = TmpGlorboHome.setup()

    write!(base, "companies/acme/company.md", "---\nname: acme\nmission: do stuff\n---\n# acme\n")

    write!(
      base,
      "companies/acme/agents/ceo/agent.md",
      "---\nname: ceo\nrole: CEO\nprovider: ollama\nmodel: qwen3:8b\n---\nSystem prompt.\n"
    )

    write!(
      base,
      "companies/acme/agents/eng/agent.md",
      "---\nname: eng\nrole: Engineer\nprovider: anthropic\nmodel: claude-sonnet\n---\nSystem prompt.\n"
    )

    assert {:ok, %{indexed: 3}} = Reindex.run(base: base)

    before_snapshot = snapshot()
    assert length(before_snapshot.companies) == 1
    assert length(before_snapshot.agents) == 2
    assert length(before_snapshot.states) == 3

    # Simulate `rm glorbo.db` by clearing the W2-scoped tables.
    # NOTE: audit_events is NOT cleared or asserted — it is not in the
    # Phase-2 reindex contract. See moduledoc.
    Repo.delete_all(ReindexState)
    Repo.delete_all(Agent)
    Repo.delete_all(Company)

    assert {:ok, %{indexed: 3}} = Reindex.run(base: base)

    after_snapshot = snapshot()

    assert after_snapshot == before_snapshot
  end
end
