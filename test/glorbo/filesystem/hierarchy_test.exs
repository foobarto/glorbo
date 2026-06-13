defmodule Glorbo.Filesystem.HierarchyTest do
  use Glorbo.DataCase, async: false

  alias Glorbo.Filesystem.Hierarchy
  alias Glorbo.Test.TmpGlorboHome

  @expected_dirs ~w(
    bin
    companies
    runtime/sockets
    logs
    run
  )

  describe "ensure!/1 (Tests 1–4)" do
    test "Test 1: creates every DESIGN.md §3 directory under base" do
      base = TmpGlorboHome.setup()
      assert :ok = Hierarchy.ensure!(base)

      for d <- @expected_dirs do
        path = Path.join(base, d)
        assert File.dir?(path), "expected directory #{d} to exist"
      end

      # config.md + logs/glorbo.log also present
      assert File.exists?(Path.join(base, "config.md"))
      assert File.exists?(Path.join(base, "logs/glorbo.log"))
    end

    test "Test 2: idempotent — re-running does not delete or re-create content" do
      base = TmpGlorboHome.setup()
      :ok = Hierarchy.ensure!(base)

      # Drop a sentinel file inside one of the managed directories
      sentinel = Path.join([base, "companies", "sentinel.txt"])
      File.write!(sentinel, "keep-me")

      # Also put content into config.md that must survive
      config_path = Path.join(base, "config.md")
      File.write!(config_path, "# my config\n")

      :ok = Hierarchy.ensure!(base)

      assert File.read!(sentinel) == "keep-me"
      assert File.read!(config_path) == "# my config\n"
    end

    test "Test 3: runtime/sockets/ is created with mode 0700" do
      base = TmpGlorboHome.setup()
      :ok = Hierarchy.ensure!(base)

      sockets_dir = Path.join(base, "runtime/sockets")
      {:ok, stat} = File.stat(sockets_dir)
      # POSIX mode stored in stat.mode — mask off file-type bits (higher octal digits)
      assert Bitwise.band(stat.mode, 0o777) == 0o700
    end

    test "Test 3b: the workspace root itself is chmoded to 0700 (GEP-0053)" do
      base = TmpGlorboHome.setup()
      # Prove ensure! tightens an over-permissive root.
      File.chmod!(base, 0o755)
      :ok = Hierarchy.ensure!(base)

      {:ok, stat} = File.stat(base)
      assert Bitwise.band(stat.mode, 0o777) == 0o700
    end

    test "Test 4: config.md — created empty when absent, content preserved when present" do
      base = TmpGlorboHome.setup()

      # Case A: absent → empty
      :ok = Hierarchy.ensure!(base)
      config_path = Path.join(base, "config.md")
      log_path = Path.join(base, "logs/glorbo.log")

      assert File.read!(config_path) == ""
      assert File.read!(log_path) == ""

      {:ok, config_stat} = File.stat(config_path)
      {:ok, log_stat} = File.stat(log_path)
      assert Bitwise.band(config_stat.mode, 0o777) == 0o600
      assert Bitwise.band(log_stat.mode, 0o777) == 0o600

      # Case B: present → preserved
      File.write!(config_path, "preserved content\n")
      File.chmod!(config_path, 0o644)
      :ok = Hierarchy.ensure!(base)
      assert File.read!(config_path) == "preserved content\n"

      {:ok, preserved_stat} = File.stat(config_path)
      assert Bitwise.band(preserved_stat.mode, 0o777) == 0o644
    end
  end

  describe "migrations (Tests 5–6)" do
    # DataCase starts the sandbox; the test DB is already migrated by the
    # `mix test` alias (ecto.create + ecto.migrate) so we assert the post-state.
    test "Test 5: all 4 tables exist after migrations" do
      rows =
        Glorbo.Repo.query!(
          "SELECT name FROM sqlite_master WHERE type='table' " <>
            "AND name IN ('companies','agents','audit_events','reindex_state')"
        ).rows

      assert length(rows) == 4
    end

    test "Test 6: each schema has the documented columns" do
      # companies
      assert column_set("companies") ==
               MapSet.new(~w(id name mission file_path inserted_at updated_at))

      # agents
      assert column_set("agents") ==
               MapSet.new(
                 ~w(id company_id name role provider model file_path permissions_hash inserted_at updated_at)
               )

      # audit_events
      assert column_set("audit_events") ==
               MapSet.new(~w(id company actor action target detail ts))

      # reindex_state — PK is file_path, no synthetic id
      reindex_cols = column_set("reindex_state")
      assert MapSet.member?(reindex_cols, "file_path")
      assert MapSet.member?(reindex_cols, "md5")
      assert MapSet.member?(reindex_cols, "size")
      assert MapSet.member?(reindex_cols, "mtime")
      refute MapSet.member?(reindex_cols, "id")
    end

    defp column_set(table) do
      Glorbo.Repo.query!("PRAGMA table_info(#{table})").rows
      |> Enum.map(fn row -> Enum.at(row, 1) end)
      |> MapSet.new()
    end
  end

  describe "config_root/0 + provider paths (GEP-61)" do
    setup do
      prev_root = Application.get_env(:glorbo, :glorbo_config_root)
      prev_creds_env = System.get_env("GLORBO_CREDENTIALS_DIR")
      Application.put_env(:glorbo, :glorbo_config_root, "/cfg/glorbo")
      # Clear the env override so `native_credentials_dir/0` resolves under
      # config_root deterministically (async: false → safe to mutate + restore).
      System.delete_env("GLORBO_CREDENTIALS_DIR")

      on_exit(fn ->
        if prev_root,
          do: Application.put_env(:glorbo, :glorbo_config_root, prev_root),
          else: Application.delete_env(:glorbo, :glorbo_config_root)

        if prev_creds_env,
          do: System.put_env("GLORBO_CREDENTIALS_DIR", prev_creds_env),
          else: System.delete_env("GLORBO_CREDENTIALS_DIR")
      end)

      :ok
    end

    test "config_root honours the :glorbo_config_root override" do
      assert Hierarchy.config_root() == "/cfg/glorbo"
    end

    test "provider config + override dir live under config_root (out of ~/.glorbo)" do
      assert Hierarchy.providers_config_path() == "/cfg/glorbo/providers.toml"
      assert Hierarchy.providers_override_dir() == "/cfg/glorbo/providers"
    end

    test "native credentials default under config_root (GLORBO_CREDENTIALS_DIR unset)" do
      assert Hierarchy.native_credentials_dir() == "/cfg/glorbo/credentials"
    end
  end
end
