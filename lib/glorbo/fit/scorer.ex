defmodule Glorbo.Fit.Scorer do
  @moduledoc """
  Pure-Elixir fit scoring (GEP-59 D1 / D5). No I/O, no NIF — all
  arithmetic + heuristics, ported from odysseus `services/hwfit/fit.py`
  into a glorbo-maintained module so the single Burrito binary stays
  dependency-free across all four cross-build targets (GEP-53 D13
  precedent).

  Given a `system` map (from `Glorbo.Fit.Probe`) and a catalog model,
  `analyze_model/3`:

    1. estimates memory needed per quant × context,
    2. searches the quant ladder (Q8_0 → Q2_K), then shrinks context,
       until a candidate fits the GPU VRAM (or system RAM),
    3. blends GPU/system-RAM bandwidth into a tok/s estimate,
    4. scores quality / speed / fit / context for the use case, and
    5. returns a composite-weighted result.

  `rank/2` runs every catalog model and returns them sorted best-first.

  ## System map

      %{
        has_gpu: boolean(),
        gpu_name: String.t() | nil,
        gpu_vram_gb: number(),         # 0 when no GPU
        available_ram_gb: number(),
        backend: String.t()            # "cuda" | "rocm" | "metal" | "cpu_x86" | "cpu_arm"
      }

  A probe failure degrades to a RAM-only system map (`has_gpu: false`,
  `gpu_vram_gb: 0`) — scoring still works, just without the GPU
  bandwidth path.
  """

  alias Glorbo.Fit.Catalog

  @type system :: %{
          optional(:has_gpu) => boolean(),
          optional(:gpu_name) => String.t() | nil,
          optional(:gpu_vram_gb) => number(),
          optional(:available_ram_gb) => number(),
          optional(:backend) => String.t()
        }

  @type result :: %{
          name: String.t(),
          provider: String.t(),
          params_b: float(),
          use_case: String.t(),
          fit_level: :perfect | :good | :marginal | :too_tight,
          run_mode: :gpu | :cpu_offload | :cpu_only | :no_fit,
          quant: String.t(),
          context: non_neg_integer(),
          required_gb: float(),
          speed_tps: float(),
          score: float(),
          scores: %{quality: float(), speed: float(), fit: float(), context: float()}
        }

  # (quality, speed, fit, context) composite weights per use case.
  # Ported from odysseus fit.USE_CASE_WEIGHTS.
  @use_case_weights %{
    "general" => {0.45, 0.30, 0.15, 0.10},
    "coding" => {0.50, 0.20, 0.15, 0.15},
    "reasoning" => {0.55, 0.15, 0.15, 0.15},
    "chat" => {0.40, 0.35, 0.15, 0.10}
  }

  @speed_target %{
    "general" => 40,
    "coding" => 40,
    "chat" => 40,
    "reasoning" => 25
  }

  @context_target %{
    "general" => 4096,
    "chat" => 4096,
    "coding" => 8192,
    "reasoning" => 8192
  }

  # Floor for the context-shrink loop. Below this a model isn't useful.
  @min_context 1024

  # GPU memory-bandwidth efficiency factor (real-world tok/s lands well
  # under the theoretical bw/model_gb ceiling). Ported from odysseus.
  @gpu_efficiency 0.55

  @doc """
  Rank every catalog model against `system`. Options:

    * `:use_case` — score for this use case (default `"general"`).
    * `:target_context` — cap the evaluated context (default: each
      model's full context length).
    * `:catalog` — override the model list (tests).
    * `:fit_only` — drop `:too_tight` rows (default `false`).

  Returns results sorted by composite score, best first.
  """
  @spec rank(system(), keyword()) :: [result()]
  def rank(system, opts \\ []) do
    use_case = Keyword.get(opts, :use_case, "general")
    target_context = Keyword.get(opts, :target_context)
    catalog = Keyword.get(opts, :catalog, Catalog.models())
    fit_only? = Keyword.get(opts, :fit_only, false)

    catalog
    |> Enum.map(&analyze_model(&1, system, use_case: use_case, target_context: target_context))
    |> Enum.reject(&is_nil/1)
    |> maybe_drop_too_tight(fit_only?)
    |> Enum.sort_by(&{&1.score, &1.params_b}, :desc)
  end

  @doc """
  The single best-fitting model for `system` + opts, or `nil` when the
  catalog is empty. `:fit_only` defaults to `true` here — the
  recommendation should be something that actually runs.
  """
  @spec recommend(system(), keyword()) :: result() | nil
  def recommend(system, opts \\ []) do
    opts = Keyword.put_new(opts, :fit_only, true)

    case rank(system, opts) do
      [best | _] -> best
      [] -> nil
    end
  end

  @doc """
  Score one catalog model against `system`. Returns a `result()` map, or
  `nil` if the model can't be sized at all (params <= 0).

  Options: `:use_case`, `:target_context` (see `rank/2`).
  """
  @spec analyze_model(Catalog.model(), system(), keyword()) :: result() | nil
  def analyze_model(model, system, opts \\ []) do
    use_case = Keyword.get(opts, :use_case, "general")
    target_context = Keyword.get(opts, :target_context)

    pb = model.params_b

    if pb <= 0 do
      nil
    else
      do_analyze(model, system, use_case, target_context)
    end
  end

  # ------------------------------------------------------------------
  # Memory estimation
  # ------------------------------------------------------------------

  @doc """
  Estimated memory (GB) to serve `model` at `quant` and `ctx` tokens.

  Weights + KV-cache + a fixed runtime overhead. Ported from odysseus
  models.estimate_memory_gb: `pb*bpp + 8e-6*pb*ctx + 0.5`.
  """
  @spec estimate_memory_gb(Catalog.model(), Catalog.quant(), non_neg_integer()) :: float()
  def estimate_memory_gb(model, quant, ctx) do
    pb = model.params_b
    bpp = Catalog.bytes_per_param(quant)
    pb * bpp + 0.000008 * pb * ctx + 0.5
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp do_analyze(model, system, use_case, target_context) do
    gpu_vram = gpu_vram(system)
    available_ram = num(Map.get(system, :available_ram_gb, 0))
    model_ctx = model.context_length
    ctx = clamp_context(model_ctx, target_context)

    quant = "Q4_K_M"

    budget = %{gpu_vram: gpu_vram, available_ram: available_ram}

    case try_quant_at(model, quant, ctx, gpu_vram, available_ram) do
      nil -> too_tight_result(model, quant, ctx)
      candidate -> build_result(model, system, use_case, candidate, budget)
    end
  end

  # Quant-downshift search: try the requested quant at full context, then
  # walk DOWN the quant ladder, then halve context and retry the ladder,
  # until something fits the VRAM (or RAM) budget. Returns
  # `{run_mode, quant, ctx, mem}` or `nil`.
  @doc false
  @spec try_quant_at(Catalog.model(), Catalog.quant(), non_neg_integer(), number(), number()) ::
          {atom(), Catalog.quant(), non_neg_integer(), float()} | nil
  def try_quant_at(model, start_quant, ctx, gpu_vram, available_ram) do
    quants = downshift_ladder(start_quant)

    Enum.reduce_while(context_steps(ctx), nil, fn cur_ctx, _acc ->
      case first_fitting_quant(model, quants, cur_ctx, gpu_vram, available_ram) do
        nil -> {:cont, nil}
        hit -> {:halt, hit}
      end
    end)
  end

  # The quant ladder to try, starting at `start_quant` (if it's in the
  # hierarchy) and descending. Unknown start labels fall back to the full
  # hierarchy so we still produce a candidate.
  defp downshift_ladder(start_quant) do
    hierarchy = Catalog.quant_hierarchy()

    case Enum.split_while(hierarchy, &(&1 != start_quant)) do
      {_before, []} -> hierarchy
      {_before, from_start} -> from_start
    end
  end

  # Context steps: full context, then repeated halving down to the floor.
  defp context_steps(ctx) do
    Stream.iterate(ctx, &div(&1, 2))
    |> Stream.take_while(&(&1 >= @min_context))
    |> Enum.to_list()
    |> dedup_first(ctx)
  end

  # Ensure the first (full) context is present even when ctx < floor*2.
  defp dedup_first([], ctx), do: [ctx]
  defp dedup_first(list, _ctx), do: list

  defp first_fitting_quant(model, quants, ctx, gpu_vram, available_ram) do
    Enum.find_value(quants, fn quant ->
      mem = estimate_memory_gb(model, quant, ctx)

      cond do
        gpu_vram > 0 and mem <= gpu_vram -> {:gpu, quant, ctx, mem}
        gpu_vram > 0 and mem <= available_ram -> {:cpu_offload, quant, ctx, mem}
        gpu_vram <= 0 and mem <= available_ram -> {:cpu_only, quant, ctx, mem}
        true -> nil
      end
    end)
  end

  defp build_result(
         model,
         system,
         use_case,
         {run_mode, quant, fit_ctx, required_gb},
         %{gpu_vram: gpu_vram, available_ram: available_ram}
       ) do
    fit_budget = if run_mode == :gpu, do: gpu_vram, else: available_ram
    fit_level = fit_level(model, run_mode, required_gb, gpu_vram, available_ram)

    offload_frac = offload_frac(run_mode, required_gb, gpu_vram)
    tps = estimate_speed(model, quant, run_mode, system, offload_frac)

    q = quality_score(model, quant, use_case)
    s = speed_score(tps, use_case)
    f = fit_score(required_gb, fit_budget)
    c = context_score(fit_ctx, use_case)

    {wq, ws, wf, wc} = Map.get(@use_case_weights, use_case, {0.45, 0.30, 0.15, 0.10})
    composite = q * wq + s * ws + f * wf + c * wc

    %{
      name: model.name,
      provider: model.provider,
      params_b: model.params_b,
      use_case: model.use_case,
      fit_level: fit_level,
      run_mode: run_mode,
      quant: quant,
      context: fit_ctx,
      required_gb: round1(required_gb),
      speed_tps: round1(tps),
      score: round1(composite),
      scores: %{
        quality: round1(q),
        speed: round1(s),
        fit: round1(f),
        context: round1(c)
      }
    }
  end

  defp too_tight_result(model, quant, ctx) do
    %{
      name: model.name,
      provider: model.provider,
      params_b: model.params_b,
      use_case: model.use_case,
      fit_level: :too_tight,
      run_mode: :no_fit,
      quant: quant,
      context: ctx,
      required_gb: round1(estimate_memory_gb(model, quant, ctx)),
      speed_tps: 0.0,
      score: 0.0,
      scores: %{quality: 0.0, speed: 0.0, fit: 0.0, context: 0.0}
    }
  end

  # ------------------------------------------------------------------
  # Speed model (bandwidth-blended tok/s)
  # ------------------------------------------------------------------

  # Ported from odysseus fit._estimate_speed. On a known GPU we use the
  # measured VRAM bandwidth; for cpu_offload we harmonic-blend GPU + CPU
  # bandwidth by the offloaded fraction. With no known GPU bandwidth we
  # fall back to the backend k-constant / params.
  defp estimate_speed(model, quant, run_mode, system, offload_frac) do
    pb = model.params_b
    bw = Catalog.bandwidth_for(Map.get(system, :gpu_name))
    backend = Map.get(system, :backend, "cpu_x86")

    cond do
      pb <= 0 ->
        0.0

      bw && run_mode in [:gpu, :cpu_offload] ->
        gpu_blended_speed(pb, quant, run_mode, bw, offload_frac)

      true ->
        k = Catalog.fallback_k(backend)
        k / pb * Catalog.speed_mult(quant)
    end
  end

  defp gpu_blended_speed(pb, quant, run_mode, bw, offload_frac) do
    bpp = Catalog.bytes_per_param(quant)
    model_gb = pb * bpp

    if model_gb <= 0 do
      0.0
    else
      eff_bw =
        case run_mode do
          :cpu_offload ->
            frac = clampf(offload_frac, 0.0, 1.0)
            frac = if frac <= 0.0, do: 0.5, else: frac
            cpu_bw = Catalog.cpu_bandwidth()
            1.0 / (frac / cpu_bw + (1.0 - frac) / bw)

          _ ->
            bw
        end

      eff_bw / model_gb * @gpu_efficiency
    end
  end

  defp offload_frac(:cpu_offload, required_gb, gpu_vram)
       when required_gb > 0 and gpu_vram > 0 do
    max(0.0, (required_gb - gpu_vram) / required_gb)
  end

  defp offload_frac(_run_mode, _required_gb, _gpu_vram), do: 0.0

  # ------------------------------------------------------------------
  # Per-axis scores (ported from odysseus fit._*_score)
  # ------------------------------------------------------------------

  defp quality_score(model, quant, use_case) do
    pb = model.params_b

    base =
      cond do
        pb < 1 -> 30
        pb < 3 -> 45
        pb < 7 -> 60
        pb < 10 -> 75
        pb < 20 -> 82
        pb < 40 -> 89
        true -> 95
      end

    base = base + family_bonus(model.family)
    base = base + Catalog.quality_penalty(quant)
    base = base + use_case_affinity(model.use_case, use_case, pb)

    base |> max(0) |> min(100) |> to_f()
  end

  defp family_bonus("qwen"), do: 2
  defp family_bonus("deepseek"), do: 3
  defp family_bonus("llama"), do: 2
  defp family_bonus("mistral"), do: 1
  defp family_bonus("gemma"), do: 1
  defp family_bonus(_), do: 0

  # A coding-specialised model gets a boost when the user wants coding,
  # but a penalty when scored for general/chat (so it doesn't dominate
  # the default scan). Ported from odysseus fit._quality_score.
  defp use_case_affinity("coding", "coding", _pb), do: 6
  defp use_case_affinity("coding", uc, _pb) when uc in ["general", "chat"], do: -10
  defp use_case_affinity("reasoning", "reasoning", pb) when pb >= 13, do: 5
  defp use_case_affinity("reasoning", "chat", _pb), do: -4
  defp use_case_affinity(_model_uc, _score_uc, _pb), do: 0

  defp speed_score(tps, use_case) do
    target = Map.get(@speed_target, use_case, 40)
    (tps / target * 100) |> max(0) |> min(100) |> to_f()
  end

  defp fit_score(required, available) do
    cond do
      required > available -> 0.0
      available <= 0 -> 0.0
      true -> fit_ratio_score(required / available)
    end
  end

  defp fit_ratio_score(ratio) when ratio <= 0.5, do: 60 + ratio / 0.5 * 40
  defp fit_ratio_score(ratio) when ratio <= 0.8, do: 100.0
  defp fit_ratio_score(ratio) when ratio <= 0.9, do: 70.0
  defp fit_ratio_score(_ratio), do: 50.0

  defp context_score(ctx, use_case) do
    target = Map.get(@context_target, use_case, 4096)

    cond do
      ctx >= target -> 100.0
      ctx >= target / 2 -> 70.0
      true -> 30.0
    end
  end

  # ------------------------------------------------------------------
  # Fit-level classification (ported from odysseus analyze_model)
  # ------------------------------------------------------------------

  defp fit_level(model, :gpu, required_gb, gpu_vram, _available_ram) do
    rec = model.recommended_ram_gb || required_gb

    cond do
      rec <= gpu_vram -> :perfect
      gpu_vram >= required_gb * 1.2 -> :good
      true -> :marginal
    end
  end

  defp fit_level(_model, :cpu_offload, required_gb, _gpu_vram, available_ram) do
    if available_ram >= required_gb * 1.2, do: :good, else: :marginal
  end

  defp fit_level(_model, :cpu_only, required_gb, _gpu_vram, available_ram) do
    if available_ram >= required_gb * 1.2, do: :good, else: :marginal
  end

  # ------------------------------------------------------------------
  # Small helpers
  # ------------------------------------------------------------------

  defp gpu_vram(system) do
    if Map.get(system, :has_gpu, false), do: num(Map.get(system, :gpu_vram_gb, 0)), else: 0
  end

  defp clamp_context(model_ctx, nil), do: model_ctx

  defp clamp_context(model_ctx, target) when is_integer(target) and target > 0,
    do: min(model_ctx, target)

  defp clamp_context(model_ctx, _), do: model_ctx

  defp maybe_drop_too_tight(results, true),
    do: Enum.reject(results, &(&1.fit_level == :too_tight))

  defp maybe_drop_too_tight(results, false), do: results

  defp num(n) when is_number(n), do: n
  defp num(_), do: 0

  defp clampf(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp to_f(n) when is_integer(n), do: n * 1.0
  defp to_f(n), do: n

  defp round1(n) when is_number(n), do: Float.round(n * 1.0, 1)
end
