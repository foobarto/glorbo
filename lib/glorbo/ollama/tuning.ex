defmodule Glorbo.Ollama.Tuning do
  @moduledoc """
  Bake per-model knobs (`num_ctx`, `temperature`, …) into a Glorbo-derived
  Ollama model (GEP-67).

  Ollama's OpenAI-compatible endpoint does NOT accept `num_ctx` (it's a
  native option, not an OpenAI field), so the only reliable way to set
  the context window through any request path is a **Modelfile**: derive
  `<base>-glorbo` `FROM <base>` with the configured `PARAMETER`s baked in,
  via the daemon's `/api/create`. The base model's layers are shared
  (no re-download) — the derived model is just a thin params override.

  The values come from `Glorbo.Ollama.Config`, already validated to sane
  numeric ranges, so the generated Modelfile carries no untrusted input.
  """

  alias Glorbo.Ollama.{Config, Detect, Pull}

  # Map config knob → Ollama Modelfile PARAMETER name (1:1 here, but kept
  # explicit so a rename in either layer is caught).
  @param_order [
    {:num_ctx, "num_ctx"},
    {:num_predict, "num_predict"},
    {:temperature, "temperature"},
    {:top_p, "top_p"}
  ]

  @doc """
  The model an agent should actually use for `base`: the Glorbo-derived
  tuned variant if `base` has configured knobs (created on demand), else
  `base` unchanged.
  """
  @spec ensure_tuned(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ensure_tuned(base, opts \\ []) when is_binary(base) do
    config = Keyword.get(opts, :config) || Config.load()
    params = Config.model_params(config, base)

    cond do
      params == %{} ->
        {:ok, base}

      Pull.validate_model(base) != :ok ->
        {:error, :invalid_model}

      true ->
        create_fun = Keyword.get(opts, :create_fun, &default_create/2)
        name = tuned_name(base)

        case create_fun.(name, modelfile(base, params)) do
          :ok -> {:ok, name}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Derived model name for `base`: appends `-glorbo` to the tag (or a
  `:glorbo` tag when `base` is untagged). Stays a valid Ollama ref.
  """
  @spec tuned_name(String.t()) :: String.t()
  def tuned_name(base) do
    case String.split(base, ":", parts: 2) do
      [name, tag] -> "#{name}:#{tag}-glorbo"
      [name] -> "#{name}:glorbo"
    end
  end

  @doc "The Modelfile baking `params` onto `base`. Values are pre-validated numbers."
  @spec modelfile(String.t(), map()) :: String.t()
  def modelfile(base, params) do
    lines =
      for {key, name} <- @param_order, Map.has_key?(params, key) do
        "PARAMETER #{name} #{format(Map.fetch!(params, key))}"
      end

    Enum.join(["FROM #{base}" | lines], "\n") <> "\n"
  end

  defp format(v) when is_integer(v), do: Integer.to_string(v)
  defp format(v) when is_float(v), do: Float.to_string(v)

  # POST the Modelfile to the daemon's /api/create. A successful create
  # streams status lines ending in "success"; a 2xx with the stream
  # completing is success. (Layers are shared with the base, so this is
  # fast — no download.)
  defp default_create(name, modelfile) do
    url = Detect.endpoint() <> "/api/create"

    case Req.post(url,
           finch: Glorbo.Finch,
           json: %{name: name, modelfile: modelfile},
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:create_http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
