defmodule Glorbo.Fit.Catalog do
  @moduledoc """
  Static, compiled-in model + quantization catalog for `Glorbo.Fit`
  (GEP-59 D4 / D1).

  Everything here is in-binary data — no disk reads, no network, no
  online refresh — so `glorbo fit` works on a fresh install with the
  machine offline (GEP-11 "boring/local first"). The quant byte/speed/
  quality tables and the GPU/Apple-Silicon bandwidth table are ported
  from odysseus's `services/hwfit` heuristics (GEP-59 D5), re-derived to
  a *smaller glorbo-maintained set* rather than vendoring the full 900+
  entry HF dump (Open-question resolution: re-derive, don't vendor).

  The catalog is a curated set of well-known, GGUF-servable models that
  span the size ladder (1.5B → 70B) so `glorbo fit` always has a real
  recommendation regardless of the host's VRAM/RAM budget.

  ## Shapes

    * `model()` — one catalog entry.
    * `quant()` — a GGUF quant-tier label (`"Q4_K_M"`, `"Q8_0"`, …).

  Quant maps are keyed by label; `bytes_per_param/1`, `speed_mult/1`,
  and `quality_penalty/1` total-fall-back to sane defaults so an
  unknown label never crashes the scorer.
  """

  @type quant :: String.t()

  @type model :: %{
          name: String.t(),
          provider: String.t(),
          params_b: float(),
          context_length: pos_integer(),
          use_case: String.t(),
          family: String.t(),
          recommended_ram_gb: float()
        }

  # GGUF quant ladder, highest quality first. The downshift search walks
  # this top-to-bottom (Q8_0 → Q2_K) trying each at the requested
  # context before shrinking context. Ported from odysseus
  # models.QUANT_HIERARCHY.
  @quant_hierarchy ["Q8_0", "Q6_K", "Q5_K_M", "Q4_K_M", "Q3_K_M", "Q2_K"]

  # Bytes-per-param used for the VRAM/RAM estimate. Ported from odysseus
  # models.QUANT_BPP (GGUF tiers only — glorbo's fit path is GGUF /
  # llama.cpp-servable, consistent with GEP-8 detect-providers).
  @quant_bpp %{
    "F16" => 2.0,
    "BF16" => 2.0,
    "Q8_0" => 1.05,
    "Q6_K" => 0.80,
    "Q5_K_M" => 0.68,
    "Q4_K_M" => 0.58,
    "Q4_0" => 0.58,
    "Q3_K_M" => 0.48,
    "Q2_K" => 0.37
  }

  # Per-quant tok/s multiplier for the CPU/backend fallback speed model.
  # Ported from odysseus models.QUANT_SPEED_MULT.
  @quant_speed_mult %{
    "F16" => 0.6,
    "BF16" => 0.6,
    "Q8_0" => 0.8,
    "Q6_K" => 0.95,
    "Q5_K_M" => 1.0,
    "Q4_K_M" => 1.15,
    "Q4_0" => 1.15,
    "Q3_K_M" => 1.25,
    "Q2_K" => 1.35
  }

  # Per-quant additive quality penalty (lower quant → bigger penalty).
  # Ported from odysseus models.QUANT_QUALITY_PENALTY.
  @quant_quality_penalty %{
    "F16" => 0.0,
    "BF16" => 0.0,
    "Q8_0" => 0.0,
    "Q6_K" => -1.0,
    "Q5_K_M" => -2.0,
    "Q4_K_M" => -5.0,
    "Q4_0" => -5.0,
    "Q3_K_M" => -8.0,
    "Q2_K" => -12.0
  }

  # The actual VRAM-bandwidth (GB/s) used to estimate GPU/Metal tok/s.
  # A glorbo-maintained subset of odysseus fit.GPU_BANDWIDTH covering the
  # common consumer NVIDIA / AMD cards + the Apple Silicon unified-memory
  # tiers. Keys are matched as case-insensitive substrings of the probed
  # GPU name, longest key first (so "m4 max" beats "m4").
  @gpu_bandwidth %{
    # NVIDIA RTX 50/40/30 consumer
    "5090" => 1792,
    "5080" => 960,
    "5070 ti" => 896,
    "5070" => 672,
    "4090" => 1008,
    "4080" => 717,
    "4070 ti" => 504,
    "4070" => 504,
    "4060 ti" => 288,
    "4060" => 272,
    "3090" => 936,
    "3080" => 760,
    "3070" => 448,
    "3060" => 360,
    # NVIDIA datacenter
    "h100" => 2039,
    "h200" => 4800,
    "a100" => 1555,
    "l40s" => 864,
    "l4" => 300,
    "a10" => 600,
    "t4" => 320,
    "a6000" => 768,
    # AMD Radeon RX 7000/9000
    "7900 xtx" => 960,
    "7900 xt" => 800,
    "7800 xt" => 624,
    "7700 xt" => 432,
    "7600" => 288,
    "9070 xt" => 624,
    "9070" => 488,
    "9060 xt" => 322,
    "9060" => 322,
    # AMD Instinct
    "mi300x" => 5300,
    "mi300" => 5300,
    "mi250" => 3277,
    "mi210" => 1638,
    # Apple Silicon unified memory
    "m1 ultra" => 800,
    "m1 max" => 400,
    "m1 pro" => 200,
    "m1" => 68,
    "m2 ultra" => 800,
    "m2 max" => 400,
    "m2 pro" => 200,
    "m2" => 100,
    "m3 ultra" => 800,
    "m3 max" => 300,
    "m3 pro" => 150,
    "m3" => 100,
    "m4 max" => 546,
    "m4 pro" => 273,
    "m4" => 120
  }

  # Backstop bandwidth (GB/s-equivalent k constant) per backend for the
  # CPU/no-known-GPU speed path. Ported from odysseus fit.FALLBACK_K.
  @fallback_k %{
    "cuda" => 220,
    "rocm" => 180,
    "metal" => 150,
    "cpu_x86" => 70,
    "cpu_arm" => 90
  }

  # System-RAM bandwidth assumption for the offload blend (GB/s). Ported
  # from odysseus fit._estimate_speed cpu_bw.
  @cpu_bandwidth 55.0

  # Curated, GGUF-servable model catalog spanning the size ladder. Each
  # entry is a real, widely-mirrored model; `params_b` and
  # `context_length` track the upstream HF cards. `recommended_ram_gb`
  # feeds the perfect/good/marginal fit-level split.
  @catalog [
    %{
      name: "Qwen2.5-Coder-1.5B-Instruct",
      provider: "Qwen",
      params_b: 1.5,
      context_length: 32_768,
      use_case: "coding",
      family: "qwen",
      recommended_ram_gb: 4.0
    },
    %{
      name: "Llama-3.2-3B-Instruct",
      provider: "meta",
      params_b: 3.2,
      context_length: 131_072,
      use_case: "general",
      family: "llama",
      recommended_ram_gb: 6.0
    },
    %{
      name: "Phi-3.5-mini-instruct",
      provider: "microsoft",
      params_b: 3.8,
      context_length: 131_072,
      use_case: "general",
      family: "phi",
      recommended_ram_gb: 8.0
    },
    %{
      name: "Qwen2.5-Coder-7B-Instruct",
      provider: "Qwen",
      params_b: 7.6,
      context_length: 32_768,
      use_case: "coding",
      family: "qwen",
      recommended_ram_gb: 10.0
    },
    %{
      name: "Mistral-7B-Instruct-v0.3",
      provider: "mistralai",
      params_b: 7.2,
      context_length: 32_768,
      use_case: "chat",
      family: "mistral",
      recommended_ram_gb: 10.0
    },
    %{
      name: "Meta-Llama-3.1-8B-Instruct",
      provider: "meta",
      params_b: 8.0,
      context_length: 131_072,
      use_case: "general",
      family: "llama",
      recommended_ram_gb: 12.0
    },
    %{
      name: "gemma-2-9b-it",
      provider: "google",
      params_b: 9.2,
      context_length: 8_192,
      use_case: "general",
      family: "gemma",
      recommended_ram_gb: 14.0
    },
    %{
      name: "Qwen2.5-14B-Instruct",
      provider: "Qwen",
      params_b: 14.7,
      context_length: 32_768,
      use_case: "general",
      family: "qwen",
      recommended_ram_gb: 20.0
    },
    %{
      name: "Qwen2.5-Coder-32B-Instruct",
      provider: "Qwen",
      params_b: 32.5,
      context_length: 32_768,
      use_case: "coding",
      family: "qwen",
      recommended_ram_gb: 40.0
    },
    %{
      name: "Qwen2.5-32B-Instruct",
      provider: "Qwen",
      params_b: 32.5,
      context_length: 32_768,
      use_case: "general",
      family: "qwen",
      recommended_ram_gb: 40.0
    },
    %{
      name: "Llama-3.3-70B-Instruct",
      provider: "meta",
      params_b: 70.6,
      context_length: 131_072,
      use_case: "general",
      family: "llama",
      recommended_ram_gb: 80.0
    }
  ]

  @doc "The curated static model catalog."
  @spec models() :: [model()]
  def models, do: @catalog

  @doc "The GGUF quant ladder, highest quality first."
  @spec quant_hierarchy() :: [quant()]
  def quant_hierarchy, do: @quant_hierarchy

  @doc """
  Bytes-per-param for `quant`. Falls back to the Q4_K_M value (0.58)
  for unknown labels so the estimate never crashes on a typo.
  """
  @spec bytes_per_param(quant()) :: float()
  def bytes_per_param(quant), do: Map.get(@quant_bpp, quant, 0.58)

  @doc "Tok/s multiplier for `quant` (CPU/backend fallback path). Default 1.0."
  @spec speed_mult(quant()) :: float()
  def speed_mult(quant), do: Map.get(@quant_speed_mult, quant, 1.0)

  @doc "Additive quality penalty for `quant`. Default 0.0."
  @spec quality_penalty(quant()) :: float()
  def quality_penalty(quant), do: Map.get(@quant_quality_penalty, quant, 0.0)

  @doc "Backend fallback k-constant (GB/s-equivalent). Default 70 (cpu_x86)."
  @spec fallback_k(String.t()) :: number()
  def fallback_k(backend), do: Map.get(@fallback_k, backend, 70)

  @doc "Assumed system-RAM bandwidth (GB/s) for the offload blend."
  @spec cpu_bandwidth() :: float()
  def cpu_bandwidth, do: @cpu_bandwidth

  @doc """
  Look up VRAM bandwidth (GB/s) for a probed GPU name via case-
  insensitive longest-substring match. Returns `nil` when no key
  matches — the scorer then takes the backend-fallback speed path.
  """
  @spec bandwidth_for(String.t() | nil) :: number() | nil
  def bandwidth_for(gpu_name) when is_binary(gpu_name) and gpu_name != "" do
    gn = String.downcase(gpu_name)

    Enum.find_value(bandwidth_keys_by_length(), fn key ->
      if String.contains?(gn, key), do: Map.fetch!(@gpu_bandwidth, key), else: nil
    end)
  end

  def bandwidth_for(_), do: nil

  # Longest key first so "m4 max" is tried before "m4", "7900 xtx"
  # before "7900 xt". Computed at compile time.
  @bandwidth_keys_by_length @gpu_bandwidth
                            |> Map.keys()
                            |> Enum.sort_by(&String.length/1, :desc)

  defp bandwidth_keys_by_length, do: @bandwidth_keys_by_length
end
