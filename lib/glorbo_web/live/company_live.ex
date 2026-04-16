defmodule GlorboWeb.CompanyLive do
  @moduledoc """
  Per-company dashboard — GET `/companies/:company` (D-22).

  Renders the heading and the 5-tab bar
  (`Kanban | Chat | Approvals | Audit | Agents`) with `Kanban` as the
  active default. Clicking a tab navigates to the appropriate
  per-company LiveView.

  404 path: unknown company → flash + `push_navigate` to `/companies`.

  Subscribes on `connected?/1` to three per-company PubSub topics
  (agents, approvals, projects) so downstream file events drive a
  re-render — although the tab bar itself is static, the agent grid
  below tabs refreshes when `agents/*` changes.
  """
  use GlorboWeb, :live_view

  @impl true
  def mount(%{"company" => slug}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    if GlorboWeb.Slug.valid?(slug) do
      mount_valid(slug, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid company identifier.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  defp mount_valid(slug, socket) do
    base = base_dir()
    co_path = Path.join([base, "companies", slug])

    if File.dir?(co_path) do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:agents")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:approvals")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{slug}:projects")
      end

      name = company_name(co_path, slug)

      {:ok,
       socket
       |> assign(:page_title, "#{name} — Glorbo")
       |> assign(:company_slug, slug)
       |> assign(:company_name, name)
       |> assign(:agents, load_agents(co_path))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company \"#{slug}\" not found.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_info({:file_event, rel_path, _events}, socket) do
    if String.starts_with?(rel_path, "agents/") do
      base = base_dir()
      co_path = Path.join([base, "companies", socket.assigns.company_slug])
      {:noreply, assign(socket, :agents, load_agents(co_path))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">{@company_name}</h1>
      </header>

      <nav class="gl-tabs" role="tablist">
        <.link
          navigate={"/companies/#{@company_slug}/kanban"}
          class="gl-tab gl-tab--active"
          role="tab"
        >
          Kanban
        </.link>
        <.link
          navigate={"/companies/#{@company_slug}/channels/general"}
          class="gl-tab"
          role="tab"
        >
          Chat
        </.link>
        <.link
          navigate={"/companies/#{@company_slug}/approvals"}
          class="gl-tab"
          role="tab"
        >
          Approvals
        </.link>
        <.link
          navigate={"/companies/#{@company_slug}/audit"}
          class="gl-tab"
          role="tab"
        >
          Audit
        </.link>
        <span class="gl-tab" role="tab">Agents</span>
      </nav>

      <div :if={@agents == []} class="gl-empty">
        <p>No agents in this company.</p>
        <p class="gl-muted">
          Scaffold one with <code>glorbo new agent {@company_slug} &lt;name&gt;</code>
        </p>
      </div>

      <div :if={@agents != []} class="gl-grid gl-grid--agents">
        <.link
          :for={a <- @agents}
          navigate={"/companies/#{@company_slug}/agents/#{a.slug}"}
          class="gl-agent-stub"
        >
          <GlorboWeb.CoreComponents.icon name="user" /> {a.name}
        </.link>
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp company_name(co_path, slug) do
    case File.read(Path.join(co_path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"name" => n}, _} -> to_string(n)
          _ -> slug
        end

      _ ->
        slug
    end
  end

  defp load_agents(co_path) do
    agents_dir = Path.join(co_path, "agents")

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.map(&%{slug: &1, name: String.capitalize(&1)})

      _ ->
        []
    end
  end

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
