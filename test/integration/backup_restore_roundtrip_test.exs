defmodule Glorbo.Integration.BackupRestoreRoundtripTest do
  @moduledoc """
  Plan 05-03 integration — same-host A → archive → B roundtrip.

  Uses `Glorbo.Test.PortabilityFixtures` to stage a minimal acme/ceo tree
  at host A, calls `Glorbo.Backup.run/1` then `Glorbo.Restore.run/2` into a
  second hermetic tmp root B, and asserts byte-equality of all markdown
  plus DB rebuildability via `Glorbo.Filesystem.Reindex.run/1`.

  Uses `Glorbo.DataCase` to set up the Ecto sandbox so that the final
  reindex step can insert `companies` / `agents` rows without polluting
  state across tests (Rule 3 deviation: the plan's skeleton used
  `ExUnit.Case` directly but reindex requires sandbox ownership to run
  `Repo.insert!`).
  """
  use Glorbo.DataCase, async: false

  @moduletag :integration

  alias Glorbo.Test.PortabilityFixtures

  setup do
    a =
      Path.join(
        System.tmp_dir!(),
        "glorbo-hostA-#{System.unique_integer([:positive])}"
      )

    b =
      Path.join(
        System.tmp_dir!(),
        "glorbo-hostB-#{System.unique_integer([:positive])}"
      )

    archive =
      Path.join(
        System.tmp_dir!(),
        "roundtrip-#{System.unique_integer([:positive])}.tar.gz"
      )

    File.mkdir_p!(a)
    File.mkdir_p!(b)

    on_exit(fn ->
      Enum.each([a, b, archive], &File.rm_rf!/1)
    end)

    %{a: a, b: b, archive: archive}
  end

  test "A → archive → B: markdown byte-equality + DB rebuildable post-restore",
       %{a: a, b: b, archive: archive} do
    # STAGE 1 — materialise host A with acme/ceo fixture
    PortabilityFixtures.write_minimal_company(a, "acme", "ceo")

    # STAGE 2 — backup A into archive
    assert {:ok, ^archive} =
             Glorbo.Backup.run(base: a, output: archive, skip_checkpoint: true)

    assert File.exists?(archive)
    assert File.stat!(archive).size > 100

    # STAGE 3 — restore archive into empty host B.
    # Restore.run requires an empty dir by default, so wipe B first.
    File.rm_rf!(b)

    assert :ok =
             Glorbo.Restore.run(archive,
               base: b,
               force: false,
               skip_migrate: true,
               skip_fixer: true
             )

    # STAGE 4 — byte-equality assertions (filesystem is source of truth)
    assert File.read!(Path.join([a, "companies", "acme", "company.md"])) ==
             File.read!(Path.join([b, "companies", "acme", "company.md"]))

    assert File.read!(Path.join([a, "companies", "acme", "agents", "ceo", "agent.md"])) ==
             File.read!(Path.join([b, "companies", "acme", "agents", "ceo", "agent.md"]))

    assert File.exists?(Path.join(b, "config.md"))
    assert File.read!(Path.join(a, "config.md")) == File.read!(Path.join(b, "config.md"))

    # STAGE 5 — DB rebuildable from markdown (CLAUDE.md invariant:
    # SQLite is derived data; `glorbo reindex` must reconstruct it).
    db_b = Path.join(b, "glorbo.db")
    if File.exists?(db_b), do: File.rm!(db_b)

    assert {:ok, _} = Glorbo.Filesystem.Reindex.run(base: b)
  end
end
