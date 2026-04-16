defmodule GlorboWeb.ApprovalQueueLive do
  @moduledoc """
  Approval queue view — GET `/companies/:company/approvals` (D-26).

  Scans `<base>/companies/<co>/agents/*/state/awaiting-approval-*.md`
  on mount; each sentinel's filename stem (e.g.
  `awaiting-approval-t-01` → `t-01`) is the task_id. The matching task
  file is resolved under `projects/**/tasks/<task_id>.md` to get the
  title for display.

  On `connected?/1` the view subscribes to `company:<co>:projects` and
  re-scans on any file event (sentinel files live under `agents/*/state`
  which doesn't have its own topic yet; projects is a reasonable
  proxy — approvals fire whenever Gate writes a sentinel in response
  to a task event).

  `Approve`/`Deny` clicks go through `GlorboWeb.Actions.set_approval/4`
  which re-validates the task_path (T-04-09 defense in depth) and
  atomically mutates the task frontmatter via
  `Glorbo.TaskDefinition.write/2`.
  """
  use GlorboWeb, :live_view

  alias GlorboWeb.Components.ApprovalCard

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    base = base_dir()

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")

    {:ok,
     socket
     |> assign(:page_title, "Approvals — #{co} — Glorbo")
     |> assign(:company_slug, co)
     |> assign(:base, base)
     |> assign(:sentinels, load_sentinels(base, co))}
  end

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    {:noreply,
     assign(socket, :sentinels, load_sentinels(socket.assigns.base, socket.assigns.company_slug))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve", %{"task_path" => tp}, socket) do
    case GlorboWeb.Actions.set_approval(
           socket.assigns.company_slug,
           tp,
           :approved,
           base: socket.assigns.base
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved.")
         |> assign(
           :sentinels,
           load_sentinels(socket.assigns.base, socket.assigns.company_slug)
         )}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(err)}")}
    end
  end

  def handle_event("deny", %{"task_path" => tp}, socket) do
    case GlorboWeb.Actions.set_approval(
           socket.assigns.company_slug,
           tp,
           :denied,
           base: socket.assigns.base
         ) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Denied. Task moved to history.")
         |> assign(
           :sentinels,
           load_sentinels(socket.assigns.base, socket.assigns.company_slug)
         )}

      {:error, err} ->
        {:noreply, put_flash(socket, :error, "Deny failed: #{inspect(err)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-approvals">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">
          Approvals <span class="gl-muted">({length(@sentinels)} pending)</span>
        </h1>
      </header>

      <div :if={@sentinels == []} class="gl-empty">
        <p>No approvals pending.</p>
        <p class="gl-muted">
          Tasks with <code>requires_approval: director</code> in frontmatter will appear here.
        </p>
      </div>

      <div :if={@sentinels != []} class="gl-approvals__list">
        <ApprovalCard.approval_card :for={s <- @sentinels} sentinel={s} />
      </div>
    </section>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_sentinels(base, co) do
    agents_dir = Path.join([base, "companies", co, "agents"])

    case File.ls(agents_dir) do
      {:ok, agents} ->
        agents
        |> Enum.sort()
        |> Enum.flat_map(fn ag ->
          state_dir = Path.join([agents_dir, ag, "state"])

          case File.ls(state_dir) do
            {:ok, files} ->
              files
              |> Enum.filter(&String.starts_with?(&1, "awaiting-approval-"))
              |> Enum.filter(&String.ends_with?(&1, ".md"))
              |> Enum.map(&build_sentinel(base, co, ag, &1))
              |> Enum.reject(&is_nil/1)

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp build_sentinel(base, co, agent, filename) do
    task_id =
      filename
      |> String.replace_prefix("awaiting-approval-", "")
      |> String.replace_suffix(".md", "")

    case find_task_path(base, co, task_id) do
      nil ->
        nil

      task_path ->
        abs = Path.join([base, "companies", co, task_path])

        case Glorbo.TaskDefinition.parse_file(abs, base: base, company: co) do
          {:ok, task} ->
            sentinel_path = Path.join([base, "companies", co, "agents", agent, "state", filename])

            %{
              task_id: task_id,
              task_path: task_path,
              title: task.title || task_id,
              requesting_agent: agent,
              requested_at: sentinel_mtime_iso(sentinel_path)
            }

          _ ->
            nil
        end
    end
  end

  defp find_task_path(base, co, task_id) do
    projects_dir = Path.join([base, "companies", co, "projects"])

    case File.ls(projects_dir) do
      {:ok, projects} ->
        Enum.find_value(projects, fn p ->
          candidate = Path.join([projects_dir, p, "tasks", "#{task_id}.md"])
          if File.exists?(candidate), do: "projects/#{p}/tasks/#{task_id}.md"
        end)

      _ ->
        nil
    end
  end

  defp sentinel_mtime_iso(sentinel_path) do
    case File.stat(sentinel_path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} when is_integer(m) ->
        DateTime.from_unix!(m) |> DateTime.to_iso8601()

      _ ->
        ""
    end
  end

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))
end
