defmodule Glorbo.Ollama do
  @moduledoc """
  Facade for the local Ollama integration (GEP-67).

  Phase 1 (this module + `Glorbo.Ollama.Detect`): detection of the local
  install + daemon, plus the built-in `ollama` provider
  (`priv/providers/ollama.toml`). Later phases add the daemon manager
  (`Glorbo.Ollama.Daemon` — adopt/start, muontrap), model pull
  (`Glorbo.Ollama.Pull`), the GEP-55 proxy local-upstream path, and the
  `/providers` Settings UI.
  """

  alias Glorbo.Ollama.Detect

  @type status :: %{
          installed?: boolean(),
          version: String.t() | nil,
          binary_path: String.t() | nil,
          daemon_reachable?: boolean(),
          endpoint: String.t()
        }

  @doc """
  A snapshot of the local Ollama install + daemon state, for the Settings
  panel. Accepts the same injectable seams as `Glorbo.Ollama.Detect`
  (`:finder`, `:runner`, `:request_fun`) so it's testable without a real
  Ollama.
  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) do
    finder = Keyword.get(opts, :finder, &System.find_executable/1)
    path = Detect.binary_path(finder)
    installed? = is_binary(path)

    version =
      if installed? do
        case Detect.version(Keyword.put(opts, :binary_path, path)) do
          {:ok, v} -> v
          :error -> nil
        end
      end

    %{
      installed?: installed?,
      version: version,
      binary_path: path,
      daemon_reachable?: Detect.daemon_reachable?(opts),
      endpoint: Detect.endpoint()
    }
  end
end
