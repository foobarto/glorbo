defmodule Glorbo.Filesystem.ConfigMigrationTest do
  @moduledoc """
  GEP-61 config-migration safety. Every case uses isolated tmp dirs via the
  `:home` / `:config_root` / `:legacy_credentials_dir` opts so the real
  `~/.glorbo` and `~/.config/glorbo` are never touched.
  """
  use ExUnit.Case, async: true

  import Bitwise, only: [band: 2]

  alias Glorbo.Filesystem.ConfigMigration

  setup do
    root = Path.join(System.tmp_dir!(), "glorbo-cfgmig-#{System.unique_integer([:positive])}")
    home = Path.join(root, "home")
    config = Path.join(root, "config")
    legacy_creds = Path.join(root, "legacy_creds")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf(root) end)
    %{home: home, config: config, legacy_creds: legacy_creds, root: root}
  end

  defp opts(ctx),
    do: [home: ctx.home, config_root: ctx.config, legacy_credentials_dir: ctx.legacy_creds]

  defp write_secret!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o600)
  end

  test "moves providers.toml, override TOMLs, and native credentials into config root", ctx do
    write_secret!(Path.join(ctx.home, "providers.toml"), "[[providers]]\n")
    write_secret!(Path.join([ctx.home, "providers", "stado.toml"]), "args = [\"acp\"]\n")
    write_secret!(Path.join(ctx.legacy_creds, "openai.toml"), "api_key = \"sk-test\"\n")

    assert {:ok, moves} = ConfigMigration.run(opts(ctx))
    assert length(moves) == 3

    # Landed in the config root...
    assert File.read!(Path.join(ctx.config, "providers.toml")) == "[[providers]]\n"
    assert File.read!(Path.join([ctx.config, "providers", "stado.toml"])) == "args = [\"acp\"]\n"

    assert File.read!(Path.join([ctx.config, "credentials", "openai.toml"])) ==
             "api_key = \"sk-test\"\n"

    # ...and removed from the old locations.
    refute File.exists?(Path.join(ctx.home, "providers.toml"))
    refute File.exists?(Path.join([ctx.home, "providers", "stado.toml"]))
    refute File.exists?(Path.join(ctx.legacy_creds, "openai.toml"))
  end

  test "preserves 0600 perms on moved secrets and locks config root to 0700", ctx do
    write_secret!(Path.join(ctx.legacy_creds, "openai.toml"), "api_key = \"sk\"\n")

    assert {:ok, [_]} = ConfigMigration.run(opts(ctx))

    {:ok, file_stat} = File.stat(Path.join([ctx.config, "credentials", "openai.toml"]))
    assert band(file_stat.mode, 0o777) == 0o600

    {:ok, root_stat} = File.stat(ctx.config)
    assert band(root_stat.mode, 0o777) == 0o700
  end

  test "no-clobber: an existing destination file is left untouched and source remains", ctx do
    write_secret!(Path.join(ctx.home, "providers.toml"), "OLD\n")
    write_secret!(Path.join(ctx.config, "providers.toml"), "NEW\n")

    assert {:ok, moves} = ConfigMigration.run(opts(ctx))
    refute Enum.any?(moves, fn {_from, to} -> to == Path.join(ctx.config, "providers.toml") end)

    # Destination kept its content; source not removed (both survive — no data loss).
    assert File.read!(Path.join(ctx.config, "providers.toml")) == "NEW\n"
    assert File.read!(Path.join(ctx.home, "providers.toml")) == "OLD\n"
  end

  test "idempotent: a second run is a no-op", ctx do
    write_secret!(Path.join(ctx.home, "providers.toml"), "x\n")
    assert {:ok, [_]} = ConfigMigration.run(opts(ctx))
    assert {:ok, []} = ConfigMigration.run(opts(ctx))
  end

  test "nothing to migrate returns {:ok, []} and creates nothing", ctx do
    assert {:ok, []} = ConfigMigration.run(opts(ctx))
    refute File.exists?(ctx.config)
  end

  test "best-effort: tolerates absent home / legacy dirs without raising", ctx do
    # home exists (setup) but has no provider files; legacy dir absent entirely.
    assert {:ok, []} = ConfigMigration.run(opts(ctx))
  end

  test "hardens an existing config root to 0700 even with nothing to migrate", ctx do
    # An already-migrated (or manually-created) config root with loose perms
    # must still be locked down on every run, not only when a move happens.
    File.mkdir_p!(Path.join(ctx.config, "credentials"))
    File.chmod!(ctx.config, 0o755)
    File.chmod!(Path.join(ctx.config, "credentials"), 0o755)

    assert {:ok, []} = ConfigMigration.run(opts(ctx))

    {:ok, root} = File.stat(ctx.config)
    assert band(root.mode, 0o777) == 0o700
    {:ok, creds} = File.stat(Path.join(ctx.config, "credentials"))
    assert band(creds.mode, 0o777) == 0o700
  end
end
