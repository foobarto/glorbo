defmodule Glorbo.RestoreTest do
  @moduledoc "Plan 05-03 — Restore module unit tests."
  use Glorbo.DataCase, async: false

  alias Glorbo.Test.PortabilityFixtures

  setup do
    home = Glorbo.Test.TmpGlorboHome.setup()
    prior = System.get_env("GLORBO_HOME")
    System.put_env("GLORBO_HOME", home)

    on_exit(fn ->
      if prior, do: System.put_env("GLORBO_HOME", prior), else: System.delete_env("GLORBO_HOME")
    end)

    {:ok, glorbo_home: home}
  end

  setup %{glorbo_home: home} do
    # Host A — source for the archive
    host_a =
      Path.join(
        System.tmp_dir!(),
        "restore-hostA-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(host_a)
    PortabilityFixtures.write_minimal_company(host_a, "acme", "ceo")

    archive =
      Path.join(
        System.tmp_dir!(),
        "restore-#{System.unique_integer([:positive])}.tar.gz"
      )

    {:ok, ^archive} =
      Glorbo.Backup.run(base: host_a, output: archive, skip_checkpoint: true)

    # Host B — destination for restore (use glorbo_home as target by default)
    host_b = home

    on_exit(fn ->
      File.rm_rf!(host_a)
      File.rm_rf!(archive)
    end)

    %{host_a: host_a, host_b: host_b, archive: archive}
  end

  describe "Glorbo.Restore.run/2" do
    test "non-empty base without --force returns :non_empty_base",
         %{host_b: b, archive: archive} do
      # glorbo_home is non-empty: seed it further to be sure.
      File.mkdir_p!(Path.join(b, "stuff"))
      File.write!(Path.join([b, "stuff", "existing.txt"]), "pre-existing user data")

      assert {:error, :non_empty_base} =
               Glorbo.Restore.run(archive,
                 base: b,
                 force: false,
                 skip_migrate: true,
                 skip_fixer: true
               )
    end

    test "--force bypasses non-empty-base guard",
         %{host_b: b, archive: archive} do
      File.mkdir_p!(Path.join(b, "stuff"))

      assert :ok =
               Glorbo.Restore.run(archive,
                 base: b,
                 force: true,
                 skip_migrate: true,
                 skip_fixer: true
               )

      assert File.exists?(Path.join(b, "config.md"))
      assert File.exists?(Path.join([b, "companies", "acme", "company.md"]))
    end

    test "traversal-guard rejects archive with ../ entries",
         %{host_b: b} do
      # Hand-craft a malicious archive.
      bad_archive =
        Path.join(
          System.tmp_dir!(),
          "evil-#{System.unique_integer([:positive])}.tar.gz"
        )

      on_exit(fn -> File.rm_rf!(bad_archive) end)

      evil_file =
        Path.join(
          System.tmp_dir!(),
          "etc_passwd_spoof-#{System.unique_integer([:positive])}"
        )

      File.write!(evil_file, "root:x:0:0:root:/root:/bin/bash\n")

      :ok =
        :erl_tar.create(
          String.to_charlist(bad_archive),
          [{~c"../../../etc/passwd", String.to_charlist(evil_file)}],
          [:compressed, :write]
        )

      File.rm!(evil_file)

      assert {:error, {:unsafe_archive, dangerous}} =
               Glorbo.Restore.run(bad_archive,
                 base: b,
                 force: true,
                 skip_migrate: true,
                 skip_fixer: true
               )

      assert Enum.any?(dangerous, &String.contains?(&1, ".."))
    end

    test "happy path: archive → base contains extracted company.md",
         %{host_a: a, host_b: b, archive: archive} do
      # host_b is intentionally empty (CLICase creates glorbo_home but empty).
      File.rm_rf!(b)
      File.mkdir_p!(b)

      assert :ok =
               Glorbo.Restore.run(archive,
                 base: b,
                 force: false,
                 skip_migrate: true,
                 skip_fixer: true
               )

      # Byte-equality between source (A) and restored (B)
      assert File.read!(Path.join([a, "companies", "acme", "company.md"])) ==
               File.read!(Path.join([b, "companies", "acme", "company.md"]))

      assert File.read!(Path.join([a, "companies", "acme", "agents", "ceo", "AGENT.md"])) ==
               File.read!(Path.join([b, "companies", "acme", "agents", "ceo", "AGENT.md"]))
    end

    # Codex round-2 regression. The prior extract-into-base path would
    # overwrite a pre-existing file (e.g. the user's config.md) before
    # verifying archive integrity, then only wipe top-level names
    # that didn't exist beforehand. An archive with one regular file
    # (overwriting `config.md`) + one escaping symlink caused permanent
    # loss of the pre-existing config.
    #
    # The transactional staging extract must leave base untouched on
    # rejection: config.md stays put with its original content.
    test "rejection leaves pre-existing files untouched (no partial overwrite)",
         %{host_b: b} do
      # Seed a pre-existing config.md the agent would replace.
      File.mkdir_p!(b)
      pre_config = Path.join(b, "config.md")
      File.write!(pre_config, "ORIGINAL-DO-NOT-CLOBBER\n")

      # Craft a malicious archive: overwrite config.md + drop an
      # escaping symlink so verify rejects after extract.
      bad_archive =
        Path.join(
          System.tmp_dir!(),
          "evil-overlay-#{System.unique_integer([:positive])}.tar.gz"
        )

      on_exit(fn -> File.rm_rf!(bad_archive) end)

      # Build the archive from a real on-disk tree so :erl_tar sees the
      # symlink as a symlink (the tuple-form symlink API is not exposed
      # by erl_tar.create/3 the same way in every OTP release).
      archive_root =
        Path.join(
          System.tmp_dir!(),
          "evil-src-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(archive_root)
      File.write!(Path.join(archive_root, "config.md"), "OVERWRITE-CONTENT\n")
      :ok = File.ln_s("../../etc/passwd", Path.join(archive_root, "escape-link"))

      {:ok, tar} = :erl_tar.open(String.to_charlist(bad_archive), [:write, :compressed])

      :ok =
        :erl_tar.add(
          tar,
          String.to_charlist(Path.join(archive_root, "config.md")),
          ~c"config.md",
          []
        )

      :ok =
        :erl_tar.add(
          tar,
          String.to_charlist(Path.join(archive_root, "escape-link")),
          ~c"escape-link",
          []
        )

      :ok = :erl_tar.close(tar)
      File.rm_rf!(archive_root)

      # Restore with --force so the non-empty-base guard doesn't pre-empt
      # the test; the transactional extract should reject on the escape
      # and leave config.md intact.
      assert {:error, _reason} =
               Glorbo.Restore.run(bad_archive,
                 base: b,
                 force: true,
                 skip_migrate: true,
                 skip_fixer: true
               )

      assert File.read!(pre_config) == "ORIGINAL-DO-NOT-CLOBBER\n"
    end

    test "archive_not_found returns :archive_not_found", %{host_b: b} do
      missing =
        "/tmp/does-not-exist-#{System.unique_integer([:positive])}.tar.gz"

      assert {:error, :archive_not_found} =
               Glorbo.Restore.run(missing,
                 base: b,
                 force: true,
                 skip_migrate: true,
                 skip_fixer: true
               )
    end
  end

  describe "Glorbo.Restore.run_cli/1" do
    test "--help returns help tuple" do
      assert {:restore, 0, out} = Glorbo.Restore.run_cli(["--help"])
      assert out =~ "glorbo restore"
      assert out =~ "--force"
    end

    test "missing archive returns usage with exit 1" do
      assert {:restore, 1, out} = Glorbo.Restore.run_cli([])
      assert out =~ "Usage: glorbo restore"
    end
  end
end
