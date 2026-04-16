defmodule Glorbo.Company.AuditLog do
  @moduledoc """
  Append-only audit sink.

  Writes a JSONL line to `audit/YYYY-MM.jsonl` under the company dir (or
  `audit/_system/<YYYY-MM>.jsonl` for orchestrator events) AND mirrors the
  entry to the `audit_events` SQLite table.

  **LOAD-BEARING (CLAUDE.md invariant):** this module exposes ONLY
  `append/2` (and GenServer's `start_link/1`). There is no `update/2`,
  `delete/2`, or `edit/2`. Negative test: `test/glorbo/stubs_test.exs`.

  **Source-of-truth ordering (FS-05):** JSONL is authoritative; SQLite is
  derived. JSONL is written FIRST with `[:append, :sync]` (fsync after
  every write). If the SQLite mirror insert fails the error is logged but
  `append/2` still returns `:ok` — the disk record is the ground truth.
  """
  use GenServer
  require Logger

  alias Glorbo.{AuditEvent, Repo}

  @type entry :: %{optional(atom()) => term(), optional(binary()) => term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Append `entry` to the audit log (JSONL + SQLite mirror).

  `entry` supports these keys (atom or string):
    * `:ts`        — `%DateTime{}` (default: `DateTime.utc_now/0`)
    * `:company`   — binary or atom; `:_system` / `"_system"` routes to
                     `~/.glorbo/audit/_system/`
    * `:actor`     — binary; e.g. `"ceo"` or `"system"`
    * `:action`    — binary; e.g. `"task.create"`
    * `:target`    — binary (optional)
    * any other key → merged into the `detail` JSON map
  """
  @spec append(GenServer.server(), entry()) :: :ok
  def append(server \\ __MODULE__, %{} = entry) do
    GenServer.call(server, {:append, entry})
  end

  @impl GenServer
  def init(opts) do
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    {:ok, %{base: base}}
  end

  @impl GenServer
  def handle_call({:append, entry}, _from, state) do
    ts = entry_ts(entry)
    ts_iso = DateTime.to_iso8601(ts)
    company = entry_company(entry)
    actor = to_string(entry[:actor] || entry["actor"] || "system")
    action = to_string(entry[:action] || entry["action"] || "unknown")
    target = entry[:target] || entry["target"]
    detail_map = drop_known_keys(entry)

    record = %{
      ts: ts_iso,
      actor: actor,
      action: action,
      target: target,
      detail: detail_map
    }

    json = Jason.encode!(record) <> "\n"
    path = jsonl_path(state.base, company, ts)
    File.mkdir_p!(Path.dirname(path))
    # FS-05: source of truth — fsync after every line.
    :ok = File.write!(path, json, [:append, :sync])

    # Mirror to SQLite — derived; failure logged but does not roll back JSONL.
    mirror_to_sqlite(company, actor, action, target, detail_map, ts)

    {:reply, :ok, state}
  end

  defp entry_ts(entry) do
    # CR-02: Normalise to UTC up-front so both the JSONL `ts` field and the
    # month-bucket filename derive from the same timezone view. A caller that
    # passes a non-UTC DateTime otherwise lands in the wrong monthly bucket
    # on timezone boundaries.
    case entry[:ts] || entry["ts"] do
      %DateTime{time_zone: "Etc/UTC"} = dt -> dt
      %DateTime{} = dt -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  defp entry_company(entry) do
    raw = entry[:company] || entry["company"] || "_system"
    to_string(raw)
  end

  defp drop_known_keys(entry) do
    entry
    |> Map.drop([:ts, :company, :actor, :action, :target])
    |> Map.drop(["ts", "company", "actor", "action", "target"])
  end

  defp mirror_to_sqlite(company, actor, action, target, detail_map, ts) do
    Repo.insert(%AuditEvent{
      company: company,
      actor: actor,
      action: action,
      target: target,
      detail: Jason.encode!(detail_map),
      ts: DateTime.truncate(ts, :second)
    })
  rescue
    e ->
      Logger.error("audit_events mirror failed: #{Exception.message(e)} (JSONL still written)")

      :error
  else
    {:ok, _} ->
      :ok

    {:error, changeset} ->
      Logger.error(
        "audit_events mirror changeset invalid: #{inspect(changeset)} (JSONL still written)"
      )

      :error
  end

  defp jsonl_path(base, company, ts) do
    month = month_bucket(ts)

    case company do
      "_system" ->
        Path.join([base, "audit", "_system", "#{month}.jsonl"])

      co ->
        Path.join([base, "companies", co, "audit", "#{month}.jsonl"])
    end
  end

  defp month_bucket(%DateTime{} = dt) do
    dt
    |> DateTime.to_date()
    |> Date.to_string()
    |> String.slice(0, 7)
  end
end
