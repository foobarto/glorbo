defmodule Glorbo.Fit.CatalogTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the static in-binary catalog (GEP-59 D4): well-formed
  model entries, the quant tables, and the substring bandwidth lookup.
  """

  alias Glorbo.Fit.Catalog

  describe "models/0" do
    test "every entry has the keys the scorer reads, with sane values" do
      for m <- Catalog.models() do
        assert is_binary(m.name) and m.name != ""
        assert is_binary(m.provider) and m.provider != ""
        assert is_float(m.params_b) and m.params_b > 0
        assert is_integer(m.context_length) and m.context_length > 0
        assert m.use_case in ~w(general coding chat reasoning)
        assert is_float(m.recommended_ram_gb) and m.recommended_ram_gb > 0
      end
    end

    test "spans the size ladder (a sub-2B and a 30B+ both present)" do
      sizes = Enum.map(Catalog.models(), & &1.params_b)
      assert Enum.min(sizes) < 2.0
      assert Enum.max(sizes) > 30.0
    end
  end

  describe "quant tables" do
    test "every hierarchy quant has bpp / speed / quality entries" do
      for q <- Catalog.quant_hierarchy() do
        assert Catalog.bytes_per_param(q) > 0
        assert Catalog.speed_mult(q) > 0
        # quality_penalty is <= 0
        assert Catalog.quality_penalty(q) <= 0
      end
    end

    test "unknown quant labels fall back, never crash" do
      assert Catalog.bytes_per_param("WAT") == 0.58
      assert Catalog.speed_mult("WAT") == 1.0
      assert Catalog.quality_penalty("WAT") == 0.0
    end

    test "hierarchy is ordered highest-bpp (quality) first" do
      bpps = Enum.map(Catalog.quant_hierarchy(), &Catalog.bytes_per_param/1)
      assert bpps == Enum.sort(bpps, :desc)
    end
  end

  describe "bandwidth_for/1 — case-insensitive longest-substring match" do
    test "matches an NVIDIA card name" do
      assert Catalog.bandwidth_for("NVIDIA GeForce RTX 4090") == 1008
    end

    test "longest key wins (m4 max beats m4)" do
      assert Catalog.bandwidth_for("Apple M4 Max") == 546
      assert Catalog.bandwidth_for("Apple M4") == 120
    end

    test "AMD substring match" do
      assert Catalog.bandwidth_for("Radeon RX 7900 XTX") == 960
    end

    test "nil / blank / unknown -> nil (caller takes fallback path)" do
      assert Catalog.bandwidth_for(nil) == nil
      assert Catalog.bandwidth_for("") == nil
      assert Catalog.bandwidth_for("Some Unknown GPU 9999") == nil
    end
  end

  describe "fallback_k/1" do
    test "known backends + default" do
      assert Catalog.fallback_k("cuda") == 220
      assert Catalog.fallback_k("metal") == 150
      assert Catalog.fallback_k("nonsense") == 70
    end
  end
end
