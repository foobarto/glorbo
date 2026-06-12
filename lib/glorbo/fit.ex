defmodule Glorbo.Fit do
  @moduledoc """
  Native hardware → model-fit scoring (GEP-59 v1).

  Closes glorbo's "fully local out of the box" gap: `detect-providers`
  (GEP-8) only wires an *already-running* local server; `glorbo fit`
  tells you which model to actually run. It probes the host hardware,
  scores the curated catalog against it, and recommends the
  highest-quality model that fits the VRAM/RAM budget at a usable
  tok/s — plus the `model:` / `provider:` lines to drop into an
  `AGENT.md`.

  This is the **scorer + recommend** path (GEP-59 D3). The `--serve`
  download/serve path is deferred.

  ## Composition

    * `Glorbo.Fit.Probe`   — host probe (RAM + GPU), degrades to RAM-only.
    * `Glorbo.Fit.Scorer`  — pure scoring + quant-downshift search.
    * `Glorbo.Fit.Catalog` — static in-binary model + quant tables.

  `recommend/1` is the top-level entry: probe → rank → recommendation.
  All external I/O is in `Probe`, injectable for tests.
  """

  alias Glorbo.Fit.Probe
  alias Glorbo.Fit.Scorer

  @type recommendation :: %{
          system: Probe.system(),
          best: Scorer.result() | nil,
          ranked: [Scorer.result()],
          use_case: String.t()
        }

  @doc """
  Probe the host, rank the catalog, and return the recommendation.

  Options:
    * `:use_case` — `"general"` (default) | `"coding"` | `"chat"` | `"reasoning"`.
    * `:target_context` — cap the evaluated context window.
    * `:host` — score a remote host's hardware (`--host`, probed over SSH).
    * `:system` — pre-probed system map (skip the probe; tests + caching).
    * `:catalog` — override the model list (tests).
    * any `Glorbo.Fit.Probe.run/1` seam (`:cmd_fun`, `:meminfo_read_fun`, …).
  """
  @spec recommend(keyword()) :: recommendation()
  def recommend(opts \\ []) do
    use_case = Keyword.get(opts, :use_case, "general")

    system =
      case Keyword.get(opts, :system) do
        %{} = s -> s
        _ -> Probe.run(probe_opts(opts))
      end

    rank_opts =
      opts
      |> Keyword.take([:target_context, :catalog])
      |> Keyword.put(:use_case, use_case)

    ranked = Scorer.rank(system, rank_opts)
    best = Enum.find(ranked, &(&1.fit_level != :too_tight))

    %{system: system, best: best, ranked: ranked, use_case: use_case}
  end

  @doc """
  The `model:` / `provider:` lines to paste into an `AGENT.md` for the
  recommended model. Returns `""` when nothing fits.

  The provider line points at `ollama` — the GGUF-servable local
  provider `glorbo detect-providers` probes for (GEP-8) — so the two
  commands compose: run `glorbo fit`, serve the model, then
  `glorbo detect-providers`.
  """
  @spec agent_md_lines(Scorer.result() | nil) :: String.t()
  def agent_md_lines(nil), do: ""

  def agent_md_lines(%{name: name}) do
    "model: #{model_id(name)}\nprovider: ollama"
  end

  @doc """
  Human-readable CLI rendering of a recommendation. Used by
  `glorbo fit`.
  """
  @spec render(recommendation(), keyword()) :: String.t()
  def render(%{system: system, best: best, ranked: ranked, use_case: use_case}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)

    header = render_header(system, use_case)
    rec = render_recommendation(best)
    table = render_table(ranked, limit)

    Enum.join([header, rec, table], "\n")
  end

  @doc """
  JSON rendering for `--json`. One object with the system, the
  recommendation, and the ranked list.
  """
  @spec render_json(recommendation()) :: String.t()
  def render_json(%{system: system, best: best, ranked: ranked, use_case: use_case}) do
    %{
      "use_case" => use_case,
      "system" => json_system(system),
      "recommendation" => json_result(best),
      "agent_md" => agent_md_lines(best),
      "ranked" => Enum.map(ranked, &json_result/1)
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  # ------------------------------------------------------------------
  # Rendering internals
  # ------------------------------------------------------------------

  defp render_header(system, use_case) do
    gpu =
      if system.has_gpu do
        "#{system.gpu_name} · #{fmt_gb(system.gpu_vram_gb)} VRAM" <>
          gpu_count_suffix(system.gpu_count)
      else
        "no GPU detected — RAM-only scoring (#{system.backend})"
      end

    errs =
      case system.probe_errors do
        [] -> ""
        list -> "\n  note: degraded probe (#{Enum.map_join(list, ", ", &inspect/1)})"
      end

    """
    glorbo fit — hardware → model recommendation (use case: #{use_case})

    Host:
      RAM: #{fmt_gb(system.total_ram_gb)} total · #{fmt_gb(system.available_ram_gb)} available
      GPU: #{gpu}#{errs}
    """
    |> String.trim_trailing()
  end

  defp gpu_count_suffix(count) when is_integer(count) and count > 1, do: " (#{count} GPUs)"
  defp gpu_count_suffix(_), do: ""

  defp render_recommendation(nil) do
    """

    Recommendation:
      Nothing in the catalog fits this host's budget. Free up RAM/VRAM,
      or lower --target-context.
    """
    |> String.trim_trailing()
  end

  defp render_recommendation(best) do
    agent_md =
      best
      |> agent_md_lines()
      |> String.split("\n")
      |> Enum.map_join("\n", &("        " <> &1))

    """

    Recommendation:
      #{best.provider}/#{best.name}
        quant: #{best.quant} · context: #{best.context} · ~#{fmt_tps(best.speed_tps)} tok/s
        needs #{fmt_gb(best.required_gb)} · run mode: #{best.run_mode} · fit: #{best.fit_level}

      AGENT.md:
    #{agent_md}
    """
    |> String.trim_trailing()
  end

  defp render_table([], _limit), do: ""

  defp render_table(ranked, limit) do
    rows =
      ranked
      |> Enum.take(limit)
      |> Enum.map_join("\n", fn r ->
        "  #{pad(r.name, 32)} #{pad(r.quant, 8)} " <>
          "score #{pad(fmt1(r.score), 6)} ~#{pad(fmt_tps(r.speed_tps), 7)} t/s " <>
          "#{pad(fmt_gb(r.required_gb), 9)} #{r.fit_level}"
      end)

    "\nRanked (top #{min(limit, length(ranked))}):\n" <> rows
  end

  # ------------------------------------------------------------------
  # JSON helpers
  # ------------------------------------------------------------------

  defp json_system(system) do
    %{
      "has_gpu" => system.has_gpu,
      "gpu_name" => system.gpu_name,
      "gpu_vram_gb" => system.gpu_vram_gb,
      "gpu_count" => system.gpu_count,
      "total_ram_gb" => system.total_ram_gb,
      "available_ram_gb" => system.available_ram_gb,
      "backend" => system.backend,
      "probe_errors" => Enum.map(system.probe_errors, &inspect/1)
    }
  end

  defp json_result(nil), do: nil

  defp json_result(r) do
    %{
      "name" => r.name,
      "provider" => r.provider,
      "params_b" => r.params_b,
      "quant" => r.quant,
      "context" => r.context,
      "required_gb" => r.required_gb,
      "speed_tps" => r.speed_tps,
      "run_mode" => Atom.to_string(r.run_mode),
      "fit_level" => Atom.to_string(r.fit_level),
      "score" => r.score,
      "scores" => r.scores
    }
  end

  # ------------------------------------------------------------------
  # Formatting primitives
  # ------------------------------------------------------------------

  # Derive a llama.cpp/Ollama-style model id (lowercase, slug-ish) from
  # the catalog display name.
  defp model_id(name), do: String.downcase(name)

  defp fmt_gb(n) when is_number(n), do: "#{fmt1(n)} GB"
  defp fmt_gb(_), do: "? GB"

  defp fmt_tps(n) when is_number(n), do: fmt1(n)
  defp fmt_tps(_), do: "?"

  defp fmt1(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 1)
  defp fmt1(n) when is_integer(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1)
  defp fmt1(other), do: to_string(other)

  defp pad(s, width) do
    s = to_string(s)
    pad_n = max(0, width - String.length(s))
    s <> String.duplicate(" ", pad_n)
  end

  defp probe_opts(opts) do
    Keyword.take(opts, [
      :host,
      :cmd_fun,
      :meminfo_read_fun,
      :os_type_fun,
      :cmd_timeout_ms
    ])
  end
end
