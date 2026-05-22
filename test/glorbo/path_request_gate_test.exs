defmodule Glorbo.PathRequestGateTest do
  @moduledoc """
  Unit coverage for the cross-company mode downgrade
  (GEP-27 §151-161, threatmodel T4).

  The director-approved `:write` must become `:read` for any path
  under another company's tree, regardless of how the agent asked.
  """
  use ExUnit.Case, async: true

  alias Glorbo.PathRequestGate
  alias Glorbo.Test.TmpGlorboHome

  @base "/fake/home/.glorbo"

  describe "resolve_cross_company_mode/4 — T4 cross-company downgrade" do
    test "own-company :write stays :write" do
      own = Path.join([@base, "companies", "acme", "projects", "web", "notes.md"])
      assert :write == PathRequestGate.resolve_cross_company_mode(own, :write, @base, "acme")
    end

    test "own-company :read stays :read" do
      own = Path.join([@base, "companies", "acme", "projects", "web", "notes.md"])
      assert :read == PathRequestGate.resolve_cross_company_mode(own, :read, @base, "acme")
    end

    test "cross-company :write is downgraded to :read" do
      other = Path.join([@base, "companies", "other-co", "projects", "web", "secrets.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :write, @base, "acme")
    end

    test "cross-company :read stays :read" do
      other = Path.join([@base, "companies", "other-co", "projects", "web", "secrets.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :read, @base, "acme")
    end

    test "paths outside any company tree keep the requested mode" do
      host = "/tmp/scratch.md"
      assert :write == PathRequestGate.resolve_cross_company_mode(host, :write, @base, "acme")
      assert :read == PathRequestGate.resolve_cross_company_mode(host, :read, @base, "acme")
    end

    test "bare `companies/<own>` root without trailing slash is downgraded (defense in depth)" do
      # The bare company-root path isn't unambiguously inside the own
      # company's tree (no trailing separator), but it *is* under
      # `companies/` — treat it as cross-company to fail safe rather
      # than grant write access to the directory header.
      bare = Path.join([@base, "companies", "acme"])

      assert :read == PathRequestGate.resolve_cross_company_mode(bare, :write, @base, "acme")
    end

    test "sibling prefix match collision is not mishandled" do
      # "acme-2" starts with "acme" but is a different company; the
      # own_prefix built from `state.company` has a trailing `/` so
      # the prefix match shouldn't accidentally treat acme-2 as own.
      other = Path.join([@base, "companies", "acme-2", "projects", "web", "x.md"])

      assert :read ==
               PathRequestGate.resolve_cross_company_mode(other, :write, @base, "acme")
    end
  end

  # GEP-27 §Approval validation §2. At approval time, any granted
  # path whose segments include a symlink must be refused — otherwise
  # the bwrap bind would resolve through the symlink at mount time,
  # exposing whatever the symlink points at.
  describe "validate_no_symlink_segments/1 — T-27-02 symlink-target check" do
    test "regular file is allowed" do
      tmp = TmpGlorboHome.setup()
      real = Path.join(tmp, "real.txt")
      File.write!(real, "ok")

      assert :ok =
               PathRequestGate.validate_no_symlink_segments([%{path: real, mode: :read}])
    end

    test "absent path is allowed (operator may grant a to-be-created path)" do
      tmp = TmpGlorboHome.setup()
      absent = Path.join(tmp, "will-be-created.txt")

      assert :ok =
               PathRequestGate.validate_no_symlink_segments([%{path: absent, mode: :write}])
    end

    test "path that IS a symlink is refused" do
      tmp = TmpGlorboHome.setup()
      target = Path.join(tmp, "target.txt")
      File.write!(target, "real")
      link = Path.join(tmp, "link.txt")
      :ok = File.ln_s(target, link)

      assert {:error, {:granted_path_has_symlink_segment, %{path: ^link}}} =
               PathRequestGate.validate_no_symlink_segments([%{path: link, mode: :read}])
    end

    test "path whose parent segment is a symlink is refused" do
      tmp = TmpGlorboHome.setup()
      real_dir = Path.join(tmp, "real-dir")
      File.mkdir_p!(real_dir)
      File.write!(Path.join(real_dir, "inside.txt"), "sensitive")

      linked_dir = Path.join(tmp, "aliased-dir")
      :ok = File.ln_s(real_dir, linked_dir)
      path_via_symlink = Path.join(linked_dir, "inside.txt")

      assert {:error, {:granted_path_has_symlink_segment, _}} =
               PathRequestGate.validate_no_symlink_segments([
                 %{path: path_via_symlink, mode: :read}
               ])
    end
  end

  describe "validate_subset/2 — B-014 confused-deputy path approval" do
    # The sentinel stores requested paths as JSON-decoded string-keyed
    # maps; the director-approved list is atom-keyed with atom modes.
    test "granting exactly the requested paths is allowed" do
      requested = [%{"path" => "/srv/data", "mode" => "write"}]
      granted = [%{path: "/srv/data", mode: :write}]
      assert :ok == PathRequestGate.validate_subset(granted, requested)
    end

    test "granting a subset of the requested paths is allowed" do
      requested = [
        %{"path" => "/srv/data", "mode" => "read"},
        %{"path" => "/srv/logs", "mode" => "write"}
      ]

      granted = [%{path: "/srv/logs", mode: :write}]
      assert :ok == PathRequestGate.validate_subset(granted, requested)
    end

    test "downgrading a requested :write to :read is allowed" do
      requested = [%{"path" => "/srv/data", "mode" => "write"}]
      granted = [%{path: "/srv/data", mode: :read}]
      assert :ok == PathRequestGate.validate_subset(granted, requested)
    end

    test "a tampered path NOT in the request is rejected" do
      requested = [%{"path" => "/srv/data", "mode" => "read"}]
      granted = [%{path: "/home/operator/.ssh/id_ed25519", mode: :read}]

      assert {:error, :granted_not_subset_of_request} ==
               PathRequestGate.validate_subset(granted, requested)
    end

    test "smuggling an extra tampered path alongside a real one is rejected" do
      requested = [%{"path" => "/srv/data", "mode" => "write"}]

      granted = [
        %{path: "/srv/data", mode: :write},
        %{path: "/home/operator/.ssh", mode: :write}
      ]

      assert {:error, :granted_not_subset_of_request} ==
               PathRequestGate.validate_subset(granted, requested)
    end

    test "escalating a requested :read to :write is rejected" do
      requested = [%{"path" => "/srv/data", "mode" => "read"}]
      granted = [%{path: "/srv/data", mode: :write}]

      assert {:error, :granted_not_subset_of_request} ==
               PathRequestGate.validate_subset(granted, requested)
    end

    test "empty or malformed requested list rejects any grant" do
      assert {:error, :granted_not_subset_of_request} ==
               PathRequestGate.validate_subset([%{path: "/srv/data", mode: :read}], [])

      assert {:error, :granted_not_subset_of_request} ==
               PathRequestGate.validate_subset(
                 [%{path: "/srv/data", mode: :read}],
                 [%{"junk" => true}]
               )
    end
  end
end
