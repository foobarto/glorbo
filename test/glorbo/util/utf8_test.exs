defmodule Glorbo.Util.UTF8Test do
  use ExUnit.Case, async: true

  alias Glorbo.Util.UTF8

  describe "safe_byte_slice/2" do
    test "returns binary unchanged when already within cap" do
      assert UTF8.safe_byte_slice("hello", 1024) == "hello"
      assert UTF8.safe_byte_slice("", 1024) == ""
    end

    test "byte-slices pure ASCII at the exact cap" do
      s = String.duplicate("A", 1024)
      assert UTF8.safe_byte_slice(s, 1024) == s
      assert UTF8.safe_byte_slice(s <> "B", 1024) == s
    end

    test "preserves UTF-8 validity when cap splits a 2-byte codepoint" do
      # 1023 ASCII bytes + `é` (0xC3 0xA9) = 1025 bytes; cap at 1024
      # naively splits between 0xC3 and 0xA9, leaving an invalid binary.
      s = String.duplicate("A", 1023) <> "é"
      assert byte_size(s) == 1025

      naive = :binary.part(s, 0, 1024)
      refute String.valid?(naive)

      safe = UTF8.safe_byte_slice(s, 1024)
      assert String.valid?(safe)
      # Should drop the entire `é` (its 0xC3 lead + the trailing
      # continuation we wouldn't include) — left with 1023 'A's.
      assert byte_size(safe) == 1023
      assert safe == String.duplicate("A", 1023)
    end

    test "preserves UTF-8 validity when cap splits a 3-byte codepoint (CJK)" do
      # `日` is 3 bytes (0xE6 0x97 0xA5). 1022 ASCII + `日` = 1025 bytes;
      # cap at 1024 lands inside the codepoint.
      s = String.duplicate("A", 1022) <> "日"
      assert byte_size(s) == 1025

      safe = UTF8.safe_byte_slice(s, 1024)
      assert String.valid?(safe)
      assert safe == String.duplicate("A", 1022)
    end

    test "preserves UTF-8 validity when cap splits a 4-byte codepoint (emoji)" do
      # `🦊` is 4 bytes (0xF0 0x9F 0xA6 0x8A). 1021 ASCII + emoji = 1025.
      s = String.duplicate("A", 1021) <> "🦊"
      assert byte_size(s) == 1025

      safe = UTF8.safe_byte_slice(s, 1024)
      assert String.valid?(safe)
      assert safe == String.duplicate("A", 1021)
    end

    test "is safe when the cap falls exactly on a codepoint boundary" do
      # 1024 ASCII = exact boundary; cap == byte_size → unchanged.
      s = String.duplicate("A", 1024)
      assert UTF8.safe_byte_slice(s, 1024) == s

      # 1022 ASCII + `é` (2 bytes) = 1024 bytes, on a boundary.
      s2 = String.duplicate("A", 1022) <> "é"
      assert byte_size(s2) == 1024
      assert UTF8.safe_byte_slice(s2, 1024) == s2
    end

    test "round-trips through Jason without raising (the load-bearing invariant)" do
      # The point of the helper: whatever we return must be Jason-encodable.
      # All the tricky cases combined.
      for tail <- ["é", "日", "🦊", "ñ", "字"], pad <- [1023, 1022, 1021, 1024] do
        s = String.duplicate("A", pad) <> tail
        safe = UTF8.safe_byte_slice(s, 1024)
        # Jason.encode! raises on invalid UTF-8.
        assert is_binary(Jason.encode!(safe)),
               "Jason.encode! failed for pad=#{pad} tail=#{tail} → #{inspect(safe)}"
      end
    end
  end
end
