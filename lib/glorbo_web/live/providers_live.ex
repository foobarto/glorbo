defmodule GlorboWeb.ProvidersLive do
  @moduledoc """
  Provider registry dashboard — GET `/providers` (GEP-8 D16).

  Reads `Glorbo.CLI.Registry.list/0` on mount and on the Refresh button.
  The registry snapshot itself only changes on explicit refresh
  (GEP-8 D3, D4, D14) — no polling, no file-system watcher.

  Three status classes surface as coloured badges:

    * **routable** (green) — installed + usage_parser bound.
    * **installed, untracked** (yellow) — installed but `usage_parser =
      "none"`; only routable for agents with
      `allow_untracked_budget: true`.
    * **not installed** (grey) — declared but binary missing from PATH.

  Version/`probe_error` columns are blank until the user clicks
  "Probe versions" (D3). User-declared entries without
  `allow_version_probe = true` stay blank forever by design (D13).
  """
  use GlorboWeb, :live_view

  alias Glorbo.CLI.Registry
  alias Glorbo.CLI.Registry.Provider

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Providers — Glorbo")
     |> assign(:probing, false)
     |> assign_providers()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    Registry.refresh()
    {:noreply, assign_providers(socket)}
  end

  def handle_event("probe", _params, socket) do
    socket = assign(socket, :probing, true)
    # Run in the LV process — fine for ≤ 6 providers × 3 s cap.
    # Larger registries could Task.async this off the mount pid.
    Registry.refresh_with_version_probe()

    {:noreply,
     socket
     |> assign(:probing, false)
     |> assign_providers()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-providers">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">Providers</h1>
        <div class="gl-toolbar">
          <button type="button" class="gl-btn" phx-click="refresh">Refresh</button>
          <button type="button" class="gl-btn" phx-click="probe" disabled={@probing}>
            {if @probing, do: "Probing...", else: "Probe versions"}
          </button>
        </div>
      </header>

      <section class="gl-providers__summary gl-muted">
        {@counts.routable} routable · {@counts.untracked} untracked · {@counts.missing} not installed
      </section>

      <table class="gl-table gl-providers__table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Status</th>
            <th>Path</th>
            <th>Version</th>
            <th>Parser</th>
            <th>Source</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={p <- @providers}
            class={"gl-providers__row gl-providers__row--" <> status_class(p)}
          >
            <td class="gl-tabular">{p.name}</td>
            <td>
              <span class={["gl-badge", "gl-badge--" <> status_class(p)]}>{status_label(p)}</span>
            </td>
            <td class="gl-tabular gl-subtle">{p.resolved_path || "—"}</td>
            <td class="gl-tabular">{version_display(p)}</td>
            <td class="gl-tabular">{p.usage_parser}</td>
            <td class="gl-tabular gl-muted">{p.source}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@providers == []} class="gl-subtle">
        No providers declared. Ship built-ins via <code>priv/providers/*.toml</code>
        or drop user-declared entries at <code>~/.glorbo/providers.toml</code>.
      </p>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data
  # ---------------------------------------------------------------------------

  defp assign_providers(socket) do
    providers = list_safe() |> Enum.sort_by(& &1.name)
    counts = count_by_status(providers)

    socket
    |> assign(:providers, providers)
    |> assign(:counts, counts)
  end

  defp list_safe do
    case Process.whereis(Registry) do
      nil -> []
      _pid -> Registry.list()
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp count_by_status(providers) do
    Enum.reduce(providers, %{routable: 0, untracked: 0, missing: 0}, fn p, acc ->
      case Provider.status(p) do
        :routable -> %{acc | routable: acc.routable + 1}
        :installed_untracked -> %{acc | untracked: acc.untracked + 1}
        :not_installed -> %{acc | missing: acc.missing + 1}
      end
    end)
  end

  defp status_class(p) do
    case Provider.status(p) do
      :routable -> "routable"
      :installed_untracked -> "untracked"
      :not_installed -> "missing"
    end
  end

  defp status_label(p) do
    case Provider.status(p) do
      :routable -> "routable"
      :installed_untracked -> "no budget track"
      :not_installed -> "not installed"
    end
  end

  defp version_display(%Provider{version: nil, probe_error: nil}), do: "—"
  defp version_display(%Provider{version: nil, probe_error: {:timeout, _}}), do: "(timeout)"

  defp version_display(%Provider{version: nil, probe_error: {:non_zero_exit, code}}),
    do: "(exit #{code})"

  defp version_display(%Provider{version: nil, probe_error: :regex_miss}), do: "(no match)"
  defp version_display(%Provider{version: nil, probe_error: err}), do: "(#{inspect(err)})"
  defp version_display(%Provider{version: v}), do: v
end
