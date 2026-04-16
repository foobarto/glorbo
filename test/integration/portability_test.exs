defmodule Glorbo.Integration.PortabilityTest do
  @moduledoc """
  Plan 05-03 integration — full two-root simulation per D-23 and
  RESEARCH.md §Pattern 6. Stages host A with an `acme/ceo` company, runs
  backup, simulates `scp` as a local file copy, restores onto host B, and
  verifies file-level byte-equality plus reindex success.

  Live agent dispatch against the restored root is OUT OF SCOPE for this
  test — it requires booting the full supervision tree against a second
  `~/.glorbo/`, which is not hermetically testable. That path is the
  Manual UAT item in 05-CONTEXT §D-32.

  Uses `Glorbo.DataCase` to set up the Ecto sandbox so that the final
  reindex step can write to `companies` / `agents` under a per-test owner
  (Rule 3 deviation: the plan's skeleton used `ExUnit.Case` directly but
  `Reindex.run/1` hits `Repo.insert!`).
  """
  use Glorbo.DataCase, async: false

  @moduletag :integration

  alias Glorbo.Test.PortabilityFixtures

  setup do
    a =
      Path.join(
        System.tmp_dir!(),
        "glorbo-portA-#{System.unique_integer([:positive])}"
      )

    b =
      Path.join(
        System.tmp_dir!(),
        "glorbo-portB-#{System.unique_integer([:positive])}"
      )

    archive_src =
      Path.join(
        System.tmp_dir!(),
        "port-src-#{System.unique_integer([:positive])}.tar.gz"
      )

    archive_dst =
      Path.join(
        System.tmp_dir!(),
        "port-dst-#{System.unique_integer([:positive])}.tar.gz"
      )

    File.mkdir_p!(a)

    on_exit(fn ->
      Enum.each([a, b, archive_src, archive_dst], &File.rm_rf!/1)
    end)

    %{a: a, b: b, archive_src: archive_src, archive_dst: archive_dst}
  end

  test "host A → backup → scp-simulated-cp → host B → restore → reindex → byte-equality",
       %{a: a, b: b, archive_src: archive_src, archive_dst: archive_dst} do
    # STAGE 1 — materialise host A
    PortabilityFixtures.write_minimal_company(a, "acme", "ceo")

    # STAGE 2 — backup at A
    assert {:ok, ^archive_src} =
             Glorbo.Backup.run(base: a, output: archive_src, skip_checkpoint: true)

    # STAGE 3 — simulate scp: local copy to a distinct "destination" path.
    # scp is a no-op in single-host test; the point is the destination-host
    # restore is a distinct file path.
    File.cp!(archive_src, archive_dst)
    assert File.exists?(archive_dst)
    assert File.stat!(archive_dst).size == File.stat!(archive_src).size

    # STAGE 4 — restore at B (fresh root — must not exist so that the
    # empty-base path is exercised).
    refute File.exists?(b), "host B must start absent to exercise the empty-base path"

    assert :ok =
             Glorbo.Restore.run(archive_dst,
               base: b,
               force: false,
               skip_migrate: true,
               skip_fixer: true
             )

    # STAGE 5 — file-level byte-equality assertions
    for rel <- [
          "config.md",
          "companies/acme/company.md",
          "companies/acme/agents/ceo/agent.md"
        ] do
      path_a = Path.join(a, rel)
      path_b = Path.join(b, rel)

      assert File.exists?(path_b), "expected #{rel} to exist at host B"
      assert File.read!(path_a) == File.read!(path_b), "#{rel} content mismatch between A and B"
    end

    # STAGE 6 — reindex from markdown (filesystem-is-source-of-truth)
    db_b = Path.join(b, "glorbo.db")
    if File.exists?(db_b), do: File.rm!(db_b)
    assert {:ok, _} = Glorbo.Filesystem.Reindex.run(base: b)

    # STAGE 7 — derived dirs were NOT restored (backup allowlist correctness)
    for derived <- ~w(bin models containers runtime) do
      refute File.exists?(Path.join(b, derived)),
             "derived dir #{derived}/ should NOT be in restored tree"
    end
  end
end
