defmodule GlorboWeb.ActivityLive do
  @moduledoc """
  Cross-company live activity feed — GET `/activity`.

  Subscribes to `audit:all` (broadcast in addition to the per-company
  `company:<co>:audit` topic from `Glorbo.Company.AuditLog`) and
  renders the most-recent N appends from every company in one stream.

  Initial entries are loaded from each company's current-month
  `audit/YYYY-MM.jsonl` file at mount time, then merged by timestamp
  (descending) and capped. Real-time appends arrive as
  `{:audit_append, company, record}` and are prepended into the in-
  memory tail.

  Filters operate client-side on the loaded window:
  - `company` — dropdown of all companies; empty = all
  - `actor`   — substring on the actor field
  - `action`  — substring on the action field
  - `q`       — free-text against actor + action + target + detail

  Unlike `AuditLive`, this view is intentionally tail-only — there's
  no Load Older button, no CSV export, no convert-to-task. Those
  belong on the per-company audit page; this view is the "what's
  happening now across the install" surface.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0, current_year_month: 0]

  alias GlorboWeb.Components.AuditEntry
  alias GlorboWeb.Components.ChatDrawer

  @cap 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "audit:all")
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "companies")
    end

    companies = list_company_slugs()
    entries = load_initial_tail(companies, @cap)

    {:ok,
     socket
     |> assign(:page_title, "Activity — Glorbo")
     |> assign(:sidebar_active, :activity)
     |> assign(:companies, companies)
     |> assign(:entries, entries)
     |> assign(:company_filter, "")
     |> assign(:actor_filter, "")
     |> assign(:action_filter, "")
     |> assign(:q, "")
     |> assign(:expanded, MapSet.new())
     |> ChatDrawer.State.wire_drawer()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:company_filter, Map.get(params, "company", socket.assigns.company_filter))
     |> assign(:q, Map.get(params, "q", socket.assigns.q))}
  end

  @impl true
  def handle_info({:audit_append, company, record}, socket)
      when is_binary(company) and is_map(record) do
    entry =
      record
      |> stringify_keys()
      |> Map.put("__company", company)

    {:noreply, assign(socket, :entries, append_capped(socket.assigns.entries, entry, @cap))}
  end

  def handle_info({:company_added, _slug}, socket),
    do: {:noreply, assign(socket, :companies, list_company_slugs())}

  def handle_info({:company_removed, _slug}, socket),
    do: {:noreply, assign(socket, :companies, list_company_slugs())}

  def handle_info({:file_event, rel, _events}, socket) do
    {:noreply, ChatDrawer.State.maybe_refresh_drawer(socket, rel)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("filter", params, socket) do
    {:noreply,
     socket
     |> assign(:company_filter, Map.get(params, "company", ""))
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

  @impl true
  def render(assigns) do
    filtered =
      assigns.entries
      |> filter_company(assigns.company_filter)
      |> filter_entries(assigns.actor_filter, assigns.action_filter, assigns.q)
      |> Enum.reverse()

    assigns = assign(assigns, :filtered, filtered)

    ~H"""
    <section class="gl-view gl-activity">
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">
          Activity <span class="gl-muted">live · all companies</span>
        </h1>
      </header>

      <form
        phx-change="filter"
        class="gl-audit__filters"
        role="search"
        aria-label="Activity filters"
      >
        <label for="activity-company" class="gl-sr-only">Company</label>
        <select id="activity-company" name="company" class="gl-input">
          <option value="" selected={@company_filter == ""}>All companies</option>
          <option :for={co <- @companies} value={co} selected={@company_filter == co}>
            {co}
          </option>
        </select>

        <label for="activity-q" class="gl-sr-only">Search</label>
        <input
          type="search"
          id="activity-q"
          name="q"
          value={@q}
          class="gl-input gl-audit__q"
          placeholder="Search actor · action · target · detail…"
        />

        <label for="activity-actor" class="gl-sr-only">Filter by actor</label>
        <input
          type="text"
          id="activity-actor"
          name="actor"
          value={@actor_filter}
          class="gl-input"
          placeholder="actor"
        />

        <label for="activity-action" class="gl-sr-only">Filter by action</label>
        <input
          type="text"
          id="activity-action"
          name="action"
          value={@action_filter}
          class="gl-input"
          placeholder="action"
        />
      </form>

      <div :if={@filtered == []} class="gl-empty">
        No activity yet. Fire a dispatch from any company and watch this fill up.
      </div>

      <div :for={{entry, idx} <- Enum.with_index(@filtered)} class="gl-activity__row">
        <a
          :if={entry["__company"]}
          href={~p"/companies/#{entry["__company"]}/audit"}
          class="gl-activity__co-tag gl-muted"
          title={"Open audit for " <> entry["__company"]}
        >
          {entry["__company"]}
        </a>
        <AuditEntry.audit_entry
          id={entry_id(entry, idx)}
          entry={entry}
          expanded={MapSet.member?(@expanded, entry_id(entry, idx))}
        />
      </div>
    </section>
    """
  end

  # --- helpers ---

  defp list_company_slugs do
    co_dir = Path.join(base_dir(), "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.filter(&File.dir?(Path.join(co_dir, &1)))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp load_initial_tail(companies, cap) do
    ym = current_year_month()
    base = base_dir()

    companies
    |> Enum.flat_map(fn co ->
      path = Path.join([base, "companies", co, "audit", "#{ym}.jsonl"])

      path
      |> tail_jsonl(cap)
      |> Enum.map(&Map.put(&1, "__company", co))
    end)
    |> Enum.sort_by(&entry_ts_for_sort/1, :asc)
    |> Enum.take(-cap)
  end

  defp tail_jsonl(path, n) do
    if File.regular?(path) do
      path
      |> File.stream!([], :line)
      |> Enum.reduce([], fn line, acc ->
        line = String.trim_trailing(line, "\n")

        if line == "" do
          acc
        else
          [line | Enum.take(acc, n - 1)]
        end
      end)
      |> Enum.reverse()
      |> Enum.map(&decode/1)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, m} -> m
      _ -> nil
    end
  end

  defp entry_ts_for_sort(%{"ts" => ts}) when is_binary(ts), do: ts
  defp entry_ts_for_sort(_), do: ""

  defp append_capped(entries, new_entry, cap) do
    appended = entries ++ [new_entry]

    if length(appended) > cap,
      do: Enum.take(appended, -cap),
      else: appended
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp filter_company(entries, ""), do: entries

  defp filter_company(entries, co) when is_binary(co) do
    Enum.filter(entries, fn e -> Map.get(e, "__company") == co end)
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

  defp entry_id(entry, fallback_idx) when is_map(entry) do
    co = to_string(entry["__company"] || "")
    ts = to_string(entry["ts"] || "")
    actor = to_string(entry["actor"] || "")
    action = to_string(entry["action"] || "")
    target = to_string(entry["target"] || "")

    case {ts, actor, action} do
      {"", "", ""} ->
        "activity-#{fallback_idx}"

      _ ->
        hash =
          :crypto.hash(
            :sha256,
            co <> "\0" <> ts <> "\0" <> actor <> "\0" <> action <> "\0" <> target
          )
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 16)

        "activity-#{hash}"
    end
  end

  defp entry_id(_entry, fallback_idx), do: "activity-#{fallback_idx}"
end
