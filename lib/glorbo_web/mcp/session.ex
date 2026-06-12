defmodule GlorboWeb.MCP.Session do
  @moduledoc """
  Per-client MCP session state (GEP-29 wave d.2).

  One `Session` GenServer per `Mcp-Session-Id`. Owns:

    * the set of resource URIs the client has subscribed to,
    * Phoenix.PubSub subscriptions that feed change events for those
      URIs,
    * the optional SSE stream pid the plug opened for this session.

  The Session is the bridge between filesystem change events (emitted
  by `Glorbo.Filesystem.Watcher` and `Glorbo.Company.AuditLog` on
  `Glorbo.PubSub`) and the MCP client's SSE stream. When an event
  arrives for a subscribed URI, the session translates it to a
  `notifications/resources/updated` JSON-RPC notification and sends it
  to the attached SSE process, if any. If no stream is attached, the
  notification is dropped — clients can always call `resources/read`
  to re-fetch the current snapshot.

  ## Lifecycle

    * `start_session/2` — called from the plug's `initialize`
      handler. Returns `{:ok, session_id}`.
    * `attach_sse/2` — called from the plug's GET handler once the
      SSE stream has opened. The session `Process.monitor/1`s the pid
      so it detaches automatically on client disconnect.
    * `subscribe/2` / `unsubscribe/2` — called from the JSON-RPC
      dispatch path when the client invokes `resources/subscribe` /
      `resources/unsubscribe`.
    * `terminate_session/1` — called from the plug's DELETE handler
      or when the supervisor decides to shed state.

  ## URI → PubSub topic map

  | URI family                         | PubSub topic                    |
  |------------------------------------|---------------------------------|
  | `glorbo://audit/<co>`              | `company:<co>:audit`            |
  | `glorbo://approvals/<co>`          | `company:<co>:projects`         |
  | `glorbo://proposals/<co>`          | `company:<co>:proposals`        |
  | `glorbo://chat/<co>/<ch>`          | `company:<co>:channels:<ch>`    |

  Audit events are broadcast by `Glorbo.Company.AuditLog`; the other
  three families are broadcast by `Glorbo.Filesystem.Watcher` on
  filesystem change. Either way, the payload is ignored — we just
  push `notifications/resources/updated` so the client re-reads the
  snapshot.
  """
  # `restart: :temporary` is load-bearing. DynamicSupervisor's default
  # is `:permanent`, which restarts the child on *any* exit — including
  # the `:normal` one we send from `terminate_session/1`. A restarted
  # session would be a zombie: same Mcp-Session-Id, no client ever
  # knew about it. MCP sessions are strictly client-owned; once the
  # client DELETEs, the session stays gone.
  use GenServer, restart: :temporary

  alias GlorboWeb.MCP.Resources

  @registry GlorboWeb.MCP.SessionRegistry
  @supervisor GlorboWeb.MCP.SessionSupervisor
  @pubsub Glorbo.PubSub

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a new session. Generates a fresh session id and registers
  the GenServer under it in `GlorboWeb.MCP.SessionRegistry`.

  `opts` mirrors the plug's per-request context:

    * `:client` — `mcp:<slug>` actor string (informational)
    * `:base`   — `~/.glorbo` root, used by the Session if it ever
      needs to read filesystem state directly.
    * `:idle_timeout_ms` — idle reap window while no SSE stream is
      attached (default: 5 minutes).
  """
  @spec start_session(map()) :: {:ok, String.t()} | {:error, term()}
  def start_session(opts \\ %{}) do
    session_id = new_session_id()

    child_spec = {__MODULE__, Map.put(opts, :session_id, session_id)}

    case DynamicSupervisor.start_child(@supervisor, child_spec) do
      {:ok, _pid} -> {:ok, session_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Subscribe the session to a resource URI. Parses the URI, then
  subscribes to the matching `Glorbo.PubSub` topic (idempotent per
  topic: re-subscribing does nothing).

  Returns `:ok` on success, `{:error, reason}` if the URI is not one
  we know how to observe (wave d.2 only covers the families listed in
  the moduledoc).
  """
  @spec subscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def subscribe(session_id, uri) when is_binary(uri) do
    call(session_id, {:subscribe, uri})
  end

  @doc """
  Drop a subscription. Idempotent — unknown URIs return `:ok`.
  """
  @spec unsubscribe(String.t(), String.t()) :: :ok | {:error, term()}
  def unsubscribe(session_id, uri) when is_binary(uri) do
    call(session_id, {:unsubscribe, uri})
  end

  @doc """
  Attach an SSE stream process to the session. Replaces any
  previously-attached pid (one stream per session). The session
  monitors the pid and auto-detaches on `:DOWN`.
  """
  @spec attach_sse(String.t(), pid()) :: :ok | {:error, :unknown_session}
  def attach_sse(session_id, pid) when is_pid(pid) do
    call(session_id, {:attach_sse, pid})
  end

  @doc """
  Detach an SSE stream pid. No-op if the stored pid differs — lets
  the SSE loop call this on exit without racing against a newer
  stream.
  """
  @spec detach_sse(String.t(), pid()) :: :ok | {:error, :unknown_session}
  def detach_sse(session_id, pid) when is_pid(pid) do
    call(session_id, {:detach_sse, pid})
  end

  @doc """
  Stop a session and unsubscribe all of its PubSub topics. Called on
  DELETE /mcp or when the client disconnects permanently.
  """
  @spec terminate_session(String.t()) :: :ok
  def terminate_session(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] ->
        stop_session(pid)

      [] ->
        :ok
    end

    :ok
  end

  # `GenServer.stop/3` exits the caller with `:noproc` if the pid
  # died between the Registry lookup and the stop call. Swallow it —
  # the session is effectively terminated either way.
  defp stop_session(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @doc """
  Introspection helper for tests: returns the current subscribed
  URIs for a session. `[]` for unknown sessions so test teardowns
  don't need to guard against a missing process.
  """
  @spec subscribed_uris(String.t()) :: [String.t()]
  def subscribed_uris(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> subscribed_uris_call(pid)
      [] -> []
    end
  end

  @doc """
  Returns true if the session exists. Used by the plug to validate
  the `Mcp-Session-Id` header on subsequent requests.
  """
  @spec exists?(String.t()) :: boolean()
  def exists?(session_id) do
    # A round-trip ping is the only race-free liveness check: `Registry
    # + Process.alive?` reports true for a just-exited pid until the
    # Registry's :DOWN handler runs. A synchronous `GenServer.call` either
    # returns or exits — the try/catch translates the exit into `false`.
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> alive_ping?(pid)
      [] -> false
    end
  end

  defp alive_ping?(pid) do
    GenServer.call(pid, :ping, 1_000)
    true
  catch
    :exit, _ -> false
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts) do
    session_id = Map.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via(session_id))
  end

  # Threatmodel T5: sessions are client-owned, but the server still
  # needs to reap abandoned ones when the client never sends DELETE.
  # Five minutes is generous for editor reconnects and human-driven
  # pauses, while still guaranteeing a dead local client cannot pin the
  # full session pool indefinitely.
  @default_idle_timeout_ms 5 * 60 * 1_000

  @impl true
  def init(opts) do
    state =
      %{
        session_id: Map.fetch!(opts, :session_id),
        client: Map.get(opts, :client, "unknown"),
        base: Map.get(opts, :base),
        subscribed_uris: MapSet.new(),
        topics: %{},
        sse_pid: nil,
        sse_monitor_ref: nil,
        idle_timeout_ms:
          normalise_idle_timeout(Map.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)),
        idle_token: nil,
        idle_timer_ref: nil
      }
      |> schedule_idle_timeout()

    {:ok, state}
  end

  # Threatmodel T5: cap per-session subscriptions so a single client
  # can't accumulate unbounded PubSub topic handlers by spamming
  # resources/subscribe. 64 is generous for legitimate workflows
  # (a resource tree tracking a company's agents + projects + channels
  # rarely exceeds ~20 URIs) and bounds the blast radius if a client
  # loops on subscribe.
  @max_subscriptions_per_session 64

  @impl true
  def handle_call({:subscribe, uri}, _from, state) do
    cond do
      MapSet.member?(state.subscribed_uris, uri) ->
        # Idempotent: already subscribed, no-op.
        {:reply, :ok, touch(state)}

      MapSet.size(state.subscribed_uris) >= @max_subscriptions_per_session ->
        {:reply, {:error, :subscription_cap_reached}, touch(state)}

      true ->
        case uri_to_topic(uri) do
          {:ok, topic} ->
            {:reply, :ok, state |> add_subscription(uri, topic) |> touch()}

          {:error, reason} ->
            {:reply, {:error, reason}, touch(state)}
        end
    end
  end

  def handle_call({:unsubscribe, uri}, _from, state) do
    {:reply, :ok, state |> drop_subscription(uri) |> touch()}
  end

  def handle_call({:attach_sse, pid}, _from, state) do
    state =
      state
      |> cancel_idle_timeout()
      |> demonitor_sse()
      |> Map.put(:sse_pid, pid)
      |> Map.put(:sse_monitor_ref, Process.monitor(pid))

    {:reply, :ok, state}
  end

  def handle_call({:detach_sse, pid}, _from, %{sse_pid: pid} = state) do
    {:reply, :ok, state |> demonitor_sse() |> Map.put(:sse_pid, nil) |> schedule_idle_timeout()}
  end

  def handle_call({:detach_sse, _other}, _from, state) do
    {:reply, :ok, touch(state)}
  end

  def handle_call(:subscribed_uris, _from, state) do
    {:reply, state.subscribed_uris |> MapSet.to_list() |> Enum.sort(), touch(state)}
  end

  def handle_call(:ping, _from, state), do: {:reply, :pong, touch(state)}

  @impl true
  def handle_info({:file_event, rel, _events}, state) do
    # Narrow the notification to URIs whose family matches the event
    # shape. Without this filter, a chat message would also fire a
    # notifications/resources/updated for the session's audit
    # subscription, which isn't what `notifications/resources/updated`
    # means in the spec.
    notify_for_file_event(state, rel)
    {:noreply, state}
  end

  def handle_info({:audit_append, _record}, state) do
    # Audit broadcasts only touch audit resources — notify only URIs
    # under the `glorbo://audit/` family.
    notify_matching(state, &String.starts_with?(&1, "glorbo://audit/"))
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{sse_monitor_ref: ref} = state) do
    if state.sse_pid == pid do
      {:noreply,
       state
       |> demonitor_sse()
       |> Map.put(:sse_pid, nil)
       |> schedule_idle_timeout()}
    else
      {:noreply, state}
    end
  end

  def handle_info({:idle_timeout, token}, %{idle_token: token, sse_pid: nil} = state) do
    {:stop, :normal, cancel_idle_timeout(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Unsubscribe from every PubSub topic we held, so the topic
    # doesn't accumulate dead subscribers after repeated
    # connect/disconnect cycles.
    Enum.each(Map.keys(state.topics), &Phoenix.PubSub.unsubscribe(@pubsub, &1))
    :ok
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp via(session_id), do: {:via, Registry, {@registry, session_id}}

  # Same race as terminate_session/1: the pid can die between the
  # Registry lookup and the call. Translate `:noproc`/`:shutdown` into
  # the same `{:error, :unknown_session}` the `[]` branch returns so
  # callers see consistent behavior.
  defp call(session_id, msg) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> safe_call(pid, msg)
      [] -> {:error, :unknown_session}
    end
  end

  defp safe_call(pid, msg) do
    GenServer.call(pid, msg)
  catch
    :exit, {:noproc, _} -> {:error, :unknown_session}
    :exit, {:shutdown, _} -> {:error, :unknown_session}
  end

  defp subscribed_uris_call(pid) do
    GenServer.call(pid, :subscribed_uris)
  catch
    :exit, {:noproc, _} -> []
    :exit, {:shutdown, _} -> []
  end

  defp add_subscription(state, uri, topic) do
    # Re-subscribing a URI is a no-op — incrementing the topic refcount
    # on a duplicate would leak the PubSub subscription because the
    # matching unsubscribe cannot observe the duplicate to decrement it
    # twice.
    if MapSet.member?(state.subscribed_uris, uri) do
      state
    else
      subscribed = MapSet.put(state.subscribed_uris, uri)

      # Track how many URIs point at a given topic so we don't
      # unsubscribe the shared topic until the last URI referencing it
      # goes away.
      {topics, newly_subscribed?} =
        case Map.fetch(state.topics, topic) do
          {:ok, n} -> {Map.put(state.topics, topic, n + 1), false}
          :error -> {Map.put(state.topics, topic, 1), true}
        end

      if newly_subscribed?, do: :ok = Phoenix.PubSub.subscribe(@pubsub, topic)

      %{state | subscribed_uris: subscribed, topics: topics}
    end
  end

  defp drop_subscription(state, uri) do
    if MapSet.member?(state.subscribed_uris, uri) do
      case uri_to_topic(uri) do
        {:ok, topic} ->
          subscribed = MapSet.delete(state.subscribed_uris, uri)

          {topics, last?} =
            case Map.fetch(state.topics, topic) do
              {:ok, 1} -> {Map.delete(state.topics, topic), true}
              {:ok, n} -> {Map.put(state.topics, topic, n - 1), false}
              :error -> {state.topics, false}
            end

          if last?, do: Phoenix.PubSub.unsubscribe(@pubsub, topic)
          %{state | subscribed_uris: subscribed, topics: topics}

        _ ->
          %{state | subscribed_uris: MapSet.delete(state.subscribed_uris, uri)}
      end
    else
      state
    end
  end

  defp demonitor_sse(%{sse_monitor_ref: nil} = state), do: state

  defp demonitor_sse(%{sse_monitor_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | sse_monitor_ref: nil}
  end

  defp touch(%{sse_pid: nil} = state), do: schedule_idle_timeout(state)
  defp touch(state), do: state

  defp schedule_idle_timeout(%{idle_timeout_ms: nil} = state), do: state

  # Invariant: an idle timeout is only ever scheduled on a non-SSE session —
  # touch/1 guards on `sse_pid: nil`, and detach_sse/the DOWN handler clear
  # `sse_pid` before calling. An SSE-attached session never idle-times-out.
  defp schedule_idle_timeout(state) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:idle_timeout, token}, state.idle_timeout_ms)

    state
    |> cancel_idle_timeout()
    |> Map.put(:idle_token, token)
    |> Map.put(:idle_timer_ref, timer_ref)
  end

  defp cancel_idle_timeout(%{idle_timer_ref: nil} = state), do: %{state | idle_token: nil}

  defp cancel_idle_timeout(%{idle_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | idle_token: nil, idle_timer_ref: nil}
  end

  defp normalise_idle_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: timeout_ms

  defp normalise_idle_timeout(_), do: nil

  defp notify_matching(%{sse_pid: nil}, _filter), do: :ok

  defp notify_matching(%{sse_pid: pid, subscribed_uris: uris}, filter) do
    Enum.each(uris, fn uri ->
      if filter.(uri) do
        send(pid, {:mcp_notification, "notifications/resources/updated", %{"uri" => uri}})
      end
    end)
  end

  # `rel` is the filesystem path from the watcher — e.g.
  # `"channels/general.md"` or `"proposals/hire-writer.md"`. Map the
  # path prefix back to a URI family and, where possible (channels),
  # narrow further by the actual filename so an unrelated channel's
  # event doesn't notify subscribers of a different channel.
  defp notify_for_file_event(state, rel) do
    cond do
      String.starts_with?(rel, "channels/") ->
        case Path.split(rel) do
          ["channels", filename] ->
            ch = Path.basename(filename, ".md")

            notify_matching(state, fn uri ->
              String.starts_with?(uri, "glorbo://chat/") and String.ends_with?(uri, "/" <> ch)
            end)

          _ ->
            :ok
        end

      String.starts_with?(rel, "proposals/") ->
        notify_matching(state, &String.starts_with?(&1, "glorbo://proposals/"))

      String.starts_with?(rel, "projects/") ->
        notify_matching(state, &String.starts_with?(&1, "glorbo://approvals/"))

      true ->
        :ok
    end
  end

  defp new_session_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  # URI → PubSub topic. Keep in sync with Resources.parse_uri.
  defp uri_to_topic(uri) do
    cond do
      String.starts_with?(uri, "glorbo://audit/") ->
        company_topic(uri, "glorbo://audit/", "audit")

      String.starts_with?(uri, "glorbo://approvals/") ->
        company_topic(uri, "glorbo://approvals/", "projects")

      String.starts_with?(uri, "glorbo://proposals/") ->
        company_topic(uri, "glorbo://proposals/", "proposals")

      String.starts_with?(uri, "glorbo://chat/") ->
        chat_topic(uri)

      true ->
        {:error, :unsupported_uri_scheme}
    end
  end

  defp company_topic(uri, prefix, topic_suffix) do
    rest = String.replace_prefix(uri, prefix, "")

    with {:ok, co} <- one_segment(rest),
         true <- Resources.valid_segment?(co) do
      {:ok, "company:#{co}:#{topic_suffix}"}
    else
      _ -> {:error, :invalid_uri}
    end
  end

  defp chat_topic(uri) do
    rest = String.replace_prefix(uri, "glorbo://chat/", "")

    case String.split(rest, "/", parts: 2) do
      [co, ch] ->
        if Resources.valid_segment?(co) and Resources.valid_segment?(ch),
          do: {:ok, "company:#{co}:channels:#{ch}"},
          else: {:error, :invalid_uri}

      _ ->
        {:error, :invalid_uri}
    end
  end

  defp one_segment(value) do
    case String.split(value, "/", parts: 2) do
      [segment] -> {:ok, segment}
      _ -> {:error, :extra_segments}
    end
  end
end
