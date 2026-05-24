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
  alias Glorbo.Providers.Detect
  alias Glorbo.Providers.Enable
  alias Glorbo.Providers.ModelCatalog

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
     |> assign(:refreshing_models, false)
     |> assign(:scanning, false)
     |> assign(:scan_results, [])
     |> assign_registry_snapshot()}
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
    {:noreply, assign_registry_snapshot(socket)}
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
     |> assign_registry_snapshot()}
  end

  def handle_event("refresh_models", _params, socket) do
    socket = assign(socket, :refreshing_models, true)
    _ = ModelCatalog.refresh_all()

    {:noreply,
     socket
     |> assign(:refreshing_models, false)
     |> assign_registry_snapshot()}
  end

  # GEP-32 phase 4 — probe localhost for native providers. Results are
  # advisory: discovering a provider does not auto-enable it; the
  # Director still has to add the matching TOML entry before Glorbo
  # will route dispatches at it.
  def handle_event("scan_localhost", _params, socket) do
    socket = assign(socket, :scanning, true)
    results = detect_safe()

    {:noreply,
     socket
     |> assign(:scanning, false)
     |> assign(:scan_results, results)}
  end

  # GEP-32 phase 4 — promote a scan result into `~/.glorbo/providers.toml`.
  # Refreshes the Registry afterwards so the main grid picks up the
  # new entry without a full page reload.
  def handle_event("enable_provider", %{"alias" => alias_name}, socket) do
    detection = Enum.find(socket.assigns.scan_results, &(&1.alias == alias_name))

    case maybe_enable(alias_name, detection) do
      :ok ->
        Registry.refresh()

        {:noreply,
         socket
         |> put_flash(:info, "Enabled #{alias_name} — added to ~/.glorbo/providers.toml.")
         |> assign_registry_snapshot()}

      {:error, :already_enabled} ->
        {:noreply,
         put_flash(socket, :info, "#{alias_name} was already in ~/.glorbo/providers.toml.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Enable failed: #{inspect(reason)}")}
    end
  end

  defp maybe_enable(_alias, nil), do: {:error, :not_in_scan_results}
  defp maybe_enable(alias_name, detection), do: Enable.enable(alias_name, detection: detection)

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
          <button
            type="button"
            class="gl-btn"
            phx-click="refresh_models"
            disabled={@refreshing_models}
          >
            {if @refreshing_models, do: "⟳ refreshing models…", else: "↻ refresh models"}
          </button>
          <button
            type="button"
            class="gl-btn"
            phx-click="scan_localhost"
            disabled={@scanning}
          >
            {if @scanning, do: "⟳ scanning…", else: "⌕ scan localhost"}
          </button>
          <button type="button" class="gl-btn gl-btn--primary" phx-click="probe" disabled={@probing}>
            {if @probing, do: "⟳ probing…", else: "⌕ probe all"}
          </button>
        </div>
      </header>

      <section :if={@scan_results != []} class="gl-providers__scan">
        <h2 class="gl-heading gl-heading--section">localhost scan</h2>
        <p class="gl-overview__quote">
          // Advisory only — add a matching TOML entry to route dispatches.
        </p>
        <ul class="gl-providers__scan-list">
          <li
            :for={r <- @scan_results}
            class={"gl-providers__scan-row gl-providers__scan-row--" <> Atom.to_string(r.status)}
          >
            <span class="gl-tabular">{r.alias}</span>
            <span class="gl-muted">{r.endpoint}</span>
            <span>{scan_status_label(r.status)}</span>
            <button
              :if={r.status == :ready}
              type="button"
              class="gl-btn gl-btn--sm"
              phx-click="enable_provider"
              phx-value-alias={r.alias}
            >
              + enable
            </button>
          </li>
        </ul>
      </section>

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
            <dt :if={p.kind == :native}>models</dt>
            <dd :if={p.kind == :native} class="gl-tabular">
              {catalog_model_count(@catalog, p.name)}
            </dd>
            <dt :if={p.kind == :native}>catalog</dt>
            <dd :if={p.kind == :native} class={catalog_status_class(@catalog, p.name)}>
              {catalog_status_label(@catalog, p.name)}
            </dd>
            <dt :if={p.kind == :native}>refreshed</dt>
            <dd :if={p.kind == :native} class="gl-tabular">
              {catalog_refreshed(@catalog, p.name)}
            </dd>
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

  defp assign_registry_snapshot(socket) do
    providers = list_safe() |> Enum.sort_by(& &1.name)
    counts = count_by_status(providers)
    catalog = catalog_safe()

    socket
    |> assign(:providers, providers)
    |> assign(:counts, counts)
    |> assign(:catalog, catalog)
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

  defp catalog_safe do
    case Process.whereis(ModelCatalog) do
      nil -> %{}
      _pid -> ModelCatalog.summary()
    end
  rescue
    _ -> %{}
  catch
    _, _ -> %{}
  end

  defp detect_safe do
    Detect.run()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp scan_status_label(:ready), do: "reachable"
  defp scan_status_label(:unreachable), do: "not listening"
  defp scan_status_label(:shape_mismatch), do: "responded · unknown service"
  defp scan_status_label(:wrong_fingerprint), do: "responded · other service"
  defp scan_status_label(other), do: Atom.to_string(other)

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

  defp catalog_model_count(catalog, provider_name) do
    case Map.get(catalog, provider_name) do
      %{model_count: count} -> Integer.to_string(count)
      _ -> "—"
    end
  end

  defp catalog_status_label(catalog, provider_name) do
    case Map.get(catalog, provider_name, %{status: :idle}).status do
      :ready -> "cached"
      :auth -> "auth failed"
      :unreachable -> "unreachable"
      :stale -> "stale"
      :shape -> "probe broken"
      _ -> "not refreshed"
    end
  end

  defp catalog_status_class(catalog, provider_name) do
    case Map.get(catalog, provider_name, %{status: :idle}).status do
      :ready -> "gl-tabular gl-accent-text"
      :idle -> "gl-tabular gl-muted"
      _ -> "gl-tabular gl-danger-text"
    end
  end

  defp catalog_refreshed(catalog, provider_name) do
    case Map.get(catalog, provider_name) do
      %{refreshed_at: %DateTime{} = dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
      _ -> "—"
    end
  end

  defp version_display(%Provider{version: nil, probe_error: nil}), do: "—"
  defp version_display(%Provider{version: nil, probe_error: {:timeout, _}}), do: "(timeout)"

  defp version_display(%Provider{version: nil, probe_error: {:non_zero_exit, code}}),
    do: "(exit #{code})"

  defp version_display(%Provider{version: nil, probe_error: :regex_miss}), do: "(no match)"
  defp version_display(%Provider{version: nil, probe_error: err}), do: "(#{inspect(err)})"
  defp version_display(%Provider{version: v}), do: v

  # Threatmodel: the raw TOML may contain user-set env overrides
  # such as `env = { ANTHROPIC_API_KEY = "sk-..." }`. Mask any value
  # whose key looks secret-shaped so the dashboard doesn't render
  # credentials in plaintext. Codex round-2 review pointed out the
  # original regex only matched a small set of bare key names + only
  # double-quoted strings, so common env names like
  # `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `*_TOKEN`, and single-
  # quoted TOML strings stayed in the clear. Now matches:
  #   * keys containing any of: key, token, secret, password, auth,
  #     bearer, credential, cookie, session, sas, signature
  #   * the whole `[A-Z][A-Z0-9_]*` env-style identifier wrapper
  #     (so `ANTHROPIC_API_KEY` matches via the `_KEY` substring)
  #   * either double- or single-quoted string values
  defp read_toml(%Provider{source_file: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, text} -> mask_toml_secrets(text)
      _ -> "# (could not read #{path})"
    end
  end

  defp read_toml(_), do: "# (no source file)"

  # A TOML key is "secret-shaped" if its name (case-insensitive)
  # contains any of these substrings. Substring match (not word
  # boundary) so `ANTHROPIC_API_KEY` matches via `key`, `gh_token`
  # via `token`, `auth_bearer` via both. False positives are fine —
  # this is a dashboard masking, not the source of truth.
  @secret_key_substrings ~w(key token secret password auth bearer credential cookie session sas signature)

  # Match a TOML `key = "..."` (or `'...'`) assignment ANYWHERE in the
  # text — NOT line-anchored — so inline-table entries like
  # `env = { ANTHROPIC_API_KEY = "sk-..." }` get masked too (Copilot
  # review on PR #34 round 2). The string body uses
  # `(?:\\.|(?!\k<q>).)*` so it handles escaped quote characters
  # (`"a\"b"`) without truncating early.
  @toml_assignment_re ~r/(?<key>[A-Za-z_][A-Za-z0-9_-]*)(?<spc>[\t ]*=[\t ]*)(?<q>["'])(?<val>(?:\\.|(?!\k<q>).)*)\k<q>/

  # Public-but-`@doc false` so tests can drive the masking logic
  # without going through the full LiveView render.
  @doc false
  def mask_toml_secrets(text) when is_binary(text) do
    Regex.replace(@toml_assignment_re, text, fn full, key, spc, q, _val ->
      if secret_shaped_key?(key) do
        "#{key}#{spc}#{q}***#{q}"
      else
        full
      end
    end)
  end

  defp secret_shaped_key?(key) when is_binary(key) do
    lower = String.downcase(key)
    Enum.any?(@secret_key_substrings, &String.contains?(lower, &1))
  end

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
