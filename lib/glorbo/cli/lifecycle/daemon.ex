defmodule Glorbo.CLI.Lifecycle.Daemon do
  @moduledoc """
  TODO(plan-02): Port-based re-exec helper for `glorbo up`.

  This module is NOT a verb — it is the subprocess-spawning utility
  that `Glorbo.CLI.Lifecycle.Up` uses to detach a child Burrito binary.
  The child inherits `RELEASE_COOKIE` from the parent's env so the new
  BEAM honours `-setcookie` via Burrito's Zig launcher (RESEARCH
  Critical Finding #1).

  Wave-0 skeleton — both functions raise until Plan 02 fills the body.
  """

  @doc """
  Spawn the Burrito binary at `bin_path` in detached mode with
  `RELEASE_COOKIE=<cookie>` in its env. Returns the child OS pid on
  success.
  """
  @spec spawn_detached(Path.t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def spawn_detached(_bin_path, _cookie) do
    raise "TODO(plan-02): implement Port+setsid re-exec"
  end

  @doc """
  Discover the path to the currently-running Burrito binary. Reads
  `__BURRITO_BIN_PATH` when set; falls back to `:escript.script_name/0`
  for `mix` dev runs (not shipped in prod).
  """
  @spec self_binary() :: Path.t()
  def self_binary do
    raise "TODO(plan-02): implement binary discovery"
  end
end
