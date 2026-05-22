defmodule Glorbo.BackupTest do
  @moduledoc "Plan 05-03 — Backup module unit tests."
  use GlorboTest.CLICase, async: false

  import Bitwise

  alias Glorbo.Test.PortabilityFixtures

  setup %{glorbo_home: home} do
    PortabilityFixtures.write_minimal_company(home, "acme", "ceo")

    archive =
      Path.join(
        System.tmp_dir!(),
        "backup-test-#{System.unique_integer([:positive])}.tar.gz"
      )

    on_exit(fn -> File.rm_rf!(archive) end)

    %{home: home, archive: archive}
  end

  describe "Glorbo.Backup.run/1" do
    test "happy path produces tar.gz with allowlist contents",
         %{home: home, archive: archive} do
      assert {:ok, ^archive} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      assert File.exists?(archive)
      assert File.stat!(archive).size > 100

      {:ok, entries} = :erl_tar.table(String.to_charlist(archive), [:compressed])
      names = Enum.map(entries, &to_string/1)

      # At least one entry under each allowlist dir/file must appear.
      assert Enum.any?(names, &String.starts_with?(&1, "companies/"))
      assert Enum.any?(names, &(&1 == "config.md"))
      assert Enum.any?(names, &String.starts_with?(&1, "audit"))
    end

    test "excludes bin/, models/, containers/, runtime/, run/ (derived)",
         %{home: home, archive: archive} do
      # Seed derived dirs with marker files that MUST NOT appear in archive.
      for d <- ~w(bin models containers runtime run) do
        File.mkdir_p!(Path.join(home, d))
        File.write!(Path.join([home, d, "SHOULD_NOT_APPEAR.marker"]), "derived")
      end

      assert {:ok, _} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      {:ok, entries} = :erl_tar.table(String.to_charlist(archive), [:compressed])
      names = Enum.map(entries, &to_string/1)

      for derived <- ~w(bin models containers runtime run) do
        refute Enum.any?(names, fn n ->
                 String.starts_with?(n, "#{derived}/") or n == derived
               end),
               "archive should not contain #{derived}/ entries but did: #{inspect(names)}"
      end
    end

    test "refuses with pidfile present (D-21)",
         %{home: home, archive: archive} do
      # Write a pidfile containing our own PID — guaranteed alive.
      File.mkdir_p!(Path.join(home, "run"))
      File.write!(Path.join([home, "run", "glorbo.pid"]), System.pid())

      assert {:error, :glorbo_running} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      refute File.exists?(archive),
             "archive must not be written when pidfile guard triggers"
    end

    test "--force-live bypasses pidfile guard",
         %{home: home, archive: archive} do
      File.mkdir_p!(Path.join(home, "run"))
      File.write!(Path.join([home, "run", "glorbo.pid"]), System.pid())

      # Capture the IO.warn output so it doesn't pollute the test run.
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert {:ok, ^archive} =
                 Glorbo.Backup.run(
                   base: home,
                   output: archive,
                   skip_checkpoint: true,
                   force_live: true
                 )
      end)

      assert File.exists?(archive)
    end

    test "output archive has mode 0600 (T-05-06 mitigation)",
         %{home: home, archive: archive} do
      assert {:ok, _} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      mode = File.stat!(archive).mode |> band(0o777)
      assert mode == 0o600, "archive mode should be 0600, got #{Integer.to_string(mode, 8)}"
    end

    test "success leaves no temporary archive beside the final output",
         %{home: home, archive: archive} do
      assert {:ok, _} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      leftovers =
        archive
        |> Path.dirname()
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, Path.basename(archive) <> ".tmp-"))

      assert leftovers == []
    end

    # C-075: the secret-bearing tmp archive must be private from creation,
    # not merely after chmod. The tmp is pre-created 0600 with O_EXCL and
    # :erl_tar.create reuses that inode, so the final archive is 0600 and
    # no world-readable window exists during the build.
    test "tmp archive is private (0600) — checked via final archive mode",
         %{home: home, archive: archive} do
      assert {:ok, _} =
               Glorbo.Backup.run(base: home, output: archive, skip_checkpoint: true)

      # erl_tar.create reuses the 0600 inode we pre-created; rename keeps it.
      assert band(File.stat!(archive).mode, 0o777) == 0o600
      refute File.exists?(archive <> ".tmp-")
    end
  end

  describe "Glorbo.Backup.run_cli/1" do
    test "--help returns help tuple" do
      assert {:backup, 0, out} = Glorbo.Backup.run_cli(["--help"])
      assert out =~ "glorbo backup"
      assert out =~ "--output"
    end
  end
end
