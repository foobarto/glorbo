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
      [_, _, _, _, erts] = Doctor.run_checks(all_pass_deps("28"))
      assert erts.name == "erts_version"
      assert erts.pass
    end

    test "OTP 27 passes (boundary)" do
      [_, _, _, _, erts] = Doctor.run_checks(all_pass_deps("27"))
      assert erts.pass
    end

    test "OTP 26 fails (below boundary)" do
      [_, _, _, _, erts] = Doctor.run_checks(all_pass_deps("26"))
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
            end
          end,
          which_fun: fn _ -> "/bin/true" end,
          otp_release_fun: fn -> "28" end
        )

      results = Doctor.run_checks(deps)
      assert length(results) == 5

      Enum.each(results, fn r ->
        assert Map.has_key?(r, :name)
        assert Map.has_key?(r, :pass)
        assert Map.has_key?(r, :detail)
        assert Map.has_key?(r, :required)
        assert is_boolean(r.pass)
        assert is_binary(r.name)
      end)

      names = Enum.map(results, & &1.name)
      assert names == ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"]
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

    test "exit_code is 1 when any check fails" do
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

  # --- helpers ---

  defp disk_cmd(kernel_out, df_out) do
    fn cmd, _args ->
      case cmd do
        "uname" -> {kernel_out, 0}
        "df" -> {df_out, 0}
      end
    end
  end

  defp all_pass_deps(otp) do
    TestHelpers.deps(
      cmd_fun: fn cmd, _args ->
        case cmd do
          "uname" -> {"6.17.0\n", 0}
          "df" -> {"Avail\n2147483648\n", 0}
        end
      end,
      which_fun: fn _ -> "/bin/true" end,
      otp_release_fun: fn -> otp end
    )
  end
end
