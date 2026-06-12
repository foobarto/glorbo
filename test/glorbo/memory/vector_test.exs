defmodule Glorbo.Memory.VectorTest do
  use ExUnit.Case, async: true

  alias Glorbo.Memory.Vector

  describe "pack/unpack round-trip" do
    test "preserves float32 values within tolerance" do
      vec = [0.0, 1.0, -1.0, 0.5, 0.25]
      blob = Vector.pack(vec)

      assert byte_size(blob) == length(vec) * 4

      unpacked = Vector.unpack(blob)

      Enum.zip(vec, unpacked)
      |> Enum.each(fn {a, b} -> assert_in_delta a, b, 1.0e-6 end)
    end

    test "unpack ignores a truncated trailing partial float" do
      blob = Vector.pack([1.0, 2.0]) <> <<0, 0>>
      assert Vector.unpack(blob) |> length() == 2
    end
  end

  describe "cosine/2" do
    test "identical direction → 1.0" do
      assert_in_delta Vector.cosine([1.0, 2.0, 3.0], [1.0, 2.0, 3.0]), 1.0, 1.0e-9
    end

    test "opposite direction → -1.0" do
      assert_in_delta Vector.cosine([1.0, 0.0], [-1.0, 0.0]), -1.0, 1.0e-9
    end

    test "orthogonal → 0.0" do
      assert_in_delta Vector.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 1.0e-9
    end

    test "ranks a closer vector above a farther one" do
      query = [1.0, 1.0, 0.0]
      close = [1.0, 0.9, 0.0]
      far = [0.0, 0.1, 1.0]

      assert Vector.cosine(query, close) > Vector.cosine(query, far)
    end

    test "zero vector → 0.0 (no NaN)" do
      assert Vector.cosine([0.0, 0.0], [1.0, 1.0]) == 0.0
    end

    test "length mismatch → 0.0 (not comparable, never crashes)" do
      assert Vector.cosine([1.0, 2.0], [1.0, 2.0, 3.0]) == 0.0
    end
  end

  describe "rrf/3 (reciprocal-rank fusion)" do
    test "an id ranked highly in both lists wins" do
      keyword = [:a, :b, :c]
      cosine = [:b, :a, :c]

      fused = Vector.rrf(keyword, cosine)
      assert {top, _score} = hd(fused)
      # :b is rank 2 + rank 1, :a is rank 1 + rank 2 — tie on raw score;
      # add a third list-agreement case below. Here both a and b sum to
      # 1/(60+1) + 1/(60+2); deterministic tie-break is on the term.
      assert top in [:a, :b]
    end

    test "consensus top beats a split decision" do
      # :x is #1 in both lists; :y is #1 in one but absent from the other.
      keyword = [:x, :y, :z]
      cosine = [:x, :z, :w]

      fused = Vector.rrf(keyword, cosine)
      assert {:x, _} = hd(fused)
    end

    test "an id present in only one list still scores" do
      fused = Vector.rrf([:only_here], [])
      assert [{:only_here, score}] = fused
      assert score == 1.0 / 61
    end

    test "deterministic ordering on ties" do
      assert Vector.rrf([:b, :a], [:a, :b]) == Vector.rrf([:b, :a], [:a, :b])
    end
  end
end
