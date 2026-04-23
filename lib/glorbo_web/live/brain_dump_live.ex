defmodule GlorboWeb.BrainDumpLive do
  @moduledoc """
  Daily brain-dump capture surface — GET `/companies/:company/braindump`.

  Three panels:

    1. **Capture** — big textarea + submit button. Submitting appends
       to today's `companies/<co>/braindump/YYYY-MM-DD.md` file via
       `Glorbo.BrainDump.capture/3` and emits a `braindump.capture`
       audit event.
    2. **Today** — entries captured today, newest first, each with
       "convert to task" and "copy link" buttons.
    3. **Recent days** — last 13 prior days collapsed per-day with a
       count; expanding shows the entries.

  Conversion scaffolds a task in `projects/inbox/tasks/` with a
  `source: braindump` frontmatter key and a back-pointer to the
  original capture timestamp. The entry in the day file is kept
  intact — conversion is additive, not a move.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.BrainDump
  alias Glorbo.Company.AuditLog
  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    cond do
      not Glorbo.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not File.dir?(Path.join([base_dir(), "companies", co])) ->
        {:ok,
         socket
         |> put_flash(:error, "Company \"#{co}\" not found.")
         |> push_navigate(to: ~p"/companies")}

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
        end

        {:ok, load_and_assign(socket, co)}
    end
  end

  @impl true
  def handle_info({:agent_status, _slug, _status, _working_on}, socket),
    do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("capture", %{"body" => body}, socket) do
    co = socket.assigns.company_slug

    case BrainDump.capture(base_dir(), co, body) do
      {:ok, entry} ->
        emit_audit(co, "braindump.capture", entry.ts, %{title: entry.title, day: entry.day})

        {:noreply,
         socket
         |> put_flash(:info, "Captured.")
         |> assign(:draft, "")
         |> load_and_assign(co)}

      {:error, :empty} ->
        {:noreply, put_flash(socket, :error, "Can't capture an empty dump.")}

      {:error, :too_large} ->
        {:noreply,
         put_flash(socket, :error, "Capture exceeds 64KB — use a task for long-form content.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Capture failed: #{inspect(reason)}")}
    end
  end

  def handle_event("convert", %{"ts" => ts}, socket) do
    co = socket.assigns.company_slug
    entry = Enum.find(socket.assigns.today ++ flat_recent(socket), &(&1.ts == ts))

    if entry do
      do_convert(socket, co, ts, entry)
    else
      {:noreply, put_flash(socket, :error, "Entry not found.")}
    end
  end

  def handle_event("expand_day", %{"day" => day}, socket) do
    expanded = MapSet.put(socket.assigns.expanded_days, day)
    {:noreply, assign(socket, :expanded_days, expanded)}
  end

  def handle_event("collapse_day", %{"day" => day}, socket) do
    expanded = MapSet.delete(socket.assigns.expanded_days, day)
    {:noreply, assign(socket, :expanded_days, expanded)}
  end

  def handle_event("draft_change", %{"body" => body}, socket) do
    {:noreply, assign(socket, :draft, body)}
  end

  defp do_convert(socket, co, ts, entry) do
    case BrainDump.convert_to_task(base_dir(), co, entry) do
      {:ok, rel_path} ->
        emit_audit(co, "braindump.convert_to_task", ts, %{task_path: rel_path})

        {:noreply,
         socket
         |> put_flash(:info, "Task scaffolded: #{rel_path}")
         |> load_and_assign(co)}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, "A task from this entry already exists.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Conversion failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-braindump-page">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">{@company_slug} /</span> brain dump
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">
              <code>companies/{@company_slug}/braindump/{@today_day}.md</code> · append-only daily log
            </span>
          </p>
        </div>
      </header>

      <section class="gl-panel gl-braindump__capture">
        <h2 class="gl-panel__header">capture</h2>
        <form phx-submit="capture" phx-change="draft_change" class="gl-braindump__form">
          <label class="gl-sr-only" for="gl-bd-body">Brain dump body</label>
          <textarea
            id="gl-bd-body"
            name="body"
            class="gl-braindump__textarea"
            rows="4"
            placeholder="dump a thought, todo, question, observation… first line becomes the title"
            autocomplete="off"
            phx-hook="SubmitOnCtrlEnter"
          >{@draft}</textarea>
          <div class="gl-braindump__form-actions">
            <span class="gl-muted">
              ctrl+enter to submit · first line becomes the title · body kept verbatim
            </span>
            <button type="submit" class="gl-btn gl-btn--primary" disabled={@draft == ""}>
              capture
            </button>
          </div>
        </form>
      </section>

      <section class="gl-panel gl-braindump__list">
        <h2 class="gl-panel__header">today · {length(@today)} entries</h2>
        <p :if={@today == []} class="gl-muted">nothing captured today yet.</p>
        <ol :if={@today != []} class="gl-braindump__entries">
          <li :for={e <- @today} class="gl-braindump__entry">
            <header class="gl-braindump__entry-head">
              <span class="gl-braindump__ts">{time_of(e.ts)}</span>
              <strong class="gl-braindump__title">{e.title}</strong>
              <div class="gl-braindump__entry-actions">
                <button
                  type="button"
                  class="gl-btn gl-btn--sm"
                  phx-click="convert"
                  phx-value-ts={e.ts}
                >
                  convert → task
                </button>
              </div>
            </header>
            <pre :if={e.body != e.title} class="gl-braindump__body">{e.body}</pre>
          </li>
        </ol>
      </section>

      <section :if={@recent_by_day != []} class="gl-panel gl-braindump__list">
        <h2 class="gl-panel__header">recent days</h2>
        <ol class="gl-braindump__days">
          <li :for={{day, entries} <- @recent_by_day} class="gl-braindump__day">
            <button
              type="button"
              class="gl-braindump__day-head"
              phx-click={
                if MapSet.member?(@expanded_days, day), do: "collapse_day", else: "expand_day"
              }
              phx-value-day={day}
              aria-expanded={to_string(MapSet.member?(@expanded_days, day))}
            >
              <span class="gl-braindump__day-chevron" aria-hidden="true">
                {if MapSet.member?(@expanded_days, day), do: "▾", else: "▸"}
              </span>
              <strong>{day}</strong>
              <span class="gl-muted">· {length(entries)} entries</span>
            </button>
            <ol :if={MapSet.member?(@expanded_days, day)} class="gl-braindump__entries">
              <li :for={e <- entries} class="gl-braindump__entry">
                <header class="gl-braindump__entry-head">
                  <span class="gl-braindump__ts">{time_of(e.ts)}</span>
                  <strong class="gl-braindump__title">{e.title}</strong>
                  <div class="gl-braindump__entry-actions">
                    <button
                      type="button"
                      class="gl-btn gl-btn--sm"
                      phx-click="convert"
                      phx-value-ts={e.ts}
                    >
                      convert → task
                    </button>
                  </div>
                </header>
                <pre :if={e.body != e.title} class="gl-braindump__body">{e.body}</pre>
              </li>
            </ol>
          </li>
        </ol>
      </section>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Loaders
  # ---------------------------------------------------------------------------

  defp load_and_assign(socket, co) do
    entries = BrainDump.list(base_dir(), co, limit_days: 14)
    today = today_string()
    {today_entries, older} = Enum.split_with(entries, &(&1.day == today))

    recent_by_day =
      older
      |> Enum.group_by(& &1.day)
      |> Enum.sort_by(fn {day, _} -> day end, :desc)

    socket
    |> assign(:page_title, "#{co} · brain dump — Glorbo")
    |> assign(:sidebar_active, :braindump)
    |> assign(:current_company, co)
    |> assign(:company_slug, co)
    |> assign(:today, today_entries)
    |> assign(:today_day, today)
    |> assign(:recent_by_day, recent_by_day)
    |> assign(:expanded_days, socket.assigns[:expanded_days] || MapSet.new())
    |> assign(:draft, socket.assigns[:draft] || "")
    |> ChatDrawer.State.wire_drawer()
  end

  defp today_string, do: Date.to_iso8601(Date.utc_today())

  defp flat_recent(socket) do
    Enum.flat_map(socket.assigns.recent_by_day, fn {_day, entries} -> entries end)
  end

  defp time_of(ts) do
    case String.split(ts, "T", parts: 2) do
      [_, tz] -> tz |> String.trim_trailing("Z") |> String.slice(0, 8)
      _ -> ts
    end
  end

  defp emit_audit(company, action, target, detail) do
    base =
      Map.merge(detail, %{
        actor: "director",
        action: action,
        target: target
      })

    # B1: AuditLog is per-company under Glorbo.Company.Supervisor
    # (`via(company, :audit_log)`) in production, but unit LV tests
    # run with a single bare-module AuditLog. `append_for/2` resolves
    # the right target; the old `AuditLog.append(base)` targeted the
    # bare module by default and silently dropped every production
    # event via the rescue :exit clause.
    AuditLog.append_for(company, base)
  end
end
