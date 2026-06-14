defmodule Glorbo.Sandbox.SymlinkGuardTest do
  @moduledoc """
  Guards the GEP-0060 contract: `Glorbo.Filesystem.Hierarchy.canonicalize_home_root/1`
  fixes the atomic-distro `/home → /var/home` false-positive by resolving the
  HOME ROOT prefix — while the unmodified `SymlinkGuard` still refuses
  agent-planted symlinks BELOW the home. Canonicalisation is ROOT-ONLY; if it
  ever leaked onto a mount path it would resolve away a planted symlink and
  neutralise the guard, so that boundary is pinned here.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Filesystem.Hierarchy
  alias Glorbo.Sandbox.SymlinkGuard
  alias Glorbo.Test.TmpGlorboHome

  test "atomic case: a home reached through a symlinked ancestor passes once canonicalised" do
    real = TmpGlorboHome.setup()
    File.mkdir_p!(Path.join([real, ".glorbo", "companies", "acme"]))
    link = real <> "-home-link"
    File.ln_s!(real, link)
    on_exit(fn -> File.rm(link) end)

    # Pre-canonical path crosses the `link` symlink → the guard refuses it
    # (this is the live breakage on atomic Fedora).
    pre = Path.join([link, ".glorbo", "companies", "acme"])

    assert_raise ArgumentError, ~r/symlinked component/, fn ->
      SymlinkGuard.assert_no_symlink_segment!(pre, "permission mount source")
    end

    # Canonicalised home root → only real-dir ancestors → the SAME guard passes.
    canon = Hierarchy.canonicalize_home_root(Path.join(link, ".glorbo"))

    assert :ok =
             SymlinkGuard.assert_no_symlink_segment!(
               Path.join([canon, "companies", "acme"]),
               "permission mount source"
             )
  end

  test "ROOT-ONLY invariant: an agent-planted symlink BELOW the canonical home is still refused" do
    home = TmpGlorboHome.setup()
    planted_parent = Path.join([home, "companies", "acme", "projects", "foo"])
    File.mkdir_p!(planted_parent)
    # The agent (holding projects:write:foo) plants tasks -> /etc.
    mount_source = Path.join(planted_parent, "tasks")
    File.ln_s!("/etc", mount_source)

    # The guard, given the VERBATIM mount path, MUST raise — this is the
    # protection GEP-0060 must not weaken.
    assert_raise ArgumentError, ~r/symlinked component/, fn ->
      SymlinkGuard.assert_no_symlink_segment!(mount_source, "permission mount source")
    end

    # And the load-bearing reason canonicalisation is root-only: applied to a
    # mount path it WOULD resolve the planted symlink away (-> /etc). So mount
    # paths must never be canonicalised — only the trusted home root is.
    assert Hierarchy.canonicalize_home_root(mount_source) == "/etc"
  end

  test "off-home: a symlinked ancestor outside the home is still refused (guard unchanged)" do
    base = TmpGlorboHome.setup()
    real = Path.join(base, "realdir")
    File.mkdir_p!(real)
    link = Path.join(base, "linkdir")
    File.ln_s!(real, link)

    assert_raise ArgumentError, ~r/symlinked component/, fn ->
      SymlinkGuard.assert_no_symlink_segment!(Path.join(link, "grant"), "external grant")
    end
  end
end
