defmodule GlorboWeb.AuditLive do
  @moduledoc """
  Audit log viewer — GET `/companies/:company/audit` (D-27).

  Reads the current-month `audit/YYYY-MM.jsonl` from the company
  directory and renders the last 500 entries (tail). The file is
  append-only and Phase 3 deliberately excludes it from the Watcher
  PubSub topics, so this LV polls via `Process.send_after(self(),
  :poll, 1_000)` to pick up new entries (04-RESEARCH line 155).

  Filter inputs (`actor`, `action`) operate client-side on the
  loaded tail. A `Load 500 older` button prepends the previous
  batch from earlier in the file; when the file start is reached
  the button is replaced with `— beginning of log —`.

  Row expansion uses a `MapSet` of expanded IDs; each click toggles
  a row.
  """
  use GlorboWeb, :live_view
  alias GlorboWeb.Components.AuditEntry

  @poll_ms 1_000
  @page 500

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    if GlorboWeb.Slug.valid?(co) do
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

    if connected?(socket), do: Process.send_after(self(), :poll, @poll_ms)

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
     |> assign(:offset, offset)
     |> assign(:total_lines, total)
     |> assign(:beginning, offset == 0)
     |> assign(:expanded, MapSet.new())
     |> assign(:entries, entries)}
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

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:actor_filter, Map.get(params, "actor", ""))
     |> assign(:action_filter, Map.get(params, "action", ""))
     |> assign(:q, Map.get(params, "q", ""))}
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
    filtered =
      filter_entries(assigns.entries, assigns.actor_filter, assigns.action_filter, assigns.q)

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <section class="gl-view gl-audit">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">
          Audit log <span class="gl-muted">{@year_month}</span>
        </h1>
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
      </form>

      <div :if={@filtered == []} class="gl-empty">No audit events this month.</div>

      <button :if={not @beginning} phx-click="load_older" class="gl-btn gl-audit__load-older">
        Load 500 older
      </button>
      <div :if={@beginning} class="gl-audit__beginning gl-muted">— beginning of log —</div>

      <AuditEntry.audit_entry
        :for={{entry, idx} <- Enum.with_index(@filtered)}
        id={entry_id(entry, idx)}
        entry={entry}
        expanded={MapSet.member?(@expanded, entry_id(entry, idx))}
      />
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

  defp current_year_month do
    d = Date.utc_today()
    "#{d.year}-#{String.pad_leading(Integer.to_string(d.month), 2, "0")}"
  end

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

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
