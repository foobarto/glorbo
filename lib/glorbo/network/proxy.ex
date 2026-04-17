defmodule Glorbo.Network.Proxy do
  @moduledoc """
  HTTPS CONNECT allowlist proxy for `network: api-only` agents (D-17;
  SEC-03; T-03-33; advisory-only per T-03-34 / Pitfall 7).

  A small (~150 LOC target) OTP-native proxy that accepts HTTPS CONNECT
  tunnels to a hostname allowlist and rejects everything else. One proxy
  per company, listening on an ephemeral port. The port is passed via
  `HTTPS_PROXY` env into the sandbox (RESEARCH Pattern — sambaiz.net
  Claude Code sandbox reference).

  ## Why custom + OTP-native (not TinyProxy)

  TinyProxy's `FilterDefaultDeny` only covers plain HTTP — its filter does
  not inspect HTTPS CONNECT tunnel hostnames. Since all three supported CLI
  tools use HTTPS exclusively, tinyproxy would be a no-op. Mitmproxy-style
  TLS interception is off the table (it breaks cert pinning + OAuth
  flows). This custom proxy parses the CONNECT line itself, validates the
  hostname against an allowlist, then opens an upstream socket and splices
  bytes bidirectionally — no TLS termination, no payload inspection.

  ## Threat model (T-03-33, T-03-34)

    * **Mitigated:** hostname spoofing (exact-match, case-folded).
    * **Mitigated:** method abuse (CONNECT-only — 405 for GET/POST/etc).
    * **Mitigated:** port abuse (443-only; plain HTTP on :80 is rejected).
    * **Accepted (advisory):** HTTPS_PROXY env var bypass. A motivated
      agent ignoring the env var (e.g. `curl --noproxy '*'`) reaches the
      internet directly via the host netns. Users needing hard egress
      control should pick `network: none` (kernel-enforced).
      netns+nftables is the hardening iteration (deferred).

  ## Allowlist composition

  Base list from `config/network_policy.exs` (Plan 03-02):

      config :glorbo, :network_policy, %{
        api_only_base_allowlist: %{
          "claude-code" => ~w(api.anthropic.com ...),
          "gemini-cli" => ~w(generativelanguage.googleapis.com ...),
          "codex"      => ~w(api.openai.com ...)
        }
      }

  At proxy init, the base list is union'd across all providers (v0.0.1
  ships a single per-company proxy serving all agents). Per-company
  override via `companies/<co>/company.md`'s `network_allow:` field is
  supported — implemented at init via the dep-injected `:allowlist_fun`.
  """
  use GenServer

  require Logger

  @type start_opts :: [
          name: GenServer.name(),
          company: String.t(),
          port: non_neg_integer(),
          allowlist_fun: (String.t() -> [String.t()]),
          task_supervisor: GenServer.name() | pid()
        ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Return the actually-bound port (after ephemeral assignment by the OS).
  """
  @spec port(GenServer.server()) :: pos_integer()
  def port(server), do: GenServer.call(server, :port)

  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.get(opts, :company, "_unknown")
    requested_port = Keyword.get(opts, :port, 0)

    allowlist_fun =
      Keyword.get(opts, :allowlist_fun, fn _co ->
        default_allowlist()
      end)

    allowlist = allowlist_fun.(company) |> Enum.map(&String.downcase/1) |> MapSet.new()

    {:ok, listen_sock} =
      :gen_tcp.listen(requested_port, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    # Prefer a supervisor-wired sibling Task.Supervisor. When none is
    # injected, start one we own ourselves so the Proxy remains usable
    # standalone (test paths + early-integration callers). Owned task_sups
    # are unlinked (so the Proxy's own terminate doesn't receive their
    # shutdown EXIT) and explicitly stopped in terminate/2 to avoid leaking
    # tunnel tasks.
    {task_sup, owns_task_sup?} =
      case Keyword.get(opts, :task_supervisor) do
        nil ->
          {:ok, ts} = Task.Supervisor.start_link()
          true = Process.unlink(ts)
          {ts, true}

        ts ->
          {ts, false}
      end

    acceptor_ref = start_acceptor(listen_sock, allowlist, task_sup)

    {:ok, bound_port} = :inet.port(listen_sock)

    {:ok,
     %{
       company: company,
       allowlist: allowlist,
       listen_sock: listen_sock,
       task_sup: task_sup,
       owns_task_sup?: owns_task_sup?,
       acceptor_ref: acceptor_ref,
       port: bound_port
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def terminate(_reason, state) do
    _ = safe_close(state.listen_sock)

    # When we spawned the Task.Supervisor ourselves, stop it explicitly so
    # any in-flight tunnel tasks are torn down (and their sockets closed)
    # instead of being abandoned as orphans.
    if state.owns_task_sup? and is_pid(state.task_sup) and Process.alive?(state.task_sup) do
      _ =
        try do
          Supervisor.stop(state.task_sup, :shutdown, 1_000)
        catch
          :exit, _ -> :ok
        end
    end

    :ok
  end

  # Acceptor died: re-arm it so the proxy keeps serving new connections.
  # This is the observable failure mode flagged by CR-02; without re-arming,
  # a tunnel-task crash that cascaded through the Task.Supervisor silently
  # stopped new-connection handling with no indication to the operator.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{acceptor_ref: ref} = state) do
    if reason not in [:normal, :shutdown, {:shutdown, :closed}] do
      Logger.warning("[network.proxy] acceptor died: #{inspect(reason)} — restarting acceptor")
    end

    new_ref = start_acceptor(state.listen_sock, state.allowlist, state.task_sup)
    {:noreply, %{state | acceptor_ref: new_ref}}
  end

  # Tunnel-task :DOWN — log abnormal exits so proxy failures are observable.
  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    if reason not in [:normal, :shutdown] do
      Logger.debug("[network.proxy] tunnel task exited: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Task result messages from async_nolink — discard.
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # Spawn the acceptor task under the Task.Supervisor using async_nolink so a
  # crash reaches us as a :DOWN (instead of an EXIT that would kill the
  # GenServer). Returns the ref we monitor for re-arming.
  defp start_acceptor(listen_sock, allowlist, task_sup) do
    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        accept_loop(listen_sock, allowlist, task_sup)
      end)

    task.ref
  end

  # ---------------------------------------------------------------------------
  # Acceptor loop
  # ---------------------------------------------------------------------------

  defp accept_loop(listen_sock, allowlist, task_sup) do
    case :gen_tcp.accept(listen_sock) do
      {:ok, client_sock} ->
        # async_nolink — a crash in handle_connection reaches the Proxy as a
        # :DOWN (logged + discarded). start_child used to link the failure to
        # the Task.Supervisor itself (see CR-02), which could cascade to the
        # acceptor and silently kill new-connection handling.
        _task =
          Task.Supervisor.async_nolink(task_sup, fn ->
            handle_connection(client_sock, allowlist, task_sup)
          end)

        accept_loop(listen_sock, allowlist, task_sup)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("[network.proxy] accept failed: #{inspect(reason)} — exiting loop")
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Connection handler
  # ---------------------------------------------------------------------------

  defp handle_connection(client_sock, allowlist, task_sup) do
    case read_request_head(client_sock, <<>>) do
      {:ok, head} ->
        dispatch_request(head, client_sock, allowlist, task_sup)

      {:error, reason} ->
        Logger.debug("[network.proxy] read_request_head failed: #{inspect(reason)}")
        safe_close(client_sock)
    end
  end

  # Read until "\r\n\r\n" or the 16KB cap. The guard is on cumulative
  # `acc` size and fires on every recursive call (not just the first) —
  # a slow-drip chunking attack can only append until the running total
  # exceeds the cap, at which point the next recursion rejects. Bounded
  # at 16KB regardless of chunk size.
  defp read_request_head(_sock, acc) when byte_size(acc) >= 16_384 do
    Logger.debug("[network.proxy] request head > 16KB — rejecting")
    {:error, :too_large}
  end

  defp read_request_head(sock, acc) do
    case :gen_tcp.recv(sock, 0, 5_000) do
      {:ok, chunk} ->
        new_acc = acc <> chunk

        if String.contains?(new_acc, "\r\n\r\n") do
          {:ok, new_acc}
        else
          read_request_head(sock, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_request(head, client_sock, allowlist, task_sup) do
    [first_line | _rest] = String.split(head, "\r\n", parts: 2)

    case parse_connect_line(first_line) do
      {:ok, host, port} ->
        evaluate_and_tunnel(host, port, client_sock, allowlist, task_sup)

      {:error, :not_connect} ->
        write_response(client_sock, "HTTP/1.1 405 Method Not Allowed\r\n\r\n")
        safe_close(client_sock)

      {:error, :malformed} ->
        write_response(client_sock, "HTTP/1.1 400 Bad Request\r\n\r\n")
        safe_close(client_sock)
    end
  end

  # "CONNECT host:port HTTP/1.1"
  defp parse_connect_line("CONNECT " <> rest) do
    with [host_port, _http_version] <- String.split(rest, " ", parts: 2),
         [host, port_str] when host != "" <- String.split(host_port, ":", parts: 2),
         {port, ""} when port > 0 and port <= 65_535 <- Integer.parse(port_str) do
      {:ok, String.downcase(host), port}
    else
      _ -> {:error, :malformed}
    end
  end

  defp parse_connect_line(_), do: {:error, :not_connect}

  defp evaluate_and_tunnel(host, port, client_sock, allowlist, task_sup) do
    cond do
      port != 443 ->
        Logger.info("[network.proxy] reject non-443 CONNECT host=#{host} port=#{port}")
        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      not MapSet.member?(allowlist, host) ->
        Logger.info("[network.proxy] reject host-not-in-allowlist host=#{host}")
        write_response(client_sock, "HTTP/1.1 403 Forbidden\r\n\r\n")
        safe_close(client_sock)

      true ->
        open_and_splice(host, port, client_sock, task_sup)
    end
  end

  defp open_and_splice(host, port, client_sock, task_sup) do
    case :gen_tcp.connect(
           String.to_charlist(host),
           port,
           [:binary, packet: :raw, active: false],
           5_000
         ) do
      {:ok, upstream_sock} ->
        write_response(client_sock, "HTTP/1.1 200 Connection Established\r\n\r\n")
        relay_bytes(client_sock, upstream_sock, task_sup)

      {:error, reason} ->
        Logger.info("[network.proxy] upstream connect failed host=#{host}: #{inspect(reason)}")
        write_response(client_sock, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
        safe_close(client_sock)
    end
  end

  # Bidirectional byte relay via two supervised tasks. Using async_nolink
  # (TODO.md Critical #3) so a pipe-task crash doesn't :EXIT-kill its
  # parent handler and leak the remaining socket. On timeout or either
  # side completing, we Task.shutdown both — :brutal_kill guarantees the
  # :gen_tcp owners are gone before we close, preventing leaked FDs
  # under concurrent-recv races.
  defp relay_bytes(client_sock, upstream_sock, task_sup) do
    caller = self()

    t1 =
      Task.Supervisor.async_nolink(task_sup, fn ->
        pipe(client_sock, upstream_sock)
        send(caller, {:pipe_done, :cu})
      end)

    t2 =
      Task.Supervisor.async_nolink(task_sup, fn ->
        pipe(upstream_sock, client_sock)
        send(caller, {:pipe_done, :uc})
      end)

    receive do
      {:pipe_done, _} -> :ok
    after
      600_000 -> :ok
    end

    _ = Task.shutdown(t1, :brutal_kill)
    _ = Task.shutdown(t2, :brutal_kill)

    safe_close(client_sock)
    safe_close(upstream_sock)
  end

  defp pipe(src, dst) do
    case :gen_tcp.recv(src, 0, 60_000) do
      {:ok, data} ->
        case :gen_tcp.send(dst, data) do
          :ok -> pipe(src, dst)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp write_response(sock, payload), do: _ = :gen_tcp.send(sock, payload)
  defp safe_close(sock), do: _ = :gen_tcp.close(sock)

  # ---------------------------------------------------------------------------
  # Allowlist default
  # ---------------------------------------------------------------------------

  defp default_allowlist do
    config = Application.get_env(:glorbo, :network_policy, %{})

    base =
      case Map.get(config, :api_only_base_allowlist) do
        %{} = by_provider -> by_provider |> Map.values() |> List.flatten()
        _ -> []
      end

    Enum.uniq(base)
  end
end
