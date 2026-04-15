defmodule Glorbo.Container.Socket do
  @moduledoc """
  Manages the Unix-socket directory that Elixir bind-mounts into each
  company's container (D-34, D-35).

  Elixir OWNS the directory with restrictive POSIX perms (0700) — Pitfall 5
  mitigation: uvicorn creates the socket inside at 0766 by default, but the
  traversal barrier lives at the parent directory. Phase 3 will add
  per-agent POSIX ACLs on the socket file itself.
  """

  @doc """
  Ensure `<base>/runtime/sockets/<company>/` exists and is chmodded 0700.

  Returns the directory path. Idempotent — safe to call repeatedly.
  """
  @spec ensure_dir!(Path.t(), String.t()) :: Path.t()
  def ensure_dir!(base, company) do
    dir = Path.join([base, "runtime", "sockets", company])
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  @doc "Canonical socket path for an (agent, company) pair. Pure."
  @spec path(Path.t(), String.t(), String.t()) :: Path.t()
  def path(base, company, agent) do
    Path.join([base, "runtime", "sockets", company, "#{agent}.sock"])
  end

  @doc """
  Remove a leftover socket file if present. No-op when absent.

  Called before every container launch so that a crashed previous run
  cannot leave a stale socket that the next uvicorn refuses to bind over.
  """
  @spec cleanup_stale(Path.t(), String.t(), String.t()) :: :ok
  def cleanup_stale(base, company, agent) do
    sock = path(base, company, agent)
    if File.exists?(sock), do: File.rm!(sock)
    :ok
  end
end
