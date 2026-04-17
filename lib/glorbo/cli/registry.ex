defmodule Glorbo.CLI.Registry do
  @moduledoc """
  Single source of truth for CLI provider availability (GEP-8 §7).

  Starts as a supervised `Agent` whose state is `%{name => Provider.t()}`.
  Boot sequence (`init/1`):

    1. `Loader.load_all!/1` — read built-in + user TOML.
    2. `Detection.detect_all/2` — synchronous PATH scan.
    3. (No version probes at boot — D3, D4. Explicit refresh only.)

  Load-validation failure is a hard crash on boot (D9). Blank registry
  is allowed (no provider files) — `list/0` returns `[]`.

  Public API is read-mostly:

    * `list/0` — all provider snapshots (dashboard, doctor).
    * `get/1` — resolve one provider by name (dispatch).
    * `refresh/0` — reload TOML + PATH scan, no version probes.
    * `refresh_with_version_probe/0` — reload TOML + PATH scan + probe.

  Reads are `Agent.get/2` calls — cheap. Writes (refresh) serialise on
  the Agent mailbox.
  """

  use Agent

  alias Glorbo.CLI.Registry.Detection
  alias Glorbo.CLI.Registry.Loader
  alias Glorbo.CLI.Registry.Provider

  @type snapshot :: %{optional(String.t()) => Provider.t()}

  @doc """
  Starts the Registry. Options (primarily for tests):

    * `:name` — agent name (default `__MODULE__`).
    * `:builtin_dir` — passed to `Loader.load_all!/1`.
    * `:user_file` — passed to `Loader.load_all!/1`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    load_opts = Keyword.take(opts, [:builtin_dir, :user_file])

    Agent.start_link(fn -> build_snapshot(load_opts) end, name: name)
  end

  @doc "Return all provider snapshots."
  @spec list(atom()) :: [Provider.t()]
  def list(name \\ __MODULE__) do
    Agent.get(name, &Map.values/1)
  end

  @doc "Return a single provider by name, or `nil`."
  @spec get(String.t(), atom()) :: Provider.t() | nil
  def get(provider_name, name \\ __MODULE__) when is_binary(provider_name) do
    Agent.get(name, &Map.get(&1, provider_name))
  end

  @doc """
  Reload TOML + PATH scan. Does not probe versions. Returns :ok.
  """
  @spec refresh(keyword()) :: :ok
  def refresh(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    load_opts = Keyword.take(opts, [:builtin_dir, :user_file])

    Agent.update(name, fn _old -> build_snapshot(load_opts) end)
  end

  @doc """
  Reload TOML + PATH scan + parallel version probes (GEP-8 §7.3).
  Blocks until all probes settle (or hit the per-probe timeout).
  """
  @spec refresh_with_version_probe(keyword()) :: :ok
  def refresh_with_version_probe(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    load_opts = Keyword.take(opts, [:builtin_dir, :user_file])
    probe_opts = Keyword.take(opts, [:system_cmd_fun, :timeout_ms])

    Agent.update(
      name,
      fn _old ->
        load_opts
        |> Loader.load_all!()
        |> Detection.detect_all()
        |> Detection.probe_versions(probe_opts)
        |> to_snapshot()
      end,
      :infinity
    )
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp build_snapshot(load_opts) do
    load_opts
    |> Loader.load_all!()
    |> Detection.detect_all()
    |> to_snapshot()
  end

  defp to_snapshot(providers) when is_list(providers) do
    Map.new(providers, &{&1.name, &1})
  end
end
