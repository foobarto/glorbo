defmodule Glorbo.Terminal.SanitizerTest do
  @moduledoc "C-117: terminal escape stripping for untrusted CLI output."
  use ExUnit.Case, async: true

  alias Glorbo.Terminal.Sanitizer

  test "strips CSI/SGR colour sequences but keeps visible text" do
    assert Sanitizer.strip("\e[31mred\e[0m text") == "red text"
  end

  test "strips OSC window-title (BEL-terminated)" do
    out = Sanitizer.strip("\e]0;evil-title\aafter")
    assert out == "after"
    refute String.contains?(out, "\e")
    refute String.contains?(out, "\a")
  end

  test "strips OSC hyperlink (ST-terminated)" do
    out = Sanitizer.strip("\e]8;;http://evil\e\\link\e]8;;\e\\")
    assert out == "link"
  end

  test "drops bare control bytes including BEL, backspace, CR" do
    out = Sanitizer.strip("a\bb\rc\ad")
    assert out == "abcd"
  end

  test "preserves tab and newline" do
    assert Sanitizer.strip("a\tb\nc") == "a\tb\nc"
  end

  test "drops raw C1 control bytes" do
    assert Sanitizer.strip(<<?a, 0x9B, ?b>>) == "ab"
  end

  test "preserves multibyte UTF-8" do
    assert Sanitizer.strip("héllo — wörld") == "héllo — wörld"
  end

  test "handles unterminated OSC without quadratic blowup" do
    # 200k ESC-] starts with no terminator — a backtracking regex would be
    # O(n^2). A linear scan finishes promptly.
    payload = String.duplicate("\e]", 100_000)
    {micros, out} = :timer.tc(fn -> Sanitizer.strip(payload) end)
    assert out == ""
    assert micros < 2_000_000, "took #{micros}us — scanner is not linear"
  end

  test "passes through plain text untouched" do
    assert Sanitizer.strip("hello world") == "hello world"
  end
end
