defmodule Glorbo.CLI.PathTransformsTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.PathTransforms

  describe "known?/1" do
    test "recognises slash_to_dash" do
      assert PathTransforms.known?("slash_to_dash")
    end

    test "rejects unknown transforms" do
      refute PathTransforms.known?("phlogiston")
      refute PathTransforms.known?(nil)
      refute PathTransforms.known?(:atom)
    end
  end

  describe "slash_to_dash/1" do
    test "replaces every slash with dash" do
      assert PathTransforms.slash_to_dash("/home/agents/alice") == "-home-agents-alice"
    end

    test "no-op when string has no slashes" do
      assert PathTransforms.slash_to_dash("agents-alice") == "agents-alice"
    end

    test "handles empty string" do
      assert PathTransforms.slash_to_dash("") == ""
    end
  end

  describe "apply!/2" do
    test "dispatches to the named transform" do
      assert PathTransforms.apply!("slash_to_dash", "/a/b/c") == "-a-b-c"
    end

    test "raises for unknown transform" do
      assert_raise ArgumentError, ~r/unknown path_transform/, fn ->
        PathTransforms.apply!("phlogiston", "x")
      end
    end
  end
end
