defmodule Glorbo.CLI.Registry.Detection do
  @moduledoc """
  PATH detection + optional version probing for registry providers
  (GEP-8 §7.1, §7.3).

  Detection is split into two phases:

    * **`detect_all/1`** — synchronous `System.find_executable/1` per
      provider (or `File.stat/1` for absolute paths). On a miss, falls
      back to each entry in `provider.fallback_paths` (expanded via
      `Path.expand/1`, so `~` works). Sub-ms total. Runs at boot.
    * **`probe_versions/2`** — fan-out `Task.async_stream` calling
      `System.cmd/3` on each provider's `version_flag`. Per-probe timeout
      of 3 s; non-fatal failures (timeout, non-zero exit, regex miss)
      populate `probe_error` without crashing the batch.

  Version probes are gated by the Provider's `allow_version_probe` flag
  (GEP-8 D13) — user-declared providers opt in explicitly so we never
  execute arbitrary user-supplied binaries on boot.

  The `:system_cmd_fun` / `:find_executable_fun` options allow tests to
  substitute pure functions for the side-effecting calls.
  """

  alias Glorbo.CLI.Registry.Provider

  @default_probe_timeout_ms 3_000

  @type opts :: [
          find_executable_fun: (String.t() -> String.t() | nil),
          file_stat_fun: (String.t() -> {:ok, term()} | {:error, term()})
        ]

  @type probe_opts :: [
          system_cmd_fun: (String.t(), [String.t()], keyword() -> {binary(), integer()}),
          timeout_ms: pos_integer()
        ]

  @doc """
  Run PATH detection over a list of providers. Returns a new list with
  `installed?` and `resolved_path` populated on each entry.

  This call is purely synchronous and does not invoke any CLI binaries.
  """
  @spec detect_all([Provider.t()], opts()) :: [Provider.t()]
  def detect_all(providers, opts \\ []) do
    find_fun = Keyword.get(opts, :find_executable_fun, &System.find_executable/1)
    stat_fun = Keyword.get(opts, :file_stat_fun, &File.stat/1)

    Enum.map(providers, &detect_one(&1, find_fun, stat_fun))
  end

  defp detect_one(%Provider{kind: :native} = p, _find_fun, _stat_fun) do
    %{p | installed?: true, resolved_path: nil}
  end

  defp detect_one(%Provider{binary: binary} = p, find_fun, stat_fun) do
    if absolute?(binary) do
      case stat_fun.(binary) do
        {:ok, _} -> %{p | installed?: true, resolved_path: binary}
        {:error, _} -> try_fallback_paths(p, stat_fun)
      end
    else
      case find_fun.(binary) do
        nil -> try_fallback_paths(p, stat_fun)
        path -> %{p | installed?: true, resolved_path: path}
      end
    end
  end

  # Walk the provider's declared `fallback_paths` in order; first one
  # whose expanded path stat()s becomes the resolved binary. Expands
  # `~` / `$HOME` here (not at load time) so the same TOML works for
  # any director on any box. Missing paths are skipped silently — the
  # provider simply remains `installed?: false` if nothing hits.
  defp try_fallback_paths(%Provider{fallback_paths: []} = p, _stat_fun) do
    %{p | installed?: false, resolved_path: nil}
  end

  defp try_fallback_paths(%Provider{fallback_paths: paths} = p, stat_fun) do
    Enum.find_value(paths, %{p | installed?: false, resolved_path: nil}, fn raw ->
      candidate = Path.expand(raw)

      case stat_fun.(candidate) do
        {:ok, _} -> %{p | installed?: true, resolved_path: candidate}
        {:error, _} -> nil
      end
    end)
  end

  defp absolute?(binary) when is_binary(binary), do: Path.type(binary) == :absolute

  @doc """
  Probe versions for every provider that is currently `installed?`
  *and* carries `allow_version_probe: true` *and* has a non-empty
  `version_flag`. Runs probes in parallel via `Task.async_stream` with
  a per-probe timeout of 3 s.

  Returns a new list of Providers with `version` and/or `probe_error`
  filled in. Providers skipped by the opt-in check pass through
  unchanged.
  """
  @spec probe_versions([Provider.t()], probe_opts()) :: [Provider.t()]
  def probe_versions(providers, opts \\ []) do
    cmd_fun = Keyword.get(opts, :system_cmd_fun, &system_cmd/3)
    timeout = Keyword.get(opts, :timeout_ms, @default_probe_timeout_ms)

    {probe, passthrough} = Enum.split_with(providers, &probeable?/1)

    # `Task.async_stream` enforces the per-task wall-clock cap: the inner
    # `cmd_fun` can call `System.cmd/3` which is synchronous and has no
    # native timeout. `on_timeout: :kill_task` kills the task after
    # `:timeout` ms; we then surface it as `probe_error: :timeout`.
    probed =
      probe
      |> Task.async_stream(
        fn p -> probe_one(p, cmd_fun) end,
        timeout: timeout,
        on_timeout: :kill_task,
        max_concurrency: max(length(probe), 1)
      )
      |> Enum.zip(probe)
      |> Enum.map(fn
        {{:ok, result}, _orig} -> result
        {{:exit, :timeout}, orig} -> %{orig | version: nil, probe_error: {:timeout, timeout}}
        {{:exit, reason}, orig} -> %{orig | version: nil, probe_error: {:task_exit, reason}}
      end)

    probed ++ passthrough
  end

  defp probeable?(%Provider{kind: :native}), do: false

  defp probeable?(%Provider{installed?: true, allow_version_probe: true, version_flag: f})
       when is_binary(f) and f != "",
       do: true

  defp probeable?(_), do: false

  defp probe_one(%Provider{resolved_path: path, version_flag: flag} = p, cmd_fun) do
    case cmd_fun.(path, [flag], stderr_to_stdout: true) do
      {output, 0} when is_binary(output) ->
        apply_regex(p, output)

      {_output, code} ->
        %{p | version: nil, probe_error: {:non_zero_exit, code}}
    end
  end

  defp apply_regex(%Provider{version_regex: nil} = p, output) do
    %{p | version: String.trim(output), probe_error: nil}
  end

  defp apply_regex(%Provider{version_regex: pattern} = p, output) do
    case Regex.compile(pattern) do
      {:ok, re} ->
        case Regex.run(re, output) do
          [_full, capture | _] -> %{p | version: capture, probe_error: nil}
          [match] -> %{p | version: match, probe_error: nil}
          nil -> %{p | version: nil, probe_error: :regex_miss}
        end

      {:error, reason} ->
        # Guarded by Loader validation, but belt-and-braces in case the
        # pattern drifted after load.
        %{p | version: nil, probe_error: {:bad_regex, reason}}
    end
  end

  defp system_cmd(path, args, cmd_opts) do
    System.cmd(path, args, cmd_opts)
  end
end
