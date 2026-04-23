defmodule GlorboWeb.CostsLive do
  @moduledoc """
  Per-agent monthly cost ledger — GET `/costs` (T2-D, #242).

  Aggregates `Glorbo.Budget.Ledger` rows across every agent in
  every company on disk. Data is already captured on every
  dispatch; this page surfaces the history.

  Shape:

    * Top: 3 summary cards (this month total, last 12mo total,
      highest-spend agent).
    * Main: a matrix table, one row per agent, one column per
      month (most recent 12 months left→right), cells show
      `$X.YY`, `—` for no data.

  Read-only; editing budgets happens by editing agent frontmatter
  (`budget_usd_cents_month:`) which the Parser consumes.
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias Glorbo.Budget.CompanyCap
  alias Glorbo.Budget.Ledger
  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      subscribe_agent_status_all()
    end

    {:ok,
     socket
     |> assign(:page_title, "Costs — Glorbo")
     |> assign(:sidebar_active, :costs)
     |> assign(:current_company, nil)
     |> load_and_assign()
     |> ChatDrawer.State.wire_drawer()}
  end

  @impl true
  def handle_info({:agent_status, _slug, _status, _working_on}, socket),
    do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  defp subscribe_agent_status_all do
    co_dir = Path.join(base_dir(), "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        Enum.each(slugs, fn slug ->
          if File.dir?(Path.join(co_dir, slug)) do
            Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:agents:status")
          end
        end)

      _ ->
        :ok
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-costs-page">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">costs</h1>
          <p class="gl-overview__path">
            <span class="gl-muted">
              Per-agent monthly LLM spend. Data is captured on every
              dispatch in <code>Glorbo.Budget</code>; this page is a read-only
              surface over the last 12 months.
            </span>
          </p>
        </div>
      </header>

      <div class="gl-costs__summary">
        <article class="gl-stat-card">
          <div class="gl-stat-card__label">this month</div>
          <div class="gl-stat-card__value">${format_cents(@this_month_cents)}</div>
          <div class="gl-stat-card__foot gl-muted">{@current_ym}</div>
        </article>
        <article class="gl-stat-card">
          <div class="gl-stat-card__label">last 12 months</div>
          <div class="gl-stat-card__value">${format_cents(@last_12mo_cents)}</div>
          <div class="gl-stat-card__foot gl-muted">across all companies</div>
        </article>
        <article class="gl-stat-card">
          <div class="gl-stat-card__label">top spender</div>
          <div class="gl-stat-card__value">{@top_spender.slug || "—"}</div>
          <div class="gl-stat-card__foot gl-muted">
            {if @top_spender.slug,
              do: "$#{format_cents(@top_spender.cents)} · " <> @top_spender.company,
              else: "no data yet"}
          </div>
        </article>
      </div>

      <section :if={@company_caps != []} class="gl-panel gl-costs__company-caps">
        <h2 class="gl-panel__header">company caps</h2>
        <ul class="gl-costs__caps-list">
          <li
            :for={c <- @company_caps}
            class={["gl-costs__cap-row", "gl-costs__cap-row--" <> c.state]}
          >
            <.link navigate={~p"/companies/#{c.company}"} class="gl-costs__cap-slug">
              {c.company}
            </.link>
            <span class="gl-costs__cap-bar" aria-hidden="true">
              <span
                class={["gl-costs__cap-fill", "gl-costs__cap-fill--" <> c.state]}
                style={"width: #{c.pct}%"}
              />
            </span>
            <span class="gl-costs__cap-text gl-tabular">
              ${format_cents(c.used_cents)} / ${format_cents(c.cap_cents)}
            </span>
            <span class={["gl-costs__cap-label", "gl-costs__cap-label--" <> c.state]}>
              {c.label}
            </span>
          </li>
        </ul>
      </section>

      <p :if={@rows == []} class="gl-muted">
        No ledger rows yet. Every dispatch with a usage-parsed provider writes
        a row; spin an agent up and come back.
      </p>

      <table :if={@rows != []} class="gl-costs-table">
        <thead>
          <tr>
            <th>agent</th>
            <th>company</th>
            <th class="gl-costs-table__tokens">tokens (in / out)</th>
            <th :for={ym <- @months} class="gl-costs-table__month">{ym}</th>
            <th class="gl-costs-table__total">total</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows}>
            <td class="gl-costs-table__slug">
              <.link navigate={~p"/companies/#{row.company}/agents/#{row.slug}"}>
                {row.slug}
              </.link>
            </td>
            <td class="gl-muted">{row.company}</td>
            <td class="gl-costs-table__tokens gl-tabular">
              {row.prompt_tokens} / {row.completion_tokens}
            </td>
            <td :for={ym <- @months} class="gl-costs-table__cell gl-tabular">
              {cell_text(Map.get(row.by_month, ym))}
            </td>
            <td class="gl-costs-table__total gl-tabular">{cost_total_text(row.total_cents)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Loaders
  # ---------------------------------------------------------------------------

  defp load_and_assign(socket) do
    base = base_dir()
    agents = list_all_agents(base)
    ledger = Ledger.history_for_agents(agents)
    months = recent_months(12)
    current_ym = hd(months)

    rows = build_rows(agents, ledger, months)
    companies = agents |> Enum.map(& &1.company) |> Enum.uniq()
    company_caps = build_company_caps(base, companies)

    socket
    |> assign(:rows, rows)
    |> assign(:months, months)
    |> assign(:current_ym, current_ym)
    |> assign(:this_month_cents, sum_month(rows, current_ym))
    |> assign(:last_12mo_cents, sum_all(rows))
    |> assign(:top_spender, top_spender(rows))
    |> assign(:company_caps, company_caps)
  end

  # #247 — render one row per company that has declared a cap.
  # Companies without `budget_usd_cents_month:` are omitted (no
  # point in showing "0 / —" filler).
  defp build_company_caps(base, companies) do
    companies
    |> Enum.flat_map(fn co ->
      case CompanyCap.read_cap(base, co) do
        nil ->
          []

        cap ->
          used = CompanyCap.used_this_month(base, co)
          pct = if cap > 0, do: min(div(used * 100, cap), 100), else: 0

          state =
            cond do
              used >= cap -> "stop"
              used * 100 >= cap * 80 -> "alert"
              true -> "ok"
            end

          label =
            case state do
              "stop" -> "at cap"
              "alert" -> "#{pct}%"
              _ -> "#{pct}%"
            end

          [
            %{
              company: co,
              cap_cents: cap,
              used_cents: used,
              pct: pct,
              state: state,
              label: label
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.pct, :desc)
  end

  defp list_all_agents(base) do
    case File.ls(Path.join(base, "companies")) do
      {:ok, companies} ->
        companies
        |> Enum.flat_map(fn co ->
          agents_dir = Path.join([base, "companies", co, "agents"])

          case File.ls(agents_dir) do
            {:ok, slugs} ->
              slugs
              |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
              |> Enum.map(&%{slug: &1, company: co})

            _ ->
              []
          end
        end)
        |> Enum.sort_by(&{&1.company, &1.slug})

      _ ->
        []
    end
  end

  # Build per-agent rows with a by_month map + totals. #246 adds
  # token aggregates alongside the cost aggregate — tokens are
  # always captured by the Budget schema even when pricing is
  # unknown, so the Costs page surfaces usage activity for
  # providers that don't have cost telemetry.
  defp build_rows(agents, ledger, months) do
    by_agent = Enum.group_by(ledger, &{&1.company_slug, &1.agent_slug})

    agents
    |> Enum.map(fn %{slug: slug, company: co} ->
      rows_for_slug = Map.get(by_agent, {co, slug}, [])

      by_month =
        rows_for_slug
        |> Map.new(&{&1.year_month, &1.cost_usd_cents})
        |> Map.take(months)

      total_cents = by_month |> Map.values() |> Enum.sum()

      months_set = MapSet.new(months)
      in_range = Enum.filter(rows_for_slug, &MapSet.member?(months_set, &1.year_month))

      prompt_tokens = Enum.reduce(in_range, 0, &(&1.prompt_tokens + &2))
      completion_tokens = Enum.reduce(in_range, 0, &(&1.completion_tokens + &2))

      %{
        slug: slug,
        company: co,
        by_month: by_month,
        total_cents: total_cents,
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens
      }
    end)
    |> Enum.filter(&row_visible?/1)
    |> Enum.sort_by(& &1.total_cents, :desc)
  end

  defp row_visible?(row) do
    row.total_cents > 0 or row.by_month != %{} or row.prompt_tokens > 0 or
      row.completion_tokens > 0
  end

  # Cost totals display matches #246 rule — show "$X.YY" only when
  # we have non-zero cost data (meaning pricing was known for at
  # least one run); otherwise "—" so the director knows "we have
  # token activity but no priced spend" for this provider/model.
  defp cost_total_text(0), do: "—"
  defp cost_total_text(cents), do: "$" <> format_cents(cents)

  defp recent_months(n) do
    {{y, m, _}, _} = :calendar.universal_time()

    for i <- 0..(n - 1) do
      {year, month} = offset_month(y, m, -i)
      format_ym(year, month)
    end
  end

  defp offset_month(y, m, offset) do
    total = y * 12 + (m - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp format_ym(y, m),
    do: "#{y}-" <> String.pad_leading(Integer.to_string(m), 2, "0")

  defp sum_month(rows, ym) do
    Enum.reduce(rows, 0, fn row, acc -> acc + Map.get(row.by_month, ym, 0) end)
  end

  defp sum_all(rows), do: Enum.reduce(rows, 0, &(&1.total_cents + &2))

  defp top_spender([]), do: %{slug: nil, company: nil, cents: 0}

  defp top_spender([top | _]) do
    %{slug: top.slug, company: top.company, cents: top.total_cents}
  end

  defp format_cents(cents) when is_integer(cents) do
    whole = div(cents, 100)
    cents_part = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{whole}.#{cents_part}"
  end

  defp format_cents(_), do: "0.00"

  defp cell_text(nil), do: "—"
  defp cell_text(0), do: "—"
  defp cell_text(cents), do: "$" <> format_cents(cents)
end
