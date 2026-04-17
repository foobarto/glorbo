defmodule Mix.Tasks.Glorbo.KillTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Glorbo.CLI.Lifecycle.Pidfile
  alias Mix.Tasks.Glorbo.Kill, as: KillTask

  setup do
    base = Path.join(System.tmp_dir!(), "glorbo_kill_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "run"))
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  test "no pidfile → exit 1 + clear error message", %{base: base} do
    output =
      capture_io(:stderr, fn ->
        assert catch_exit(KillTask.run(["--base", base])) == {:shutdown, 1}
      end)

    assert output =~ "no pidfile"
  end

  test "stale pidfile → exit 2 + file removed", %{base: base} do
    # Write a pid that will never be alive — PID 1 is init (pid 0 reserved);
    # use a deliberately-bogus huge pid instead. Linux PID max is 4_194_304;
    # writing something beyond that is always "not alive" from kill -0.
    Pidfile.write!(9_999_999, base)

    output =
      capture_io(fn ->
        assert catch_exit(KillTask.run(["--base", base])) == {:shutdown, 2}
      end)

    assert output =~ "stale"
    refute File.exists?(Pidfile.path(base))
  end

  test "our own pid → SIGTERM delivered (we survive because ExUnit catches) but status reported",
       %{base: base} do
    # Write a short-lived child pid so we can deliver SIGTERM without
    # killing the test runner. `sleep 10` is POSIX-portable.
    port =
      Port.open({:spawn_executable, System.find_executable("sleep")}, [
        {:args, ["10"]},
        :exit_status
      ])

    {:os_pid, child_pid} = Port.info(port, :os_pid)

    Pidfile.write!(child_pid, base)

    output =
      capture_io(fn ->
        try do
          KillTask.run(["--base", base])
        catch
          :exit, _ -> :ok
        end
      end)

    assert output =~ "SIGTERM"
    assert output =~ "#{child_pid}"

    # Port typically already closed by the SIGTERM above — tolerate either.
    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end
end
