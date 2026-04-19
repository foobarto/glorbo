defmodule GlorboWeb.Components.Sidebar do
  @moduledoc """
  Persistent left-rail sidebar (260px, mockup-aligned — see `shell.jsx`
  `Sidebar` in the reference zip).

  Three sections, each with an uppercase 11px letterspaced label:

    1. **COMPANY** — six nav items (Overview / Kanban / Channels /
       Approvals / Audit log / Providers). Each gets a glyph, a
       label, and optionally a count badge. Active row has phosphor
       text + 2px left border + a slightly-raised background.
    2. **AGENTS** — ASCII-tree listing (`├─ / └─`) of the current
       company's agents, each with a status pill dot + slug + provider
       short-name.
    3. **PROJECTS** — ASCII-tree listing of the current company's
       projects, each with a `▸` glyph + slug.

  The agent + project lists stay empty when no company is focused
  (overview, health, providers routes); the COMPANY nav still renders
  but those five entries remain disabled-looking until a company is
  selected (dim + non-navigable).

  ## Attrs

    * `:current_company` — slug string or nil.
    * `:active` — one of `:overview | :kanban | :chat | :approvals |
      :audit | :providers | nil`; drives the active-row highlight.
  """
  use Phoenix.Component
  use GlorboWeb, :verified_routes

  attr :current_company, :string, default: nil
  attr :active, :atom, default: nil

  @nav [
    {:overview, "◈", "Overview", :company},
    {:kanban, "▤", "Kanban", :company},
    {:chat, "◫", "Channels", :company},
    {:approvals, "✓", "Approvals", :company},
    {:audit, "≡", "Audit log", :company},
    {:providers, "⎔", "Providers", :global}
  ]

  def sidebar(assigns) do
    # Focus a company: the one in the URL if any, else the first on disk.
    # This keeps the sidebar functional on /providers, /health, and
    # /companies (the cross-company landing) — navigating from there
    # into a sub-view takes you into that company.
    focus = assigns.current_company || first_company()

    assigns =
      assigns
      |> assign(:nav, @nav)
      |> assign(:focus, focus)
      |> assign(:agents, list_agents(focus))
      |> assign(:projects, list_projects(focus))

    ~H"""
    <aside class="gl-sidebar">
      <div class="gl-sidebar__section-label">COMPANY</div>
      <nav>
        <.link
          :for={{id, glyph, label, scope} <- @nav}
          navigate={nav_href(id, @focus)}
          class={[
            "gl-sidebar__nav-item",
            @active == id && "gl-sidebar__nav-item--active",
            scope == :company && is_nil(@focus) && "gl-sidebar__nav-item--disabled"
          ]}
          aria-current={@active == id && "page"}
        >
          <span class="gl-sidebar__glyph" aria-hidden="true">{glyph}</span>
          <span class="gl-sidebar__label">{label}</span>
        </.link>
      </nav>

      <div class="gl-sidebar__section-label gl-sidebar__section-label--spaced">AGENTS</div>
      <div :if={@agents == []} class="gl-sidebar__empty">(none)</div>
      <.agent_row
        :for={{a, i} <- Enum.with_index(@agents)}
        company={@focus}
        agent={a}
        prefix={tree_prefix(i, length(@agents))}
      />

      <div class="gl-sidebar__section-label gl-sidebar__section-label--spaced">PROJECTS</div>
      <div :if={@projects == []} class="gl-sidebar__empty">(none)</div>
      <.project_row
        :for={{p, i} <- Enum.with_index(@projects)}
        company={@focus}
        project={p}
        prefix={tree_prefix(i, length(@projects))}
      />

      <div class="gl-sidebar__footer">
        <GlorboWeb.Components.HealthDot.health_dot
          status={health_status_atom(compute_health())}
          label={"Doctor summary: " <> health_label(compute_health())}
        />
        <.link navigate={~p"/health"} class="gl-sidebar__footer-link">
          {health_label(compute_health())}
        </.link>
      </div>
    </aside>
    """
  end

  attr :company, :string, required: true
  attr :agent, :map, required: true
  attr :prefix, :string, required: true

  defp agent_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/companies/#{@company}/agents/#{@agent.slug}"}
      class="gl-sidebar__nav-item gl-sidebar__nav-item--tree"
    >
      <span class="gl-sidebar__tree-line" aria-hidden="true">{@prefix}</span>
      <span
        class={["gl-pill gl-pill--" <> Atom.to_string(@agent.status), "gl-sidebar__pill"]}
        aria-hidden="true"
      >
        <span class="gl-pill__dot"></span>
      </span>
      <i
        :if={@agent.icon}
        class={["gl-sidebar__icon", "fa-solid", @agent.icon]}
        aria-hidden="true"
      />
      <span class="gl-sidebar__label">{@agent.slug}</span>
      <span class="gl-sidebar__meta">{short_provider(@agent.provider)}</span>
    </.link>
    """
  end

  attr :company, :string, required: true
  attr :project, :map, required: true
  attr :prefix, :string, required: true

  defp project_row(assigns) do
    ~H"""
    <.link
      navigate={~p"/companies/#{@company}/kanban?project=#{@project.slug}"}
      class="gl-sidebar__nav-item gl-sidebar__nav-item--tree"
    >
      <span class="gl-sidebar__tree-line" aria-hidden="true">{@prefix}</span>
      <i
        :if={@project.icon}
        class={["gl-sidebar__icon", "fa-solid", @project.icon]}
        aria-hidden="true"
      />
      <span
        :if={is_nil(@project.icon)}
        class="gl-sidebar__glyph gl-sidebar__glyph--dim"
        aria-hidden="true"
      >
        ▸
      </span>
      <span class="gl-sidebar__label">{@project.slug}</span>
    </.link>
    """
  end

  defp nav_href(:providers, _), do: ~p"/providers"
  defp nav_href(:overview, nil), do: ~p"/companies"
  defp nav_href(:overview, slug), do: ~p"/companies/#{slug}"
  defp nav_href(_, nil), do: "#"
  defp nav_href(:kanban, slug), do: ~p"/companies/#{slug}/kanban"
  defp nav_href(:chat, slug), do: ~p"/companies/#{slug}/channels/general"
  defp nav_href(:approvals, slug), do: ~p"/companies/#{slug}/approvals"
  defp nav_href(:audit, slug), do: ~p"/companies/#{slug}/audit"

  defp tree_prefix(i, count) when i == count - 1, do: "└─ "
  defp tree_prefix(_, _), do: "├─ "

  defp short_provider(nil), do: ""

  defp short_provider(provider) when is_binary(provider) do
    provider |> String.split("-") |> List.first() || provider
  end

  defp short_provider(_), do: ""

  defp first_company do
    base = Glorbo.Filesystem.Hierarchy.default_root()
    dir = Path.join(base, "companies")

    case File.ls(dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.find(&File.dir?(Path.join(dir, &1)))

      _ ->
        nil
    end
  end

  defp list_agents(nil), do: []

  defp list_agents(company) do
    base = Glorbo.Filesystem.Hierarchy.default_root()
    agents_dir = Path.join([base, "companies", company, "agents"])

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.map(&agent_row(agents_dir, &1))

      _ ->
        []
    end
  end

  defp agent_row(agents_dir, slug) do
    md = Glorbo.Agent.FileLayout.agent_md(Path.join(agents_dir, slug))
    {provider, icon} = scan_agent_md(md)

    company = infer_company_from_path(agents_dir)

    %{
      slug: slug,
      status: live_status(company, slug),
      provider: provider,
      icon: icon
    }
  end

  # Light-weight agent.md skim — pulls `provider:` + `icon:` without
  # a full YAML parse (sidebar renders on every company page load; a
  # full parse per agent per render is overkill). The regexes accept
  # optional quoting.
  defp scan_agent_md(path) do
    case File.read(path) do
      {:ok, content} -> {scan_provider(content), scan_icon(content)}
      _ -> {nil, nil}
    end
  end

  defp scan_provider(content) do
    case Regex.run(~r/^provider:\s*([^\s\n]+)/m, content) do
      [_, p] -> String.trim(p, "\"")
      _ -> nil
    end
  end

  @fa_icon_regex ~r/\A[a-z][a-z0-9-]{0,63}\z/

  defp scan_icon(content) do
    case Regex.run(~r/^icon:\s*"?([^"\n]+?)"?\s*$/m, content) do
      [_, raw] ->
        name = raw |> String.trim() |> String.downcase() |> String.replace_leading("fa-", "")
        if Regex.match?(@fa_icon_regex, name), do: "fa-#{name}", else: nil

      _ ->
        nil
    end
  end

  # agents_dir shape: `<base>/companies/<co>/agents` — extract the slug.
  defp infer_company_from_path(agents_dir) do
    case agents_dir |> Path.split() |> Enum.reverse() do
      ["agents", co | _] -> co
      _ -> nil
    end
  end

  # Derive the sidebar pill from the live AgentServer state, falling
  # back to `:idle` when the server isn't registered (agent not booted).
  # Gray (`:idle`) → not running / idle; green (`:alive`) → dispatching;
  # red (`:stop`) → last invocation exited non-zero. Bumped to :idle on
  # any lookup failure so a cold test environment doesn't render :stop
  # for every agent on every page.
  defp live_status(nil, _slug), do: :idle

  defp live_status(company, slug) do
    key = {:agent_server, company, slug}

    case Registry.lookup(Glorbo.Agent.Registry, key) do
      [{pid, _}] when is_pid(pid) ->
        try do
          status = Glorbo.Agent.Server.status({:via, Registry, {Glorbo.Agent.Registry, key}})
          classify_status(status)
        rescue
          _ -> :idle
        catch
          :exit, _ -> :idle
        end

      _ ->
        :idle
    end
  end

  # Exit-status markers that should surface as red :stop on the pill.
  # Integer non-zero exit AND the synthetic strings Glorbo.Agent.Server
  # writes when the director kills a dispatch or the task crashes.
  defp classify_status(%{state: :busy}), do: :alive
  defp classify_status(%{last_exit_status: s}) when is_integer(s) and s != 0, do: :stop
  defp classify_status(%{last_exit_status: "stopped_by_director"}), do: :stop
  defp classify_status(%{last_exit_status: {:crashed, _}}), do: :stop
  defp classify_status(_), do: :idle

  defp list_projects(nil), do: []

  defp list_projects(company) do
    base = Glorbo.Filesystem.Hierarchy.default_root()
    projects_dir = Path.join([base, "companies", company, "projects"])

    case File.ls(projects_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.sort()
        |> Enum.filter(&File.dir?(Path.join(projects_dir, &1)))
        |> Enum.map(fn slug ->
          %{slug: slug, icon: project_icon(projects_dir, slug)}
        end)

      _ ->
        []
    end
  end

  # Skim project.md for an `icon:` field if present. Cheap — one File.read
  # per project, frontmatter regex. Same allowlist as agent icons.
  defp project_icon(projects_dir, slug) do
    path = Path.join([projects_dir, slug, "project.md"])

    case File.read(path) do
      {:ok, content} -> scan_icon(content)
      _ -> nil
    end
  end

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

  defp health_status_atom(%{blocker: b}) when b > 0, do: :crashed
  defp health_status_atom(%{warning: w}) when w > 0, do: :warning
  defp health_status_atom(_), do: :healthy

  defp health_label(%{blocker: b}) when b > 0, do: "#{b} blocker check#{s(b)} failing"
  defp health_label(%{warning: w}) when w > 0, do: "#{w} warning#{s(w)}"
  defp health_label(_), do: "all systems operational"

  defp s(1), do: ""
  defp s(_), do: "s"
end
