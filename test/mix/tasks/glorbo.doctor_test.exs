defmodule Mix.Tasks.Glorbo.DoctorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Glorbo.Doctor, as: DoctorTask

  @all_pass [
    %{name: "linux_kernel", pass: true, detail: "6.17.0", required: "≥ 5.13"},
    %{
      name: "uidmap",
      pass: true,
      detail: "/bin/newuidmap, /bin/newgidmap",
      required: "uidmap"
    },
    %{name: "disk_space", pass: true, detail: "2.0 GB", required: "≥ 1 GB"},
    %{name: "glorbo_dir", pass: true, detail: "/tmp/.glorbo", required: "writable"},
    %{name: "erts_version", pass: true, detail: "OTP 28", required: "≥ 27"}
  ]

  @one_fail [
    %{name: "linux_kernel", pass: true, detail: "6.17.0", required: "≥ 5.13"},
    %{name: "uidmap", pass: false, detail: "newuidmap not found in PATH", required: "uidmap"},
    %{name: "disk_space", pass: true, detail: "2.0 GB", required: "≥ 1 GB"},
    %{name: "glorbo_dir", pass: true, detail: "/tmp/.glorbo", required: "writable"},
    %{name: "erts_version", pass: true, detail: "OTP 28", required: "≥ 27"}
  ]

  describe "report/2 default (table) output" do
    test "prints human table and returns :ok on all pass" do
      output =
        capture_io(fn ->
          assert :ok = DoctorTask.report(@all_pass, [])
        end)

      assert output =~ "Glorbo Doctor"

      for name <- ["linux_kernel", "uidmap", "disk_space", "glorbo_dir", "erts_version"] do
        assert output =~ name
      end

      assert output =~ "All checks passed"
    end

    test "exits with {:shutdown, 1} when any check fails" do
      capture_io(fn ->
        assert catch_exit(DoctorTask.report(@one_fail, [])) == {:shutdown, 1}
      end)
    end
  end

  describe "report/2 --json output" do
    test "emits JSON decodable via Jason with stable envelope" do
      output =
        capture_io(fn ->
          assert :ok = DoctorTask.report(@all_pass, ["--json"])
        end)

      decoded = Jason.decode!(output)
      assert decoded["version"] == Mix.Project.config()[:version]
      assert decoded["all_passed"] == true
      assert decoded["passed_count"] == 5
      assert decoded["total_count"] == 5
      assert decoded["exit_code"] == 0
      assert length(decoded["checks"]) == 5

      first = List.first(decoded["checks"])

      for k <- ["name", "pass", "detail", "required"] do
        assert Map.has_key?(first, k), "missing key #{k} in check payload"
      end
    end

    test "--json output has exit_code 1 and exits shutdown 1 when a check fails" do
      output =
        capture_io(fn ->
          assert catch_exit(DoctorTask.report(@one_fail, ["--json"])) == {:shutdown, 1}
        end)

      decoded = Jason.decode!(output)
      assert decoded["all_passed"] == false
      assert decoded["exit_code"] == 1
      assert decoded["passed_count"] == 4
    end
  end

  describe "run/1 end-to-end on the real host" do
    @tag :smoke
    test "run/1 with no args prints something containing the phrase 'Glorbo Doctor'" do
      # This hits the real host's uname, df, newuidmap lookups. We only assert
      # the output shape, not pass/fail (CI runners may lack uidmap).
      output =
        capture_io(fn ->
          try do
            DoctorTask.run([])
          catch
            :exit, {:shutdown, 1} -> :ok
          end
        end)

      assert output =~ "Glorbo Doctor"
    end
  end
end
