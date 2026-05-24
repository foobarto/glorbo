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

  # Gemini round-2 finding: the gate's request validator was too
  # permissive — it relied on the upstream Router caller to slug-
  # validate task_id, and the forbidden-paths list only covered
  # /proc, /sys, /dev. Any future caller / out-of-band reader that
  # skipped Router could exfiltrate config.md (dashboard_token +
  # key_base), /etc/shadow, ~/.ssh, etc.
  describe "validate_request/1 — task_id self-defense + broadened denylist (gemini round-2)" do
    defp req(overrides) do
      Map.merge(
        %{
          task_id: "task-1",
          paths: [%{"path" => "/srv/data/foo.txt", "mode" => "read"}],
          reason: "needs the data for the analysis pass"
        },
        Map.new(overrides)
      )
    end

    test "rejects task_ids that don't match the slug-and-number shape" do
      for bad <- [
            "../../etc/passwd",
            "task; rm -rf /",
            "task\n\nyaml-injected: true",
            "Task-1",
            "task",
            "1-task",
            ""
          ] do
        result = PathRequestGate.validate_request(req(task_id: bad))

        assert match?({:error, e} when e in [:invalid_task_id, :missing_task_id], result),
               "expected invalid_task_id for #{inspect(bad)}, got #{inspect(result)}"
      end
    end

    test "accepts well-formed task_ids" do
      for good <- ["task-1", "blog-101", "user-onboarding-12", "x_y_z-999"] do
        assert :ok == PathRequestGate.validate_request(req(task_id: good))
      end
    end

    test "rejects requests for paths under critical host roots" do
      forbidden_paths = [
        "/etc/shadow",
        "/etc/passwd",
        "/etc/sudoers.d/00-glorbo",
        "/root/.bashrc",
        "/boot/grub.cfg",
        "/var/log/auth.log",
        "/var/lib/secret-thing",
        "/lib/systemd/system/x.service",
        "/proc/self/environ",
        "/sys/class/net/eth0/address",
        "/dev/sda1"
      ]

      # The per-entry validator (`valid_path_entry?`) calls
      # `any_forbidden_path?` internally and returns
      # `:invalid_path_entry`; the dedicated `:forbidden_path` tag
      # only fires when an entry passes per-entry shape but the
      # multi-entry sweep catches a forbidden prefix. Either reason
      # is a refusal — accept both.
      for p <- forbidden_paths do
        result = PathRequestGate.validate_request(req(paths: [%{"path" => p, "mode" => "read"}]))

        assert match?({:error, e} when e in [:forbidden_path, :invalid_path_entry], result),
               "expected refusal (forbidden_path | invalid_path_entry) for #{p}, got #{inspect(result)}"
      end
    end

    test "rejects requests for paths under user-secret dirs (HOME-relative)" do
      # Override HOME to a deterministic temp dir so this test doesn't
      # depend on the runner's environment (Copilot review on PR #34).
      prev_home = System.get_env("HOME")

      try do
        fake_home = Path.join(System.tmp_dir!(), "glorbo-pathgate-test-#{System.unique_integer([:positive])}")
        File.mkdir_p!(fake_home)
        System.put_env("HOME", fake_home)

        forbidden_home_paths = [
          Path.join(fake_home, ".ssh/id_ed25519"),
          Path.join(fake_home, ".gnupg/private-keys-v1.d/foo.key"),
          Path.join(fake_home, ".aws/credentials"),
          Path.join(fake_home, ".glorbo/config.md"),
          Path.join(fake_home, ".kube/config"),
          Path.join(fake_home, ".netrc")
        ]

        for p <- forbidden_home_paths do
          result =
            PathRequestGate.validate_request(req(paths: [%{"path" => p, "mode" => "read"}]))

          assert match?({:error, e} when e in [:forbidden_path, :invalid_path_entry], result),
                 "expected refusal for #{p}, got #{inspect(result)}"
        end
      after
        if prev_home, do: System.put_env("HOME", prev_home), else: System.delete_env("HOME")
      end
    end

    test "accepts well-formed requests for project paths" do
      assert :ok ==
               PathRequestGate.validate_request(
                 req(paths: [%{"path" => "/tmp/glorbo-uat/proj/x.md", "mode" => "read"}])
               )
    end
  end
end
