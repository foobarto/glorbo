defmodule Glorbo.CLI.Lifecycle.DistributionTest do
  use ExUnit.Case, async: true

  test "ensure_epmd passes -address 127.0.0.1 flag" do
    # We can't call ensure_epmd/0 directly (private), but we CAN
    # verify the module source embeds the flag. This is a contract
    # test — if the flag disappears, this fails.
    source = File.read!("lib/glorbo/cli/lifecycle/distribution.ex")
    assert source =~ ~s("-address", "127.0.0.1")
  end
end
