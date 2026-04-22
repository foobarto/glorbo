defmodule GlorboWeb.MCP.Tools.QueryAudit do
  @moduledoc """
  MCP tool: `glorbo.query_audit` (GEP-29 wave b.2).

  Scans `companies/<co>/audit/YYYY-MM.jsonl` files and returns
  entries matching optional filters. Newest-first. Unlike
  `Glorbo.Audit.Query.for_task/4` (task-scoped), this tool accepts
  free-form actor / action / substring filters and can span
  multiple months via `since` / `until`.
  """
  @behaviour GlorboWeb.MCP.Tool

  alias GlorboWeb.MCP.Args

  @default_limit 100
  @max_limit 1000

  @impl true
  def name, do: "glorbo.query_audit"

  @impl true
  def description,
    do: """
    Query the company audit log. Each row is an append-only JSONL
    entry (ts, action, actor, target, detail). Optional filters:
    - actor: exact match on the actor string
    - action: exact match (e.g. "task.approve", "proposal.requested")
    - since / until: ISO8601 timestamps; inclusive lower, exclusive upper
    - q: substring match against target + JSON-stringified detail
    - limit: cap on entries returned (default 100, max 1000)
    """

  @impl true
  def input_schema,
    do: %{
      "type" => "object",
      "properties" => %{
        "company" => %{"type" => "string"},
        "actor" => %{"type" => ["string", "null"]},
        "action" => %{"type" => ["string", "null"]},
        "since" => %{"type" => ["string", "null"], "description" => "ISO8601"},
        "until" => %{"type" => ["string", "null"], "description" => "ISO8601"},
        "q" => %{"type" => ["string", "null"], "description" => "substring match"},
        "limit" => %{"type" => ["integer", "null"]}
      },
      "required" => ["company"],
      "additionalProperties" => false
    }

  @impl true
  def call(%{"company" => company} = args, context) when is_binary(company) do
    with :ok <- Args.require_slug(company, :company) do
      do_call(company, args, context)
    end
  end

  def call(_args, _context), do: {:error, :missing_company_arg}

  defp do_call(company, args, context) do
    base = context[:base] || Glorbo.Filesystem.Hierarchy.default_root()
    audit_dir = Path.join([base, "companies", company, "audit"])

    since = nilify(args["since"])
    until_arg = nilify(args["until"])
    months = enumerate_months(since, until_arg)
    limit = clamp_limit(args["limit"])

    entries =
      months
      |> Enum.flat_map(&read_month(audit_dir, &1))
      |> filter_by(:actor, nilify(args["actor"]))
      |> filter_by(:action, nilify(args["action"]))
      |> filter_time(since, until_arg)
      |> filter_q(nilify(args["q"]))
      # Each month's file is already oldest-first; combined list is
      # oldest-first across months. Reverse for newest-first, then take.
      |> Enum.reverse()
      |> Enum.take(limit)

    {:ok, %{"entries" => entries}}
  end

  # ---------------------------------------------------------------------------
  # File enumeration
  # ---------------------------------------------------------------------------

  defp enumerate_months(nil, nil), do: [current_year_month()]

  defp enumerate_months(since, until_arg) do
    start_ym = to_year_month(since) || current_year_month()
    end_ym = to_year_month(until_arg) || current_year_month()

    {lo, hi} = if start_ym <= end_ym, do: {start_ym, end_ym}, else: {end_ym, start_ym}
    months_between(lo, hi)
  end

  defp months_between(lo, hi) do
    # Bounded walker — generate YYYY-MM strings month by month.
    {ly, lm} = parse_ym(lo)
    {hy, hm} = parse_ym(hi)

    Stream.iterate({ly, lm}, &next_month/1)
    |> Stream.take_while(fn {y, m} -> y < hy or (y == hy and m <= hm) end)
    |> Enum.map(fn {y, m} -> format_ym(y, m) end)
  end

  defp next_month({y, 12}), do: {y + 1, 1}
  defp next_month({y, m}), do: {y, m + 1}

  defp parse_ym(<<y::binary-size(4), "-", m::binary-size(2)>>),
    do: {String.to_integer(y), String.to_integer(m)}

  defp format_ym(y, m), do: :io_lib.format("~4..0B-~2..0B", [y, m]) |> IO.iodata_to_binary()

  defp read_month(audit_dir, ym) do
    path = Path.join(audit_dir, "#{ym}.jsonl")

    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_line/1)

      _ ->
        []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> [entry]
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------
  # Filters
  # ---------------------------------------------------------------------------

  defp filter_by(entries, _key, nil), do: entries

  defp filter_by(entries, key, value) do
    Enum.filter(entries, fn e -> to_string(e[Atom.to_string(key)] || "") == value end)
  end

  defp filter_time(entries, nil, nil), do: entries

  defp filter_time(entries, since, until_arg) do
    # Audit records emit `ts` per the GEP-7 / FileSpec.AuditMonthJsonl
    # schema. Compare via DateTime.compare so fractional-second
    # precision mismatches (e.g. `10:00:00Z` vs `10:00:00.123Z`)
    # don't wrongly drop rows near the boundary.
    since_dt = parse_iso(since)
    until_dt = parse_iso(until_arg)

    Enum.filter(entries, fn e ->
      case parse_iso(e["ts"]) do
        nil ->
          # Missing/malformed timestamp → include it rather than
          # silently drop (observer convention, matches other tools).
          true

        ts ->
          after_since?(ts, since_dt) and before_until?(ts, until_dt)
      end
    end)
  end

  defp after_since?(_ts, nil), do: true
  defp after_since?(ts, since_dt), do: DateTime.compare(ts, since_dt) != :lt
  defp before_until?(_ts, nil), do: true
  defp before_until?(ts, until_dt), do: DateTime.compare(ts, until_dt) == :lt

  defp parse_iso(nil), do: nil
  defp parse_iso(""), do: nil

  defp parse_iso(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_iso(_), do: nil

  defp filter_q(entries, nil), do: entries

  defp filter_q(entries, q) do
    Enum.filter(entries, fn e ->
      target = to_string(e["target"] || "")
      detail_json = Jason.encode!(Map.get(e, "detail", %{}))
      String.contains?(target, q) or String.contains?(detail_json, q)
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp current_year_month do
    Date.utc_today() |> Date.to_string() |> String.slice(0, 7)
  end

  defp to_year_month(nil), do: nil

  defp to_year_month(<<y::binary-size(4), "-", m::binary-size(2), _rest::binary>>),
    do: "#{y}-#{m}"

  defp to_year_month(_), do: nil

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(n) when is_integer(n) and n >= 1 and n <= @max_limit, do: n
  defp clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  defp clamp_limit(_), do: @default_limit

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(v) when is_binary(v), do: v
  defp nilify(_), do: nil
end
