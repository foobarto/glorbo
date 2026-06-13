defmodule Glorbo.Providers.Enable do
  @moduledoc """
  Append a discovered localhost native provider to
  `~/.config/glorbo/providers.toml` (GEP-32 phase 4).

  "Enable" is the Director-triggered step that promotes a
  `Detect.run/0` result into a routable provider. The action is
  additive — existing `[[providers]]` entries are preserved — and
  idempotent: a second Enable call for the same alias returns
  `{:error, :already_enabled}` rather than duplicating the entry.

  Scope per GEP-32 §"Local-provider auto-detection":
    * Local providers get `auth = "none"`, empty credentials.
    * Native kind + `usage_parser = "native-v1"`, so the Director can
      flip straight to routable without manual TOML edits.
    * No network calls — this module trusts the caller's detection
      result. Re-probing is `Glorbo.Providers.Detect.run/0`.
  """
  alias Glorbo.Filesystem.Hierarchy
  alias Glorbo.Providers.Detect

  @type detection :: Detect.detection()

  @spec default_path() :: Path.t()
  def default_path do
    Hierarchy.providers_config_path()
  end

  @doc """
  Append the TOML entry for `alias_name` to `opts[:path]` (default
  `~/.config/glorbo/providers.toml`).

  Options:
    * `:path` — override the target file (tests).
    * `:detection` — the concrete `%{status: :ready, endpoint: _}` map
      to enable. When absent, runs `Detect.run/0` and picks the
      matching alias.
  """
  @spec enable(String.t(), keyword()) ::
          :ok
          | {:error,
             :not_reachable
             | :already_enabled
             | :unknown_alias
             | {:write_failed, term()}}
  def enable(alias_name, opts \\ []) when is_binary(alias_name) do
    path = Keyword.get(opts, :path, default_path())

    with {:ok, detection} <- find_detection(alias_name, opts),
         :ok <- ensure_not_enabled(path, alias_name),
         {:ok, entry} <- render_entry(alias_name, detection) do
      append_entry(path, entry)
    end
  end

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  defp find_detection(alias_name, opts) do
    case Keyword.get(opts, :detection) do
      %{status: :ready} = det ->
        {:ok, det}

      nil ->
        detections = Detect.run()

        case Enum.find(detections, &(&1.alias == alias_name and &1.status == :ready)) do
          nil -> {:error, :not_reachable}
          det -> {:ok, det}
        end

      _ ->
        {:error, :not_reachable}
    end
  end

  defp ensure_not_enabled(path, alias_name) do
    case File.read(path) do
      {:ok, body} ->
        # Ignore the alignment whitespace the renderer uses below — any
        # existing `name = "<alias_name>"` line (TOML-legal with arbitrary
        # spaces around `=`) means the Director has already enabled this
        # alias, and the tested idempotence contract is "no duplicate
        # appends."
        pattern = ~r/\bname\s*=\s*"#{Regex.escape(alias_name)}"/

        if Regex.match?(pattern, body), do: {:error, :already_enabled}, else: :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:write_failed, reason}}
    end
  end

  defp render_entry(alias_name, %{endpoint: endpoint}) do
    %{shape: shape, path: model_path} = shape_for(alias_name)

    entry = """

    # Auto-added by `glorbo detect-providers` (GEP-32).
    [[providers]]
    name         = "#{alias_name}"
    kind         = "native"
    endpoint     = "#{endpoint}"
    auth         = "none"
    usage_parser = "native-v1"
    usage_path   = { kind = "json_file", path = "{workspace}/.glorbo-run/{task_id}/usage.json" }
    model_list   = { path = "#{model_path}", shape = "#{shape}" }
    """

    {:ok, entry}
  end

  # Maps discovery aliases to their canonical model-list shape +
  # endpoint. Unknown aliases fall through to the OpenAI shape since
  # all our tie-break candidates share it.
  defp shape_for("ollama"), do: %{shape: "ollama", path: "/api/tags"}
  defp shape_for("llamacpp"), do: %{shape: "openai", path: "/v1/models"}
  defp shape_for("localai"), do: %{shape: "openai", path: "/v1/models"}
  defp shape_for("vllm"), do: %{shape: "openai", path: "/v1/models"}
  defp shape_for("lm-studio"), do: %{shape: "openai", path: "/v1/models"}
  defp shape_for(_), do: %{shape: "openai", path: "/v1/models"}

  defp append_entry(path, entry) do
    File.mkdir_p!(Path.dirname(path))

    case File.open(path, [:append, :binary], fn fd -> IO.binwrite(fd, entry) end) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end
end
