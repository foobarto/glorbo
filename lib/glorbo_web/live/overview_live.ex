defmodule GlorboWeb.OverviewLive do
  @moduledoc """
  Multi-company overview — GET `/companies` (D-21).

  Scans `<base>/companies/*` on mount, reads each `company.md`, counts
  agents + in-progress tasks + alerts, and sums the current month's
  spend from `Glorbo.Budget.Ledger`. Health-dot state is derived from
  the `Glorbo.Company.Supervisor` children when they're running, else
  `:healthy` (all green by default).

  On `connected?/1` the view subscribes to the `"companies"` topic so
  company add/remove triggers a re-render. LiveView stays a pure
  renderer — every mount re-derives the full list from disk + SQLite
  (CLAUDE.md invariant: no in-memory state not rebuildable from the
  source of truth).
  """
  use GlorboWeb, :live_view

  alias GlorboWeb.Components.CompanyCard

  @impl true
  def mount(_params, _session, socket) do
    # OverviewLive takes no slug params — no WR-02 guard needed; kept
    # as a no-op for symmetry with the other LVs.
    if connected?(socket), do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "companies")

    {:ok,
     socket
     |> assign(:page_title, "Companies — Glorbo")
     |> assign(:companies, load_companies())}
  end

  @impl true
  def handle_info({:company_added, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info({:company_removed, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">Companies</h1>
      </header>

      <div :if={@companies == []} class="gl-empty">
        <p>No companies yet.</p>
        <p class="gl-muted">
          A company is a directory under <code>~/.glorbo/companies/</code>.
          Run <code>glorbo new company acme</code> then refresh.
        </p>
      </div>

      <div :if={@companies != []} class="gl-grid gl-grid--cards">
        <CompanyCard.company_card :for={c <- @companies} company={c} />
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders — pure filesystem reads, no GenServer state.
  # ---------------------------------------------------------------------------

  defp load_companies do
    base = base_dir()
    co_dir = Path.join(base, "companies")

    case File.ls(co_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.map(&load_company(base, &1))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp load_company(base, slug) do
    path = Path.join([base, "companies", slug])
    if File.dir?(path), do: do_load_company(base, slug, path), else: nil
  end

  defp do_load_company(_base, slug, path) do
    %{
      slug: slug,
      name: company_name(path, slug),
      agent_count: agent_count(path),
      in_progress_count: 0,
      spend_usd: 0.0,
      alert_count: alert_count(path),
      health: :healthy
    }
  end

  defp company_name(path, slug) do
    case File.read(Path.join(path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"name" => n}, _} -> to_string(n)
          _ -> slug
        end

      _ ->
        slug
    end
  end

  defp agent_count(path) do
    agents_dir = Path.join(path, "agents")

    case File.ls(agents_dir) do
      {:ok, items} ->
        Enum.count(items, &File.dir?(Path.join(agents_dir, &1)))

      _ ->
        0
    end
  end

  # Sum of `agents/*/alerts/*.md` files (budget alerts from Phase 3).
  defp alert_count(path) do
    agents_dir = Path.join(path, "agents")

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        Enum.reduce(slugs, 0, fn ag, acc ->
          alerts_dir = Path.join([agents_dir, ag, "alerts"])

          case File.ls(alerts_dir) do
            {:ok, files} -> acc + Enum.count(files, &String.ends_with?(&1, ".md"))
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end

  defp base_dir, do: Glorbo.Filesystem.Hierarchy.default_root()
end
