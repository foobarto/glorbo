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

    test "GLORBO_CREDENTIALS_DIR honours an absolute override" do
      System.put_env("GLORBO_CREDENTIALS_DIR", "/secrets/glorbo")
      assert Hierarchy.native_credentials_dir() == "/secrets/glorbo"
    end

    # GEP-61: native_credentials_dir delegates to the single guard authority
    # (NativeConfig.credentials_dir), so a bad override fails LOUD everywhere
    # rather than being silently honoured in one path and rejected in another.
    test "GLORBO_CREDENTIALS_DIR raises on a relative override (GEP-61 guard)" do
      System.put_env("GLORBO_CREDENTIALS_DIR", "relative/creds")
      assert_raise ArgumentError, ~r/absolute path/, &Hierarchy.native_credentials_dir/0
    end

    test "GLORBO_CREDENTIALS_DIR raises on a `..`-bearing override (GEP-61 guard)" do
      System.put_env("GLORBO_CREDENTIALS_DIR", "/etc/../root/.creds")
      assert_raise ArgumentError, ~r/must not contain/, &Hierarchy.native_credentials_dir/0
    end
  end

  describe "canonicalize_home_root/1 + home_root/0 (GEP-0060)" do
    setup do
      real = TmpGlorboHome.setup()
      link = real <> "-home-link"
      File.ln_s!(real, link)
      on_exit(fn -> File.rm(link) end)
      {:ok, real: real, link: link}
    end

    test "resolves a symlinked ancestor to its real path", %{real: real, link: link} do
      assert Hierarchy.canonicalize_home_root(Path.join(link, ".glorbo")) ==
               Path.join(real, ".glorbo")
    end

    test "resolves only the existing prefix, keeping a not-yet-created tail lexically",
         %{real: real, link: link} do
      # companies/acme doesn't exist yet — the symlinked prefix resolves, the
      # tail is appended verbatim (this is what a fresh install hits).
      assert Hierarchy.canonicalize_home_root(Path.join([link, ".glorbo", "companies", "acme"])) ==
               Path.join([real, ".glorbo", "companies", "acme"])
    end

    test "is idempotent on an already-canonical path", %{real: real} do
      p = Path.join(real, ".glorbo")
      assert Hierarchy.canonicalize_home_root(p) == p
    end

    test "home_root: explicit GLORBO_HOME wins over :glorbo_base and is canonicalised",
         %{real: real, link: link} do
      prev = System.get_env("GLORBO_HOME")
      prev_base = Application.get_env(:glorbo, :glorbo_base)
      # :glorbo_base would normally win for default_root/0; home_root must
      # prefer the explicit GLORBO_HOME (CLI semantics) and resolve its symlink.
      Application.put_env(:glorbo, :glorbo_base, "/some/test/base")
      System.put_env("GLORBO_HOME", Path.join(link, ".glorbo"))

      on_exit(fn ->
        if prev, do: System.put_env("GLORBO_HOME", prev), else: System.delete_env("GLORBO_HOME")

        if prev_base,
          do: Application.put_env(:glorbo, :glorbo_base, prev_base),
          else: Application.delete_env(:glorbo, :glorbo_base)
      end)

      assert Hierarchy.home_root() == Path.join(real, ".glorbo")
    end

    test "home_root falls back to default_root when GLORBO_HOME unset" do
      prev = System.get_env("GLORBO_HOME")
      System.delete_env("GLORBO_HOME")
      on_exit(fn -> if prev, do: System.put_env("GLORBO_HOME", prev) end)
      # :glorbo_base is set by config/test.exs → default_root returns it verbatim.
      assert Hierarchy.home_root() == Hierarchy.default_root()
    end

    # A symlink cycle in the home ancestor chain must NOT hang (the hop budget
    # is global across the whole resolution). Run under a timeout so a
    # regression fails the test instead of wedging the suite.
    test "terminates on a self-referential symlink (no infinite loop)" do
      base = TmpGlorboHome.setup()
      x = Path.join(base, "x")
      File.ln_s!(x, x)
      task = Task.async(fn -> Hierarchy.canonicalize_home_root(Path.join(x, "sub")) end)
      assert {:ok, result} = Task.yield(task, 5_000) || Task.shutdown(task)
      assert is_binary(result)
    end

    test "terminates on a mutual symlink loop a→b→a (no infinite loop)" do
      base = TmpGlorboHome.setup()
      a = Path.join(base, "a")
      b = Path.join(base, "b")
      File.ln_s!(b, a)
      File.ln_s!(a, b)
      task = Task.async(fn -> Hierarchy.canonicalize_home_root(Path.join(a, ".glorbo")) end)
      assert {:ok, result} = Task.yield(task, 5_000) || Task.shutdown(task)
      assert is_binary(result)
    end
  end
end
