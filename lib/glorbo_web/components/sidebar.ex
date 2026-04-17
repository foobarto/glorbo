defmodule GlorboWeb.Components.Sidebar do
  @moduledoc """
  Persistent left-rail sidebar (220px, D-09).

  Lists every company under `<base>/companies/*` as a navigable link,
  marks the active company via a 2px accent left-rail (see UI-SPEC
  §Color accent reserved list item #1), and renders a bottom
  "health strip" that summarises crashed/alert counts and links to
  `/health`.

  ## Attrs

    * `:current_company` — slug string or nil; when matched, the row
      gets `gl-sidebar__item--active`.

  The health-strip badge is derived from `Glorbo.Doctor.run_checks/0`
  internally — the previous `:health` attr was never populated by any
  LiveView and made the badge lie ("all systems operational") regardless
  of actual Doctor state (TODO2.md §3).
  """
  use Phoenix.Component

  attr :current_company, :string, default: nil

  def sidebar(assigns) do
    assigns =
      assigns
      |> assign(:companies, list_companies())
      |> assign(:health, compute_health())

    ~H"""
    <aside class="gl-sidebar">
      <header class="gl-sidebar__header">Companies</header>
      <nav>
        <a
          :for={co <- @companies}
          href={"/companies/#{co.slug}"}
          class={[
            "gl-sidebar__item",
            @current_company == co.slug && "gl-sidebar__item--active"
          ]}
        >
          <GlorboWeb.CoreComponents.icon name="folder" /> {co.name}
        </a>
        <div :if={@companies == []} class="gl-sidebar__item gl-muted">(none)</div>
      </nav>
      <div class="gl-sidebar__health-strip">
        <a href="/health">
          <GlorboWeb.Components.HealthDot.health_dot
            status={health_status_atom(@health)}
            label={"Doctor summary: #{health_label(@health)}"}
          />
          {health_label(@health)}
        </a>
      </div>
    </aside>
    """
  end

  # Roll up Doctor check results into `%{blocker: N, warning: N}` so the
  # footer badge reflects real host state. Wrapped in try/rescue/catch
  # so the component never crashes a layout render on Doctor hiccups.
  defp compute_health do
    checks = Glorbo.Doctor.run_checks()

    blocker =
      Enum.count(checks, fn c ->
        not c.pass and Map.get(c, :severity, :blocker) == :blocker
      end)

    warning =
      Enum.count(checks, fn c ->
        not c.pass and Map.get(c, :severity, :blocker) == :warning
      end)

    %{blocker: blocker, warning: warning}
  rescue
    _ -> %{blocker: 0, warning: 0}
  catch
    _, _ -> %{blocker: 0, warning: 0}
  end

  defp list_companies do
    base = Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
    dir = Path.join(base, "companies")

    case File.ls(dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(dir, &1)))
        |> Enum.map(&%{slug: &1, name: String.capitalize(&1)})

      _ ->
        []
    end
  end

  # Atom variant for HealthDot (which takes an atom); closed-set map
  # avoids `String.to_existing_atom/1` with its test-env gotchas.
  defp health_status_atom(%{blocker: b}) when b > 0, do: :crashed
  defp health_status_atom(%{warning: w}) when w > 0, do: :warning
  defp health_status_atom(_), do: :healthy

  defp health_label(%{blocker: b}) when b > 0, do: "#{b} blocker check#{s(b)} failing"
  defp health_label(%{warning: w}) when w > 0, do: "#{w} warning#{s(w)}"
  defp health_label(_), do: "all systems operational"

  defp s(1), do: ""
  defp s(_), do: "s"
end
