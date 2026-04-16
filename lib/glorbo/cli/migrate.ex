defmodule Glorbo.CLI.Migrate do
  @moduledoc """
  `glorbo migrate` — thin wrapper over `Ecto.Migrator.run(Glorbo.Repo,
  priv/repo/migrations, :up, all: true)` per D-18.

  Exits 0 on success (including 0-applied no-op case), 2 on exception.
  `--help` prints the usage block. Every invocation emits
  `cli.migrate.start` + `cli.migrate.complete` (or `cli.migrate.failed`)
  audit events via `Glorbo.CLI.Audit`.

  No `--rollback` in v0.0.2 — the Director hand-edits migration files
  for advanced cases.
  """
  alias Glorbo.CLI.Audit

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} =
      OptionParser.parse(argv, strict: [help: :boolean])

    if opts[:help], do: {:migrate, 0, help_text()}, else: do_migrate()
  end

  defp do_migrate do
    Audit.emit("migrate", "start", %{})

    case migrations_path() do
      {:error, msg} ->
        Audit.emit("migrate", "failed", %{reason: msg})
        {:migrate, 2, "Migrations dir not found: #{msg}\n"}

      {:ok, path} ->
        try do
          applied = Ecto.Migrator.run(Glorbo.Repo, path, :up, all: true)
          Audit.emit("migrate", "complete", %{count: length(applied)})
          {:migrate, 0, "✓ migrations applied: #{length(applied)}\n"}
        rescue
          e ->
            msg = Exception.message(e)
            Audit.emit("migrate", "failed", %{reason: msg})
            {:migrate, 2, "Migration failed: #{msg}\n"}
        catch
          :exit, reason ->
            Audit.emit("migrate", "failed", %{reason: inspect(reason)})
            {:migrate, 2, "Migration failed: #{inspect(reason)}\n"}
        end
    end
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

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo migrate — run Ecto migrations against ~/.glorbo/glorbo.db.

    USAGE
      glorbo migrate

    BEHAVIOR
      Runs all pending :up migrations. Exits non-zero on failure. No
      --rollback in v0.0.2 (hand-edit migration files for advanced cases).
    """
  end
end
