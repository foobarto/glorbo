defmodule Glorbo.Test.UniqueName do
  @moduledoc """
  Unique-per-test process names for helpers that spawn short-lived
  named GenServers/Supervisors.

  The BEAM's `System.unique_integer/1` counter is bounded (monotonic
  per-scheduler 64-bit integer), so creating one atom per test via
  `:"prefix_\#{n}"` can't exhaust the atom table in any realistic test
  run. Production code never constructs names this way (GEP-12 /
  T-03-15: no user-input atoms ever), but tests have a different
  threat model — the "input" is a counter, not a user.

  This helper exists to:

    1. Consolidate the pattern into one call site so `mix credo
       --strict` only needs one `# credo:disable-for-next-line
       Credo.Check.Warning.UnsafeToAtom` annotation instead of ~20
       scattered across the test tree.

    2. Make the "why is this safe in tests specifically?" reasoning
       discoverable in one module.
  """

  @doc """
  Build a unique atom for a named test process. The returned atom is
  of the form `:"<prefix>_<counter>"`.

  ## Examples

      iex> Glorbo.Test.UniqueName.gen("router") |> Atom.to_string() |> String.starts_with?("router_")
      true
  """
  @spec gen(String.t()) :: atom()
  def gen(prefix) when is_binary(prefix) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
