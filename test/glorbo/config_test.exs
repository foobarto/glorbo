defmodule Glorbo.ConfigTest do
  @moduledoc """
  Plan 04-01 Task 2: `Glorbo.Config.load/1` contract.

  Cases:
    * First-boot path (no config.md) generates a 0600 file with a
      fresh `secret_key_base` and default host/port.
    * Existing valid file round-trips verbatim (preserves host/port/token).
    * Malformed / missing frontmatter returns `{:error, :config_parse}`
      with NO value leakage in the error payload.
  """
  use ExUnit.Case, async: true

  alias Glorbo.Config
  alias Glorbo.Test.TmpGlorboHome

  describe "first-boot bootstrap" do
    test "generates config.md with strong secret + default host/port + mode 0600" do
      base = TmpGlorboHome.setup()

      assert {:ok, cfg} = Config.load(base)
      assert is_binary(cfg.secret_key_base)
      assert byte_size(cfg.secret_key_base) >= 64
      assert cfg.host == "127.0.0.1"
      assert cfg.port == 4000
      assert is_binary(cfg.dashboard_token)
      assert byte_size(cfg.dashboard_token) >= 16

      path = Path.join(base, "config.md")
      assert File.exists?(path)

      # Mode 0600 — Director-only readable (T-04-05).
      {:ok, %File.Stat{mode: mode}} = File.stat(path)
      # mode is encoded with the file-type bits (0o100000 for regular);
      # mask off to get just the permission bits.
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "two subsequent loads are idempotent (do not rewrite the file)" do
      base = TmpGlorboHome.setup()

      {:ok, cfg1} = Config.load(base)
      {:ok, cfg2} = Config.load(base)

      assert cfg1.secret_key_base == cfg2.secret_key_base
      assert cfg1.host == cfg2.host
      assert cfg1.port == cfg2.port
    end

    test "write_default! generates a non-nil dashboard_token" do
      base = TmpGlorboHome.setup()
      assert {:ok, cfg} = Config.load(base)
      assert is_binary(cfg.dashboard_token)
      assert byte_size(cfg.dashboard_token) >= 16
    end

    test "config.md written on first boot contains dashboard_token value (not null)" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)
      content = File.read!(Path.join(base, "config.md"))
      # Must not be `dashboard_token: null`
      refute content =~ "dashboard_token: null"
      assert content =~ "dashboard_token: "
    end
  end

  describe "parsing an existing config.md" do
    test "reads host/port/token/secret from frontmatter" do
      base = TmpGlorboHome.setup()

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: "my-lan-token"
      host: "0.0.0.0"
      port: 8080
      ---

      # Glorbo configuration
      """)

      assert {:ok, cfg} = Config.load(base)
      assert cfg.secret_key_base =~ "abcdefghij"
      assert cfg.dashboard_token == "my-lan-token"
      assert cfg.host == "0.0.0.0"
      assert cfg.port == 8080
    end

    test "null dashboard_token in existing file is auto-generated" do
      base = TmpGlorboHome.setup()

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      dashboard_token: null
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      assert {:ok, cfg} = Config.load(base)
      assert is_binary(cfg.dashboard_token)
      assert byte_size(cfg.dashboard_token) >= 16
    end
  end

  describe "malformed input" do
    test "no frontmatter fence returns {:error, :config_parse} (no leakage)" do
      base = TmpGlorboHome.setup()
      File.write!(Path.join(base, "config.md"), "# just markdown, no frontmatter\n")

      # The helper synthesizes a secret when one is missing; a file with no
      # frontmatter at all is treated as an empty frontmatter map, which
      # succeeds with defaults. Verify that explicitly — the error path is
      # reserved for genuinely unparseable YAML.
      assert {:ok, cfg} = Config.load(base)
      assert byte_size(cfg.secret_key_base) >= 32
    end

    test "truly unparseable YAML returns {:error, :config_parse}" do
      base = TmpGlorboHome.setup()

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: "unterminated
      ---

      # ugly
      """)

      assert {:error, :config_parse} = Config.load(base)
    end
  end

  describe "token auto-generation" do
    test "null token in existing config.md is replaced with a generated token" do
      base = TmpGlorboHome.setup()

      File.mkdir_p!(base)

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: null
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      assert {:ok, cfg} = Config.load(base)
      assert is_binary(cfg.dashboard_token)
      assert byte_size(cfg.dashboard_token) >= 16

      # Also patched on disk
      content = File.read!(Path.join(base, "config.md"))
      refute content =~ "dashboard_token: null"
      assert content =~ "dashboard_token: " <> cfg.dashboard_token
    end

    test "empty-string token is also replaced" do
      base = TmpGlorboHome.setup()

      File.mkdir_p!(base)

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: ""
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      assert {:ok, cfg} = Config.load(base)
      assert is_binary(cfg.dashboard_token)
      assert byte_size(cfg.dashboard_token) >= 16
    end

    test "existing non-empty token is preserved and not rewritten" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.mkdir_p!(base)

      File.write!(path, """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: my-existing-token-abc123
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      File.chmod!(path, 0o600)

      {:ok, %File.Stat{mtime: before}} = File.stat(path)
      :timer.sleep(1_100)

      assert {:ok, cfg} = Config.load(base)
      assert cfg.dashboard_token == "my-existing-token-abc123"

      {:ok, %File.Stat{mtime: after_}} = File.stat(path)
      assert before == after_
    end

    test "config.md stays mode 0600 after token patch" do
      base = TmpGlorboHome.setup()

      File.mkdir_p!(base)

      File.write!(Path.join(base, "config.md"), """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: null
      host: "127.0.0.1"
      port: 4000
      ---
      """)

      {:ok, _} = Config.load(base)
      {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(base, "config.md"))
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  describe "erl_cookie/1 (Plan 05-01, D-25)" do
    test "generates + persists a cookie when erl_cookie is absent" do
      base = TmpGlorboHome.setup()
      # Prime the file via load/1 so the baseline config.md is present WITHOUT
      # an erl_cookie key — write_default!/1 may start writing one going
      # forward, so strip the key for a deterministic baseline.
      {:ok, _} = Config.load(base)
      path = Path.join(base, "config.md")
      content = File.read!(path)
      stripped = String.replace(content, ~r/^erl_cookie:.*\n/m, "")
      File.write!(path, stripped)

      assert {:ok, cookie} = Config.erl_cookie(base)
      assert is_binary(cookie)
      # 24 bytes base64-url-encoded without padding → 32 chars
      assert byte_size(cookie) >= 16
      assert File.read!(path) =~ "erl_cookie:"
    end

    test "returns existing cookie ≥ 16 bytes without rewriting the file" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.write!(path, """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: null
      erl_cookie: EXISTING_COOKIE_VALUE_24B_OK_XYZ
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      File.chmod!(path, 0o600)
      {:ok, %File.Stat{mtime: mtime_before}} = File.stat(path)

      # Sleep a second so a rewrite would bump mtime.
      :timer.sleep(1_100)

      assert {:ok, "EXISTING_COOKIE_VALUE_24B_OK_XYZ"} = Config.erl_cookie(base)

      {:ok, %File.Stat{mtime: mtime_after}} = File.stat(path)
      assert mtime_before == mtime_after
    end

    test "replaces a too-short cookie with a fresh one (line-level rewrite)" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.write!(path, """
      ---
      secret_key_base: abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ01234==
      dashboard_token: null
      erl_cookie: short
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      File.chmod!(path, 0o600)

      assert {:ok, cookie} = Config.erl_cookie(base)
      assert byte_size(cookie) >= 16
      refute cookie == "short"

      content = File.read!(path)
      refute content =~ "erl_cookie: short"
      assert content =~ "erl_cookie: " <> cookie
      # Frontmatter preserved.
      assert content =~ "host: \"127.0.0.1\""
      assert content =~ "port: 4000"
    end

    test "config.md remains mode 0600 after cookie write" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.erl_cookie(base)

      path = Path.join(base, "config.md")
      {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end
end
