defmodule Glorbo.Test.TmpGlorboHome do
  @moduledoc """
  Per-test isolated `~/.glorbo/`-shaped tree under `System.tmp_dir!()`.

  Returns a fresh path for each call; registers an `on_exit` hook that
  recursively removes the directory after the test finishes. Use inside any
  ExUnit test that needs a hermetic filesystem root (Hierarchy, Reindex,
  AuditLog).
  """

  @spec setup() :: Path.t()
  def setup do
    path = Path.join(System.tmp_dir!(), "glorbo_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> rm_rf_resilient(path) end)
    path
  end

  # Tests that spawn child daemons (UpTest, RunTest) face a race: an
  # earlier `on_exit` SIGKILLs the daemon, but the kernel may flush a
  # pending write to disk milliseconds later. `File.rm_rf!` walks the
  # tree once; if a new file appears between the scan and the unlink,
  # it raises `File.Error reason: :eexist` — flaking CI on x86_64 GH
  # runners under load. Retry up to a few times before giving up.
  defp rm_rf_resilient(path, attempts \\ 5) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, _reason, _partial} when attempts > 0 ->
        Process.sleep(50)
        rm_rf_resilient(path, attempts - 1)

      {:error, reason, partial} ->
        raise File.Error,
          reason: reason,
          action: "remove files and directories recursively from",
          path: partial
    end
  end
end
