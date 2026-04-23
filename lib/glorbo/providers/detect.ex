defmodule Glorbo.Providers.Detect do
  @moduledoc """
  Localhost native-provider auto-detection (GEP-32 phase 4).

  Given a well-known port table, probe each candidate alias with the
  shape-appropriate model-list endpoint (`/v1/models` for OpenAI-shape,
  `/api/tags` for Ollama-shape). Tie-breaks between providers sharing
  a port (llama.cpp / LocalAI on 8080) fall back to response-header
  fingerprints.

  Scope, per GEP-32 §"Local-provider auto-detection":
    * Localhost only — no LAN probing.
    * Short timeouts: 1 s connect, 2 s read.
    * No side effects. Discovered providers are surfaced to the caller;
      activation (creating the per-provider TOML override) is a
      separate Director-triggered step.
  """
  alias Glorbo.CLI.Harness.HTTP

  @type fingerprint :: :ollama | :llamacpp | :localai | :vllm | :lm_studio | :openai | :unknown

  @type candidate :: %{
          alias: String.t(),
          endpoint: String.t(),
          shape: :openai | :ollama,
          path: String.t(),
          fingerprint: fingerprint()
        }

  @type detection :: %{
          alias: String.t(),
          endpoint: String.t(),
          status: :ready | :unreachable | :shape_mismatch | :wrong_fingerprint,
          detail: term() | nil
        }

  @default_connect_timeout_ms 1_000
  @default_read_timeout_ms 2_000

  # Known-port ladder. Order-sensitive only for the 8080 tie-break
  # (llama.cpp probed before LocalAI because LocalAI's /readyz flag
  # is an affirmative signal; llama.cpp is the default assumption on
  # that port).
  @candidates [
    %{
      alias: "ollama",
      endpoint: "http://127.0.0.1:11434",
      shape: :ollama,
      path: "/api/tags",
      fingerprint: :ollama
    },
    %{
      alias: "llamacpp",
      endpoint: "http://127.0.0.1:8080",
      shape: :openai,
      path: "/v1/models",
      fingerprint: :llamacpp
    },
    %{
      alias: "localai",
      endpoint: "http://127.0.0.1:8080",
      shape: :openai,
      path: "/v1/models",
      fingerprint: :localai
    },
    %{
      alias: "vllm",
      endpoint: "http://127.0.0.1:8000",
      shape: :openai,
      path: "/v1/models",
      fingerprint: :vllm
    },
    %{
      alias: "lm-studio",
      endpoint: "http://127.0.0.1:1234",
      shape: :openai,
      path: "/v1/models",
      fingerprint: :lm_studio
    }
  ]

  @doc """
  The canonical localhost probe table. Exposed for tests and the
  Providers UI.
  """
  @spec candidates() :: [candidate()]
  def candidates, do: @candidates

  @doc """
  Probe every candidate alias and return one detection per alias.

  Options:
    * `:candidates` — override the probe table (tests).
    * `:request_fun` — override HTTP implementation (tests).
    * `:connect_timeout_ms` / `:read_timeout_ms` — override timeouts.
  """
  @spec run(keyword()) :: [detection()]
  def run(opts \\ []) do
    candidates = Keyword.get(opts, :candidates, @candidates)
    request_fun = Keyword.get(opts, :request_fun, &HTTP.request/1)

    timeout_ms =
      Keyword.get(opts, :read_timeout_ms, @default_read_timeout_ms) +
        Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms)

    candidates
    |> Task.async_stream(
      fn c -> probe_one(c, request_fun, timeout_ms) end,
      max_concurrency: length(candidates),
      timeout: timeout_ms + 1_000,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, det} ->
        det

      {:exit, reason} ->
        %{
          alias: "<task-exit>",
          endpoint: "",
          status: :unreachable,
          detail: {:task_exit, reason}
        }
    end)
    |> Enum.reject(fn det -> det.alias == "<task-exit>" end)
  end

  @doc """
  Human-readable one-line rendering for CLI output.
  """
  @spec format_line(detection()) :: String.t()
  def format_line(%{alias: a, endpoint: e, status: :ready}),
    do: "  ✓ #{a} — reachable at #{e}"

  def format_line(%{alias: a, endpoint: e, status: :unreachable, detail: reason}),
    do: "  ✗ #{a} — unreachable at #{e} (#{inspect(reason)})"

  def format_line(%{alias: a, endpoint: e, status: :shape_mismatch, detail: reason}),
    do: "  ~ #{a} — responded at #{e} but payload shape unexpected (#{inspect(reason)})"

  def format_line(%{alias: a, endpoint: e, status: :wrong_fingerprint, detail: actual}),
    do: "  ~ #{a} — responded at #{e} but fingerprinted as #{inspect(actual)}"

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp probe_one(candidate, request_fun, timeout_ms) do
    request = %{
      method: :get,
      url: candidate.endpoint <> candidate.path,
      headers: [{"accept", "application/json"}],
      timeout_ms: timeout_ms
    }

    case safe_request(request_fun, request) do
      {:ok, %{status: 200, body: body, headers: headers}} ->
        classify_response(candidate, body, headers)

      {:ok, %{status: status}} ->
        %{
          alias: candidate.alias,
          endpoint: candidate.endpoint,
          status: :unreachable,
          detail: {:http_status, status}
        }

      {:error, reason} ->
        %{
          alias: candidate.alias,
          endpoint: candidate.endpoint,
          status: :unreachable,
          detail: reason
        }
    end
  end

  defp safe_request(request_fun, request) do
    request_fun.(request)
  rescue
    e -> {:error, {:probe_crashed, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:probe_exit, reason}}
  end

  defp classify_response(candidate, body, headers) do
    server = header(headers, "server")

    actual = fingerprint_of(candidate.shape, server, body)

    cond do
      candidate.fingerprint == :ollama and match_ollama?(body) ->
        ok(candidate)

      candidate.fingerprint == :llamacpp and server_matches?(server, "llama.cpp") ->
        ok(candidate)

      candidate.fingerprint == :localai and match_localai?(body) ->
        ok(candidate)

      candidate.fingerprint == :vllm and server_matches?(server, "uvicorn") ->
        ok(candidate)

      candidate.fingerprint == :lm_studio and server_matches?(server, "lm studio") ->
        ok(candidate)

      # Fell through — shape may be right but fingerprint isn't; still
      # useful feedback so we don't silently claim llama.cpp on a port
      # that's actually running something else.
      actual == :unknown ->
        %{
          alias: candidate.alias,
          endpoint: candidate.endpoint,
          status: :shape_mismatch,
          detail: :no_known_fingerprint
        }

      true ->
        %{
          alias: candidate.alias,
          endpoint: candidate.endpoint,
          status: :wrong_fingerprint,
          detail: actual
        }
    end
  end

  defp ok(candidate) do
    %{
      alias: candidate.alias,
      endpoint: candidate.endpoint,
      status: :ready,
      detail: nil
    }
  end

  # The response gives us _some_ signal (shape + server header); return
  # the best-guess fingerprint we can derive.
  defp fingerprint_of(:ollama, _server, body) do
    if match_ollama?(body), do: :ollama, else: :unknown
  end

  defp fingerprint_of(:openai, server, body) do
    cond do
      server_matches?(server, "llama.cpp") -> :llamacpp
      server_matches?(server, "uvicorn") -> :vllm
      server_matches?(server, "lm studio") -> :lm_studio
      match_localai?(body) -> :localai
      true -> :unknown
    end
  end

  defp match_ollama?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"models" => list}} when is_list(list) -> true
      _ -> false
    end
  end

  defp match_ollama?(_), do: false

  defp match_localai?(body) when is_binary(body) do
    # LocalAI returns the same `{"data": []}` shape as OpenAI on
    # `/v1/models`, but the "object" field is typically "list" and
    # responses commonly embed a "owned_by" of "localai".
    case Jason.decode(body) do
      {:ok, %{"data" => data}} when is_list(data) ->
        Enum.any?(data, fn
          %{"owned_by" => owner} when is_binary(owner) ->
            String.downcase(owner) == "localai"

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  defp match_localai?(_), do: false

  defp header(headers, key) when is_map(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(to_string(k)) == key, do: to_string(v), else: nil
    end)
  end

  defp header(headers, key) when is_list(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if String.downcase(to_string(k)) == key, do: to_string(v), else: nil
    end)
  end

  defp header(_, _), do: nil

  defp server_matches?(nil, _needle), do: false

  defp server_matches?(server, needle) do
    String.downcase(server) =~ String.downcase(needle)
  end
end
