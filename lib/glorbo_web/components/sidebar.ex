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
    * `:health` — map with `:crashed` and `:alerts` integer counts;
      drives the health-strip dot color and copy.
  """
  use Phoenix.Component

  attr :current_company, :string, default: nil
  attr :health, :map, default: %{alerts: 0, crashed: 0}

  def sidebar(assigns) do
    assigns = assign(assigns, :companies, list_companies())

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
          <span class={["gl-dot", "gl-dot--" <> health_status(@health)]} />
          {health_label(@health)}
        </a>
      </div>
    </aside>
    """
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

  defp health_status(%{crashed: c}) when c > 0, do: "crashed"
  defp health_status(%{alerts: a}) when a > 0, do: "warning"
  defp health_status(_), do: "healthy"

  defp health_label(%{crashed: c}) when c > 0, do: "#{c} crashed"
  defp health_label(%{alerts: a}) when a > 0, do: "#{a} alert(s)"
  defp health_label(_), do: "all systems operational"
end
