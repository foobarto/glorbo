defmodule Glorbo.Filesystem.ReindexTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.{Agent, Company}
  alias Glorbo.Filesystem.{Reindex, ReindexState}
  alias Glorbo.Test.TmpGlorboHome

  # Helper: build the companies/<co>/... scaffold and write a file.
  defp write!(base, rel, content) do
    full = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
    full
  end

  describe "run/1 (Tests 5–11)" do
    test "Test 5: empty companies tree returns {:ok, %{indexed: 0, skipped: 0, deleted: 0}}" do
      base = TmpGlorboHome.setup()
      File.mkdir_p!(Path.join(base, "companies"))

      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)
    end

    test "Test 5b: missing companies dir returns zero counts without crashing" do
      base = TmpGlorboHome.setup()
      # no companies dir
      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)
    end

    test "Test 6: company.md is inserted into companies table" do
      base = TmpGlorboHome.setup()

      company_path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\nmission: do stuff\n---\n# Acme\n"
        )

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Company)
      assert row.name == "acme"
      assert row.mission == "do stuff"
      assert row.file_path == company_path
    end

    test "Test 7: agent.md is inserted and linked to its company" do
      base = TmpGlorboHome.setup()

      _co = write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      agent_path =
        write!(
          base,
          "companies/acme/agents/ceo/agent.md",
          "---\nname: ceo\nrole: CEO\nprovider: ollama\nmodel: qwen3:8b\n---\n"
        )

      assert {:ok, %{indexed: 2}} = Reindex.run(base: base)

      [company] = Repo.all(Company)
      [agent] = Repo.all(Agent)

      assert agent.name == "ceo"
      assert agent.role == "CEO"
      assert agent.provider == "ollama"
      assert agent.model == "qwen3:8b"
      assert agent.company_id == company.id
      assert agent.file_path == agent_path
    end

    test "Test 8: re-running without changes is a no-op (all unchanged)" do
      base = TmpGlorboHome.setup()
      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)
      # Second pass: md5 matches → unchanged
      assert {:ok, %{indexed: 0, skipped: 0, deleted: 0}} = Reindex.run(base: base)

      # reindex_state has exactly 1 row
      assert length(Repo.all(ReindexState)) == 1
    end

    test "Test 9: modifying a file re-indexes it" do
      base = TmpGlorboHome.setup()
      path = write!(base, "companies/acme/company.md", "---\nname: acme\n---\nv1\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      # Modify the file content — md5 must change
      File.write!(path, "---\nname: acme\nmission: updated\n---\nv2\n")

      assert {:ok, %{indexed: 1}} = Reindex.run(base: base)

      [row] = Repo.all(Company)
      assert row.mission == "updated"
    end

    test "Test 10: deleting a file deletes its reindex_state + domain row" do
      base = TmpGlorboHome.setup()

      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")
      agent = write!(base, "companies/acme/agents/ceo/agent.md", "---\nname: ceo\n---\n")

      assert {:ok, %{indexed: 2}} = Reindex.run(base: base)
      assert length(Repo.all(Agent)) == 1

      File.rm!(agent)

      assert {:ok, %{deleted: 1}} = Reindex.run(base: base)
      assert Repo.all(Agent) == []
      # Company row is untouched
      assert length(Repo.all(Company)) == 1
    end

    test "Test 11: corrupt YAML is skipped, logged, other files still indexed" do
      base = TmpGlorboHome.setup()

      # Valid company
      write!(base, "companies/acme/company.md", "---\nname: acme\n---\n")

      # Corrupt agent
      write!(
        base,
        "companies/acme/agents/ceo/agent.md",
        "---\nname: : : :\n  - broken\n  garbage:\n---\nbody\n"
      )

      import ExUnit.CaptureLog

      {result, log} =
        with_log(fn ->
          Reindex.run(base: base)
        end)

      assert {:ok, %{indexed: 1, skipped: 1}} = result
      assert log =~ "skipped"

      # Company still indexed
      assert length(Repo.all(Company)) == 1
      assert Repo.all(Agent) == []
    end
  end

  describe "mark_dirty/2 + process_path/2 (Plan 04 B4)" do
    test "process_path/2 indexes a single file without a full run" do
      base = TmpGlorboHome.setup()

      path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\nmission: x\n---\n"
        )

      assert :indexed = Reindex.process_path("acme", path)
      [row] = Repo.all(Company)
      assert row.name == "acme"
    end

    test "mark_dirty/2 returns :ok and triggers incremental index" do
      base = TmpGlorboHome.setup()

      path =
        write!(
          base,
          "companies/acme/company.md",
          "---\nname: acme\n---\n"
        )

      assert :ok = Reindex.mark_dirty("acme", path)
      [row] = Repo.all(Company)
      assert row.name == "acme"

      # Second call on an unchanged file should still return :ok.
      assert :ok = Reindex.mark_dirty("acme", path)
    end
  end
end
