defmodule Glorbo.CLI.ParsersTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers

  describe "known?/1" do
    test "recognises built-in parser names" do
      assert Parsers.known?("none")
      assert Parsers.known?("claude_jsonl")
      assert Parsers.known?("gemini_stdout")
      assert Parsers.known?("codex_jsonl")
    end

    test "rejects unknown names" do
      refute Parsers.known?("wat")
      refute Parsers.known?(nil)
      refute Parsers.known?(:atom)
      refute Parsers.known?("")
    end
  end

  describe "module_for/1" do
    test "returns the module" do
      assert Parsers.module_for("none") == Glorbo.CLI.Parsers.None
      assert Parsers.module_for("claude_jsonl") == Glorbo.CLI.Parsers.ClaudeJsonl
    end

    test "returns nil for unknown" do
      assert Parsers.module_for("wat") == nil
    end
  end

  describe "Parsers.None.parse/1" do
    test "always returns {:error, :untracked}" do
      assert {:error, :untracked} = Glorbo.CLI.Parsers.None.parse({:stdout, "x"})
      assert {:error, :untracked} = Glorbo.CLI.Parsers.None.parse({:jsonl_file, "y"})
    end
  end
end
