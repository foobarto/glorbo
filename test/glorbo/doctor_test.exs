defmodule Glorbo.DoctorTest do
  use ExUnit.Case, async: true

  alias Glorbo.Doctor
  alias Glorbo.Doctor.Formatter
  alias Glorbo.Doctor.TestHelpers

  # --- kernel check ---

  describe "check_linux_kernel (via run_checks/1)" do
    test "6.17.0 passes" do
      deps = TestHelpers.deps(cmd_fun: TestHelpers.canned_cmd("6.17.0\n"))
      [%{name: "linux_kernel"} = c | _] = Doctor.run_checks(deps)
      assert c.pass
      assert c.detail == "6.17.0"
    end

    test "5.13.0 passes (boundary)" do
      deps = TestHelpers.deps(cmd_fun: TestHelpers.canned_cmd("5.13.0\n"))
      [c | _] = Doctor.run_checks(deps)
      assert c.pass
    end

    test "5.12.99 fails (below boundary)" do
      deps = TestHelpers.deps(cmd_fun: TestHelpers.canned_cmd("5.12.99\n"))
      [c | _] = Doctor.run_checks(deps)
      refute c.pass
    end

    test "4.19.0 fails" do
      deps = TestHelpers.deps(cmd_fun: TestHelpers.canned_cmd("4.19.0\n"))
      [c | _] = Doctor.run_checks(deps)
      refute c.pass
    end
  end

  # --- uidmap check ---

  describe "check_uidmap (via run_checks/1)" do
    test "both newuidmap and newgidmap present: pass" do
      which =
        TestHelpers.canned_which(%{
          "newuidmap" => "/usr/bin/newuidmap",
          "newgidmap" => "/usr/bin/newgidmap"
        })

      deps =
        TestHelpers.deps(
          which_fun: which,
          cmd_fun: fn cmd, _args ->
            case cmd do
              "uname" -> {"6.17.0\n", 0}
              "df" -> {"Avail\n2147483648\n", 0}
              _ -> {"", 0}
            end
          end
        )

      [_kernel, uid_check | _] = Doctor.run_checks(deps)
      assert uid_check.name == "uidmap"
      assert uid_check.pass
      assert uid_check.detail =~ "newuidmap"
      assert uid_check.detail =~ "newgidmap"
    end

    test "newuidmap missing: fail with specific detail" do
      which = TestHelpers.canned_which(%{"newuidmap" => nil, "newgidmap" => "/bin/newgidmap"})

      deps =
        TestHelpers.deps(which_fun: which, cmd_fun: fn _, _ -> {"6.17.0\n", 0} end)

      [_, uid_check | _] = Doctor.run_checks(deps)
      refute uid_check.pass
      assert uid_check.detail =~ "newuidmap"
    end

    test "newgidmap missing: fail with specific detail" do
      which = TestHelpers.canned_which(%{"newuidmap" => "/bin/newuidmap", "newgidmap" => nil})

      deps =
        TestHelpers.deps(which_fun: which, cmd_fun: fn _, _ -> {"6.17.0\n", 0} end)

      [_, uid_check | _] = Doctor.run_checks(deps)
      refute uid_check.pass
      assert uid_check.detail =~ "newgidmap"
    end
  end

  # --- disk_space check ---

  describe "check_disk_space (via run_checks/1)" do
    test "2GB available: pass" do
      deps = TestHelpers.deps(cmd_fun: disk_cmd("6.17.0\n", "Avail\n2147483648\n"))
      [_, _, disk | _] = Doctor.run_checks(deps)
      assert disk.name == "disk_space"
      assert disk.pass
    end

    test "500MB available: fail" do
      deps = TestHelpers.deps(cmd_fun: disk_cmd("6.17.0\n", "Avail\n524288000\n"))
      [_, _, disk | _] = Doctor.run_checks(deps)
      refute disk.pass
    end

    test "exactly 1GB: pass (boundary)" do
      deps = TestHelpers.deps(cmd_fun: disk_cmd("6.17.0\n", "Avail\n1073741824\n"))
      [_, _, disk | _] = Doctor.run_checks(deps)
      assert disk.pass
    end
  end

  # --- glorbo_dir check ---

  describe "check_glorbo_dir (via run_checks/1)" do
    test "creates ~/.glorbo/ under an injected HOME tmp dir" do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "glorbo-doctor-test-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(tmp) end)
      File.mkdir_p!(tmp)

      deps =
        TestHelpers.deps(
          home_fun: fn -> tmp end,
          cmd_fun: fn _, _ -> {"6.17.0\n", 0} end,
          which_fun: fn _ -> "/bin/true" end
        )

      [_, _, _, dir_check | _] = Doctor.run_checks(deps)
      assert dir_check.name == "glorbo_dir"
      assert dir_check.pass
      assert File.dir?(Path.join(tmp, ".glorbo"))

      refute File.exists?(Path.join([tmp, ".glorbo", ".doctor_probe"])),
             "Probe file should have been cleaned up"
    end
  end

  # --- erts_version check ---

  describe "check_erts_version (via run_checks/1)" do
    test "OTP 28 passes" do
      [_, _, _, _, erts | _] = Doctor.run_checks(all_pass_deps("28"))
      assert erts.name == "erts_version"
      assert erts.pass
    end

    test "OTP 27 passes (boundary)" do
      [_, _, _, _, erts | _] = Doctor.run_checks(all_pass_deps("27"))
      assert erts.pass
    end

    test "OTP 26 fails (below boundary)" do
      [_, _, _, _, erts | _] = Doctor.run_checks(all_pass_deps("26"))
      refute erts.pass
    end
  end

  # --- shape ---

  describe "run_checks/1 shape" do
    test "returns 5 check maps with the contract keys" do
      # Use injected deps so we don't depend on real host state (uidmap may be
      # absent on some CI runners).
      deps =
        TestHelpers.deps(
          cmd_fun: fn cmd, _args ->
            case cmd do
              "uname" -> {"6.17.0\n", 0}
              "df" -> {"Avail\n2147483648\n", 0}
              _ -> {"", 1}
            end
          end,
          which_fun: fn _ -> "/bin/true" end,
          otp_release_fun: fn -> "28" end
        )

      results = Doctor.run_checks(deps)
      # GEP-5 D6: 5 Phase-1 + 3 Phase-2 + 2 Phase-3 = 10
      # (podman/ollama/ollama_daemon/runtime_image/runtime_exec dropped)
      assert length(results) == 10

      Enum.each(results, fn r ->
        assert Map.has_key?(r, :name)
        assert Map.has_key?(r, :pass)
        assert Map.has_key?(r, :detail)
        assert Map.has_key?(r, :required)
        assert Map.has_key?(r, :severity)
        assert is_boolean(r.pass)
        assert is_binary(r.name)
        assert r.severity in [:blocker, :warning]
      end)

      names = Enum.map(results, & &1.name)
      # Phase-1 names preserved verbatim in original order at head.
      assert Enum.take(names, 5) ==
               ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"]

      # Remaining Phase-2 checks + Phase-3 additions after GEP-5 D6 pruning.
      assert Enum.drop(names, 5) ==
               [
                 "audit_dir",
                 "sockets_dir",
                 "tar_zstd",
                 "bwrap",
                 "user_namespaces"
               ]
    end
  end

  # --- Formatter ---

  describe "Formatter.to_table/1" do
    test "contains all 5 check names" do
      results = [
        %{name: "linux_kernel", pass: true, detail: "6.17.0", required: "≥ 5.13"},
        %{
          name: "uidmap",
          pass: true,
          detail: "/bin/newuidmap, /bin/newgidmap",
          required: "uidmap"
        },
        %{name: "disk_space", pass: false, detail: "0.5 GB", required: "≥ 1 GB"},
        %{name: "glorbo_dir", pass: true, detail: "/tmp/.glorbo", required: "writable"},
        %{name: "erts_version", pass: true, detail: "OTP 28", required: "≥ 27"}
      ]

      out = Formatter.to_table(results)

      for name <- ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"] do
        assert out =~ name, "Expected output to contain #{name}, got:\n#{out}"
      end

      assert out =~ "required:"
      assert out =~ "1 check(s) failed"
    end
  end

  describe "Formatter.to_json/1" do
    test "produces valid JSON with stable envelope" do
      results = [%{name: "linux_kernel", pass: true, detail: "6.17.0", required: "≥ 5.13"}]
      decoded = results |> Formatter.to_json() |> Jason.decode!()

      assert decoded["version"] == Mix.Project.config()[:version]
      assert decoded["all_passed"] == true
      assert decoded["passed_count"] == 1
      assert decoded["total_count"] == 1
      assert decoded["exit_code"] == 0
      assert [first_check] = decoded["checks"]
      assert first_check["name"] == "linux_kernel"
      assert first_check["pass"] == true
    end

    test "exit_code is 1 when any check fails (Phase-1 fixture, missing severity)" do
      # Legacy 5-field fixture — no severity. Doctor.exit_code/1 falls back
      # to treating missing severity as :blocker so Phase-1 fixtures still
      # map to exit code 1 on any failure (backward compat).
      results = [
        %{name: "a", pass: true, detail: "", required: ""},
        %{name: "b", pass: false, detail: "", required: ""}
      ]

      decoded = results |> Formatter.to_json() |> Jason.decode!()
      assert decoded["all_passed"] == false
      assert decoded["exit_code"] == 1
      assert decoded["passed_count"] == 1
      assert decoded["total_count"] == 2
    end
  end

  # ========================================================================
  # Phase 2 extensions — D-43, D-44, D-45 (severity + 8 new checks)
  # ========================================================================

  describe "Phase 2: severity field on every check (D-44, D-45)" do
    test "each check map carries :severity ∈ {:blocker, :warning}" do
      deps = all_pass_deps("28")
      results = Doctor.run_checks(deps)

      Enum.each(results, fn r ->
        assert Map.has_key?(r, :severity)
        assert r.severity in [:blocker, :warning]
      end)
    end

    test "severity classification matches plan spec" do
      deps = all_pass_deps("28")
      results = Doctor.run_checks(deps)
      by_name = Map.new(results, &{&1.name, &1.severity})

      # Blockers
      for name <- ["linux_kernel", "uidmap", "glorbo_dir", "erts_version", "audit_dir"] do
        assert by_name[name] == :blocker, "#{name} should be :blocker"
      end

      # Warnings
      for name <- [
            "disk_space",
            "sockets_dir",
            "tar_zstd"
          ] do
        assert by_name[name] == :warning, "#{name} should be :warning"
      end
    end
  end

  describe "Phase 2: exit_code/1 severity-weighted (D-45)" do
    test "returns 0 when every check passes" do
      all_pass = [
        %{name: "k", pass: true, detail: "", required: "", severity: :blocker},
        %{name: "w", pass: true, detail: "", required: "", severity: :warning}
      ]

      assert Doctor.exit_code(all_pass) == 0
    end

    test "returns 1 when any blocker fails" do
      results = [
        %{name: "k", pass: false, detail: "", required: "", severity: :blocker},
        %{name: "w", pass: true, detail: "", required: "", severity: :warning}
      ]

      assert Doctor.exit_code(results) == 1
    end

    test "returns 2 when only warnings fail" do
      results = [
        %{name: "k", pass: true, detail: "", required: "", severity: :blocker},
        %{name: "w", pass: false, detail: "", required: "", severity: :warning}
      ]

      assert Doctor.exit_code(results) == 2
    end

    test "blocker fail dominates warning fail (returns 1)" do
      results = [
        %{name: "k", pass: false, detail: "", required: "", severity: :blocker},
        %{name: "w", pass: false, detail: "", required: "", severity: :warning}
      ]

      assert Doctor.exit_code(results) == 1
    end
  end

  describe "Phase 2: check_audit_dir + check_sockets_dir (D-46 idempotent)" do
    test "creates + cleans probe in ~/.glorbo/audit/_system/ and ~/.glorbo/runtime/sockets/" do
      tmp =
        Path.join(System.tmp_dir!(), "glorbo-doctor-test-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(tmp) end)
      File.mkdir_p!(tmp)

      deps =
        TestHelpers.deps(
          home_fun: fn -> tmp end,
          cmd_fun: fn cmd, _args ->
            case cmd do
              "uname" -> {"6.17.0\n", 0}
              "df" -> {"Avail\n2147483648\n", 0}
              _ -> {"", 1}
            end
          end,
          which_fun: fn _ -> "/bin/true" end,
          otp_release_fun: fn -> "28" end
        )

      results = Doctor.run_checks(deps)
      audit = Enum.find(results, &(&1.name == "audit_dir"))
      sockets = Enum.find(results, &(&1.name == "sockets_dir"))

      assert audit.pass
      assert audit.severity == :blocker
      assert File.dir?(Path.join([tmp, ".glorbo", "audit", "_system"]))

      assert sockets.pass
      assert sockets.severity == :warning
      sockets_path = Path.join([tmp, ".glorbo", "runtime", "sockets"])
      assert File.dir?(sockets_path)

      %File.Stat{mode: mode} = File.stat!(sockets_path)
      # Lower 9 bits hold permissions; assert 0700.
      assert Bitwise.band(mode, 0o777) == 0o700
    end
  end

  describe "Phase 2: check_tar_zstd" do
    test "pass when tar --version output contains \"zstd\"" do
      deps =
        TestHelpers.deps(
          cmd_fun: fn cmd, args ->
            cond do
              cmd == "uname" ->
                {"6.17.0\n", 0}

              cmd == "df" ->
                {"Avail\n2147483648\n", 0}

              cmd == "tar" and args == ["--version"] ->
                {"tar (GNU tar) 1.35\nzstd support compiled in\n", 0}

              true ->
                {"", 1}
            end
          end,
          which_fun: fn _ -> "/bin/true" end,
          otp_release_fun: fn -> "28" end
        )

      check = Doctor.run_checks(deps) |> Enum.find(&(&1.name == "tar_zstd"))
      assert check.pass
      assert check.detail =~ "tar --zstd"
    end

    test "pass when separate zstd binary exists" do
      deps =
        TestHelpers.deps(
          cmd_fun: fn cmd, _args ->
            case cmd do
              "uname" -> {"6.17.0\n", 0}
              "df" -> {"Avail\n2147483648\n", 0}
              "tar" -> {"tar (GNU tar) 1.30\n", 0}
              _ -> {"", 1}
            end
          end,
          which_fun: fn
            "zstd" -> "/usr/bin/zstd"
            _ -> "/bin/true"
          end,
          otp_release_fun: fn -> "28" end
        )

      check = Doctor.run_checks(deps) |> Enum.find(&(&1.name == "tar_zstd"))
      assert check.pass
      assert check.detail =~ "zstd binary present"
    end

    test "fail when neither tar --zstd nor zstd binary is available" do
      deps =
        TestHelpers.deps(
          cmd_fun: fn cmd, _args ->
            case cmd do
              "uname" -> {"6.17.0\n", 0}
              "df" -> {"Avail\n2147483648\n", 0}
              "tar" -> {"tar (GNU tar) 1.30\n", 0}
              _ -> {"", 1}
            end
          end,
          which_fun: fn
            "zstd" -> nil
            "newuidmap" -> "/bin/newuidmap"
            "newgidmap" -> "/bin/newgidmap"
            _ -> "/bin/true"
          end,
          otp_release_fun: fn -> "28" end
        )

      check = Doctor.run_checks(deps) |> Enum.find(&(&1.name == "tar_zstd"))
      refute check.pass
      assert check.severity == :warning
      assert check.detail =~ "neither"
    end
  end

  describe "Phase 2: JSON additive schema (D-44)" do
    test "every Phase-1 key is preserved verbatim and severity is additive" do
      deps = all_pass_deps("28")
      results = Doctor.run_checks(deps)
      decoded = results |> Formatter.to_json() |> Jason.decode!()

      # GEP-5 D6: 5 Phase-1 + 3 Phase-2 + 2 Phase-3 = 10
      assert length(decoded["checks"]) == 10
      # Top-level envelope keys all still present
      for k <- ["version", "checks", "all_passed", "passed_count", "total_count", "exit_code"] do
        assert Map.has_key?(decoded, k), "envelope key #{k} missing"
      end

      first = hd(decoded["checks"])
      # Phase 1 contract keys preserved verbatim
      for k <- ["name", "pass", "detail", "required"] do
        assert Map.has_key?(first, k), "Phase-1 key #{k} missing"
      end

      # Phase 2 additive key
      assert Map.has_key?(first, "severity")
      assert first["severity"] in ["blocker", "warning"]
    end

    test "exit_code reflects severity-weighted logic" do
      deps = all_pass_deps("28")
      results = Doctor.run_checks(deps)
      decoded = results |> Formatter.to_json() |> Jason.decode!()
      # Phase 2 warning checks fail under the `/bin/true` fixture (no real
      # podman/ollama/etc). Phase 3 adds bwrap as a :blocker — the fixture's
      # `/bin/true --version` returns exit 1, which trips the blocker path.
      # So exit_code is 1 (at-least-one-blocker-failed) post-Plan-03-05.
      assert decoded["exit_code"] == 1
    end
  end

  # --- helpers ---

  defp disk_cmd(kernel_out, df_out) do
    # 2-arity fake used by Phase-1 kernel/uname/df checks AND by Phase-2
    # checks via Glorbo.Doctor.invoke_cmd/4's 2-arity fallback. Non-{uname,df}
    # commands return a non-zero exit so new Phase 2 warning checks fail
    # cleanly (Phase-1 tests only pattern-match the first N check results).
    fn cmd, _args ->
      case cmd do
        "uname" -> {kernel_out, 0}
        "df" -> {df_out, 0}
        _ -> {"", 1}
      end
    end
  end

  defp all_pass_deps(otp) do
    TestHelpers.deps(
      cmd_fun: fn cmd, _args ->
        case cmd do
          "uname" -> {"6.17.0\n", 0}
          "df" -> {"Avail\n2147483648\n", 0}
          _ -> {"", 1}
        end
      end,
      which_fun: fn _ -> "/bin/true" end,
      otp_release_fun: fn -> otp end
    )
  end
end
