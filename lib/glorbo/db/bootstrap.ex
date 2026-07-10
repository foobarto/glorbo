defmodule Glorbo.DB.Bootstrap do
  @moduledoc """
  Auto-migration bootstrap child (GEP-28 fix).

  Starts after `Glorbo.Repo` and applies every pending migration before any
  downstream child can query derived tables. It is a fail-fast one-shot child:
  a missing migration directory or migration failure aborts application boot
  rather than leaving a partially usable runtime.
  """

  require Logger

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary
    }
  end

  @spec start_link() :: :ignore | {:error, {:database_bootstrap_failed, term()}}
  def start_link do
    case run() do
      {:ok, []} ->
        :ignore

      {:ok, applied} ->
        Logger.info("DB.Bootstrap: #{length(applied)} migration(s) applied")
        :ignore

      {:error, reason} ->
        Logger.error("DB.Bootstrap: migration failed: #{format_reason(reason)}")
        {:error, {:database_bootstrap_failed, reason}}
    end
  end

  @doc false
  @spec run(keyword()) :: {:ok, [integer()]} | {:error, term()}
  def run(opts \\ []) do
    path_fun = Keyword.get(opts, :migrations_path_fun, &migrations_path/0)
    migrator_fun = Keyword.get(opts, :migrator_fun, &run_migrator/1)

    case path_fun.() do
      {:ok, path} -> migrator_fun.(path)
      {:error, _reason} = error -> error
    end
  end

  defp run_migrator(path) do
    {:ok, Ecto.Migrator.run(Glorbo.Repo, path, :up, all: true)}
  rescue
    e -> {:error, {:exception, e, __STACKTRACE__}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp migrations_path do
    case :code.priv_dir(:glorbo) do
      {:error, reason} ->
        {:error, "priv_dir lookup failed: #{inspect(reason)}"}

      dir when is_list(dir) ->
        path = Path.join(to_string(dir), "repo/migrations")
        if File.dir?(path), do: {:ok, path}, else: {:error, path}
    end
  end

  defp format_reason({:exception, exception, _stacktrace}), do: Exception.message(exception)
  defp format_reason(reason), do: inspect(reason)
end
