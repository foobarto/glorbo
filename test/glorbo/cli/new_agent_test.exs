defmodule Glorbo.CLI.NewAgentTest do
  @moduledoc "Stubs — filled in by Plan 02."
  use GlorboTest.CLICase, async: false

  @moduletag :pending

  describe "new agent" do
    test "valid <co>/<slug> scaffolds agents/<slug>/agent.md" do
      flunk("TODO(plan-02): implement new-agent happy path")
    end

    test "missing company returns exit 1" do
      flunk("TODO(plan-02): implement new-agent missing-company error")
    end

    test "defaults shipped in agent.md (role, provider, network, budget)" do
      flunk("TODO(plan-02): assert default frontmatter values")
    end
  end
end
