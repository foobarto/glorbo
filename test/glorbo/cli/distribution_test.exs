defmodule Glorbo.CLI.Lifecycle.DistributionTest do
  @moduledoc """
  Coverage for `Glorbo.CLI.Lifecycle.Distribution`: the `-address` flag
  contract, the EPMD name-collision *detection*, and the `epmd -names` parser.

  The load-bearing bug guarded here: a cross-process EPMD name collision does
  NOT surface as `{:already_started, _}` (the shape the module used to match).
  On OTP 29 it surfaces as net_kernel failing its distribution child with
  `:nodistribution`. Matching the wrong shape made the friendly "another glorbo
  is running / stale-registration recovery" path unreachable, so a stale EPMD
  registration after a crash raised an opaque error and wedged every restart.

  The recovery side-effects (`live_owner?/0`, killing an orphaned EPMD,
  re-`Node.start`) drive real EPMD + OS processes and are exercised by the
  manual reproduction in docs/testing, not here — these tests pin the pure
  decision that routes into that recovery.
  """
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Lifecycle.Distribution

  test "ensure_epmd passes -address 127.0.0.1 flag" do
    # We can't call ensure_epmd/0 directly (private), but we CAN
    # verify the module source embeds the flag. This is a contract
    # test — if the flag disappears, this fails.
    source = File.read!("lib/glorbo/cli/lifecycle/distribution.ex")
    assert source =~ ~s("-address", "127.0.0.1")
  end

  describe "name_collision?/1" do
    test "matches the real OTP-29 cross-process EPMD collision (:nodistribution)" do
      # Captured verbatim from `Node.start(:\"glorbo@127.0.0.1\", :longnames)`
      # against a held name on OTP 29 — the `{:error, reason}` reason term.
      reason =
        {{:shutdown, {:failed_to_start_child, :net_kernel, {:EXIT, :nodistribution}}},
         {:child, :undefined, :net_sup_dynamic,
          {:erl_distribution, :start_link,
           [%{name: :"glorbo@127.0.0.1", name_domain: :longnames}]}, :permanent, false, 1000,
          :supervisor, [:erl_distribution]}}

      assert Distribution.name_collision?(reason)
    end

    test "matches the legacy / same-VM {:already_started, pid} shape" do
      assert Distribution.name_collision?({:already_started, self()})
    end

    test "does NOT match unrelated startup errors" do
      refute Distribution.name_collision?(:econnrefused)
      refute Distribution.name_collision?({:shutdown, :enoent})
      refute Distribution.name_collision?({:error, :badarg})

      # A different child failing is not a name collision.
      refute Distribution.name_collision?(
               {{:shutdown, {:failed_to_start_child, :some_other_child, {:EXIT, :whatever}}},
                {:child, :undefined}}
             )
    end
  end

  describe "parse_names/1" do
    test "extracts {name, port} pairs from real `epmd -names` output" do
      output = """
      epmd: up and running on port 4369 with data:
      name glorbo at port 43783
      name othernode at port 41001
      """

      assert Distribution.parse_names(output) == [{"glorbo", 43_783}, {"othernode", 41_001}]
    end

    test "returns [] when no nodes are registered" do
      assert Distribution.parse_names("epmd: up and running on port 4369 with data:\n") == []
      assert Distribution.parse_names("") == []
    end

    test "ignores non-matching noise (e.g. EPMD-unreachable error text)" do
      assert Distribution.parse_names("epmd: Cannot connect to local epmd\n") == []
    end
  end

  describe "canonical_node/0" do
    test "is the loopback-pinned long name" do
      assert Distribution.canonical_node() == :"glorbo@127.0.0.1"
    end
  end
end
