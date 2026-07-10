defmodule GlorboWeb.Components.Topbar do
  @moduledoc """
  Persistent top bar (M1 mockup alignment — see abc.zip shell.jsx:11-29).

  Renders the brand, the path breadcrumb for the currently-focused
  company directory, version info (app/bwrap/kernel), the keyboard-
  shortcut hint line, and the TWEAKS toggle button. The `Tweaks`
  LiveView hook owns the drawer controls so saved values survive the
  dead-to-connected layout patch.

  ## Attrs

    * `:current_company` — slug string or nil. Drives the path
      breadcrumb.
    * `:tweaks_open?` — whether the tweaks drawer is open (toggles
      the button's visual state). Defaults to false.

  ## Version data

  `app_version/0` reads `Application.spec(:glorbo, :vsn)` so the
  topbar always matches the shipped release. `bwrap_version/0` is
  best-effort (runs `bwrap --version`, short-timeout, caches nothing
  — the topbar re-renders often but a cache here would need a
  GenServer and the answer is rarely interesting). If either shell-
  out fails the bar just hides the value rather than crashing.
  """
  use Phoenix.Component
  use GlorboWeb, :verified_routes

  attr :current_company, :string, default: nil
  attr :tweaks_open?, :boolean, default: false

  def topbar(assigns) do
    assigns =
      assigns
      |> assign(:app_version, app_version())
      |> assign(:bwrap_version, bwrap_version())
      |> assign(:otp_version, otp_version())
      |> assign(:kernel_version, kernel_version())
      |> assign(:emergency_stopped?, emergency_stopped?(assigns[:current_company]))

    ~H"""
    <header
      id="gl-topbar"
      class="gl-topbar"
      role="banner"
      data-current-company={@current_company}
      phx-hook="Tweaks"
    >
      <button
        type="button"
        id="gl-sidebar-toggle"
        class="gl-topbar__sidebar-toggle"
        aria-label="Toggle sidebar (Ctrl+B)"
        title="Toggle sidebar (Ctrl+B)"
      >
        ‖
      </button>
      <.link navigate={~p"/companies"} class="gl-topbar__brand" aria-label="Go to companies list">
        <span class="gl-topbar__brand-glyph" aria-hidden="true">▟</span> GLORBO
      </.link>
      <span class="gl-topbar__sep" aria-hidden="true">│</span>

      <.link
        navigate={~p"/companies"}
        class="gl-topbar__path"
        title={"All companies · base=#{GlorboWeb.LiveHelpers.display_base()}"}
      >
        {GlorboWeb.LiveHelpers.display_base()}/companies/
        <span :if={@current_company} class="gl-topbar__path-company">{@current_company}</span>
      </.link>

      <span class="gl-topbar__sep" aria-hidden="true">│</span>
      <span class="gl-topbar__version">
        v{@app_version}
        <span :if={@bwrap_version != ""}>· bwrap {@bwrap_version}</span>
        <span :if={@otp_version != ""}>· otp-{@otp_version}</span>
        <span :if={@kernel_version != ""}>· kernel {@kernel_version}</span>
      </span>

      <span class="gl-topbar__spacer"></span>

      <.link
        :if={@current_company}
        navigate={~p"/companies/#{@current_company}/braindump"}
        class="gl-topbar__dump"
        title="Open brain dump (g b)"
      >
        <span class="gl-topbar__dump-glyph" aria-hidden="true">✎</span> dump
      </.link>

      <.link
        :if={@current_company && @emergency_stopped?}
        navigate={~p"/companies/#{@current_company}"}
        class="gl-topbar__estop gl-topbar__estop--engaged"
        title="Emergency stop engaged — all dispatch halted for this company. Click to manage."
      >
        <span aria-hidden="true">⏹</span> EMERGENCY STOP
      </.link>

      <span class="gl-topbar__kbd" aria-hidden="true">
        <kbd>g</kbd><kbd>o</kbd>
        overview · <kbd>g</kbd><kbd>c</kbd>
        chat · <kbd>g</kbd><kbd>k</kbd>
        kanban · <kbd>g</kbd><kbd>a</kbd>
        audit · <kbd>g</kbd><kbd>b</kbd>
        dump
      </span>
      <span class="gl-topbar__sep" aria-hidden="true">│</span>
      <button
        type="button"
        id="gl-tweaks-toggle"
        class={["gl-topbar__tweaks", @tweaks_open? && "gl-topbar__tweaks--on"]}
        aria-expanded={to_string(@tweaks_open?)}
        aria-controls="gl-tweaks-drawer"
      >
        TWEAKS
      </button>
    </header>

    <div
      id="gl-tweaks-drawer"
      class="gl-tweaks-drawer"
      role="region"
      aria-label="Interface tweaks"
      hidden
    >
      <h2 class="gl-panel__header">/tweaks</h2>
      <label class="gl-tweaks-drawer__row">
        <span>density</span>
        <select id="gl-tweaks-density" name="density">
          <option value="comfortable">comfortable</option>
          <option value="dense">dense</option>
        </select>
      </label>
      <label class="gl-tweaks-drawer__row">
        <span>vocab</span>
        <select id="gl-tweaks-vocab" name="vocab">
          <option value="default">agents · companies · director</option>
          <option value="crew">crew · orgs · chief</option>
        </select>
      </label>
      <p class="gl-muted gl-tweaks-drawer__hint">
        Saved to localStorage. Density applies instantly; vocab ships in M5.3.
      </p>
    </div>
    """
  end

  defp app_version do
    case Application.spec(:glorbo, :vsn) do
      nil -> "dev"
      v -> to_string(v)
    end
  end

  defp bwrap_version do
    case System.cmd("bwrap", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", parts: 2)
        |> List.first()
        |> to_string()
        |> String.replace("bwrap ", "")
        |> String.trim()

      _ ->
        ""
    end
  rescue
    _ -> ""
  end

  defp kernel_version do
    case System.cmd("uname", ["-r"], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  defp otp_version do
    :erlang.system_info(:otp_release) |> to_string()
  rescue
    _ -> ""
  end

  defp emergency_stopped?(nil), do: false

  defp emergency_stopped?(co) when is_binary(co) do
    Glorbo.EmergencyStop.engaged?(co)
  rescue
    _ -> false
  end
end
