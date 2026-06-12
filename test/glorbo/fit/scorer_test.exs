defmodule Glorbo.Fit.ScorerTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit tests for the pure-Elixir fit scorer (GEP-59 D1/D5). All math,
  no I/O — every test drives `Scorer` with a hand-built system map.
  """

  alias Glorbo.Fit.Catalog
  alias Glorbo.Fit.Scorer

  # A handful of fixed catalog entries so the tests don't drift when the
  # curated catalog gains/loses models. These mirror real catalog shapes.
  defp model(overrides) do
    Map.merge(
      %{
        name: "TestModel-7B",
        provider: "acme",
        params_b: 7.0,
        context_length: 32_768,
        use_case: "general",
        family: "qwen",
        recommended_ram_gb: 10.0
      },
      overrides
    )
  end

  defp gpu_system(vram, ram, name \\ "NVIDIA GeForce RTX 4090") do
    %{
      has_gpu: true,
      gpu_name: name,
      gpu_vram_gb: vram,
      available_ram_gb: ram,
      backend: "cuda"
    }
  end

  defp ram_only_system(ram) do
    %{
      has_gpu: false,
      gpu_name: nil,
      gpu_vram_gb: 0,
      available_ram_gb: ram,
      backend: "cpu_x86"
    }
  end

  describe "estimate_memory_gb/3 — ported odysseus formula" do
    test "weights + KV + overhead grows with quant bpp and context" do
      m = model(%{params_b: 8.0})

      # pb*bpp + 8e-6*pb*ctx + 0.5
      assert_in_delta Scorer.estimate_memory_gb(m, "Q4_K_M", 4096), 8.0 * 0.58 + 0.26 + 0.5, 0.01
      assert_in_delta Scorer.estimate_memory_gb(m, "Q8_0", 4096), 8.0 * 1.05 + 0.26 + 0.5, 0.01
    end

    test "lower quant needs strictly less memory" do
      m = model(%{params_b: 8.0})
      hierarchy = Catalog.quant_hierarchy()

      sizes = Enum.map(hierarchy, &Scorer.estimate_memory_gb(m, &1, 4096))
      assert sizes == Enum.sort(sizes, :desc)
    end
  end

  describe "analyze_model/3 — fit on GPU" do
    test "a model that fits VRAM at Q4_K_M lands on the GPU at full context" do
      m = model(%{params_b: 7.0, context_length: 8192})
      result = Scorer.analyze_model(m, gpu_system(24.0, 64.0))

      assert result.run_mode == :gpu
      assert result.quant == "Q4_K_M"
      assert result.context == 8192
      assert result.fit_level in [:perfect, :good]
      assert result.speed_tps > 0
    end

    test "nil for a zero-param model (unsizable)" do
      assert Scorer.analyze_model(model(%{params_b: 0.0}), gpu_system(24.0, 64.0)) == nil
    end
  end

  describe "quant-downshift search (GEP-59 core invariant)" do
    test "picks a smaller quant when the larger one does not fit" do
      # 8B at Q4_K_M needs ~5.4 GB at 4096 ctx; cap RAM to 5.0 GB so the
      # search must downshift to Q3_K_M (~4.6 GB).
      m = model(%{params_b: 8.0, context_length: 32_768})
      result = Scorer.analyze_model(m, ram_only_system(5.0), target_context: 4096)

      assert result.run_mode == :cpu_only
      assert result.quant == "Q3_K_M"
      assert result.required_gb <= 5.0
      # And it's genuinely smaller than the default Q4_K_M would have been.
      assert Scorer.estimate_memory_gb(m, "Q4_K_M", 4096) > 5.0
    end

    test "keeps Q4_K_M when it already fits (no needless downshift)" do
      m = model(%{params_b: 8.0, context_length: 32_768})
      result = Scorer.analyze_model(m, ram_only_system(8.0), target_context: 4096)

      assert result.quant == "Q4_K_M"
    end

    test "shrinks context before declaring no-fit when even Q2_K is too big at full ctx" do
      # Big context blows the KV budget; force the context-halving branch.
      m = model(%{params_b: 14.0, context_length: 131_072})
      # Pick a RAM budget that only the smaller-context candidate clears.
      full = Scorer.estimate_memory_gb(m, "Q2_K", 131_072)
      halved = Scorer.estimate_memory_gb(m, "Q4_K_M", 8192)
      ram = (full + halved) / 2

      result = Scorer.analyze_model(m, ram_only_system(ram))

      assert result.fit_level != :too_tight
      assert result.context < 131_072
    end
  end

  describe "no-fit -> :too_tight" do
    test "a 70B model on a tiny box is flagged too_tight, never crashes" do
      m = model(%{name: "Big-70B", params_b: 70.0, context_length: 8192})
      result = Scorer.analyze_model(m, gpu_system(8.0, 8.0))

      assert result.fit_level == :too_tight
      assert result.run_mode == :no_fit
      assert result.score == 0.0
      assert result.speed_tps == 0.0
    end
  end

  describe "bandwidth-blended tok/s" do
    test "known GPU uses VRAM bandwidth (much faster than CPU fallback)" do
      m = model(%{params_b: 7.0, context_length: 8192})
      gpu = Scorer.analyze_model(m, gpu_system(24.0, 64.0, "NVIDIA GeForce RTX 4090"))
      cpu = Scorer.analyze_model(m, ram_only_system(64.0))

      assert gpu.speed_tps > cpu.speed_tps
    end

    test "cpu_offload is slower than fully-on-GPU for the same model" do
      m = model(%{name: "Mid-14B", params_b: 14.0, context_length: 8192})
      on_gpu = Scorer.analyze_model(m, gpu_system(24.0, 96.0))
      # Tight VRAM forces offload; ample RAM lets it still fit.
      offloaded = Scorer.analyze_model(m, gpu_system(6.0, 96.0))

      assert on_gpu.run_mode == :gpu
      assert offloaded.run_mode == :cpu_offload
      assert offloaded.speed_tps < on_gpu.speed_tps
    end
  end

  describe "use-case scoring" do
    test "coding model scores higher for coding than for general use" do
      coder = model(%{name: "Coder-7B", use_case: "coding", params_b: 7.0})
      sys = gpu_system(24.0, 64.0)

      for_coding = Scorer.analyze_model(coder, sys, use_case: "coding")
      for_general = Scorer.analyze_model(coder, sys, use_case: "general")

      assert for_coding.scores.quality > for_general.scores.quality
    end
  end

  describe "rank/2 + recommend/2 against the real catalog" do
    test "24GB GPU recommends a mid/large model that fits perfectly" do
      best = Scorer.recommend(gpu_system(24.0, 64.0), use_case: "general")

      assert best.fit_level in [:perfect, :good]
      assert best.params_b >= 7.0
      assert best.run_mode == :gpu
    end

    test "8GB GPU recommends a smaller model than a 24GB GPU does" do
      small = Scorer.recommend(gpu_system(8.0, 32.0), use_case: "general")
      large = Scorer.recommend(gpu_system(24.0, 64.0), use_case: "general")

      assert small.params_b <= large.params_b
      assert small.fit_level in [:perfect, :good]
    end

    test "recommend/2 never returns a too_tight row (fit_only default)" do
      # 4 GB RAM, no GPU — only the very smallest models can fit.
      best = Scorer.recommend(ram_only_system(4.0))

      if best do
        assert best.fit_level != :too_tight
      end
    end

    test "rank/2 is sorted best-score first" do
      ranked = Scorer.rank(gpu_system(24.0, 64.0), use_case: "general")
      scores = Enum.map(ranked, & &1.score)
      assert scores == Enum.sort(scores, :desc)
    end

    test "fit_only: true drops too_tight rows" do
      sys = gpu_system(8.0, 8.0)
      all = Scorer.rank(sys)
      fit = Scorer.rank(sys, fit_only: true)

      assert Enum.any?(all, &(&1.fit_level == :too_tight))
      refute Enum.any?(fit, &(&1.fit_level == :too_tight))
    end
  end
end
