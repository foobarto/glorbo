defmodule Glorbo.Doctor.Fixer do
  @moduledoc """
  TODO(plan-03): Implement the `doctor --fix` fixer registry per D-16.
  Each registered fixer handles one check name from `Glorbo.Doctor` and
  returns `{:ok, detail} | {:error, reason} | {:explain, guidance}`.

  Wave-0 skeleton — the registry is empty; Plan 03 populates it per
  RESEARCH.md Pattern 5.
  """

  # @fixers filled in Plan 03 per RESEARCH.md Pattern 5
  # Expected shape (Plan 03):
  #
  #   @fixers %{
  #     "glorbo_dir"     => &__MODULE__.fix_glorbo_dir/1,
  #     "audit_dir"      => &__MODULE__.fix_audit_dir/1,
  #     "sockets_dir"    => &__MODULE__.fix_sockets_dir/1,
  #     "podman"         => &__MODULE__.fix_podman/1,
  #     "ollama"         => &__MODULE__.fix_ollama/1,
  #     "runtime_image"  => &__MODULE__.fix_runtime_image/1,
  #     "bwrap"          => &__MODULE__.explain_bwrap/1
  #   }

  @spec run(keyword()) :: Glorbo.CLI.result()
  def run(_opts) do
    {:doctor, 0, "doctor --fix: not implemented in Wave 0 (Plan 03 fills)\n"}
  end
end
