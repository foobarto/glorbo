defmodule GlorboWeb.AgentLive do
  @moduledoc """
  Agent detail view — GET `/companies/:company/agents/:agent` (D-24).

  Mount reads `agent.md` via `Glorbo.Agent.Parser.parse_file/1` and
  resolves the month-to-date spend from `Glorbo.Budget.Ledger.fetch/2`
  (degrading gracefully to `0.00` when the SQLite row or ledger table
  isn't available yet — e.g. on an uninitialised LiveCase run).

  On `connected?/1` the view:

    * subscribes to `company:<co>:agents:<ag>:{stdout,wake,budget}`
      (budget subscription gracefully no-ops if the topic isn't
      broadcast yet — Wave 0 commented-out extension).
    * starts a `GlorboWeb.StdoutStreamer` under the DynamicSupervisor
      and `Process.monitor/1`s its pid (Pitfall 4 mitigation).

  `terminate/2` stops the streamer cleanly. `handle_info/2` for
  `{:DOWN, _, :process, pid, _}` (where pid == streamer) re-spawns a
  fresh streamer rather than killing the LV — crash-isolation between
  streamer and view.
  """
  use GlorboWeb, :live_view
  require Logger

  alias GlorboWeb.Components.{BudgetRing, StdoutTail}

  @impl true
  def mount(%{"company" => co, "agent" => ag}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    cond do
      not GlorboWeb.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not GlorboWeb.Slug.valid?(ag) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid agent identifier.")
         |> push_navigate(to: ~p"/companies/#{co}")}

      true ->
        mount_valid(co, ag, socket)
    end
  end

  defp mount_valid(co, ag, socket) do
    base = base_dir()
    ag_dir = Path.join([base, "companies", co, "agents", ag])

    if File.dir?(ag_dir) do
      agent_info = load_agent(base, co, ag)

      socket =
        socket
        |> assign(:page_title, "#{agent_info.name} — #{co} — Glorbo")
        |> assign(:company_slug, co)
        |> assign(:agent_slug, ag)
        |> assign(:agent, agent_info)
        |> assign(:streamer_pid, nil)
        |> stream(:stdout, [], limit: -1000)

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:stdout")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:wake")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:budget")

        case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
          {:ok, pid} ->
            Process.monitor(pid)
            {:ok, assign(socket, :streamer_pid, pid)}

          _ ->
            {:ok, socket}
        end
      else
        {:ok, socket}
      end
    else
      {:ok,
       socket
       |> put_flash(:error, "Agent \"#{ag}\" not found in #{co}.")
       |> push_navigate(to: ~p"/companies/#{co}")}
    end
  end

  @impl true
  def handle_info({:stdout_line, _co, _ag, %{id: id, body: body}}, socket) do
    {:noreply, stream_insert(socket, :stdout, %{id: id, body: body}, at: -1, limit: -1000)}
  end

  def handle_info({:file_event, _rel, _events}, socket), do: {:noreply, socket}

  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %{assigns: %{streamer_pid: pid}} = socket
      ) do
    base = base_dir()
    co = socket.assigns.company_slug
    ag = socket.assigns.agent_slug

    case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
      {:ok, new_pid} ->
        Process.monitor(new_pid)
        {:noreply, assign(socket, :streamer_pid, new_pid)}

      _ ->
        {:noreply, assign(socket, :streamer_pid, nil)}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("wake", %{"reason" => reason}, socket) do
    base = base_dir()

    case GlorboWeb.Actions.wake_agent(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           reason,
           base: base
         ) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Woken. Writing state/wake-request.md…")}

      {:error, err} ->
        # WR-08: humanize error; log raw atom for operators.
        Logger.warning("wake_agent failed",
          company: socket.assigns.company_slug,
          agent: socket.assigns.agent_slug,
          reason: inspect(err)
        )

        {:noreply, put_flash(socket, :error, "Could not wake agent.")}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if pid = socket.assigns[:streamer_pid], do: GlorboWeb.StdoutStreamer.stop(pid)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-agent">
      <header class="gl-agent__header">
        <h1 class="gl-heading gl-heading--display">{@agent.name}</h1>
        <span class="gl-muted">{@agent.role}</span>
        <span class="gl-badge">{@agent.provider}</span>
        <BudgetRing.budget_ring used={@agent.used} cap={@agent.cap} size={96} />
      </header>

      <section class="gl-agent__current">
        <h2 class="gl-heading gl-heading--heading">Current task</h2>
        <p class="gl-muted">No active task. Waiting for next wake.</p>
      </section>

      <section class="gl-agent__wake">
        <h2 class="gl-heading gl-heading--heading">
          Recent wakes <span class="gl-muted">(last 20)</span>
        </h2>
        <p class="gl-muted">No wakes logged this session.</p>
        <form phx-submit="wake" class="gl-wake-form">
          <label>
            Wake reason (optional):
            <input type="text" name="reason" class="gl-input" maxlength="200" />
          </label>
          <button type="submit" class="gl-btn gl-btn--primary">Wake agent</button>
        </form>
      </section>

      <section class="gl-agent__stdout">
        <h2 class="gl-heading gl-heading--heading">
          Stdout <span class="gl-muted">(last 1000 lines)</span>
        </h2>
        <StdoutTail.stdout_tail stream={@streams.stdout} />
      </section>

      <section class="gl-agent__perms">
        <h2 class="gl-heading gl-heading--heading">Permissions</h2>
        <ul :if={@agent.permissions != []} class="gl-perms-list">
          <li :for={p <- @agent.permissions}><code>{format_perm(p)}</code></li>
        </ul>
        <p :if={@agent.permissions == []} class="gl-muted">
          No permissions granted. This agent is filesystem-sandboxed to its own workspace only.
        </p>
      </section>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_agent(base, co, ag) do
    agent_path = Path.join([base, "companies", co, "agents", ag, "agent.md"])

    spec =
      case Glorbo.Agent.Parser.parse_file(agent_path) do
        {:ok, s} -> s
        _ -> nil
      end

    %{
      name: (spec && spec.slug |> to_string() |> String.capitalize()) || String.capitalize(ag),
      role: (spec && spec.role) || "agent",
      provider: (spec && spec.provider) || "unknown",
      permissions: (spec && spec.permissions) || [],
      used: load_used_usd(ag),
      cap:
        spec && spec.budget_usd_cents_month &&
          spec.budget_usd_cents_month / 100.0
    }
  end

  defp load_used_usd(agent_slug) do
    case Glorbo.Budget.Ledger.fetch(agent_slug, current_year_month()) do
      %{cost_usd_cents: c} -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
  end

  defp current_year_month do
    now = DateTime.utc_now()
    "#{now.year}-#{String.pad_leading(Integer.to_string(now.month), 2, "0")}"
  end

  defp format_perm({r, a, s}), do: "#{r}:#{a}:#{s}"
  defp format_perm(other), do: inspect(other)

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
