defmodule Glorbo.Test.BwrapHelpers do
  @moduledoc """
  Test helpers for the `:bwrap`-tagged integration suite.

  Integration tests that shell out to real `bwrap(1)` call
  `bwrap_available?/0` in a `setup` block and skip if bwrap isn't
  installed. This lets the CI matrix run on hosts without bubblewrap
  (unit-only jobs) while still enforcing kernel-layer correctness on the
  bwrap-equipped job.
  """

  @doc """
  True iff the `bwrap` binary is on PATH and responds to `--version`
  with exit 0. Cached per-process via the process dictionary to avoid
  repeated exec calls across tests.
  """
  @spec bwrap_available?() :: boolean()
  def bwrap_available? do
    case Process.get(:bwrap_available_cache) do
      nil ->
        result = probe_bwrap()
        Process.put(:bwrap_available_cache, result)
        result

      cached ->
        cached
    end
  end

  defp probe_bwrap do
    case System.find_executable("bwrap") do
      nil ->
        false

      path ->
        try do
          case System.cmd(path, ["--version"], stderr_to_stdout: true) do
            {_out, 0} -> true
            _ -> false
          end
        rescue
          _ -> false
        end
    end
  end

  @doc """
  Returns the absolute path to the bwrap binary, or raises if unavailable.
  Tests guarded by `bwrap_available?` can call this without further checks.
  """
  @spec bwrap_path!() :: String.t()
  def bwrap_path! do
    System.find_executable("bwrap") || raise "bwrap not on PATH"
  end
end
