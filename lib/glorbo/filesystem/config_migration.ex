defmodule Glorbo.Filesystem.ConfigMigration do
  @moduledoc """
  GEP-61 one-time migration: move provider config + credentials OUT of the
  `~/.glorbo/` data tree (and the legacy `~/.local/etc/glorbo/credentials`)
  into the XDG config root (`Hierarchy.config_root/0`, default
  `~/.config/glorbo`), so naive backups of `~/.glorbo/` never sweep secrets.

  Moves:

    * `<home>/providers.toml`   → `<config>/providers.toml`  (registry)
    * `<home>/providers/<f>`    → `<config>/providers/<f>`   (per-provider overrides)
    * `<legacy_creds>/<f>`      → `<config>/credentials/<f>`  (native API keys)

  **Idempotent** (re-runnable; once moved, a no-op), **no-clobber** (never
  overwrites a file already at the destination — the destination wins),
  **perms-preserving** (carries the source mode, e.g. `0600`), and
  **best-effort** (any error is swallowed and returns `{:ok, []}` — a failed
  migration must never block the CLI; the old paths simply keep being read
  until the next attempt). Safe to call on every CLI start.
  """
  import Bitwise, only: [band: 2]

  alias Glorbo.Filesystem.Hierarchy

  @legacy_credentials_dir "~/.local/etc/glorbo/credentials"

  @doc """
  Run the migration. Returns `{:ok, moves}` where `moves` is the list of
  `{from, to}` pairs actually relocated (empty when nothing needed moving).
  Never raises.

  Options (for tests): `:home`, `:config_root`, `:legacy_credentials_dir`.
  """
  @spec run(keyword()) :: {:ok, [{Path.t(), Path.t()}]}
  def run(opts \\ []) do
    home = Keyword.get(opts, :home, Hierarchy.default_root())
    config = Keyword.get(opts, :config_root, Hierarchy.config_root())

    legacy_creds =
      Keyword.get(opts, :legacy_credentials_dir, Path.expand(@legacy_credentials_dir))

    moves =
      move_file(Path.join(home, "providers.toml"), Path.join(config, "providers.toml")) ++
        move_dir(Path.join(home, "providers"), Path.join(config, "providers")) ++
        move_dir(legacy_creds, Path.join(config, "credentials"))

    # Lock the config root (+ its secret subdirs) to 0700 whenever it exists —
    # NOT only after a move. An already-migrated config root, or one created
    # manually with loose perms, still gets hardened on every run (idempotent).
    # Parity with the ~/.glorbo root (GEP-53). (codex review, #55)
    harden(config)

    {:ok, moves}
  rescue
    _ -> {:ok, []}
  end

  # Copy-then-remove (never a bare rename: the source + destination may be on
  # different filesystems). Copy FIRST, preserve mode, then remove the source —
  # so a crash between steps leaves the secret readable at the old path, never
  # lost. No-clobber: if the destination already exists, leave both untouched.
  defp move_file(from, to) do
    if File.regular?(from) and not File.exists?(to) do
      File.mkdir_p!(Path.dirname(to))
      File.cp!(from, to)
      preserve_mode(from, to)
      File.rm!(from)
      [{from, to}]
    else
      []
    end
  end

  defp move_dir(from, to) do
    case File.ls(from) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          src = Path.join(from, name)
          if File.regular?(src), do: move_file(src, Path.join(to, name)), else: []
        end)

      {:error, _} ->
        []
    end
  end

  defp preserve_mode(from, to) do
    case File.stat(from) do
      {:ok, %File.Stat{mode: mode}} -> File.chmod(to, band(mode, 0o777))
      _ -> :ok
    end
  end

  # Chmod the config root + its secret subdirs to 0700 — but only what already
  # exists (never create just to harden). Safe to call on every run.
  defp harden(config) do
    if File.dir?(config) do
      _ = File.chmod(config, 0o700)

      for sub <- ["credentials", "providers"] do
        dir = Path.join(config, sub)
        if File.dir?(dir), do: File.chmod(dir, 0o700)
      end
    end

    :ok
  end
end
