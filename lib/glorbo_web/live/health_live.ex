defmodule GlorboWeb.HealthLive do
  @moduledoc """
  System health view — GET `/health` (D-28).

  Polls three data sources every 3 s (D-14 — no PubSub, timer only):

    * `Glorbo.Doctor.run_checks/0` — host prerequisites (kernel,
      podman, ollama, bwrap, uidmap, user_namespaces, …). Each check
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
          <span class={["gl-dot", "gl-dot--" <> severity_to_dot(c)]} />
          <span class="gl-tabular">{c.name}</span>
          <span class="gl-muted">{c.detail}</span>
        </div>
      </section>

      <section class="gl-health__section">
        <h2 class="gl-heading gl-heading--heading">Supervisors</h2>
        <ul :if={@supervisors != []} class="gl-health__tree">
          <li :for={s <- @supervisors}>
            <span class={["gl-dot", "gl-dot--" <> Atom.to_string(s.status)]} />
            <span>{s.name}</span>
            <span class="gl-muted">— {s.child_count} children</span>
          </li>
        </ul>
        <div :if={@supervisors == []} class="gl-subtle">No companies running.</div>
      </section>

      <section class="gl-health__section">
        <h2 class="gl-heading gl-heading--heading">CLI tools</h2>
        <div :for={t <- @cli_tools} class="gl-health__check-row">
          <span class={["gl-dot", "gl-dot--" <> if(t.present, do: "healthy", else: "crashed")]} />
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

  defp severity_to_dot(%{pass: true}), do: "healthy"

  defp severity_to_dot(%{severity: :warning}), do: "warning"
  defp severity_to_dot(%{severity: :blocker}), do: "crashed"
  defp severity_to_dot(_), do: "idle"

  defp list_supervisors do
    case Process.whereis(Glorbo.CompanySupervisor) do
      nil ->
        []

      _pid ->
        Glorbo.CompanySupervisor
        |> Supervisor.which_children()
        |> Enum.map(&summarize_child/1)
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp summarize_child({_id, pid, _type, _mods}) do
    children =
      try do
        if is_pid(pid), do: Supervisor.which_children(pid), else: []
      rescue
        _ -> []
      catch
        _, _ -> []
      end

    %{name: inspect(pid), status: :healthy, child_count: length(children)}
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
