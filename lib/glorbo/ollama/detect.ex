defmodule Glorbo.Ollama.Detect do
  @moduledoc """
  Detection for the local Ollama install + daemon (GEP-67, Phase 1).

  Three independent checks, each with an injectable seam so the Settings
  UI and tests can drive them without a real Ollama:

    * `installed?/1` / `binary_path/1` — is the `ollama` binary on `PATH`?
    * `version/1` — the installed CLI version (`ollama --version`, run as
      a discrete-argv execve — no shell).
    * `daemon_reachable?/1` — is a daemon answering on
      `127.0.0.1:11434` with the Ollama shape? Reuses the GEP-32
      `Glorbo.Providers.Detect` fingerprint, probing only the ollama
      candidate.

  Nothing here runs at boot — detection is a Director-initiated action
  (the `/providers` "Local models" panel), never an automatic probe of a
  host binary (GEP-8 D13's caution).
  """

  alias Glorbo.Providers.Detect

  @endpoint "http://127.0.0.1:11434"

  # The single ollama probe candidate (mirrors the entry in
  # `Glorbo.Providers.Detect`'s ladder) so `daemon_reachable?/1` probes
  # only ollama, not the whole local-LLM ladder.
  @candidate %{
    alias: "ollama",
    endpoint: @endpoint,
    shape: :ollama,
    path: "/api/tags",
    fingerprint: :ollama
  }

  @doc "Absolute path to the `ollama` binary on `PATH`, or `nil`."
  @spec binary_path((String.t() -> String.t() | nil)) :: String.t() | nil
  def binary_path(finder \\ &System.find_executable/1), do: finder.("ollama")

  @doc "True when the `ollama` binary is on `PATH`."
  @spec installed?((String.t() -> String.t() | nil)) :: boolean()
  def installed?(finder \\ &System.find_executable/1), do: is_binary(binary_path(finder))

  @doc """
  The installed CLI version (e.g. `"0.6.2"`), or `:error` when ollama
  isn't installed or the probe fails. Runs `ollama --version` as a
  discrete-argv execve via the injectable `:runner` (defaults to
  `System.cmd/3`) — never a shell string.
  """
  @spec version(keyword()) :: {:ok, String.t()} | :error
  def version(opts \\ []) do
    path =
      Keyword.get(opts, :binary_path) ||
        binary_path(Keyword.get(opts, :finder, &System.find_executable/1))

    runner = Keyword.get(opts, :runner, &System.cmd/3)

    if is_binary(path) do
      case safe_run(runner, path) do
        {out, 0} -> {:ok, parse_version(out)}
        _ -> :error
      end
    else
      :error
    end
  end

  @doc """
  True when a daemon is answering on `127.0.0.1:11434` with the Ollama
  shape. Reuses the GEP-32 `Providers.Detect` fingerprint; pass
  `:request_fun` to stub the HTTP probe in tests.
  """
  @spec daemon_reachable?(keyword()) :: boolean()
  def daemon_reachable?(opts \\ []) do
    opts
    |> Keyword.put(:candidates, [@candidate])
    |> Detect.run()
    |> Enum.any?(fn d -> d.alias == "ollama" and d.status == :ready end)
  end

  @doc "The local Ollama endpoint (`http://127.0.0.1:11434`)."
  @spec endpoint() :: String.t()
  def endpoint, do: @endpoint

  defp safe_run(runner, path) do
    runner.(path, ["--version"], stderr_to_stdout: true)
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # `ollama --version` prints e.g. "ollama version is 0.6.2"; pull out
  # the dotted version, else fall back to the trimmed raw line.
  defp parse_version(out) do
    out = to_string(out)

    case Regex.run(~r/(\d+\.\d+\.\d+)/, out) do
      [_, v] -> v
      _ -> String.trim(out)
    end
  end
end
