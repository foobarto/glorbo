defmodule Glorbo.Container.SocketTest do
  use ExUnit.Case, async: true

  alias Glorbo.Container.Socket
  alias Glorbo.Test.TmpGlorboHome

  setup do
    {:ok, base: TmpGlorboHome.setup()}
  end

  describe "path/3" do
    test "returns the canonical socket path (pure)", %{base: base} do
      assert Socket.path(base, "acme", "ceo") ==
               Path.join([base, "runtime", "sockets", "acme", "ceo.sock"])
    end
  end

  describe "ensure_dir!/2" do
    test "creates <base>/runtime/sockets/<company>/ with mode 0700", %{base: base} do
      dir = Socket.ensure_dir!(base, "acme")

      assert File.dir?(dir)
      assert dir == Path.join([base, "runtime", "sockets", "acme"])

      %File.Stat{mode: mode} = File.stat!(dir)
      # Mode is a full stat integer; the lowest 9 bits are permission bits.
      perms = Bitwise.band(mode, 0o777)
      assert perms == 0o700, "expected 0700, got #{Integer.to_string(perms, 8)}"
    end

    test "is idempotent", %{base: base} do
      dir1 = Socket.ensure_dir!(base, "acme")
      dir2 = Socket.ensure_dir!(base, "acme")

      assert dir1 == dir2
      assert File.dir?(dir1)
    end
  end

  describe "cleanup_stale/3" do
    test "removes a leftover socket file if present", %{base: base} do
      Socket.ensure_dir!(base, "acme")
      sock = Socket.path(base, "acme", "ceo")
      File.write!(sock, "")
      assert File.exists?(sock)

      assert :ok = Socket.cleanup_stale(base, "acme", "ceo")
      refute File.exists?(sock)
    end

    test "is a no-op when no socket exists", %{base: base} do
      Socket.ensure_dir!(base, "acme")
      assert :ok = Socket.cleanup_stale(base, "acme", "ceo")
    end
  end
end
