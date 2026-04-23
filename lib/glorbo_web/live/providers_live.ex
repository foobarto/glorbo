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
    if connected?(socket) do
      subscribe_agent_status_all()
    end

    {:ok,
     socket
     |> assign(:page_title, "Providers — Glorbo")
     |> assign(:sidebar_active, :providers)
     |> assign(:probing, false)
     |> assign_providers()}
  end

  @impl true
  def handle_info({:agent_status, _slug, _status, _working_on}, socket),
    do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Pick a company to chat.")}

  def handle_event("refresh", _params, socket) do
    Registry.refresh()
    {:noreply, assign_providers(socket)}
  end

  def handle_event("probe", _params, socket) do
    socket = assign(socket, :probing, true)
    # Run in the LV process — fine for the current built-in set and the
    # 3 s per-provider probe cap.
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
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">providers /</span> registry
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">priv/providers/*.toml · </span>{GlorboWeb.LiveHelpers.display_base()}/providers.toml
          </p>
          <p class="gl-overview__quote">
            // Config-driven, not code-driven. Add a TOML file, get a new provider.
          </p>
        </div>
        <div class="gl-providers__actions">
          <button type="button" class="gl-btn" phx-click="refresh">↻ refresh PATH</button>
          <button type="button" class="gl-btn gl-btn--primary" phx-click="probe" disabled={@probing}>
            {if @probing, do: "⟳ probing…", else: "⌕ probe all"}
          </button>
        </div>
      </header>

      <section class="gl-providers__summary">
        <span class="gl-pill gl-pill--alive">
          <span class="gl-pill__dot"></span>{@counts.routable} routable
        </span>
        <span class="gl-pill gl-pill--info">
          <span class="gl-pill__dot"></span>{@counts.untracked} untracked
        </span>
        <span class="gl-pill gl-pill--stop">
          <span class="gl-pill__dot"></span>{@counts.missing} not installed
        </span>
      </section>

      <div :if={@providers != []} class="gl-providers__grid">
        <article
          :for={p <- @providers}
          class={"gl-provider-card gl-provider-card--" <> status_class(p)}
        >
          <header class="gl-provider-card__header">
            <span class="gl-provider-card__name">{p.name}</span>
            <span class="gl-provider-card__source gl-tag">{p.source}</span>
            <span class={["gl-pill", "gl-pill--" <> pill_class(p)]}>
              <span class="gl-pill__dot"></span>{status_label(p)}
            </span>
          </header>
          <dl class="gl-kv gl-provider-card__kv">
            <dt>kind</dt>
            <dd class="gl-tabular">{p.kind}</dd>
            <dt :if={p.kind == :cli}>binary</dt>
            <dd :if={p.kind == :cli} class="gl-tabular">{p.binary}</dd>
            <dt :if={p.kind == :cli}>path</dt>
            <dd
              :if={p.kind == :cli}
              class={[
                "gl-tabular",
                if(p.resolved_path, do: "gl-accent-text", else: "gl-danger-text")
              ]}
            >
              {p.resolved_path || "(not found on PATH)"}
            </dd>
            <dt :if={p.kind == :native}>endpoint</dt>
            <dd :if={p.kind == :native} class="gl-tabular gl-cyan-text">{p.endpoint}</dd>
            <dt :if={p.kind == :native}>auth</dt>
            <dd :if={p.kind == :native} class="gl-tabular">{p.auth}</dd>
            <dt>version</dt>
            <dd class="gl-tabular">{version_display(p)}</dd>
            <dt>parser</dt>
            <dd class="gl-tabular">
              <span :if={p.usage_parser == "none"} class="gl-muted">
                none · untracked budget
              </span>
              <span :if={p.usage_parser != "none"} class="gl-cyan-text">{p.usage_parser}</span>
            </dd>
          </dl>
          <details class="gl-provider-card__toml">
            <summary class="gl-muted">▸ show toml</summary>
            <pre class="gl-provider-card__toml-pre"><code>{read_toml(p)}</code></pre>
          </details>
        </article>
      </div>

      <p :if={@providers == []} class="gl-muted">
        No providers declared. Ship built-ins via <code>priv/providers/*.toml</code>
        or drop user-declared entries at <code>{GlorboWeb.LiveHelpers.display_base()}/providers.toml</code>.
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

  defp pill_class(p) do
    case Provider.status(p) do
      :routable -> "alive"
      :installed_untracked -> "info"
      :not_installed -> "stop"
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

  defp read_toml(%Provider{source_file: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> text
      _ -> "# (could not read #{path})"
    end
  end

  defp read_toml(_), do: "# (no source file)"

  defp subscribe_agent_status_all do
    co_dir = Path.join(GlorboWeb.LiveHelpers.base_dir(), "companies")

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
end
