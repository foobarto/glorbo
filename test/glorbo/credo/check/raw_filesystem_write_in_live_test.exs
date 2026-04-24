defmodule Glorbo.Credo.Check.RawFilesystemWriteInLiveTest do
  @moduledoc """
  Regression coverage for the GEP-36 custom Credo check. Runs the
  check against synthetic source files to assert (1) raw File.*
  mutations in lib/glorbo_web/live/ are flagged, (2) the allowlist
  silences matched files, (3) files outside the live/ prefix are
  ignored wholesale, (4) read-only File.* calls never fire.
  """
  use ExUnit.Case, async: false

  alias Glorbo.Credo.Check.RawFilesystemWriteInLive

  # Credo.SourceFile.parse/2 talks to an ETS-backed GenServer that
  # Credo starts from its own Application supervisor. Since we don't
  # start :credo as an application here, boot the GenServer ourselves
  # (idempotent — tolerates the :already_started race).
  setup_all do
    {:ok, _} = Application.ensure_all_started(:credo)
    :ok
  end

  defp run(relative_path, source, params \\ []) do
    # Credo expands to absolute paths relative to cwd(). Feed a path
    # that's absolute + rooted in cwd so Path.relative_to/2 returns the
    # value we expect.
    abs = Path.join(File.cwd!(), relative_path)
    source_file = Credo.SourceFile.parse(source, abs)
    RawFilesystemWriteInLive.run(source_file, params)
  end

  @live_source """
  defmodule Demo do
    def go(path) do
      File.write!(path, "hi")
      File.rename(path, path <> ".bak")
      File.read(path)
    end
  end
  """

  test "flags raw File.write!/File.rename inside a LiveView path" do
    issues = run("lib/glorbo_web/live/demo_live.ex", @live_source)
    triggers = Enum.map(issues, & &1.trigger)
    assert "File.write!" in triggers
    assert "File.rename" in triggers
    refute "File.read" in triggers
  end

  test "silent when the file is on the allowlist" do
    issues =
      run("lib/glorbo_web/live/demo_live.ex", @live_source,
        allowlist: ["lib/glorbo_web/live/demo_live.ex"]
      )

    assert issues == []
  end

  test "silent when the file is outside lib/glorbo_web/live/" do
    issues = run("lib/glorbo/some_module.ex", @live_source)
    assert issues == []
  end

  test "does not flag read-only File.* calls" do
    source = """
    defmodule Demo do
      def go(p) do
        File.read(p)
        File.exists?(p)
        File.ls(p)
      end
    end
    """

    issues = run("lib/glorbo_web/live/demo_live.ex", source)
    assert issues == []
  end

  test "flags all forbidden write-family functions" do
    source = """
    defmodule Demo do
      def go(p) do
        File.write!(p, "x")
        File.mkdir_p!(p)
        File.rm_rf(p)
        File.cp!(p, p)
        File.touch(p)
        File.ln_s(p, p)
      end
    end
    """

    issues = run("lib/glorbo_web/live/demo_live.ex", source)
    triggers = Enum.map(issues, & &1.trigger) |> MapSet.new()

    for expected <- ~w(File.write! File.mkdir_p! File.rm_rf File.cp! File.touch File.ln_s) do
      assert expected in triggers, "expected #{expected} in #{inspect(triggers)}"
    end
  end
end
