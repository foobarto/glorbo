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

  import GlorboWeb.LiveHelpers, only: [base_dir: 0, current_year_month: 0]

  alias GlorboWeb.Components.CompanyCard

  @impl true
  def mount(_params, _session, socket) do
    # OverviewLive takes no slug params — no WR-02 guard needed; kept
    # as a no-op for symmetry with the other LVs.
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "companies")
      subscribe_agent_status_all()
    end

    {:ok,
     socket
     |> assign(:page_title, "Companies — Glorbo")
     |> assign(:sidebar_active, :overview)
     |> assign(:new_company_open?, false)
     |> assign(:new_company_slug, "")
     |> assign(:new_company_slug_status, :empty)
     |> assign(:companies, load_companies())}
  end

  @impl true
  def handle_info({:company_added, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info({:company_removed, _slug}, socket),
    do: {:noreply, assign(socket, :companies, load_companies())}

  def handle_info({:agent_status, _slug, _status, _working_on}, socket) do
    # Trigger a re-render so the sticky sidebar/statusbar pick up fresh
    # agent state.
    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp subscribe_agent_status_all do
    base = base_dir()
    co_dir = Path.join(base, "companies")

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

  @impl true
  def handle_event("chat_drawer_post", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Pick a company to chat.")}

  def handle_event("new_company", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_company_open?, true)
     |> assign(:new_company_slug, "")
     |> assign(:new_company_slug_status, :empty)}
  end

  def handle_event("new_company_cancel", _params, socket) do
    {:noreply, assign(socket, :new_company_open?, false)}
  end

  # Slug availability probe (paperclip-ux-gaps §18 — inline "taken"
  # marker instead of submit-then-flash). Checks the filesystem
  # directly; no SQLite round-trip.
  def handle_event("new_company_slug_input", %{"slug" => slug}, socket) do
    trimmed = slug |> to_string() |> String.trim()

    status =
      cond do
        trimmed == "" -> :empty
        not Glorbo.Slug.valid?(trimmed) -> :invalid
        File.dir?(Path.join([base_dir(), "companies", trimmed])) -> :taken
        true -> :available
      end

    {:noreply,
     socket
     |> assign(:new_company_slug, trimmed)
     |> assign(:new_company_slug_status, status)}
  end

  def handle_event("new_company_create", %{"slug" => slug} = params, socket) do
    guided? = params["_guided"] == "1"

    case Glorbo.CLI.Scaffold.Company.run([slug]) do
      {:new_company, 0, msg} ->
        Phoenix.PubSub.broadcast(Glorbo.PubSub, "companies", {:company_added, slug})

        flash_msg =
          if String.contains?(msg, "already exists"),
            do: "Company #{slug} already exists — no change.",
            else: "Created company: #{slug}"

        if guided? do
          # paperclip-ux-gaps §13 — chain into CompanyLive with
          # `?wizard=new_agent`; CompanyLive opens the new-agent modal
          # on mount and after save chains to `?wizard=new_project`.
          {:noreply,
           socket
           |> put_flash(:info, flash_msg)
           |> push_navigate(to: ~p"/companies/#{slug}?wizard=new_agent")}
        else
          {:noreply,
           socket
           |> assign(:new_company_open?, false)
           |> assign(:companies, load_companies())
           |> put_flash(:info, flash_msg)}
        end

      {:new_company, _nonzero, msg} ->
        {:noreply, put_flash(socket, :error, String.trim(msg))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view">
      <header class="gl-view__header gl-view__header--split">
        <h1 class="gl-heading gl-heading--display">Companies</h1>
        <button type="button" class="gl-btn" phx-click="new_company">
          + new company
        </button>
      </header>

      <div :if={@companies == []} class="gl-empty">
        <p>No companies yet.</p>
        <p class="gl-muted">
          A company is a directory under <code>{GlorboWeb.LiveHelpers.display_base()}/companies/</code>.
          Run <code>glorbo new company acme</code> then refresh.
        </p>
        <p class="gl-muted">
          Already have a paperclip <code>agentcompanies</code>
          tree? Run <code>glorbo import paperclip &lt;path&gt; --as &lt;slug&gt;</code>
          to bring it in.
        </p>
      </div>

      <div :if={@companies != []} class="gl-grid gl-grid--cards">
        <CompanyCard.company_card :for={c <- @companies} company={c} />
      </div>

      <%!--
        UAT N1: single-company installs left the right ~70% of the
        viewport empty and the user wondering if they were missing
        something. Hint panel shows only when every company has ≤1
        agent (otherwise the board is already populated and noise).
      --%>
      <aside
        :if={@companies != [] and Enum.all?(@companies, &(&1.agent_count <= 1))}
        class="gl-welcome-hint"
      >
        <h2 class="gl-heading gl-heading--heading">Next step</h2>
        <ul class="gl-welcome-hint__list">
          <li>Click a company card → see its agents + kanban.</li>
          <li>Press <kbd>?</kbd> to see keyboard shortcuts.</li>
          <li>Press <kbd>⌘K</kbd> / <kbd>CtrlK</kbd> for the command palette.</li>
          <li>
            Inside a company page, use <strong>+ new agent</strong>
            to scaffold one (or <code>glorbo new agent &lt;co&gt;/&lt;slug&gt;</code>
            from the CLI).
          </li>
        </ul>
      </aside>

      <div :if={@new_company_open?} class="gl-modal-scrim" phx-click-away="new_company_cancel">
        <form
          phx-submit="new_company_create"
          phx-change="new_company_slug_input"
          phx-window-keydown="new_company_cancel"
          phx-key="Escape"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-new-company-title"
        >
          <header class="gl-modal__header">
            <div id="gl-new-company-title"><strong>+ new company</strong></div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="new_company_cancel"
              aria-label="Close"
            >
              ×
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">slug</span>
              <input
                type="text"
                name="slug"
                class={[
                  "gl-input",
                  @new_company_slug_status == :taken && "gl-input--invalid",
                  @new_company_slug_status == :available && "gl-input--valid"
                ]}
                required
                maxlength="64"
                pattern="[a-z0-9][-a-z0-9]*"
                placeholder="acme-corp"
                title="Lowercase letters / digits / dashes"
                autocomplete="off"
                autofocus
                value={@new_company_slug}
                phx-debounce="150"
                aria-describedby="gl-new-company-slug-hint"
              />
              <span
                id="gl-new-company-slug-hint"
                class={[
                  "gl-slug-hint",
                  "gl-slug-hint--" <> Atom.to_string(@new_company_slug_status)
                ]}
                role="status"
                aria-live="polite"
              >
                {slug_hint_text(@new_company_slug_status)}
              </span>
            </label>
            <p class="gl-muted" style="font-size: 11px;">
              Creates <code>{GlorboWeb.LiveHelpers.display_base()}/companies/&lt;slug&gt;/</code>
              with <code>company.md</code>, <code>agents/</code>, <code>projects/</code>, <code>channels/</code>,
              <code>audit/</code>
              scaffolding. You can edit <code>company.md</code>
              afterward.
            </p>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="new_company_cancel">cancel</button>
            <button
              type="submit"
              class="gl-btn"
              name="_guided"
              value="1"
              disabled={@new_company_slug_status == :taken}
              title="Create company, then scaffold an agent + project next (paperclip-style wizard)."
            >
              create + continue →
            </button>
            <button
              type="submit"
              class="gl-btn gl-btn--primary"
              disabled={@new_company_slug_status == :taken}
            >
              create
            </button>
          </footer>
        </form>
      </div>
    </section>
    """
  end

  defp slug_hint_text(:empty), do: ""
  defp slug_hint_text(:invalid), do: "Lowercase letters, digits, dashes only"
  defp slug_hint_text(:taken), do: "✗ taken"
  defp slug_hint_text(:available), do: "✓ available"

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

  defp do_load_company(base, slug, path) do
    %{
      slug: slug,
      name: company_name(path, slug),
      agent_count: agent_count(path),
      in_progress_count: in_progress_count(base, slug, path),
      spend_usd: spend_usd(slug, path),
      alert_count: alert_count(path),
      goals: goals_summary(base, slug, path),
      health: :healthy
    }
  end

  # Backlog #13: overview card shows a goals-progress summary. We
  # reuse the same per-goal task-count rollup CompanyLive uses; no
  # new data source. Returns `%{count, total_tasks, done_tasks,
  # pct}` or nil if the company has no goals defined — the card
  # hides the row entirely in that case.
  defp goals_summary(base, slug, path) do
    goals = company_goals(path)

    if goals == [] do
      nil
    else
      counts = goal_task_counts(base, slug)
      per_goal = Enum.map(goals, &merge_goal_stats(&1, counts))
      total_tasks = Enum.sum(Enum.map(per_goal, & &1.task_count))
      done_tasks = Enum.sum(Enum.map(per_goal, & &1.done_count))
      pct = if total_tasks == 0, do: 0, else: div(done_tasks * 100, total_tasks)

      %{
        count: length(per_goal),
        total_tasks: total_tasks,
        done_tasks: done_tasks,
        pct: pct
      }
    end
  end

  defp company_goals(path) do
    case File.read(Path.join(path, "company.md")) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"goals" => g}, _} when is_list(g) ->
            # Threatmodel T9: `goal.slug` comes from attacker-controlled
            # YAML. A list or map value previously made `to_string/1`
            # raise `Protocol.UndefinedError` and took down the /companies
            # overview for everyone. Filter down to real scalars before
            # coercing; silently drop malformed entries.
            for item <- g,
                is_map(item),
                slug = safe_goal_slug(Map.get(item, "slug")),
                slug != "" do
              %{slug: slug}
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp safe_goal_slug(v) when is_binary(v), do: v
  defp safe_goal_slug(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_goal_slug(v) when is_integer(v), do: Integer.to_string(v)
  defp safe_goal_slug(_), do: ""

  # Same shape as safe_goal_slug but used inline for any agent-
  # controlled scalar field (status, etc). Refuses to coerce
  # maps/lists which would crash `to_string/1`.
  defp safe_scalar(v) when is_binary(v), do: v
  defp safe_scalar(v) when is_atom(v) and not is_nil(v), do: Atom.to_string(v)
  defp safe_scalar(v) when is_number(v), do: to_string(v)
  defp safe_scalar(_), do: ""

  # Per-goal task counts: {total, done} keyed by goal slug. Walks
  # `projects/*/tasks/*.md` once, bucketing by frontmatter `goal:`.
  defp goal_task_counts(base, slug) do
    pattern = Path.join([base, "companies", slug, "projects", "*", "tasks", "*.md"])

    pattern
    |> Path.wildcard()
    |> Enum.reduce(%{}, &fold_task/2)
  end

  defp fold_task(path, acc) do
    # Threatmodel wave 23: lstat + 1 MiB cap on the agent-RW task md.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576) do
      {:ok, content} ->
        case Glorbo.Filesystem.Frontmatter.parse(content) do
          {:ok, %{"goal" => goal_slug} = meta, _} when is_binary(goal_slug) and goal_slug != "" ->
            status = safe_scalar(Map.get(meta, "status", ""))
            delta = if status == "done", do: {1, 1}, else: {1, 0}

            Map.update(acc, goal_slug, delta, fn {t, d} ->
              {t0, d0} = delta
              {t + t0, d + d0}
            end)

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp merge_goal_stats(%{slug: s} = goal, counts) do
    {total, done} = Map.get(counts, s, {0, 0})
    pct = if total == 0, do: 0, else: div(done * 100, total)
    Map.merge(goal, %{task_count: total, done_count: done, progress_pct: pct})
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

  # Count tasks under any project with frontmatter `status: in-progress`
  # (KanbanLive.group_by_column uses exactly the same classification).
  # Walks projects/*/tasks/*.md; returns 0 on any filesystem hiccup.
  defp in_progress_count(base, company_slug, company_path) do
    projects_dir = Path.join(company_path, "projects")

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.reduce(projects, 0, fn project, acc ->
          acc + count_in_progress_in_project(projects_dir, project, base, company_slug)
        end)

      _ ->
        0
    end
  end

  defp count_in_progress_in_project(projects_dir, project, base, company) do
    tasks_dir = Path.join([projects_dir, project, "tasks"])

    case File.ls(tasks_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.count(fn filename ->
          path = Path.join(tasks_dir, filename)

          case Glorbo.TaskDefinition.parse_file(path, base: base, company: company) do
            {:ok, %{status: "in-progress"}} -> true
            _ -> false
          end
        end)

      _ ->
        0
    end
  end

  # Sum each agent's current-month ledger row into USD. Tolerant of
  # missing SQLite / missing row / crashed ledger — mirrors
  # AgentLive.load_used_usd/1 (agent_live.ex:222-231).
  defp spend_usd(company_slug, company_path) do
    agents_dir = Path.join(company_path, "agents")
    ym = current_year_month()

    case File.ls(agents_dir) do
      {:ok, slugs} ->
        slugs
        |> Enum.filter(&File.dir?(Path.join(agents_dir, &1)))
        |> Enum.reduce(0.0, fn slug, acc -> acc + agent_spend_usd(company_slug, slug, ym) end)

      _ ->
        0.0
    end
  end

  defp agent_spend_usd(company_slug, agent_slug, year_month) do
    case Glorbo.Budget.Ledger.fetch(company_slug, agent_slug, year_month) do
      %{cost_usd_cents: c} when is_integer(c) -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
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
end
