defmodule GlorboWeb.SkillsLive do
  @moduledoc """
  Skills marketplace / bundle view — GET
  `/companies/:company/skills` (paperclip-ux-gaps §9).

  Lists every skill that agents in this company can resolve —
  combines the company-local `<base>/skills/*.md` directory (custom /
  director-authored) with the builtin `priv/templates/skills/` bundle.

  Each row shows: name, source (`builtin` / `custom` / `shadowed` —
  meaning a custom file overrides a builtin of the same name), title
  from frontmatter, and a used-by count derived by scanning every
  agent's `skills:` list in this company.

  Clicking a row expands it to show the raw markdown of the skill
  so the director can confirm what the agent sees without leaving
  the dashboard. Pure read-only — adding/editing skills stays a
  CLI-scaffolding path (keeps the filesystem as the source of
  truth, per GEP-7 / CLAUDE.md invariant).
  """
  use GlorboWeb, :live_view

  import GlorboWeb.LiveHelpers, only: [base_dir: 0]

  alias GlorboWeb.Components.ChatDrawer

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not File.dir?(Path.join([base_dir(), "companies", co])) ->
        {:ok,
         socket
         |> put_flash(:error, "Company \"#{co}\" not found.")
         |> push_navigate(to: ~p"/companies")}

      true ->
        co_path = Path.join([base_dir(), "companies", co])

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")
        end

        {:ok,
         socket
         |> assign(:page_title, "#{co} · skills — Glorbo")
         |> assign(:sidebar_active, :skills)
         |> assign(:current_company, co)
         |> assign(:company_slug, co)
         |> assign(:skills, load_skills(co_path))
         |> assign(:expanded, MapSet.new())
         |> ChatDrawer.State.wire_drawer()}
    end
  end

  @impl true
  def handle_info({:agent_status, _slug, _status, _working_on}, socket),
    do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("toggle", %{"name" => name}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, name) do
        MapSet.delete(socket.assigns.expanded, name)
      else
        MapSet.put(socket.assigns.expanded, name)
      end

    {:noreply, assign(socket, :expanded, expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-skills-page">
      <header class="gl-view__header gl-view__header--split">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">{@company_slug} /</span> skills
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">
              builtins ship under <code>priv/templates/skills/</code>; overrides live under <code>{GlorboWeb.LiveHelpers.display_base()}/skills/</code>.
            </span>
          </p>
        </div>
      </header>

      <p :if={@skills == []} class="gl-muted">No skills discovered.</p>

      <table :if={@skills != []} class="gl-skills-table">
        <thead>
          <tr>
            <th>name</th>
            <th>source</th>
            <th>title</th>
            <th>used by</th>
          </tr>
        </thead>
        <tbody>
          <%= for skill <- @skills do %>
            <tr
              phx-click="toggle"
              phx-value-name={skill.name}
              class={[
                "gl-skills-table__row",
                MapSet.member?(@expanded, skill.name) && "gl-skills-table__row--open"
              ]}
              role="button"
              tabindex="0"
            >
              <td class="gl-skills-table__name">{skill.name}</td>
              <td>
                <span class={["gl-badge", "gl-badge--" <> skill.source]}>{skill.source}</span>
              </td>
              <td>{skill.title}</td>
              <td>
                <span :if={skill.used_by == []} class="gl-muted">—</span>
                <span :if={skill.used_by != []}>
                  {length(skill.used_by)}
                  <span class="gl-muted">
                    ({Enum.join(skill.used_by, ", ")})
                  </span>
                </span>
              </td>
            </tr>
            <tr :if={MapSet.member?(@expanded, skill.name)} class="gl-skills-table__body-row">
              <td colspan="4">
                <pre class="gl-skills-table__body"><code>{skill.body}</code></pre>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_skills(co_path) do
    used_by_map = used_by_agents(co_path)

    user_dir = Path.join([base_dir(), "skills"])
    builtin_dir = Application.app_dir(:glorbo, "priv/templates/skills")

    user_files = list_skill_files(user_dir)
    builtin_files = list_skill_files(builtin_dir)

    user_names = MapSet.new(user_files, fn {name, _path} -> name end)

    builtins =
      Enum.map(builtin_files, fn {name, path} ->
        source = if MapSet.member?(user_names, name), do: "shadowed", else: "builtin"
        read_skill(name, path, source, Map.get(used_by_map, name, []))
      end)

    users =
      Enum.map(user_files, fn {name, path} ->
        read_skill(name, path, "custom", Map.get(used_by_map, name, []))
      end)

    (users ++ builtins)
    |> Enum.sort_by(& &1.name)
  end

  defp list_skill_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(fn filename ->
          name = Path.basename(filename, ".md")
          {name, Path.join(dir, filename)}
        end)

      _ ->
        []
    end
  end

  defp read_skill(name, path, source, used_by) do
    {title, body} =
      case File.read(path) do
        {:ok, content} ->
          case Glorbo.Filesystem.Frontmatter.parse(content) do
            {:ok, fm, body} ->
              {to_string(fm["title"] || fm["name"] || name), body}

            _ ->
              {name, content}
          end

        _ ->
          {name, ""}
      end

    %{
      name: name,
      source: source,
      title: title,
      used_by: used_by,
      body: body
    }
  end

  # Scan every agent's `skills:` frontmatter list in this company and
  # return a map of `skill_name => [agent_slug]`.
  defp used_by_agents(co_path) do
    agents_dir = Path.join(co_path, "agents")

    case File.ls(agents_dir) do
      {:ok, slugs} -> Enum.reduce(slugs, %{}, &merge_agent_skills(agents_dir, &1, &2))
      _ -> %{}
    end
  end

  defp merge_agent_skills(agents_dir, slug, acc) do
    skills_for_agent(agents_dir, slug)
    |> Enum.reduce(acc, fn name, a -> Map.update(a, name, [slug], &(&1 ++ [slug])) end)
  end

  defp skills_for_agent(agents_dir, slug) do
    agent_md = Path.join([agents_dir, slug, "AGENT.md"])

    with {:ok, content} <- File.read(agent_md),
         {:ok, fm, _} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      fm
      |> Map.get("skills", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
    else
      _ -> []
    end
  end
end
