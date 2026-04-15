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
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
