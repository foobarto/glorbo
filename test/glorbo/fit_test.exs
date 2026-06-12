defmodule Glorbo.FitTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the `Glorbo.Fit` facade (GEP-59): probe → rank →
  recommendation, plus AGENT.md line generation and CLI rendering. The
  probe is bypassed via the `:system` opt so these stay pure.
  """

  alias Glorbo.Fit

  defp gpu_system(vram, ram) do
    %{
      has_gpu: true,
      gpu_name: "NVIDIA GeForce RTX 4090",
      gpu_vram_gb: vram,
      gpu_count: 1,
      total_ram_gb: ram,
      available_ram_gb: ram,
      backend: "cuda",
      probe_errors: []
    }
  end

  defp tiny_system do
    # 0.8 GB available — below even the smallest catalog model at Q2_K.
    %{
      has_gpu: false,
      gpu_name: nil,
      gpu_vram_gb: 0,
      gpu_count: 0,
      total_ram_gb: 0.8,
      available_ram_gb: 0.8,
      backend: "cpu_x86",
      probe_errors: [:no_gpu_detected]
    }
  end

  describe "recommend/1" do
    test "with a pre-probed system, returns a best fit + ranked list" do
      rec = Fit.recommend(system: gpu_system(24.0, 64.0), use_case: "general")

      assert rec.best
      assert rec.best.fit_level != :too_tight
      assert rec.use_case == "general"
      assert is_list(rec.ranked)
      assert rec.ranked != []
    end

    test "best is nil when nothing fits the budget" do
      rec = Fit.recommend(system: tiny_system())
      assert rec.best == nil
    end

    test "uses the catalog override for deterministic ranking" do
      one_model = [
        %{
          name: "Only-7B",
          provider: "acme",
          params_b: 7.0,
          context_length: 8192,
          use_case: "general",
          family: "qwen",
          recommended_ram_gb: 10.0
        }
      ]

      rec = Fit.recommend(system: gpu_system(24.0, 64.0), catalog: one_model)

      assert rec.best.name == "Only-7B"
      assert length(rec.ranked) == 1
    end
  end

  describe "agent_md_lines/1" do
    test "produces model: + provider: lines for a recommendation" do
      rec = Fit.recommend(system: gpu_system(24.0, 64.0))
      lines = Fit.agent_md_lines(rec.best)

      assert lines =~ "model:"
      assert lines =~ "provider: ollama"
    end

    test "empty string when nothing fits" do
      assert Fit.agent_md_lines(nil) == ""
    end
  end

  describe "render/2" do
    test "human output names the recommended model + AGENT.md lines" do
      rec = Fit.recommend(system: gpu_system(24.0, 64.0))
      out = Fit.render(rec)

      assert out =~ "glorbo fit"
      assert out =~ "Recommendation:"
      assert out =~ rec.best.name
      assert out =~ "AGENT.md:"
      assert out =~ "provider: ollama"
      assert out =~ "Ranked"
    end

    test "RAM-only host says so in the header" do
      rec = Fit.recommend(system: tiny_system())
      out = Fit.render(rec)

      assert out =~ "no GPU detected"
      assert out =~ "RAM-only"
    end

    test "degraded probe surfaces a note" do
      sys = %{gpu_system(24.0, 64.0) | probe_errors: [{:meminfo_read, :enoent}]}
      out = Fit.render(Fit.recommend(system: sys))

      assert out =~ "degraded probe"
    end
  end

  describe "render_json/1" do
    test "is valid JSON carrying system + recommendation + ranked" do
      rec = Fit.recommend(system: gpu_system(24.0, 64.0))
      json = Fit.render_json(rec)

      decoded = Jason.decode!(json)
      assert decoded["use_case"] == "general"
      assert decoded["system"]["backend"] == "cuda"
      assert decoded["recommendation"]["name"] == rec.best.name
      assert is_list(decoded["ranked"])
      assert decoded["agent_md"] =~ "provider: ollama"
    end

    test "recommendation is null when nothing fits" do
      json = Fit.render_json(Fit.recommend(system: tiny_system()))
      assert Jason.decode!(json)["recommendation"] == nil
    end
  end
end
