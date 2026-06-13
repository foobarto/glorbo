defmodule Glorbo.CLI.Lifecycle.Distribution do
  @moduledoc """
  Starts the BEAM's node-distribution subsystem (`Node.start/2`) with this
  instance's node name. Only called by the CLI verbs that actually need
  distribution — `serve`, `up`, `console` — so lightweight verbs (`help`,
  `status`, `down`, `doctor`, ...) never contend for the name and never trip
  EPMD collisions.

  ## Per-instance node identity (GEP-62)

  The node name is **`glorbo-<node_id>@127.0.0.1`**, where `<node_id>` is the
  stable per-instance id minted into this home's `config.md` (`Config.node_id/1`).
  This lets multiple isolated glorbo instances coexist on one machine (distinct
  home + node name + port + EPMD registration) without colliding on a shared
  EPMD. The single-home default install just gets one stable id. Loopback-only
  (`127.0.0.1`) trust per T-05-04; long-name distribution so
  `iex --name console@127.0.0.1 --remsh glorbo-<id>@127.0.0.1` keeps working.
  If `config.md` can't be read to resolve the id, we fall back to the legacy
  fixed `glorbo@127.0.0.1` (defensive — distribution still starts).

  ## Idempotent

  If `Node.self/0` is already this instance's node — someone else has already
  started us — return `:ok`. If distribution is started under a DIFFERENT name,
  return `{:error, :already_started, other_node}`; callers decide whether to
  abort.

  ## Collision detection + stale-registration recovery

  If this instance's name is already registered with EPMD, `Node.start/2`
  fails. The error shape is NOT `{:already_started, _}` (a common
  misconception); the cross-process collision surfaces as net_kernel failing
  its distribution child with `:nodistribution` — verified on OTP 29:

      {:error, {{:shutdown, {:failed_to_start_child, :net_kernel,
                {:EXIT, :nodistribution}}}, _}}

  A collision has two causes:

    * **A genuinely-running glorbo** (this same instance, already up). We
      re-surface `{:error, :name_collision, node}` so the CLI can print
      "another glorbo is already running — use `glorbo status` / `glorbo down`".
    * **A STALE registration from a *crashed* glorbo.** EPMD does not always
      drop a dead node's registration (a child that inherited the EPMD socket
      fd can hold it open), so the orphaned name blocks every subsequent start
      with the same opaque `:nodistribution` error.

  We distinguish the two by **probing the registered distribution port**
  (`live_owner?/1`): a running node accepts the TCP connection; a stale
  registration refuses it. On a stale registration we recover — SIGKILL the
  orphaned EPMD and respawn a clean one, then retry once — but ONLY when this
  instance's name is EPMD's **sole** registrant. That gate is also what makes
  recovery safe under GEP-62 multi-instance: if sibling instances are live,
  EPMD lists several `glorbo-<id>` names → not sole → we do NOT kill (which
  would take the siblings' EPMD down) and degrade to the collision message.

  **Multi-instance limitation:** because of that gate, a crashed instance's
  stale registration cannot auto-recover *while a sibling instance is live*
  (killing the shared EPMD is unsafe). It recovers automatically once it's the
  sole registrant, or the operator clears it manually. The common single-
  instance case recovers automatically as before.

  The recovery is **fail-safe**: any uncertainty (EPMD unreadable, a live node,
  other names registered) skips the kill and falls back to the collision
  message. We keep EPMD hardened — no `-relaxed_command_check` (GEP-48); we
  reclaim our own orphan via an OS signal, not by weakening EPMD's command
  surface.

  ## epmd bind

  epmd is spawned with `-address 127.0.0.1` so its listen socket is
  loopback-only. If another Erlang application already started epmd on all
  interfaces, our `-daemon` invocation exits silently (epmd is idempotent);
  `Node.start/2` still succeeds. The risk is the pre-existing epmd's wider
  bind, not ours.
  """

  alias Glorbo.Config
  alias Glorbo.Filesystem.Hierarchy

  @loopback ~c"127.0.0.1"
  # Defensive fallback only — used if config.md can't be read to resolve the
  # per-instance node_id.
  @fallback_node :"glorbo@127.0.0.1"

  @spec start() :: :ok | {:error, :name_collision | :already_started, node()} | {:error, term()}
  def start do
    node = canonical_node()
    alive = alive_name_of(node)

    case Node.self() do
      :nonode@nohost ->
        do_start(node, alive)

      ^node ->
        :ok

      other ->
        {:error, :already_started, other}
    end
  end

  defp do_start(node, alive) do
    ensure_epmd()

    case Node.start(node, :longnames) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        if name_collision?(reason) do
          resolve_collision(node, alive)
        else
          {:error, reason}
        end
    end
  end

  # A name collision can surface two ways. The legacy / same-VM form is
  # `{:already_started, _}`. The cross-process EPMD collision (another OS
  # process already holds the name) surfaces as net_kernel failing its
  # distribution child with `:nodistribution` — empirically verified on
  # OTP 29. Public for direct unit-testing against the captured tuples.
  @doc false
  @spec name_collision?(term()) :: boolean()
  def name_collision?({:already_started, _pid}), do: true

  def name_collision?(
        {{:shutdown, {:failed_to_start_child, :net_kernel, {:EXIT, :nodistribution}}}, _child}
      ),
      do: true

  def name_collision?(_), do: false

  # A collision is either a live glorbo (let the CLI tell the user to run
  # `glorbo down`) or a stale registration from a crash (recover). Probe the
  # registered distribution port to tell them apart.
  defp resolve_collision(node, alive) do
    if live_owner?(alive) do
      {:error, :name_collision, node}
    else
      recover_from_stale(node, alive)
    end
  end

  # Stale registration: clear the orphaned EPMD (only when safe) and retry
  # `Node.start/2` once. Any failure degrades to the collision message rather
  # than crashing — never worse than the pre-fix behaviour.
  defp recover_from_stale(node, alive) do
    case clear_stale_registration(alive) do
      :ok ->
        ensure_epmd()

        case Node.start(node, :longnames) do
          {:ok, _pid} -> :ok
          _ -> {:error, :name_collision, node}
        end

      :unsafe ->
        {:error, :name_collision, node}
    end
  end

  # Is a process actually listening on the distribution port EPMD has
  # registered for this instance's alive name? A crashed node leaves the
  # registration but nothing listening, so a refused connection == stale. A
  # live node accepts the TCP connection (we close before any handshake — the
  # listener tolerates it). 250ms is generous for a loopback connect. Fails
  # SAFE: any exception returns `true`, so we never kill EPMD out from under a
  # possibly-live node.
  @spec live_owner?(String.t()) :: boolean()
  defp live_owner?(alive) do
    case List.keyfind(epmd_names(), alive, 0) do
      {_name, port} ->
        case :gen_tcp.connect(@loopback, port, [:binary, active: false], 250) do
          {:ok, sock} ->
            :gen_tcp.close(sock)
            true

          {:error, _} ->
            false
        end

      nil ->
        false
    end
  rescue
    _ -> true
  end

  # Clear a stale registration by killing the orphaned EPMD, but ONLY when this
  # instance's alive name is EPMD's SOLE registrant. A shared EPMD may front
  # other applications' — or sibling glorbo instances' (GEP-62) — live nodes we
  # must not disturb. EPMD's own `-kill` / `-stop` are refused while any node is
  # registered and we keep it hardened (no `-relaxed_command_check`, GEP-48), so
  # we SIGKILL the orphan process and let `ensure_epmd/0` respawn a clean one.
  # We are not yet registered ourselves (Node.start just failed), so killing
  # EPMD deregisters nothing of ours.
  @spec clear_stale_registration(String.t()) :: :ok | :unsafe
  defp clear_stale_registration(alive) do
    case epmd_names() do
      [{^alive, _port}] ->
        kill_epmd()
        :ok

      _ ->
        # Empty (can't confirm), or other names present (incl. live sibling
        # instances) — don't nuke a possibly-shared EPMD.
        :unsafe
    end
  end

  # SIGKILL the orphaned EPMD — specifically the process LISTENING on the EPMD
  # port we just probed, never every `epmd` on the host (a shared host / CI
  # runner can run unrelated EPMDs on other ports; `pkill -x epmd` would take
  # those down too). The sole-registrant gate above already proved this EPMD
  # fronts only our stale name. The short sleep lets the OS reap it and free
  # the port before `ensure_epmd/0` respawns.
  @spec kill_epmd() :: :ok
  defp kill_epmd do
    case epmd_pids() do
      [] ->
        :ok

      pids ->
        Enum.each(pids, fn pid ->
          _ = System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
        end)

        Process.sleep(150)
        :ok
    end
  rescue
    _ -> :ok
  end

  # PIDs of the process(es) LISTENING on the EPMD port (`ERL_EPMD_PORT` or the
  # 4369 default). Uses `lsof` (present on Linux + macOS, glorbo's targets);
  # returns [] if lsof is absent or nothing is listening, so the caller degrades
  # safely (no kill, falls back to the collision message).
  @spec epmd_pids() :: [pos_integer()]
  defp epmd_pids do
    port = System.get_env("ERL_EPMD_PORT") || "4369"

    case System.cmd("lsof", ["-t", "-i", "tcp:#{port}", "-sTCP:LISTEN"], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split()
        |> Enum.flat_map(fn s ->
          case Integer.parse(s) do
            {n, ""} when n > 0 -> [n]
            _ -> []
          end
        end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # Parse `epmd -names` output into `[{name, port}]`. Public for unit-testing
  # the parser against captured EPMD output. Example line:
  #   "name glorbo-ab12cd34 at port 43783"
  @doc false
  @spec parse_names(binary()) :: [{String.t(), non_neg_integer()}]
  def parse_names(output) when is_binary(output) do
    ~r/^name\s+(\S+)\s+at\s+port\s+(\d+)/m
    |> Regex.scan(output)
    |> Enum.map(fn [_, name, port] -> {name, String.to_integer(port)} end)
  end

  # Query the local EPMD for registered names via the bundled `epmd -names`
  # (reliable + distribution-free — `:erl_epmd.names/1` is finicky about its
  # host argument before net_kernel is up). Returns [] on any failure.
  @spec epmd_names() :: [{String.t(), non_neg_integer()}]
  defp epmd_names do
    case System.cmd(epmd_bin(), ["-names"], stderr_to_stdout: true) do
      {out, 0} -> parse_names(out)
      _ -> []
    end
  rescue
    _ -> []
  end

  # Burrito ships ERTS but not a running EPMD. If none is listening on
  # port 4369 yet, `Node.start(_, :longnames)` crashes with `econnrefused`
  # ~100ms after start. Spawn the daemon ourselves — epmd refuses to
  # double-bind, so this is idempotent. Erlang ships `epmd` next to the current
  # ERTS binary; if it isn't there we refuse to spawn rather than fall back to
  # PATH (a PATH search would let an attacker plant a malicious `epmd` earlier
  # in PATH and hijack execution before `Node.start/2`).
  defp ensure_epmd do
    epmd = epmd_bin()

    if File.exists?(epmd) do
      _ = System.cmd(epmd, ["-address", "127.0.0.1", "-daemon"], stderr_to_stdout: true)
      :ok
    else
      :no_bundled_epmd
    end
  rescue
    _ -> :ok
  end

  # Path to the EPMD shipped next to the current ERTS. Never falls back to a
  # PATH lookup (an attacker could plant a malicious `epmd` earlier in PATH).
  @spec epmd_bin() :: Path.t()
  defp epmd_bin do
    Path.join(
      :code.root_dir() |> to_string() |> Path.join("erts-#{:erlang.system_info(:version)}"),
      "bin/epmd"
    )
  end

  @doc """
  This instance's canonical node name — `glorbo-<node_id>@127.0.0.1` (GEP-62),
  resolving `node_id` from `<base>/config.md`. Falls back to the legacy fixed
  `glorbo@127.0.0.1` if config can't be read. Stable for a given home so
  `up` / `down` / `status` / `console` all agree.
  """
  @spec canonical_node(Path.t()) :: atom()
  def canonical_node(base \\ Hierarchy.default_root()) do
    case Config.node_id(base) do
      # `Node.start/2` requires an atom node name, built at runtime from
      # `node_id` — glorbo-minted, validated `[a-z0-9_-]+` in `Config`, bounded
      # (one stable id per install / operator-owned config.md), and NOT
      # request-derived, so the atom table can't be exhausted (distinct from
      # the GEP-12 user-input-atom DoS). Sobelow DOS.BinToAtom is ignored in
      # `.sobelow-conf` (documented there); Credo UnsafeToAtom disabled inline.
      # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
      {:ok, id} -> :"glorbo-#{id}@127.0.0.1"
      _ -> @fallback_node
    end
  end

  # The "alive" part (before `@`) of a node name, as a String, for EPMD lookups.
  @spec alive_name_of(atom()) :: String.t()
  defp alive_name_of(node) do
    node |> Atom.to_string() |> String.split("@") |> hd()
  end
end
