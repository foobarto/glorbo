defmodule Glorbo.Ollama.Config do
  @moduledoc """
  Director-tunable knobs for local Ollama models (GEP-67).

  Read from `<config_root>/ollama.toml` (GEP-61 config home). Three
  layers, each set with the Ollama-canonical mechanism:

      [daemon]                  # applied as env when Glorbo SPAWNS the
      num_parallel = 2          #   daemon (managed mode only — an adopted
      max_loaded_models = 1     #   external daemon is the user's to tune)
      keep_alive = "5m"         #   → OLLAMA_NUM_PARALLEL / _MAX_LOADED_MODELS / _KEEP_ALIVE

      [models."llama3.1:8b"]    # baked into a Glorbo-derived tuned model
      num_ctx = 32768           #   via a Modelfile (`Glorbo.Ollama.Tuning`):
      temperature = 0.7         #   num_ctx can't be set over the OpenAI-compat
      num_predict = 4096        #   endpoint, so a Modelfile PARAMETER is the
      top_p = 0.9               #   only reliable path. Per-knob, not per-request.

  Every value is validated against a sane range; a malformed knob is
  dropped (logged), never crashes — a bad config can't take Ollama down.
  Read-only here; the Phase-5 Settings panel writes the file.
  """

  require Logger

  alias Glorbo.Filesystem.Hierarchy

  @type t :: %{daemon: map(), models: %{optional(String.t()) => map()}}

  @keep_alive_re ~r/^-?\d+(\.\d+)?(ns|us|ms|s|m|h)?$/

  @doc "Load + validate the Ollama knob config. Missing/unreadable file → empty config."
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    path = Keyword.get(opts, :path, default_path())

    with {:ok, raw} <- File.read(path),
         {:ok, parsed} <- Toml.decode(raw) do
      %{
        daemon: validate_daemon(Map.get(parsed, "daemon", %{})),
        models: validate_models(Map.get(parsed, "models", %{}))
      }
    else
      {:error, :enoent} ->
        empty()

      {:error, reason} ->
        Logger.warning("Glorbo.Ollama.Config: ignoring #{path}: #{inspect(reason)}")
        empty()
    end
  end

  @doc "Default config path: `<config_root>/ollama.toml`."
  def default_path, do: Path.join(Hierarchy.config_root(), "ollama.toml")

  @doc """
  Daemon env (`[{"OLLAMA_NUM_PARALLEL", "2"}, ...]`) for a Glorbo-SPAWNED
  `ollama serve`. Only the knobs actually set appear; unset → Ollama's
  own default.
  """
  @spec daemon_env(t()) :: [{String.t(), String.t()}]
  def daemon_env(%{daemon: d}) do
    [
      {"OLLAMA_NUM_PARALLEL", d[:num_parallel]},
      {"OLLAMA_MAX_LOADED_MODELS", d[:max_loaded_models]},
      {"OLLAMA_KEEP_ALIVE", d[:keep_alive]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map(fn {k, v} -> {k, to_string(v)} end)
  end

  @doc "The per-model knobs map (`%{num_ctx: ..., temperature: ...}`) for `model`, or `%{}`."
  @spec model_params(t(), String.t()) :: map()
  def model_params(%{models: models}, model), do: Map.get(models, model, %{})

  @doc "True when `model` has at least one per-model knob set (so a tuned variant is worth baking)."
  @spec tuned?(t(), String.t()) :: boolean()
  def tuned?(config, model), do: model_params(config, model) != %{}

  # ---------------------------------------------------------------------------
  # Validation — drop bad values, never crash
  # ---------------------------------------------------------------------------

  defp empty, do: %{daemon: %{}, models: %{}}

  defp validate_daemon(d) when is_map(d) do
    %{}
    |> put_int(d, "num_parallel", :num_parallel, 1, 64)
    |> put_int(d, "max_loaded_models", :max_loaded_models, 1, 16)
    |> put_keep_alive(d)
  end

  defp validate_daemon(_), do: %{}

  defp validate_models(models) when is_map(models) do
    models
    |> Enum.map(fn {name, params} -> {name, validate_model_params(params)} end)
    # Drop models with no valid knobs, and reject any model name that
    # isn't a valid Ollama ref (it flows into the /api/create payload).
    |> Enum.filter(fn {name, params} ->
      params != %{} and Glorbo.Ollama.Pull.validate_model(name) == :ok
    end)
    |> Map.new()
  end

  defp validate_models(_), do: %{}

  defp validate_model_params(p) when is_map(p) do
    %{}
    |> put_int(p, "num_ctx", :num_ctx, 1, 1_048_576)
    |> put_int(p, "num_predict", :num_predict, -2, 1_048_576)
    |> put_float(p, "temperature", :temperature, 0.0, 2.0)
    |> put_float(p, "top_p", :top_p, 0.0, 1.0)
  end

  defp validate_model_params(_), do: %{}

  defp put_int(acc, src, key, out, min, max) do
    case Map.get(src, key) do
      v when is_integer(v) and v >= min and v <= max -> Map.put(acc, out, v)
      nil -> acc
      bad -> warn_drop(key, bad, acc)
    end
  end

  defp put_float(acc, src, key, out, min, max) do
    case Map.get(src, key) do
      v when is_number(v) and v >= min and v <= max -> Map.put(acc, out, v / 1.0)
      nil -> acc
      bad -> warn_drop(key, bad, acc)
    end
  end

  defp put_keep_alive(acc, d) do
    case Map.get(d, "keep_alive") do
      v when is_binary(v) ->
        if Regex.match?(@keep_alive_re, v),
          do: Map.put(acc, :keep_alive, v),
          else: warn_drop("keep_alive", v, acc)

      v when is_integer(v) ->
        Map.put(acc, :keep_alive, Integer.to_string(v))

      nil ->
        acc

      bad ->
        warn_drop("keep_alive", bad, acc)
    end
  end

  defp warn_drop(key, value, acc) do
    Logger.warning("Glorbo.Ollama.Config: dropping invalid #{key}=#{inspect(value)}")
    acc
  end
end
