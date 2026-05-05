defmodule Mix.Tasks.Glorbo.PrivacyCheckTest do
  use ExUnit.Case, async: false

  @task "glorbo.privacy_check"

  setup do
    Mix.Task.clear()
    :ok
  end

  test "current tracked tree is clean" do
    assert capture_task() =~ "mix glorbo.privacy_check — clean"
  end

  test "secret pattern detector catches API-key-shaped values" do
    path = tmp_tracked_file!("tmp-privacy-fixture.txt")

    File.write!(
      path,
      "OPENAI_API_KEY=sk-proj-#{String.duplicate("a", 32)}\n"
    )

    try do
      assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
               assert catch_exit(Mix.Task.rerun(@task, [])) == {:shutdown, 1}
             end) =~ "possible privacy leaks found"
    after
      _ = System.cmd("git", ["rm", "--cached", "--quiet", "--", path], stderr_to_stdout: true)
      File.rm(path)
    end
  end

  defp capture_task do
    ExUnit.CaptureIO.capture_io(fn ->
      Mix.Task.rerun(@task, [])
    end)
  end

  defp tmp_tracked_file!(name) do
    path = "tmp-privacy-#{System.unique_integer([:positive])}-#{name}"
    File.write!(path, "")

    case System.cmd("git", ["add", "-N", "--", path], stderr_to_stdout: true) do
      {_out, 0} -> path
      {out, status} -> flunk("git add -N failed with #{status}: #{out}")
    end
  end
end
