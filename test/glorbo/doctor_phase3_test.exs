defmodule Glorbo.DoctorPhase3Test do
  use ExUnit.Case, async: true

  alias Glorbo.Doctor

  # Only override the Phase-3 specific deps (bwrap which + userns read);
  # Phase-1/2 checks use their production defaults against the host. Tests
  # here focus on the shape of the two new checks.
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
    test "GEP-5 D6 removed 4 podman/ollama checks; count is 11 with private_files" do
      checks = Doctor.run_checks(phase3_deps())
      names = Enum.map(checks, & &1.name) |> MapSet.new()

      assert "bwrap" in names
      assert "user_namespaces" in names
      assert "private_files" in names
      assert length(checks) == 11
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
      assert "user_namespaces" in names
    end
  end
end
