defmodule Glorbo.DB.Bootstrap do
  @moduledoc """
  Auto-migration bootstrap child (GEP-28 fix).

  Starts after `Glorbo.Repo` in the supervision tree. Checks whether
  the SQLite database has been initialized by looking for
  `schema_migrations`. If the table is missing, runs all pending
  `:up` migrations so that downstream children (CompanyBoot,
  Filesystem.Watcher, Reindex) can query the derived tables without
  crashing.

  This is a best-effort one-shot child: it runs on boot, migrates if
  needed, then returns `:ignore` so it does not stay in the tree.
  Migration failures are logged but never crash the supervisor — the
  app continues booting and surfaces the problem via `glorbo doctor`.
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

  @spec start_link() :: :ignore
  def start_link do
    case table_exists?("schema_migrations") do
      true ->
        :ignore

      false ->
        Logger.info("DB.Bootstrap: schema_migrations missing — running migrations")
        do_migrate()
        :ignore
    end
  end

  defp do_migrate do
    case migrations_path() do
      {:error, reason} ->
        Logger.error("DB.Bootstrap: migrations dir not found: #{inspect(reason)}")

      {:ok, path} ->
        try do
          applied = Ecto.Migrator.run(Glorbo.Repo, path, :up, all: true)
          Logger.info("DB.Bootstrap: #{length(applied)} migration(s) applied")
        rescue
          e ->
            Logger.error("DB.Bootstrap: migration failed: #{Exception.message(e)}")
        catch
          :exit, reason ->
            Logger.error("DB.Bootstrap: migration exited: #{inspect(reason)}")
        end
    end
  end

  defp table_exists?(name) do
    sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"

    case Ecto.Adapters.SQL.query(Glorbo.Repo, sql, [name]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  rescue
    _ -> false
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
end
