defmodule Glorbo.Filesystem.Hierarchy do
  @moduledoc """
  Materialises the `~/.glorbo/` tree per DESIGN.md §3.

  Idempotent (D-19): re-running `ensure!/1` on an existing tree is a no-op —
  existing content in `config.md` and `logs/glorbo.log` is preserved, and no
  directory is re-created or wiped.

  The directories listed here are the Phase-2 scope. Phase 3 introduces
  company-specific subdirectories (`companies/<co>/agents/<n>/inbox`,
  `channels`, `audit`, `workspace`, etc.) when the Director runs
  `glorbo new company`.
  """

  # Directories created unconditionally (mkdir -p). Order-independent.
  @dirs ~w(
    bin
    cache/providers
    companies
    runtime/sockets
    logs
    run
  )

  # Files touched empty if absent; preserved if present.
  @files [
    {"config.md", ""},
    {"logs/glorbo.log", ""}
  ]

  @doc """
  Materialise the `~/.glorbo/` tree rooted at `base`.

  Safe to call repeatedly. The workspace root and the `runtime/sockets/`
  and `run/` directories are chmoded to `0o700` on every call (see Pitfall
  5: uvicorn's socket is 0766 by default; we defend at the
  containing-directory level). The 0700 root keeps every secret in the
  tree (config token, password hash, secret_key_base, erl_cookie) and the
  audit log unreadable by other local users (GEP-0053).
  """
  @spec ensure!(Path.t()) :: :ok
  def ensure!(base) when is_binary(base) do
    Enum.each(@dirs, fn d -> File.mkdir_p!(Path.join(base, d)) end)

    # GEP-0053 codex r-C1: restrict the workspace root itself to 0700 (the
    # `~/.ssh` model). The tree holds the director_password_hash, the
    # dashboard token, secret_key_base, erl_cookie, the SQLite projection,
    # and the append-only audit log — none of which any other local user
    # should read or enumerate. A private root also means the brief
    # umask-default window on a freshly-created secret tmp file
    # (`atomic_write_secret!`) is unreachable from other accounts. Applied
    # on every call (idempotent), parity with runtime/sockets + run/.
    File.chmod!(base, 0o700)

    Enum.each(@files, fn {path, default} ->
      full = Path.join(base, path)

      unless File.exists?(full) do
        File.write!(full, default)
        File.chmod!(full, 0o600)
      end
    end)

    File.chmod!(Path.join(base, "runtime/sockets"), 0o700)

    # Plan 05-01: `run/` holds the glorbo.pid (0600) — restrict the
    # containing dir to 0700 so only the Director can enumerate it
    # (threat T-05-03, parity with runtime/sockets/).
    run_dir = Path.join(base, "run")
    if File.exists?(run_dir), do: File.chmod!(run_dir, 0o700)
    :ok
  end

  @doc """
  Default root — `~/.glorbo/` expanded against the current user's home.

  Precedence:
    1. `config :glorbo, :glorbo_base, "..."` (tests and integration use this)
    2. `GLORBO_HOME` environment variable (matches CLI lifecycle tasks)
    3. `~/.glorbo/`
  """
  @spec default_root() :: Path.t()
  def default_root do
    case Application.get_env(:glorbo, :glorbo_base) do
      nil -> System.get_env("GLORBO_HOME") || Path.expand("~/.glorbo")
      base -> base
    end
  end

  @doc """
  XDG config root for glorbo — `$XDG_CONFIG_HOME/glorbo` (default
  `~/.config/glorbo`).

  Holds provider config + credentials OUT of the `~/.glorbo/` data tree
  (GEP-61) so naive home-folder backups of `~/.glorbo/` never sweep secrets
  into the archive. `~/.glorbo/` stays pure user data.

  Precedence:
    1. `config :glorbo, :glorbo_config_root, "..."` (tests / integration)
    2. `$XDG_CONFIG_HOME/glorbo` when `XDG_CONFIG_HOME` is set + absolute
    3. `~/.config/glorbo`
  """
  @spec config_root() :: Path.t()
  def config_root do
    case Application.get_env(:glorbo, :glorbo_config_root) do
      nil -> xdg_config_root()
      root -> root
    end
  end

  # XDG_CONFIG_HOME must be an absolute path per the spec; fall back to
  # ~/.config if it is unset, empty, or relative (a relative XDG_CONFIG_HOME
  # is invalid and must be ignored).
  defp xdg_config_root do
    base =
      case System.get_env("XDG_CONFIG_HOME") do
        dir when is_binary(dir) and dir != "" ->
          if String.starts_with?(dir, "/"), do: dir, else: Path.expand("~/.config")

        _ ->
          Path.expand("~/.config")
      end

    Path.join(base, "glorbo")
  end

  @doc """
  Default directory for native-provider credentials —
  `<config_root>/credentials` (GEP-61), overridable via
  `GLORBO_CREDENTIALS_DIR`.

  Lives under `config_root/0` (outside `~/.glorbo/`) on purpose so naive
  home-folder backups of Glorbo state do not sweep API keys into the archive.
  """
  @spec native_credentials_dir() :: Path.t()
  def native_credentials_dir do
    System.get_env("GLORBO_CREDENTIALS_DIR") ||
      Path.join(config_root(), "credentials")
  end

  @doc """
  Canonical path to the user provider registry — `<config_root>/providers.toml`
  (GEP-61, moved out of `~/.glorbo/providers.toml`).
  """
  @spec providers_config_path() :: Path.t()
  def providers_config_path, do: Path.join(config_root(), "providers.toml")

  @doc """
  Canonical directory for per-provider override TOMLs —
  `<config_root>/providers/` (GEP-61, moved out of `~/.glorbo/providers/`).
  """
  @spec providers_override_dir() :: Path.t()
  def providers_override_dir, do: Path.join(config_root(), "providers")

  @doc """
  Cache directory for derived provider-model catalogs.
  """
  @spec providers_cache_dir(Path.t()) :: Path.t()
  def providers_cache_dir(base \\ default_root()) when is_binary(base) do
    Path.join([base, "cache", "providers"])
  end
end
