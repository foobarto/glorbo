defmodule Glorbo.Company.ProposalsSink do
  @moduledoc """
  Per-company observer that emits audit events when `proposals/*.md`
  files change (GEP-28 wave 2a).

  Subscribes to the `company:<co>:proposals` PubSub topic (populated
  by `Glorbo.Filesystem.Watcher`) and, for each `{:file_event, rel,
  events}` naming a direct child of `proposals/`, reads the file,
  parses frontmatter, and emits one of:

    * `proposal.requested`   — status `pending-approval`
    * `proposal.approved`    — status `approved`
    * `proposal.denied`      — status `denied`
    * `proposal.superseded`  — status `superseded`

  **Best-effort:** a malformed / unreadable / unknown-status proposal
  is logged and skipped; the sink never crashes the supervision tree
  over a single bad file.

  **Not an enforcer.** Router-level status-flip enforcement (GEP-28
  failure-modes row) is a separate concern — this module only
  observes.

  ## Dep injection

    * `audit_fun` — `(company, entry) -> any`, defaults to the
      Registry-resolved `Glorbo.Company.AuditLog` for the company.
    * `read_fun` — `(path) -> {:ok, binary} | {:error, term}`, defaults
      to `File.read/1`. Used by tests to avoid touching disk.
    * `test_pid` — when set, every emission is also `send`-ed to the
      pid as `{:proposals_sink_emitted, company, entry}`.
  """
  use GenServer
  require Logger

  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter

  @type state :: %{
          company: String.t(),
          base: String.t(),
          pubsub: atom(),
          audit_fun: (String.t(), map() -> any()),
          read_fun: (Path.t() -> {:ok, binary()} | {:error, term()}),
          test_pid: pid() | nil
        }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    state = %{
      company: Keyword.fetch!(opts, :company),
      base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root()),
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
      audit_fun: Keyword.get(opts, :audit_fun, &default_audit_fun/2),
      read_fun: Keyword.get(opts, :read_fun, &File.read/1),
      test_pid: Keyword.get(opts, :test_pid)
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    :ok = Phoenix.PubSub.subscribe(state.pubsub, "company:#{state.company}:proposals")
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:file_event, rel, events}, state) when is_binary(rel) and is_list(events) do
    if proposal_md?(rel) and write_event?(events) do
      handle_proposal_event(rel, state)
    end

    {:noreply, state}
  end

  # Catch-all: observer-style sink intentionally ignores non-file
  # PubSub traffic rather than crashing on unrelated messages.
  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp proposal_md?(rel) do
    case Path.split(rel) do
      ["proposals", file] -> String.ends_with?(file, ".md")
      _ -> false
    end
  end

  defp write_event?(events), do: Enum.any?(events, &(&1 in [:created, :modified]))

  defp handle_proposal_event(rel, state) do
    abs_path = Path.join([state.base, "companies", state.company, rel])

    with {:ok, content} <- state.read_fun.(abs_path),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         {:ok, action} <- classify(meta) do
      # Threatmodel T12: the sink is a filesystem observer, not an
      # authorization oracle. Do not trust `approved_by`/`proposed_by`
      # from frontmatter — an agent with `proposals:write:*` can set
      # any value there and forge an apparently-director-signed audit
      # entry. The Router's separate audit emit (when it handles an
      # outbox proposal) is the authoritative record; this sink just
      # captures that the proposal file changed. Always use the
      # sentinel `"proposal-file"` actor and preserve the claimed
      # values inside `detail` for investigators.
      entry = %{
        company: state.company,
        actor: "proposal-file",
        action: action,
        target: rel,
        detail: %{
          subtype: Map.get(meta, "subtype"),
          id: Map.get(meta, "id"),
          claimed_proposed_by: Map.get(meta, "proposed_by"),
          claimed_approved_by: Map.get(meta, "approved_by")
        }
      }

      emit(state, entry)
    else
      {:error, reason} ->
        Logger.warning(
          "[proposals_sink/#{state.company}] skipped #{rel} reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      # Best-effort observer: never crash the GenServer on a single
      # bad file. Log and move on.
      Logger.warning(
        "[proposals_sink/#{state.company}] raised on #{rel}: #{Exception.message(e)}"
      )

      :ok
  end

  # Returns {:ok, action} or {:error, reason}. Unknown status values
  # are a skip, not a crash — the watcher sees every write and many
  # will be in-flight edits (e.g. a Director saving a half-typed
  # status field). T12: the action name signals "file was seen in
  # status X", not "X was authorized" — the sink is an observer.
  defp classify(meta) do
    case Map.get(meta, "status") do
      "pending-approval" -> {:ok, "proposal.file_pending"}
      "approved" -> {:ok, "proposal.file_approved"}
      "denied" -> {:ok, "proposal.file_denied"}
      "superseded" -> {:ok, "proposal.file_superseded"}
      other -> {:error, {:unknown_status, other}}
    end
  end

  defp emit(state, entry) do
    _ = state.audit_fun.(state.company, entry)

    if is_pid(state.test_pid) do
      send(state.test_pid, {:proposals_sink_emitted, state.company, entry})
    end

    :ok
  rescue
    e ->
      Logger.error("[proposals_sink/#{state.company}] audit emit raised: #{Exception.message(e)}")

      :ok
  end

  # Mirrors the Registry-lookup pattern used by Router /
  # Scheduler (`default_audit_fun/2`). Falls back to the bare
  # module name when no per-company AuditLog is registered.
  defp default_audit_fun(company, entry) when is_binary(company) do
    server =
      case resolve_audit_server(company) do
        {:ok, via} -> via
        :not_found -> AuditLog
      end

    AuditLog.append(server, Map.put(entry, :company, company))
  end

  defp resolve_audit_server(company) do
    key = {:company_child, company, :audit_log}

    case Elixir.Registry.lookup(Glorbo.Agent.Registry, key) do
      [{_pid, _}] -> {:ok, {:via, Elixir.Registry, {Glorbo.Agent.Registry, key}}}
      _ -> :not_found
    end
  end
end
