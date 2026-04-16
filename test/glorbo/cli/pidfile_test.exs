defmodule Glorbo.CLI.Lifecycle.PidfileTest do
  @moduledoc """
  Plan 05-01 Task 1: `Glorbo.CLI.Lifecycle.Pidfile` atomic pidfile helper.

  Covers:
    * `:stopped` when file absent
    * `:running` when file contains an alive OS pid
    * `:stale` when file contains a dead pid
    * `:stale` when file is unparseable
    * `write!/2` + `read!/1` roundtrip (atomic temp+rename, 0600 mode)
    * `rm/1` idempotency (tolerant of ENOENT)
    * `run/` parent dir auto-created if missing
  """
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Lifecycle.Pidfile
  alias Glorbo.Test.TmpGlorboHome

  describe "status/1" do
    test "returns :stopped when pidfile is absent" do
      base = TmpGlorboHome.setup()
      assert Pidfile.status(base) == :stopped
    end

    test "returns :running when pidfile contains an alive OS pid" do
      base = TmpGlorboHome.setup()
      # System.pid/0 returns the BEAM OS pid as a string — definitely alive.
      my_pid = System.pid() |> String.to_integer()
      Pidfile.write!(my_pid, base)
      assert Pidfile.status(base) == :running
    end

    test "returns :stale when pidfile contains a dead pid" do
      base = TmpGlorboHome.setup()
      # 99_999_999 is well above realistic max pid; guaranteed not-alive.
      Pidfile.write!(99_999_999, base)
      assert Pidfile.status(base) == :stale
    end

    test "returns :stale when pidfile content is unparseable" do
      base = TmpGlorboHome.setup()
      run_dir = Path.join(base, "run")
      File.mkdir_p!(run_dir)
      File.write!(Path.join(run_dir, "glorbo.pid"), "not-a-pid\n")
      assert Pidfile.status(base) == :stale
    end
  end

  describe "write!/2 and read!/1" do
    test "roundtrip: write integer pid, read it back" do
      base = TmpGlorboHome.setup()
      Pidfile.write!(12_345, base)
      assert Pidfile.read!(base) == 12_345
    end

    test "creates parent run/ directory if missing" do
      base = TmpGlorboHome.setup()
      # Do NOT pre-create run/ — Pidfile.write!/2 must mkdir_p it.
      refute File.exists?(Path.join(base, "run"))
      Pidfile.write!(42, base)
      assert File.dir?(Path.join(base, "run"))
      assert File.exists?(Path.join(base, "run/glorbo.pid"))
    end

    test "file is written with mode 0600" do
      base = TmpGlorboHome.setup()
      Pidfile.write!(42, base)
      path = Path.join(base, "run/glorbo.pid")
      {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
    end
  end

  describe "rm/1" do
    test "removes an existing pidfile" do
      base = TmpGlorboHome.setup()
      Pidfile.write!(42, base)
      assert :ok = Pidfile.rm(base)
      refute File.exists?(Path.join(base, "run/glorbo.pid"))
    end

    test "is idempotent (tolerant of ENOENT)" do
      base = TmpGlorboHome.setup()
      # File does not exist.
      assert :ok = Pidfile.rm(base)
      # Second call also :ok.
      assert :ok = Pidfile.rm(base)
    end
  end
end
