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

  @doc """
  Append to whichever AuditLog server is actually running for this
  company. Production routes through the per-company via-tuple set
  up by `Glorbo.Company.Supervisor`; the unit-LV test harness in
  `GlorboWeb.LiveCase` instead starts a single bare-module AuditLog
  that all companies share.

  The bare `append/2` call with the bare module name silently exits
  when the per-company tree is running (threatmodel-adjacent bug B1,
  discovered during the bench-tech-blog UAT 2026-04-22) because no
  process is registered under `Glorbo.Company.AuditLog`.

  This helper picks the correct target so LiveViews that only know
  the company slug emit events successfully in both environments.
  """
  @spec append_for(String.t(), entry()) :: :ok
  def append_for(company, %{} = entry) when is_binary(company) do
    server = resolve_server(company)

    try do
      GenServer.call(server, {:append, Map.put_new(entry, :company, company)})
    rescue
      e ->
        Logger.warning(
          "[audit/#{company}] append_for failed: #{Exception.message(e)} " <>
            "action=#{inspect(Map.get(entry, :action))} target=#{inspect(Map.get(entry, :target))}"
        )

        :ok
    catch
      :exit, reason ->
        Logger.warning(
          "[audit/#{company}] append_for exited: #{inspect(reason)} " <>
            "action=#{inspect(Map.get(entry, :action))} target=#{inspect(Map.get(entry, :target))}"
        )

        :ok
    end
  end

  defp resolve_server(company) do
    via = Glorbo.Company.Supervisor.via(company, :audit_log)

    case GenServer.whereis(via) do
      nil ->
        case Process.whereis(__MODULE__) do
          nil -> via
          pid when is_pid(pid) -> pid
        end

      pid when is_pid(pid) ->
        pid
    end
  end

  @impl GenServer
  def init(opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    {:ok, %{base: base}}
  end

  @impl GenServer
  def handle_call({:append, entry}, _from, state) do
    # WR-10: normalise atom/string keys to a single string-keyed map so the
    # "atom wins over string" behaviour (surprising when both are present)
    # disappears and every helper below reads one key taxonomy.
    entry = normalize_entry(entry)

    ts = entry_ts(entry)
    ts_iso = DateTime.to_iso8601(ts)
    company = entry_company(entry)
    actor = to_string(entry["actor"] || "system")
    action = to_string(entry["action"] || "unknown")
    target = entry["target"]
    detail_map = drop_known_keys(entry)

    record = %{
      kind: "audit-event/v1",
      ts: ts_iso,
      actor: actor,
      action: action,
      target: target,
      detail: detail_map
    }

    json = Jason.encode!(record) <> "\n"
    path = jsonl_path(state.base, company, ts)
    File.mkdir_p!(Path.dirname(path))

    # threatmodel M03: although the audit/ tree is host-owned, an
    # agent with write access to `state/` or `outbox/` could relative-
    # path a symlink via `company/audit/YYYY-MM.jsonl` if the audit
    # directory is ever bind-mounted. `File.write!(:append)` follows
    # symlinks; the lstat check below refuses any non-regular shape
    # before writing. Absent file is the common case (first append
    # of the month).
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: type}} -> raise "audit path not regular: #{inspect(type)} at #{path}"
    end

    # FS-05: source of truth — fsync after every line.
    :ok = File.write!(path, json, [:append, :sync])

    # Mirror to SQLite — derived; failure logged but does not roll back JSONL.
    mirror_to_sqlite(company, actor, action, target, detail_map, ts)

    # Broadcast post-write so UI subscribers can stream in realtime.
    # Safe because this module is the sole writer of audit files
    # (D-24), so there's no echo-loop risk. Watcher deliberately
    # skips audit/* — this is the only channel.
    broadcast_append(company, record)

    {:reply, :ok, state}
  end

  defp broadcast_append("_system", _record), do: :ok

  defp broadcast_append(company, record) when is_binary(company) do
    _ =
      Phoenix.PubSub.broadcast(Glorbo.PubSub, "company:#{company}:audit", {:audit_append, record})

    :ok
  rescue
    _ -> :ok
  end

  # WR-10: stringify all keys so downstream lookups read one taxonomy only.
  defp normalize_entry(entry) do
    for {k, v} <- entry, into: %{}, do: {to_string(k), v}
  end

  defp entry_ts(entry) do
    # CR-02: Normalise to UTC up-front so both the JSONL `ts` field and the
    # month-bucket filename derive from the same timezone view. A caller that
    # passes a non-UTC DateTime otherwise lands in the wrong monthly bucket
    # on timezone boundaries.
    case entry["ts"] do
      %DateTime{time_zone: "Etc/UTC"} = dt -> dt
      %DateTime{} = dt -> DateTime.shift_zone!(dt, "Etc/UTC")
      _ -> DateTime.utc_now()
    end
  end

  # Threatmodel: callers can stuff anything into `entry["company"]`
  # — atoms, integers, an unsanitised string with `../`. The downstream
  # `jsonl_path/3` builds the audit jsonl path with `Path.join`, which
  # does not normalise `..` segments. An entry with
  # `company: "../../etc"` would scribble outside `companies/`. Coerce
  # to string then validate against the canonical slug regex; fall
  # back to the `_system` bucket on anything that doesn't match so
  # the audit still lands somewhere on disk.
  defp entry_company(entry) do
    case entry["company"] do
      nil ->
        "_system"

      raw ->
        co = to_string(raw)

        cond do
          # The host's "no-company" sentinel — kept literal, doesn't
          # match the slug regex (leading underscore).
          co == "_system" ->
            co

          Glorbo.Actions.Support.valid_slug?(co) ->
            co

          true ->
            Logger.warning(
              "audit: rejecting non-slug company=#{inspect(co)}; bucketing into _system"
            )

            "_system"
        end
    end
  end

  defp drop_known_keys(entry) do
    Map.drop(entry, ["ts", "company", "actor", "action", "target"])
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
