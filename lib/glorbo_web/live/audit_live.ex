defmodule GlorboWeb.AuditLive do
  @moduledoc """
  Audit log viewer — GET `/companies/:company/audit` (D-27).

  Reads the current-month `audit/YYYY-MM.jsonl` from the company
  directory and renders the last 500 entries (tail). The file is
  append-only.

  Updates stream in via PubSub — `Glorbo.Company.AuditLog` broadcasts
  `{:audit_append, record}` on `company:<co>:audit` after every
  successful append. The Watcher deliberately ignores `audit/*`
  events (would loop with AuditLog-writing subscribers), so this
  channel is the only one. A 15s low-rate poll remains as a safety
  net for out-of-band file edits.

  Filter inputs (`actor`, `action`) operate client-side on the
  loaded tail. A `Load 500 older` button prepends the previous
  batch from earlier in the file; when the file start is reached
  the button is replaced with `— beginning of log —`.

  Row expansion uses a `MapSet` of expanded IDs; each click toggles
  a row.
  """
  use GlorboWeb, :live_view
  import GlorboWeb.LiveHelpers, only: [base_dir: 0, current_year_month: 0]
  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.AuditEntry

  # Out-of-band safety-net poll. PubSub `{:audit_append, record}` drives
  # realtime updates; this poll catches manual edits or recovery scenarios.
  @poll_ms 15_000
  @page 500

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    if Glorbo.Slug.valid?(co) do
      mount_valid(co, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid company identifier.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  defp mount_valid(co, socket) do
    base = base_dir()
    ym = current_year_month()
    path = audit_path(base, co, ym)

    if connected?(socket) do
      Process.send_after(self(), :poll, @poll_ms)
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
    end

    {entries, offset, total} = load_tail(path, @page)

    {:ok,
     socket
     |> assign(:page_title, "Audit — #{co} — Glorbo")
     |> assign(:sidebar_active, :audit)
     |> assign(:current_company, co)
     |> assign(:company_slug, co)
     |> assign(:year_month, ym)
     |> assign(:path, path)
     |> assign(:actor_filter, "")
     |> assign(:action_filter, "")
     |> assign(:q, "")
     |> assign(:since_filter, "")
     |> assign(:until_filter, "")
     |> assign(:offset, offset)
     |> assign(:total_lines, total)
     |> assign(:beginning, offset == 0)
     |> assign(:expanded, MapSet.new())
     |> assign(:entries, entries)
     |> ChatDrawer.State.wire_drawer()}
  end

  # #264 — URL params let other views deep-link with a pre-filled
  # filter. `?q=<task-path>` is the main use case (TaskLive's "view
  # full audit" link). Also accepts `?actor=`, `?action=`, `?since=`,
  # `?until=` for completeness.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:q, Map.get(params, "q", socket.assigns.q))
     |> assign(:actor_filter, Map.get(params, "actor", socket.assigns.actor_filter))
     |> assign(:action_filter, Map.get(params, "action", socket.assigns.action_filter))
     |> assign(:since_filter, Map.get(params, "since", socket.assigns.since_filter))
     |> assign(:until_filter, Map.get(params, "until", socket.assigns.until_filter))}
  end

  @impl true
  def handle_info(:poll, socket) do
    Process.send_after(self(), :poll, @poll_ms)
    {entries, offset, total} = load_tail(socket.assigns.path, @page)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:offset, offset)
     |> assign(:total_lines, total)
     |> assign(:beginning, offset == 0)}
  end

  # AuditLog broadcast — append realtime without re-reading the file.
  def handle_info({:audit_append, record}, socket) when is_map(record) do
    # Records from AuditLog use atom keys; the file-read path produces
    # string keys. Normalise to strings so entry_id + filter helpers
    # stay uniform.
    entry = stringify_keys(record)

    new_entries = append_capped(socket.assigns.entries, entry, @page)
    new_total = socket.assigns.total_lines + 1

    {:noreply,
     socket
     |> assign(:entries, new_entries)
     |> assign(:total_lines, new_total)}
  end

  def handle_info({:file_event, rel, _events}, socket) do
    {:noreply, ChatDrawer.State.maybe_refresh_drawer(socket, rel)}
  end

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    {:noreply, assign(socket, :_agent_status_tick, System.unique_integer([:positive]))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  # Cap the in-memory tail at @page entries — matches load_tail's
  # bound so realtime appends don't grow unboundedly during long
  # LiveView sessions.
  defp append_capped(entries, new_entry, cap) do
    appended = entries ++ [new_entry]

    if length(appended) > cap,
      do: Enum.take(appended, -cap),
      else: appended
  end

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:actor_filter, Map.get(params, "actor", ""))
     |> assign(:action_filter, Map.get(params, "action", ""))
     |> assign(:q, Map.get(params, "q", ""))
     |> assign(:since_filter, Map.get(params, "since", ""))
     |> assign(:until_filter, Map.get(params, "until", ""))}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, id) do
        MapSet.delete(socket.assigns.expanded, id)
      else
        MapSet.put(socket.assigns.expanded, id)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  # #254 — convert an audit entry to a task in projects/inbox/tasks/.
  # Finds the entry by its id (ts+actor+action+target hash) from the
  # currently-loaded window; if the lookup misses (e.g. the row just
  # scrolled out), flashes an error rather than silently failing.
  def handle_event("convert_to_task", %{"id" => id}, socket) do
    # Match against the full loaded window (`:entries`), not the
    # render-time `:filtered` (which is only computed inside render/1
    # and not persisted). The id hash is stable across filter changes
    # because it's derived from the entry's ts+actor+action+target.
    entries = socket.assigns.entries

    entry =
      Enum.find(Enum.with_index(entries), fn {e, idx} ->
        entry_id(e, idx) == id
      end)

    case entry do
      {e, _idx} ->
        case Glorbo.Actions.Audit.scaffold_from_entry(
               socket.assigns.company_slug,
               e,
               actor: "director",
               base: base_dir()
             ) do
          {:ok, %{rel_path: rel_path}} ->
            {:noreply, put_flash(socket, :info, "Task scaffolded: #{rel_path}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Conversion failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Audit entry no longer in view.")}
    end
  end

  def handle_event("load_older", _params, socket) do
    {older, new_offset} = load_older(socket.assigns.path, socket.assigns.offset, @page)

    socket =
      case older do
        [] ->
          assign(socket, :beginning, true)

        _ ->
          socket
          |> assign(:entries, older ++ socket.assigns.entries)
          |> assign(:offset, new_offset)
          |> assign(:beginning, new_offset == 0)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    # UAT N4: entries are stored oldest-first (append-only tail); reverse
    # at render time so the user sees newest at the top, matching how
    # every other log viewer (Slack, Datadog, `tail` + page-up) behaves.
    filtered =
      assigns.entries
      |> filter_entries(assigns.actor_filter, assigns.action_filter, assigns.q)
      |> filter_date_range(assigns.since_filter, assigns.until_filter)
      |> Enum.reverse()

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <section class="gl-view gl-audit">
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">
          Audit log <span class="gl-muted">{@year_month}</span>
        </h1>
        <div class="gl-audit__header-actions">
          <a
            href={~p"/companies/#{@company_slug}/audit.csv"}
            class="gl-btn gl-btn--sm"
            title="Download the current month's audit log as CSV"
            download
          >
            ⇩ export CSV
          </a>
        </div>
      </header>

      <form phx-change="filter" class="gl-audit__filters" role="search" aria-label="Audit filters">
        <label for="audit-q" class="gl-sr-only">Search</label>
        <input
          type="search"
          id="audit-q"
          name="q"
          value={@q}
          class="gl-input gl-audit__q"
          placeholder="Search actor · action · target · detail…"
        />
        <label for="audit-filter-actor" class="gl-sr-only">Filter by actor</label>
        <input
          type="text"
          id="audit-filter-actor"
          name="actor"
          value={@actor_filter}
          class="gl-input"
          placeholder="actor"
        />
        <label for="audit-filter-action" class="gl-sr-only">Filter by action</label>
        <input
          type="text"
          id="audit-filter-action"
          name="action"
          value={@action_filter}
          class="gl-input"
          placeholder="action"
        />
        <label for="audit-filter-since" class="gl-sr-only">Since date</label>
        <input
          type="date"
          id="audit-filter-since"
          name="since"
          value={@since_filter}
          class="gl-input gl-audit__date"
          title="Show events on or after this date (UTC)"
        />
        <label for="audit-filter-until" class="gl-sr-only">Until date</label>
        <input
          type="date"
          id="audit-filter-until"
          name="until"
          value={@until_filter}
          class="gl-input gl-audit__date"
          title="Show events on or before this date (UTC)"
        />
      </form>

      <div :if={@filtered == []} class="gl-empty">No audit events this month.</div>

      <AuditEntry.audit_entry
        :for={{entry, idx} <- Enum.with_index(@filtered)}
        id={entry_id(entry, idx)}
        entry={entry}
        expanded={MapSet.member?(@expanded, entry_id(entry, idx))}
      />

      <%!--
        Load-older button moved below the list (UAT N4): newest-first
        rendering means older events sit "further down" in the feed,
        which matches how the Load Older control has to work.
      --%>
      <button :if={not @beginning} phx-click="load_older" class="gl-btn gl-audit__load-older">
        Load 500 older
      </button>
      <div :if={@beginning} class="gl-audit__beginning gl-muted">— beginning of log —</div>
    </section>
    """
  end

  # WR-03: Key expansion state on a stable hash of the entry's unique
  # fields (timestamp + actor + action + target) rather than the
  # render-order index. Audit entries are append-only, so the tuple is
  # effectively unique within a monthly log. Polls and filter changes
  # no longer drift the expansion state onto neighboring rows.
  defp entry_id(entry, fallback_idx) when is_map(entry) do
    ts = to_string(entry["ts"] || "")
    actor = to_string(entry["actor"] || "")
    action = to_string(entry["action"] || "")
    target = to_string(entry["target"] || "")

    case {ts, actor, action} do
      {"", "", ""} ->
        "audit-#{fallback_idx}"

      _ ->
        hash =
          :crypto.hash(:sha256, ts <> "\0" <> actor <> "\0" <> action <> "\0" <> target)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 16)

        "audit-#{hash}"
    end
  end

  defp entry_id(_entry, fallback_idx), do: "audit-#{fallback_idx}"

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp audit_path(base, co, ym),
    do: Path.join([base, "companies", co, "audit", "#{ym}.jsonl"])

  defp load_tail(path, n) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)
        total = length(lines)
        tail = Enum.take(lines, -n)
        entries = tail |> Enum.map(&decode/1) |> Enum.reject(&is_nil/1)
        offset = max(total - n, 0)
        {entries, offset, total}

      _ ->
        {[], 0, 0}
    end
  end

  defp load_older(path, current_offset, n) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n", trim: true)
        new_offset = max(current_offset - n, 0)
        slice = Enum.slice(lines, new_offset, current_offset - new_offset)
        entries = slice |> Enum.map(&decode/1) |> Enum.reject(&is_nil/1)
        {entries, new_offset}

      _ ->
        {[], 0}
    end
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp filter_entries(entries, "", "", ""), do: entries

  defp filter_entries(entries, actor_f, action_f, q) do
    needle = String.downcase(q)

    Enum.filter(entries, fn e ->
      actor_match?(e, actor_f) and action_match?(e, action_f) and q_match?(e, needle)
    end)
  end

  defp actor_match?(_e, ""), do: true
  defp actor_match?(e, f), do: String.contains?(to_string(e["actor"] || ""), f)

  defp action_match?(_e, ""), do: true
  defp action_match?(e, f), do: String.contains?(to_string(e["action"] || ""), f)

  defp q_match?(_e, ""), do: true

  defp q_match?(e, needle) when is_binary(needle) do
    haystack =
      [
        to_string(e["actor"] || ""),
        to_string(e["action"] || ""),
        to_string(e["target"] || ""),
        detail_haystack(e["detail"])
      ]
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, needle)
  end

  defp detail_haystack(nil), do: ""
  defp detail_haystack(d) when is_binary(d), do: d
  defp detail_haystack(d) when is_map(d) or is_list(d), do: Jason.encode!(d)
  defp detail_haystack(d), do: to_string(d)

  # #263 — date range filter. Accepts `"YYYY-MM-DD"` strings for
  # `since` (inclusive, 00:00:00Z) and `until` (inclusive, 23:59:59Z).
  # Empty strings skip the bound. Malformed dates skip silently so
  # mid-typing (e.g. "2026-04-" in a date input) doesn't blank the
  # list.
  defp filter_date_range(entries, "", ""), do: entries

  defp filter_date_range(entries, since, until) do
    since_dt = parse_date_bound(since, :start)
    until_dt = parse_date_bound(until, :end)

    Enum.filter(entries, fn e ->
      case parse_entry_ts(e["ts"]) do
        nil -> true
        dt -> in_range?(dt, since_dt, until_dt)
      end
    end)
  end

  defp in_range?(_dt, nil, nil), do: true
  defp in_range?(dt, nil, until_dt), do: DateTime.compare(dt, until_dt) != :gt
  defp in_range?(dt, since_dt, nil), do: DateTime.compare(dt, since_dt) != :lt

  defp in_range?(dt, since_dt, until_dt) do
    DateTime.compare(dt, since_dt) != :lt and DateTime.compare(dt, until_dt) != :gt
  end

  defp parse_date_bound("", _), do: nil

  defp parse_date_bound(s, :start) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_date_bound(s, :end) when is_binary(s) do
    case Date.from_iso8601(s) do
      {:ok, d} -> DateTime.new!(d, ~T[23:59:59], "Etc/UTC")
      _ -> nil
    end
  end

  defp parse_date_bound(_, _), do: nil

  defp parse_entry_ts(nil), do: nil

  defp parse_entry_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_entry_ts(_), do: nil
end
