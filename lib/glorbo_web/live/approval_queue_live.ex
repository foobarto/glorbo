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
  require Logger

  alias GlorboWeb.Components.ApprovalCard

  @impl true
  def mount(%{"company" => co}, _session, socket) do
    # WR-02: slug gate before any filesystem construction.
    if GlorboWeb.Slug.valid?(co) do
      mount_valid(co, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, "Invalid company identifier.")
       |> push_navigate(to: ~p"/companies")}
    end
  end

  defp mount_valid(co, socket) do
    base = base_dir()

    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:projects")

    sentinels = load_sentinels(base, co)

    {:ok,
     socket
     |> assign(:page_title, "Approvals — #{co} — Glorbo")
     |> assign(:sidebar_active, :approvals)
     |> assign(:company_slug, co)
     |> assign(:current_company, co)
     |> assign(:base, base)
     |> assign(:sentinels, sentinels)
     |> assign(:selected_index, initial_selection(sentinels))}
  end

  defp initial_selection([]), do: nil
  defp initial_selection(_), do: 0

  @impl true
  def handle_info({:file_event, _rel, _events}, socket) do
    sentinels = load_sentinels(socket.assigns.base, socket.assigns.company_slug)

    {:noreply,
     socket
     |> assign(:sentinels, sentinels)
     |> assign(:selected_index, clamp_selection(socket.assigns.selected_index, sentinels))}
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
        # WR-08: humanize error; log raw atom for operators.
        Logger.warning("set_approval approve failed",
          company: socket.assigns.company_slug,
          task_path: tp,
          reason: inspect(err)
        )

        {:noreply, put_flash(socket, :error, "Could not record approval.")}
    end
  end

  def handle_event("select", %{"index" => i}, socket) do
    idx = parse_index(i, socket.assigns.sentinels)
    {:noreply, assign(socket, :selected_index, idx)}
  end

  def handle_event("keydown", %{"key" => key}, socket) do
    case key do
      k when k in ["j", "ArrowDown"] ->
        {:noreply, assign(socket, :selected_index, step(socket.assigns, 1))}

      k when k in ["k", "ArrowUp"] ->
        {:noreply, assign(socket, :selected_index, step(socket.assigns, -1))}

      "y" ->
        keyboard_action(socket, "approve")

      "n" ->
        keyboard_action(socket, "deny")

      _ ->
        {:noreply, socket}
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
        # WR-08: humanize error; log raw atom for operators.
        Logger.warning("set_approval deny failed",
          company: socket.assigns.company_slug,
          task_path: tp,
          reason: inspect(err)
        )

        {:noreply, put_flash(socket, :error, "Could not record approval.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-approvals" phx-window-keydown="keydown">
      <header class="gl-view__header">
        <h1 class="gl-heading gl-heading--display">
          Approvals <span class="gl-muted">({length(@sentinels)} pending)</span>
        </h1>
        <p :if={@sentinels != []} class="gl-muted gl-kbdhint">
          <kbd>j</kbd>/<kbd>k</kbd> move · <kbd>y</kbd> approve · <kbd>n</kbd> deny
        </p>
      </header>

      <div :if={@sentinels == []} class="gl-empty">
        <p>No approvals pending.</p>
        <p class="gl-muted">
          Tasks with <code>requires_approval: director</code> in frontmatter will appear here.
        </p>
      </div>

      <div :if={@sentinels != []} class="gl-approvals__split">
        <div class="gl-approvals__list">
          <div
            :for={{s, idx} <- Enum.with_index(@sentinels)}
            phx-click="select"
            phx-value-index={idx}
            class={approval_row_class(idx, @selected_index)}
            role="button"
            tabindex="0"
          >
            <ApprovalCard.approval_card sentinel={s} />
          </div>
        </div>

        <aside class="gl-approvals__diff" aria-label="Task prompt">
          <h2 class="gl-panel__header">/prompt</h2>
          <pre class="gl-diff"><code>{selected_body(@sentinels, @selected_index)}</code></pre>
        </aside>
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
              |> Enum.filter(
                &(String.starts_with?(&1, "awaiting-approval-") and String.ends_with?(&1, ".md"))
              )
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
              requested_at: sentinel_mtime_iso(sentinel_path),
              prompt_body: task.prompt_body || ""
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

  defp approval_row_class(idx, idx), do: "gl-approvals__row gl-approvals__row--selected"
  defp approval_row_class(_, _), do: "gl-approvals__row"

  defp selected_body(sentinels, idx)
       when is_integer(idx) and idx >= 0 and idx < length(sentinels) do
    case Enum.at(sentinels, idx) do
      %{prompt_body: body} when is_binary(body) and body != "" -> body
      _ -> "(no prompt body)"
    end
  end

  defp selected_body(_, _), do: "(select a row to preview)"

  defp base_dir,
    do: Application.get_env(:glorbo, :glorbo_base, Path.expand("~/.glorbo"))

  defp clamp_selection(_, []), do: nil
  defp clamp_selection(nil, _), do: 0
  defp clamp_selection(idx, sentinels), do: min(idx, length(sentinels) - 1)

  defp parse_index(i, sentinels) do
    case Integer.parse(to_string(i)) do
      {n, _} when n >= 0 -> clamp_selection(n, sentinels)
      _ -> 0
    end
  end

  defp step(%{sentinels: []}, _), do: nil

  defp step(%{sentinels: sentinels, selected_index: nil}, _),
    do: if(sentinels == [], do: nil, else: 0)

  defp step(%{sentinels: sentinels, selected_index: idx}, delta) do
    max_idx = length(sentinels) - 1
    idx |> Kernel.+(delta) |> max(0) |> min(max_idx)
  end

  defp keyboard_action(socket, event) do
    sentinels = socket.assigns.sentinels
    idx = socket.assigns.selected_index

    if is_integer(idx) and idx >= 0 and idx < length(sentinels) do
      sentinel = Enum.at(sentinels, idx)
      handle_event(event, %{"task_path" => sentinel.task_path}, socket)
    else
      {:noreply, socket}
    end
  end
end
