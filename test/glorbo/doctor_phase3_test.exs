defmodule Glorbo.DoctorPhase3Test do
  use ExUnit.Case, async: true

  alias Glorbo.Doctor

  # Only override the Phase-3 specific deps (bwrap/pasta which + userns read);
  # Phase-1/2 checks use their production defaults against the host. Tests
  # here focus on the shape of the three Linux runtime checks.
  defp phase3_deps(overrides \\ []) do
    defaults = [
      read_fun: fn
        "/proc/sys/user/max_user_namespaces" -> {:ok, "254351\n"}
        _ -> {:error, :enoent}
      end
    ]

    Keyword.merge(defaults, overrides)
  end

  describe "D1: run_checks count (post-GEP-5 D6 pruning)" do
    test "GEP-31 adds pasta; v0.18 adds migrations_pending; count is 13" do
      checks = Doctor.run_checks(phase3_deps())
      names = Enum.map(checks, & &1.name) |> MapSet.new()

      assert "bwrap" in names
      assert "pasta" in names
      assert "user_namespaces" in names
      assert "private_files" in names
      assert "migrations_pending" in names
      assert length(checks) == 13
    end
  end

  describe "D2: bwrap present on host" do
    test "bwrap check passes when binary + --version exit 0 (uses real host bwrap)" do
      checks = Doctor.run_checks(phase3_deps())
      bwrap_check = Enum.find(checks, &(&1.name == "bwrap"))

      # On dev host bwrap is present (verified at plan start). If ever run on
      # a host without bwrap, the check will fail — which is the correct
      # behaviour.
      if System.find_executable("bwrap") do
        assert bwrap_check.pass, "bwrap check unexpectedly failed: #{inspect(bwrap_check)}"
        assert bwrap_check.detail =~ "bubblewrap" or bwrap_check.detail =~ "0."
      else
        refute bwrap_check.pass
      end

      assert bwrap_check.severity == :blocker
    end
  end

  describe "D3: bwrap absent — blocker fail" do
    test "missing bwrap → fail with blocker severity" do
      # Fake only bwrap as missing; fall through to real System.find_executable
      # for every other binary so Phase 1/2 checks don't break.
      deps =
        phase3_deps(
          which_fun: fn
            "bwrap" -> nil
            bin -> System.find_executable(bin)
          end
        )

      checks = Doctor.run_checks(deps)
      bwrap_check = Enum.find(checks, &(&1.name == "bwrap"))
      refute bwrap_check.pass
      assert bwrap_check.severity == :blocker
      assert bwrap_check.detail =~ "bwrap not found"

      # exit_code should be 1 since a blocker failed
      assert Doctor.exit_code(checks) == 1
    end
  end

  describe "D4: user_namespaces check" do
    test "non-zero max_user_namespaces → pass" do
      deps = phase3_deps(read_fun: fn _ -> {:ok, "254351\n"} end)
      checks = Doctor.run_checks(deps)
      ns_check = Enum.find(checks, &(&1.name == "user_namespaces"))
      assert ns_check.pass
      assert ns_check.detail =~ "254351"
      assert ns_check.severity == :warning
    end

    test "zero max_user_namespaces → warning fail" do
      deps = phase3_deps(read_fun: fn _ -> {:ok, "0"} end)
      checks = Doctor.run_checks(deps)
      ns_check = Enum.find(checks, &(&1.name == "user_namespaces"))
      refute ns_check.pass
      assert ns_check.severity == :warning
    end

    test "missing /proc/sys/user/max_user_namespaces → warning fail" do
      deps = phase3_deps(read_fun: fn _ -> {:error, :enoent} end)
      checks = Doctor.run_checks(deps)
      ns_check = Enum.find(checks, &(&1.name == "user_namespaces"))
      refute ns_check.pass
      assert ns_check.severity == :warning
    end
  end

  describe "D4b: pasta check" do
    test "pasta check is present and warning-scoped" do
      checks = Doctor.run_checks(phase3_deps())
      pasta_check = Enum.find(checks, &(&1.name == "pasta"))

      refute is_nil(pasta_check)
      assert pasta_check.severity == :warning
    end
  end

  describe "D5: JSON schema additive-only" do
    test "Phase 1 + Phase 2 check names all present in extended run_checks" do
      checks = Doctor.run_checks(phase3_deps())
      names = Enum.map(checks, & &1.name)

      # Phase 1
      assert "linux_kernel" in names
      assert "uidmap" in names
      assert "disk_space" in names
      assert "glorbo_dir" in names
      assert "erts_version" in names

      # Phase 2 (podman/ollama/runtime_image/runtime_exec removed per GEP-5 D6)
      assert "audit_dir" in names
      assert "sockets_dir" in names
      assert "private_files" in names
      assert "tar_zstd" in names

      # Phase 3 additions
      assert "bwrap" in names
      assert "pasta" in names
      assert "user_namespaces" in names

      # v0.18 runtime-state additions
      assert "migrations_pending" in names
    end
  end

  describe "D6: migrations_pending check (v0.18 runtime-state)" do
    # The check is read-only and dependency-injected (`db_path_fun`,
    # `migrations_dir_fun`). These tests use temp-dir fakes to avoid
    # touching `~/.glorbo/glorbo.db` and to keep results deterministic.

    setup do
      tmp = Path.join(System.tmp_dir!(), "doctor_mig_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "migrations"))
      on_exit(fn -> File.rm_rf(tmp) end)
      {:ok, tmp: tmp}
    end

    defp mig_deps(tmp, db_filename, files) do
      Enum.each(files, fn name ->
        File.write!(Path.join([tmp, "migrations", name]), "# fake\n")
      end)

      [
        db_path_fun: fn -> Path.join(tmp, db_filename) end,
        migrations_dir_fun: fn -> Path.join(tmp, "migrations") end
      ]
      |> Keyword.merge(phase3_deps())
    end

    test "DB absent → :ok with `glorbo init` hint", %{tmp: tmp} do
      deps = mig_deps(tmp, "missing.db", ["20260101000001_create_companies.exs"])

      checks = Doctor.run_checks(deps)
      mig = Enum.find(checks, &(&1.name == "migrations_pending"))

      assert mig.pass
      assert mig.detail =~ "no DB yet"
      assert mig.detail =~ "glorbo init"
      assert mig.severity == :warning
    end

    test "DB has all migrations applied → :ok", %{tmp: tmp} do
      db_path = Path.join(tmp, "all_applied.db")
      seed_schema_migrations!(db_path, [20_260_101_000_001, 20_260_102_000_001])

      deps =
        mig_deps(tmp, "all_applied.db", [
          "20260101000001_create_companies.exs",
          "20260102000001_create_agents.exs"
        ])

      checks = Doctor.run_checks(deps)
      mig = Enum.find(checks, &(&1.name == "migrations_pending"))

      assert mig.pass
      assert mig.detail =~ "2 migration"
    end

    test "DB has fewer applied than files on disk → :fail with `glorbo migrate` hint",
         %{tmp: tmp} do
      db_path = Path.join(tmp, "pending.db")
      seed_schema_migrations!(db_path, [20_260_101_000_001])

      deps =
        mig_deps(tmp, "pending.db", [
          "20260101000001_create_companies.exs",
          "20260102000001_create_agents.exs",
          "20260103000001_create_audit_events.exs"
        ])

      checks = Doctor.run_checks(deps)
      mig = Enum.find(checks, &(&1.name == "migrations_pending"))

      refute mig.pass
      assert mig.detail =~ "2 pending"
      assert mig.detail =~ "20260102000001"
      assert mig.detail =~ "glorbo migrate"
      assert mig.severity == :warning
      # Warning, not blocker — exit code 2 (or 0 if no other failures).
      refute Doctor.exit_code(checks) == 1
    end
  end

  defp seed_schema_migrations!(db_path, versions) do
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(
        conn,
        "CREATE TABLE schema_migrations (version BIGINT PRIMARY KEY, inserted_at DATETIME)"
      )

    :done = Exqlite.Sqlite3.step(conn, stmt)
    :ok = Exqlite.Sqlite3.release(conn, stmt)

    Enum.each(versions, fn v ->
      {:ok, ins} =
        Exqlite.Sqlite3.prepare(
          conn,
          "INSERT INTO schema_migrations (version, inserted_at) VALUES (?, datetime('now'))"
        )

      :ok = Exqlite.Sqlite3.bind(ins, [v])
      :done = Exqlite.Sqlite3.step(conn, ins)
      :ok = Exqlite.Sqlite3.release(conn, ins)
    end)

    :ok = Exqlite.Sqlite3.close(conn)
  end
end
