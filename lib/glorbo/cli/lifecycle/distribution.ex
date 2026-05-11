defmodule Glorbo.CLI.Lifecycle.Distribution do
  @moduledoc """
  Starts the BEAM's node-distribution subsystem (`Node.start/2`)
  with the canonical Glorbo node name. Only called by the CLI verbs
  that actually need distribution — `serve`, `up`, `console` — so
  lightweight verbs (`help`, `status`, `down`, `doctor`, ...) never
  contend for the name and never trip EPMD collisions.

  Node name is `glorbo@127.0.0.1` (loopback-only trust per T-05-04).
  Long-name distribution so `iex --name console@127.0.0.1
  --remsh glorbo@127.0.0.1` keeps working (name-class has to match;
  short-name would reject long-name callers).

  ## Idempotent

  If `Node.self/0` is already `glorbo@127.0.0.1` — someone else has
  already started us — return `:ok`. If distribution is started
  under a DIFFERENT name (edge case: an early boot mis-set the
  name), return `{:error, {:already_started, other_node}}`; callers
  decide whether to abort.

  ## Collision detection

  If a second `glorbo@127.0.0.1` is already registered with EPMD
  (typically a running daemon from a previous `glorbo up`), BEAM
  refuses the registration with `{:error, {:already_started, pid}}`.
  We re-surface that as a tuple the caller can pattern-match on so
  the CLI can print a useful "another glorbo is already running —
  use `./glorbo status` or `./glorbo down`" message instead of the
  opaque BEAM error.

  ## epmd bind

  epmd is spawned with `-address 127.0.0.1` so its listen socket is
  loopback-only. Edge case: if another Erlang application already started
  epmd on all interfaces before glorbo, our `-daemon` invocation exits
  silently (epmd is idempotent). We log a warning but do not abort —
  `Node.start/2` still succeeds. The risk is the pre-existing epmd's
  wider bind, not ours.
  """

  @canonical_node :"glorbo@127.0.0.1"

  @spec start() :: :ok | {:error, :already_started, node()} | {:error, term()}
  def start do
    case Node.self() do
      :nonode@nohost ->
        do_start()

      @canonical_node ->
        :ok

      other ->
        {:error, :already_started, other}
    end
  end

  defp do_start do
    ensure_epmd()

    case Node.start(@canonical_node, :longnames) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        {:error, :name_collision, @canonical_node}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Burrito ships ERTS but not a running EPMD. If none is listening on
  # port 4369 yet, `Node.start(_, :longnames)` crashes with
  # `econnrefused` ~100ms after start. Spawn the daemon ourselves —
  # epmd refuses to double-bind, so this is idempotent. Erlang ships
  # `epmd` next to the current ERTS binary; if it isn't there for some
  # reason we refuse to spawn rather than fall back to the PATH (a
  # PATH search would let an attacker plant a malicious `epmd` earlier
  # in PATH and hijack execution before `Node.start/2`).
  defp ensure_epmd do
    epmd =
      Path.join(
        :code.root_dir() |> to_string() |> Path.join("erts-#{:erlang.system_info(:version)}"),
        "bin/epmd"
      )

    if File.exists?(epmd) do
      _ = System.cmd(epmd, ["-address", "127.0.0.1", "-daemon"], stderr_to_stdout: true)
      :ok
    else
      # No bundled epmd. `Node.start/2` will surface the real error
      # to the caller; better than silently running an attacker's
      # `epmd` from PATH.
      :no_bundled_epmd
    end
  rescue
    _ -> :ok
  end

  @spec canonical_node() :: atom()
  def canonical_node, do: @canonical_node
end
