defmodule Glorbo.PathRequestGate do
  @moduledoc """
  Per-company GenServer managing the lifecycle of agent path-access
  requests (GEP-27).

  Flow:
    1. **Request** — Router classifies an outbox `path-request-*.md`
       file and calls `handle_request/3`. Gate validates the request,
       writes a pending sentinel, and emits `path_access.requested`.
    2. **Approve** — Director approves via UI (`approve/4`). Gate
       writes the grant to `PathGrantStore`, archives the request,
       and emits `path_access.approved`.
    3. **Deny** — Director denies (`deny/3`). Gate archives the
       request, notifies the agent via inbox, and emits
       `path_access.denied`.
    4. **Revoke** — After dispatch completes, the dispatch pipeline
       calls `revoke/3` to remove the grant from ETS and emit
       `path_access.revoked`.

  Sentinel files:
    - Request: `agents/<slug>/outbox/path-request-<task_id>.md` (agent-written)
    - Pending: `agents/<slug>/state/path-pending-<task_id>-<seq>.md` (gate-written)

  State is minimal — the filesystem is the source of truth. On
  restart, pending sentinels are re-scanned from disk.
  """
  use GenServer

  require Logger

  alias Glorbo.PathGrantStore

  @pending_regex ~r{\Apath-pending-[a-z0-9][a-z0-9-]*-[0-9]+\.md\z}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start a per-company PathRequestGate.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Handle a new path request from an agent's outbox.

  Validates the request shape, writes a pending sentinel, and emits
  an audit event. Returns `:ok` or `{:error, reason}`.
  """
  @spec handle_request(String.t(), String.t(), map(), keyword()) :: :ok | {:error, term()}
  def handle_request(company, agent_slug, request_meta, opts \\ []) do
    GenServer.call(via(company), {:handle_request, agent_slug, request_meta, opts})
  end

  @doc """
  Approve a pending path request. The director can modify the granted
  paths (downgrade write→read, remove paths).

  `granted_paths` is a list of `%{path: ..., mode: :read | :write}`.
  """
  @spec approve(String.t(), String.t(), String.t(), [map()], keyword()) :: :ok | {:error, term()}
  def approve(company, agent_slug, task_id, granted_paths, opts \\ []) do
    GenServer.call(via(company), {:approve, agent_slug, task_id, granted_paths, opts})
  end

  @doc """
  Deny a pending path request.
  """
  @spec deny(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def deny(company, agent_slug, task_id, opts \\ []) do
    GenServer.call(via(company), {:deny, agent_slug, task_id, opts})
  end

  @doc """
  Revoke a granted path access after dispatch completes.
  """
  @spec revoke(String.t(), String.t(), String.t(), keyword()) :: :ok
  def revoke(company, agent_slug, task_id, opts \\ []) do
    GenServer.call(via(company), {:revoke, agent_slug, task_id, opts})
  end

  @doc """
  List pending requests for an agent.
  """
  @spec list_pending(String.t(), String.t()) :: [map()]
  def list_pending(company, agent_slug) do
    GenServer.call(via(company), {:list_pending, agent_slug})
  end

  @doc """
  List all pending requests for a company.
  """
  @spec list_all_pending(String.t()) :: [map()]
  def list_all_pending(company) do
    GenServer.call(via(company), {:list_all_pending})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    company = Keyword.fetch!(opts, :company)
    base = Keyword.fetch!(opts, :base)
    audit_server = Keyword.get(opts, :audit_server, Glorbo.Company.AuditLog)

    state = %{
      company: company,
      base: base,
      audit_server: audit_server
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:handle_request, agent_slug, meta, _opts}, _from, state) do
    result = do_handle_request(agent_slug, meta, state)
    audit_result(result, state)
    {:reply, result, state}
  end

  def handle_call({:approve, agent_slug, task_id, granted_paths, _opts}, _from, state) do
    result = do_approve(agent_slug, task_id, granted_paths, state)
    audit_result(result, state)
    {:reply, result, state}
  end

  def handle_call({:deny, agent_slug, task_id, _opts}, _from, state) do
    result = do_deny(agent_slug, task_id, state)
    audit_result(result, state)
    {:reply, result, state}
  end

  def handle_call({:revoke, agent_slug, task_id, _opts}, _from, state) do
    PathGrantStore.revoke(state.company, agent_slug, task_id)

    emit_audit(state, "path_access.revoked", "agent:#{agent_slug}", %{
      task_id: task_id,
      agent: agent_slug
    })

    {:reply, :ok, state}
  end

  def handle_call({:list_pending, agent_slug}, _from, state) do
    pending = scan_pending_sentinels(state, agent_slug)
    {:reply, pending, state}
  end

  def handle_call({:list_all_pending}, _from, state) do
    pending = scan_all_pending_sentinels(state)
    {:reply, pending, state}
  end

  # ---------------------------------------------------------------------------
  # Core logic
  # ---------------------------------------------------------------------------

  defp do_handle_request(agent_slug, meta, state) do
    with :ok <- validate_request(meta),
         :ok <- ensure_state_dir(agent_slug, state),
         sentinel_path <- build_pending_sentinel_path(agent_slug, meta.task_id, state),
         :ok <- write_pending_sentinel(sentinel_path, meta, agent_slug, state) do
      emit_audit(state, "path_access.requested", "agent:#{agent_slug}", %{
        task_id: meta.task_id,
        agent: agent_slug,
        paths: meta.paths,
        reason: meta.reason
      })

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_approve(agent_slug, task_id, granted_paths, state) do
    with {:ok, _sentinel} <- find_pending_sentinel(agent_slug, task_id, state),
         :ok <- validate_granted_paths(granted_paths),
         :ok <- write_grant(agent_slug, task_id, granted_paths, state),
         :ok <- archive_request(agent_slug, task_id, state) do
      emit_audit(state, "path_access.approved", "director", %{
        task_id: task_id,
        agent: agent_slug,
        granted_paths: granted_paths
      })

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_deny(agent_slug, task_id, state) do
    with {:ok, _sentinel} <- find_pending_sentinel(agent_slug, task_id, state),
         :ok <- archive_request(agent_slug, task_id, state),
         :ok <- notify_agent_denied(agent_slug, task_id, state) do
      emit_audit(state, "path_access.denied", "director", %{
        task_id: task_id,
        agent: agent_slug
      })

      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @valid_mode_re ~r/\A(read|write)\z/
  @absolute_path_re ~r/\A\//
  @forbidden_paths ["/proc", "/sys", "/dev"]

  defp validate_request(meta) do
    cond do
      not is_binary(meta.task_id) or meta.task_id == "" ->
        {:error, :missing_task_id}

      not is_list(meta.paths) or meta.paths == [] ->
        {:error, :missing_paths}

      length(meta.paths) > 5 ->
        {:error, :too_many_paths}

      not is_binary(meta.reason) or String.length(meta.reason) < 10 ->
        {:error, :reason_too_short}

      not Enum.all?(meta.paths, &valid_path_entry?/1) ->
        {:error, :invalid_path_entry}

      any_forbidden_path?(meta.paths) ->
        {:error, :forbidden_path}

      true ->
        :ok
    end
  end

  defp valid_path_entry?(%{"path" => p, "mode" => m}) do
    valid_host_path?(p) and Regex.match?(@valid_mode_re, m)
  end

  defp valid_path_entry?(_), do: false

  defp valid_host_path?(path) when is_binary(path) do
    Regex.match?(@absolute_path_re, path) and
      not String.contains?(path, "..") and
      not any_forbidden_path?([%{"path" => path}])
  end

  defp valid_host_path?(_), do: false

  defp any_forbidden_path?(paths) do
    Enum.any?(paths, fn %{"path" => p} ->
      Enum.any?(@forbidden_paths, fn fp -> String.starts_with?(p, fp) end)
    end)
  end

  defp validate_granted_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &valid_granted_path?/1) do
      :ok
    else
      {:error, :invalid_granted_path}
    end
  end

  defp validate_granted_paths(_), do: {:error, :empty_granted_paths}

  defp valid_granted_path?(%{path: p, mode: m}) when is_binary(p) and m in [:read, :write] do
    valid_host_path?(p)
  end

  defp valid_granted_path?(_), do: false

  # ---------------------------------------------------------------------------
  # Filesystem operations
  # ---------------------------------------------------------------------------

  defp ensure_state_dir(agent_slug, state) do
    dir = Path.join([state.base, "companies", state.company, "agents", agent_slug, "state"])
    File.mkdir_p(dir)
  end

  defp build_pending_sentinel_path(agent_slug, task_id, state) do
    state_dir = Path.join([state.base, "companies", state.company, "agents", agent_slug, "state"])
    seq = System.unique_integer([:positive, :monotonic])
    Path.join(state_dir, "path-pending-#{task_id}-#{seq}.md")
  end

  defp write_pending_sentinel(path, meta, agent_slug, _state) do
    content = """
    ---
    kind: path-pending/v1
    agent: #{agent_slug}
    task_id: #{meta.task_id}
    paths: #{Jason.encode!(meta.paths)}
    reason: #{meta.reason}
    requested_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    ---

    Path access request from agent `#{agent_slug}` for task `#{meta.task_id}`.
    """

    case File.write(path, content, [:sync]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write_sentinel_failed, reason}}
    end
  end

  defp find_pending_sentinel(agent_slug, task_id, state) do
    state_dir = Path.join([state.base, "companies", state.company, "agents", agent_slug, "state"])

    case File.ls(state_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@pending_regex, &1))
        |> Enum.find_value(fn entry ->
          path = Path.join(state_dir, entry)

          case read_sentinel_meta(path) do
            %{task_id: ^task_id, agent: ^agent_slug} -> {:ok, path}
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, :pending_not_found}
          result -> result
        end

      {:error, reason} ->
        {:error, {:list_state_dir_failed, reason}}
    end
  end

  defp read_sentinel_meta(path) do
    with {:ok, content} <- File.read(path),
         {:ok, meta, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      %{
        task_id: Map.get(meta, "task_id"),
        agent: Map.get(meta, "agent"),
        paths: Map.get(meta, "paths", []),
        reason: Map.get(meta, "reason", ""),
        requested_at: Map.get(meta, "requested_at")
      }
    else
      _ -> %{}
    end
  end

  defp write_grant(agent_slug, task_id, granted_paths, state) do
    now = DateTime.utc_now()

    paths_for_store =
      Enum.map(granted_paths, fn %{path: host_path, mode: mode} ->
        %{
          host_path: host_path,
          sandbox_path: sandbox_path_for(host_path),
          mode: mode
        }
      end)

    PathGrantStore.grant(state.company, agent_slug, task_id, paths_for_store, now)
  end

  defp archive_request(agent_slug, task_id, state) do
    state_dir = Path.join([state.base, "companies", state.company, "agents", agent_slug, "state"])
    archive_dir = Path.join(state_dir, "path-request-archive")
    File.mkdir_p(archive_dir)

    case File.ls(state_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@pending_regex, &1))
        |> Enum.each(fn entry ->
          src = Path.join(state_dir, entry)
          meta = read_sentinel_meta(src)

          if meta.task_id == task_id and meta.agent == agent_slug do
            ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
            dest = Path.join(archive_dir, "path-pending-#{task_id}-#{ts}.md")
            File.rename(src, dest)
          end
        end)

        :ok

      {:error, _} ->
        :ok
    end
  end

  defp notify_agent_denied(agent_slug, task_id, state) do
    inbox_dir =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        agent_slug,
        "inbox",
        "notifications"
      ])

    File.mkdir_p(inbox_dir)

    content = """
    ---
    kind: inbox-message/v1
    from: director
    delivered_at: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    ---

    Your path access request for task `#{task_id}` was denied.
    """

    ts = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(":", "-")
    filename = "path-request-denied-#{task_id}-#{ts}.md"
    File.write(Path.join(inbox_dir, filename), content, [:sync])
  end

  # ---------------------------------------------------------------------------
  # Sentinel scanning (for UI)
  # ---------------------------------------------------------------------------

  defp scan_pending_sentinels(state, agent_slug) do
    state_dir = Path.join([state.base, "companies", state.company, "agents", agent_slug, "state"])

    case File.ls(state_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(@pending_regex, &1))
        |> Enum.map(fn entry ->
          path = Path.join(state_dir, entry)
          meta = read_sentinel_meta(path)
          Map.put(meta, :sentinel_file, entry)
        end)

      {:error, _} ->
        []
    end
  end

  defp scan_all_pending_sentinels(state) do
    agents_dir = Path.join([state.base, "companies", state.company, "agents"])

    case File.ls(agents_dir) do
      {:ok, agent_slugs} ->
        Enum.flat_map(agent_slugs, fn slug ->
          scan_pending_sentinels(state, slug)
          |> Enum.map(&Map.put(&1, :agent_slug, slug))
        end)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp sandbox_path_for(host_path) do
    basename = Path.basename(host_path)
    "/external/#{basename}"
  end

  defp via(company) do
    {:via, Registry, {Glorbo.Agent.Registry, {:company_child, company, :path_request_gate}}}
  end

  defp emit_audit(state, action, actor, detail) do
    audit_server = state.audit_server

    try do
      GenServer.call(audit_server, {:append, %{action: action, actor: actor, detail: detail}})
    catch
      _, _ -> :ok
    end
  end

  defp audit_result(:ok, _state), do: :ok

  defp audit_result({:error, reason}, state) do
    emit_audit(state, "path_access.error", "system", %{error: reason})
    :ok
  end
end
