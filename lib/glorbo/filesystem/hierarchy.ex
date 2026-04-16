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
    models
    containers/glorbo-runtime
    containers/cache
    companies
    runtime/sockets
    logs/containers
    run
  )

  # Files touched empty if absent; preserved if present.
  @files [
    {"config.md", ""},
    {"logs/glorbo.log", ""}
  ]

  @doc """
  Materialise the `~/.glorbo/` tree rooted at `base`.

  Safe to call repeatedly. The `runtime/sockets/` directory is chmoded to
  `0o700` on every call (see Pitfall 5: uvicorn's socket is 0766 by default;
  we defend at the containing-directory level).
  """
  @spec ensure!(Path.t()) :: :ok
  def ensure!(base) when is_binary(base) do
    Enum.each(@dirs, fn d -> File.mkdir_p!(Path.join(base, d)) end)

    Enum.each(@files, fn {path, default} ->
      full = Path.join(base, path)
      unless File.exists?(full), do: File.write!(full, default)
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
  """
  @spec default_root() :: Path.t()
  def default_root, do: Path.expand("~/.glorbo")
end
