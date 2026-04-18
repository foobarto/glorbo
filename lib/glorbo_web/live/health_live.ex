defmodule GlorboWeb.HealthLive do
  @moduledoc """
  System health view — GET `/health` (D-28).

  Polls three data sources every 3 s (D-14 — no PubSub, timer only):

    * `Glorbo.Doctor.run_checks/0` — host prerequisites (kernel,
      bwrap, uidmap, user_namespaces, …). Each check
      is `%{name, pass, detail, required, severity}` with severity
      `:blocker | :warning`. Mapped to a `.gl-dot--healthy|warning|crashed`
      class.
    * `Supervisor.which_children(Glorbo.CompanySupervisor)` — running
      per-company supervisors. Falls back to an empty list when the
      named DynamicSupervisor isn't registered (test environment).
    * `System.find_executable/1` for `claude | gemini | codex | bwrap`
      — CLI agent runtimes (Plan 03 bwrap gating).
  """
  use GlorboWeb, :live_view

  @tick_ms 3_000

  @cli_tools ~w(claude gemini codex bwrap)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

    {:ok,
     socket
     |> assign(:page_title, "System health — Glorbo")
     |> assign(:checks, run_checks_safe())
     |> assign(:supervisors, list_supervisors())
     |> assign(:cli_tools, detect_tools())}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)

    {:noreply,
     socket
     |> assign(:checks, run_checks_safe())
     |> assign(:supervisors, list_supervisors())
     |> assign(:cli_tools, detect_tools())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", _params, socket),
    do: {:noreply, put_flash(socket, :info, "Pick a company to chat.")}

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-health">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">System health</h1>
      </header>

      <section class="gl-health__section">
        <h2 class="gl-heading gl-heading--heading">Doctor checks</h2>
        <div class="gl-muted">
          pass {@checks.pass} · warn {@checks.warn} · fail {@checks.fail}
        </div>
        <div :for={c <- @checks.rows} class="gl-health__check-row">
          <GlorboWeb.Components.HealthDot.health_dot
            status={check_status(c)}
            label={"#{c.name}: #{if c.pass, do: "pass", else: c.detail}"}
          />
          <span class="gl-tabular">{c.name}</span>
          <span class="gl-muted">{c.detail}</span>
        </div>
      </section>

      <section class="gl-health__section">
        <h2 class="gl-heading gl-heading--heading">Supervisors</h2>
        <ul :if={@supervisors != []} class="gl-health__tree">
          <li :for={s <- @supervisors}>
            <GlorboWeb.Components.HealthDot.health_dot
              status={s.status}
              label={"Company #{s.name}: #{s.status}, #{s.child_count} children"}
            />
            <span>{s.name}</span>
            <span class="gl-muted">— {s.child_count} children</span>
          </li>
        </ul>
        <div :if={@supervisors == []} class="gl-subtle">No companies running.</div>
      </section>

      <section class="gl-health__section">
        <h2 class="gl-heading gl-heading--heading">CLI tools</h2>
        <div :for={t <- @cli_tools} class="gl-health__check-row">
          <GlorboWeb.Components.HealthDot.health_dot
            status={if t.present, do: :healthy, else: :crashed}
            label={"CLI tool #{t.name}: #{t.detail}"}
          />
          <span>{t.name}: {t.detail}</span>
        </div>
      </section>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp run_checks_safe do
    rows =
      try do
        Glorbo.Doctor.run_checks([])
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    pass = Enum.count(rows, & &1.pass)

    fail_blocker =
      Enum.count(rows, fn r ->
        not r.pass and Map.get(r, :severity, :blocker) == :blocker
      end)

    warn =
      Enum.count(rows, fn r ->
        not r.pass and Map.get(r, :severity, :blocker) == :warning
      end)

    %{rows: rows, pass: pass, warn: warn, fail: fail_blocker}
  end

  defp check_status(%{pass: true}), do: :healthy
  defp check_status(%{severity: :warning}), do: :warning
  defp check_status(%{severity: :blocker}), do: :crashed
  defp check_status(_), do: :idle

  # Enumerate running companies by slug via Glorbo.Agent.Registry rather
  # than PIDs — `{:company_child, slug, :audit_log}` is registered by
  # every running Glorbo.Company.Supervisor (see company/supervisor.ex:88).
  # TODO2.md § P0 called out the old `inspect(pid)` surface as operator-
  # hostile.
  defp list_supervisors do
    case Process.whereis(Glorbo.Agent.Registry) do
      nil ->
        []

      _pid ->
        Glorbo.Agent.Registry
        |> Registry.select([
          {{{:company_child, :"$1", :audit_log}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
        ])
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(&summarize_company/1)
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp summarize_company({slug, audit_log_pid}) when is_binary(slug) and is_pid(audit_log_pid) do
    # Count sibling registered roles for this company. Stable upper bound
    # on role count; we don't need to find the supervisor itself.
    child_count =
      Registry.select(Glorbo.Agent.Registry, [
        {{{:company_child, slug, :"$1"}, :_, :_}, [], [:"$1"]}
      ])
      |> length()

    %{name: slug, status: :healthy, child_count: child_count}
  rescue
    _ -> %{name: slug, status: :healthy, child_count: 0}
  end

  defp detect_tools do
    Enum.map(@cli_tools, fn tool ->
      case System.find_executable(tool) do
        nil ->
          suffix = if tool == "bwrap", do: " — agents cannot sandbox", else: ""
          %{name: tool, present: false, detail: "not found" <> suffix}

        path ->
          %{name: tool, present: true, detail: path}
      end
    end)
  end
end
