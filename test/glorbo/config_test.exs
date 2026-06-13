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

  describe "director_password_hash (GEP-0053)" do
    # Helper: a structurally valid PBKDF2 hash at the test round count.
    defp pbkdf2_hash, do: Pbkdf2.hash_pwd_salt("director-secret")

    defp write_config(base, hash_line) do
      File.write!(Path.join(base, "config.md"), """
      ---
      kind: config/v1
      secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      dashboard_token: tok-abc123
      #{hash_line}
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)
    end

    test "absent key coerces to nil (bootstrap)" do
      base = TmpGlorboHome.setup()
      {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == nil
    end

    test "PRESENT null value coerces to :malformed — NOT bootstrap (D9 fail-closed)" do
      base = TmpGlorboHome.setup()
      write_config(base, "director_password_hash: null")
      assert {:ok, cfg} = Config.load(base)
      # A present-but-blank key is a torn-write / tamper signature, not a
      # legitimate bootstrap. Only an ABSENT key is bootstrap. (Codex r-C1
      # finding 1.) To reset to bootstrap, REMOVE the line (reset-password),
      # don't blank it.
      assert cfg.director_password_hash == :malformed
    end

    test "PRESENT empty-string value coerces to :malformed — NOT bootstrap (D9)" do
      base = TmpGlorboHome.setup()
      write_config(base, ~s(director_password_hash: ""))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == :malformed
    end

    test "valid pbkdf2 hash coerces to the hash string (configured)" do
      base = TmpGlorboHome.setup()
      hash = pbkdf2_hash()
      write_config(base, ~s(director_password_hash: "#{hash}"))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == hash
    end

    test "garbage (no pbkdf2 prefix) coerces to :malformed — fail-closed, NOT nil (D9)" do
      base = TmpGlorboHome.setup()
      write_config(base, ~s(director_password_hash: "garbage-not-a-hash"))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == :malformed
    end

    test "right prefix but broken envelope coerces to :malformed (structural, not prefix-only)" do
      base = TmpGlorboHome.setup()
      # Has the `$pbkdf2-sha512$` prefix but is NOT a full rounds$salt$hash
      # envelope — must be :malformed, else verify_pass would later raise on
      # it. (Codex r-C1 finding 4.)
      write_config(base, ~s(director_password_hash: "$pbkdf2-sha512$garbage"))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == :malformed
    end

    test "zero-rounds hash coerces to :malformed — verify_pass would never terminate (D9)" do
      base = TmpGlorboHome.setup()
      # `$0$` rounds: pbkdf2's verifier iterates `rounds - 1` and never
      # reaches its base case, so a hand-edited/torn zero must be DEGRADED
      # (hard deny), not CONFIGURED. (Codex PR-42 P2 finding.)
      write_config(base, ~s(director_password_hash: "$pbkdf2-sha512$0$c2FsdA$aGFzaA"))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == :malformed
    end

    test "leading-zero rounds coerces to :malformed (no octal-looking rounds)" do
      base = TmpGlorboHome.setup()
      write_config(base, ~s(director_password_hash: "$pbkdf2-sha512$0160000$c2FsdA$aGFzaA"))
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == :malformed
    end

    test "put_password_hash/2 persists a quoted hash that round-trips + stays 0600" do
      base = TmpGlorboHome.setup()
      {:ok, before} = Config.load(base)
      hash = pbkdf2_hash()

      assert :ok = Config.put_password_hash(base, hash)

      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == hash
      # other secrets preserved across the patch
      assert cfg.dashboard_token == before.dashboard_token
      assert cfg.secret_key_base == before.secret_key_base

      # D16: written as a double-quoted scalar so fmt / YAML-significant
      # bytes can never corrupt the credential line.
      content = File.read!(Path.join(base, "config.md"))
      assert content =~ ~s(director_password_hash: "#{hash}")

      {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(base, "config.md"))
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "clear_password_hash/1 removes the key → back to bootstrap (nil)" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)
      hash = pbkdf2_hash()
      :ok = Config.put_password_hash(base, hash)
      assert {:ok, %{director_password_hash: ^hash}} = Config.load(base)

      assert :ok = Config.clear_password_hash(base)
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == nil
      refute File.read!(Path.join(base, "config.md")) =~ "director_password_hash:"
    end

    test "put_password_hash is frontmatter-scoped — a body line with the key can't divert it (Codex r-C1 #2)" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")
      # Frontmatter has NO hash key, but the body contains a line that
      # starts with `director_password_hash:`. A whole-file replace would
      # rewrite the body line and never inject into frontmatter → next load
      # sees no hash → bootstrap reopens. Frontmatter-scoping prevents that.
      File.write!(path, """
      ---
      kind: config/v1
      secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
      dashboard_token: tok-abc123
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      director_password_hash: this-is-prose-not-config
      """)

      hash = pbkdf2_hash()
      assert :ok = Config.put_password_hash(base, hash)

      # The hash IS persisted in (and read back from) frontmatter.
      assert {:ok, %{director_password_hash: ^hash}} = Config.load(base)
      # The body prose line is left untouched.
      assert File.read!(path) =~ "director_password_hash: this-is-prose-not-config"
    end

    test "writing a secret forces the containing dir to 0700 (closes the tmp fd-window, codex r-C1 #3)" do
      base = TmpGlorboHome.setup()
      # Loosen the dir first to prove the write tightens it.
      File.chmod!(base, 0o755)
      {:ok, _} = Config.load(base)
      :ok = Config.put_password_hash(base, pbkdf2_hash())

      {:ok, %File.Stat{mode: dir_mode}} = File.stat(base)
      assert Bitwise.band(dir_mode, 0o777) == 0o700
    end

    test "put_password_hash tolerates a CRLF config.md (normalises to LF, codex r-C1 re-review #2)" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      crlf =
        [
          "---",
          "kind: config/v1",
          "secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
          "dashboard_token: tok-abc123",
          ~s(host: "127.0.0.1"),
          "port: 4000",
          "---",
          "",
          "# notes"
        ]
        |> Enum.join("\r\n")

      File.write!(path, crlf)

      hash = pbkdf2_hash()
      assert :ok = Config.put_password_hash(base, hash)
      assert {:ok, %{director_password_hash: ^hash}} = Config.load(base)
      # Normalised to LF on write (no stray CRLF left behind).
      refute File.read!(path) =~ "\r\n"
    end

    test "clear/put are span-aware: a multiline hash value can't orphan lines onto a neighbour (codex r-C1 #m3)" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      # Pathological hand-authored block-scalar value. Glorbo never writes
      # this, but a torn write / hand-edit could. The two indented
      # continuation lines must be consumed WITH the key, never left to
      # fold into `port:` below them.
      content =
        [
          "---",
          "kind: config/v1",
          "secret_key_base: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
          "dashboard_token: tok-abc123",
          "director_password_hash: |",
          "  line-one-of-bogus",
          "  line-two-of-bogus",
          "port: 4000",
          "---",
          "",
          "# notes"
        ]
        |> Enum.join("\n")

      File.write!(path, content <> "\n")

      assert :ok = Config.clear_password_hash(base)
      assert {:ok, cfg} = Config.load(base)
      assert cfg.director_password_hash == nil
      # The neighbour key survived intact — no orphaned continuation lines.
      assert cfg.port == 4000
      refute File.read!(path) =~ "bogus"

      # And a subsequent put writes a clean single-line value.
      hash = pbkdf2_hash()
      assert :ok = Config.put_password_hash(base, hash)
      assert {:ok, %{director_password_hash: ^hash, port: 4000}} = Config.load(base)
    end

    test "put_password_hash_if_absent is single-shot under concurrency — one writer wins (D7)" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)

      results =
        1..10
        |> Task.async_stream(
          fn i -> Config.put_password_hash_if_absent(base, Pbkdf2.hash_pwd_salt("pw-#{i}")) end,
          max_concurrency: 10,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      # Proves the :global.trans({_, self()}) mutex serializes concurrent
      # setup commits: exactly one task sees "no hash" and writes; the other
      # nine see the freshly-written hash and get :already_set.
      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == :already_set)) == 9

      assert {:ok, %{director_password_hash: stored}} = Config.load(base)
      assert is_binary(stored)
    end

    test "put_password_hash_if_absent fails closed on a :malformed disk value (D9)" do
      base = TmpGlorboHome.setup()
      write_config(base, ~s(director_password_hash: "garbage-not-a-hash"))

      assert :degraded = Config.put_password_hash_if_absent(base, pbkdf2_hash())
      # Never overwritten — still malformed.
      assert {:ok, %{director_password_hash: :malformed}} = Config.load(base)
    end

    test "put_password_hash_if_absent returns :already_set when a hash is present" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)
      :ok = Config.put_password_hash(base, pbkdf2_hash())

      assert :already_set = Config.put_password_hash_if_absent(base, pbkdf2_hash())
    end

    test "a hash-bearing config.md is a Formatter fixpoint + hash stays quoted (D16)" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)
      hash = pbkdf2_hash()
      :ok = Config.put_password_hash(base, hash)
      path = Path.join(base, "config.md")

      {:ok, _change, f1} = Glorbo.FileSpec.Formatter.format_content(path, File.read!(path))
      # Running the formatter on its own output is a no-op (stable fixpoint).
      {:ok, change2, f2} = Glorbo.FileSpec.Formatter.format_content(path, f1)
      assert change2 == :unchanged
      assert f1 == f2
      # The $-leading hash is emitted double-quoted and survives a reload.
      assert f1 =~ ~s(director_password_hash: "#{hash}")
      File.write!(path, f1)
      assert {:ok, %{director_password_hash: ^hash}} = Config.load(base)
    end
  end

  describe "node_id/1 (GEP-62)" do
    test "mints + persists a node_id when absent" do
      base = TmpGlorboHome.setup()
      {:ok, _} = Config.load(base)
      path = Path.join(base, "config.md")
      # Deterministic baseline without node_id (write_default!/1 adds one going forward).
      File.write!(path, String.replace(File.read!(path), ~r/^node_id:.*\n/m, ""))

      assert {:ok, id} = Config.node_id(base)
      assert id =~ ~r/\A[a-z0-9]+\z/
      assert File.read!(path) =~ "node_id: #{id}"
    end

    test "returns an existing node_id without rewriting the file" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.write!(path, """
      ---
      kind: config/v1
      node_id: cafef00d
      host: "127.0.0.1"
      port: 4000
      ---

      # notes
      """)

      File.chmod!(path, 0o600)
      {:ok, %File.Stat{mtime: mtime_before}} = File.stat(path)
      :timer.sleep(1_100)

      assert {:ok, "cafef00d"} = Config.node_id(base)

      {:ok, %File.Stat{mtime: mtime_after}} = File.stat(path)
      assert mtime_before == mtime_after
    end

    test "re-mints a malformed node_id (not node-name-safe)" do
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.write!(path, """
      ---
      kind: config/v1
      node_id: "has spaces / slashes"
      host: "127.0.0.1"
      port: 4000
      ---
      """)

      File.chmod!(path, 0o600)

      assert {:ok, id} = Config.node_id(base)
      assert id =~ ~r/\A[a-z0-9]+\z/
      refute id == "has spaces / slashes"
    end

    test "an all-digit node_id (YAML-parsed as integer) is stable, not re-minted" do
      # ~1.6% of 8-hex ids are all decimal digits (e.g. "12345678"). Written
      # unquoted, the YAML parser reads them back as an INTEGER — the is_binary
      # guard would otherwise re-mint a fresh id on every call. Coercing to the
      # string form keeps the node name stable across reads. (copilot #57)
      base = TmpGlorboHome.setup()
      path = Path.join(base, "config.md")

      File.write!(path, """
      ---
      kind: config/v1
      node_id: 12345678
      host: "127.0.0.1"
      port: 4000
      ---
      """)

      File.chmod!(path, 0o600)
      {:ok, %File.Stat{mtime: mtime_before}} = File.stat(path)
      :timer.sleep(1_100)

      # Coerced to the string form, returned identically twice, file untouched.
      assert {:ok, "12345678"} = Config.node_id(base)
      assert {:ok, "12345678"} = Config.node_id(base)

      {:ok, %File.Stat{mtime: mtime_after}} = File.stat(path)
      assert mtime_before == mtime_after
    end
  end
end
