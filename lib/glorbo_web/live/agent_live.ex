defmodule GlorboWeb.AgentLive do
  @moduledoc """
  Agent detail view — GET `/companies/:company/agents/:agent` (M3 rewrite).

  Matches the mockup (abc.zip views/agent.jsx) — a three-column layout
  that treats this as the signature view of the dashboard.

  ## Columns

  **Left** — identity card + workspace file tree. Tree walks
  `agents/<slug>/workspace/` and annotates each entry with its
  bind-mount class (`rw` / `ro` / hidden). Under the walk, a
  "NOT MOUNTED" list makes the kernel-guard invariant visible:
  sibling agents, other companies, and so on.

  **Center** — three tabs over the same dataset: stdout (streaming),
  sandbox argv (mount-argv generated from the agent's permissions),
  inbox/outbox (last message pair).

  **Right** — config `<dl>`, budget meter with 80% threshold line,
  permissions list where each row is tagged `mount` or `router`
  depending on whether `PermissionMapper` emits a bwrap flag.

  ## Stdout streaming

  Same as before: `GlorboWeb.StdoutStreamer` on the DynamicSupervisor,
  monitored; crash → re-spawn without killing the LV.

  ## Actions

  Header action row: edit AGENT.md (disabled), send message
  (disabled), stop (disabled pending M3.5 server-side sentinel),
  wake now (wired via `Glorbo.Actions.wake_agent/3`).
  """
  use GlorboWeb, :live_view
  require Logger

  import GlorboWeb.LiveHelpers,
    only: [base_dir: 0, current_year_month: 0, two_dp: 1, zero_dp: 1]

  alias Glorbo.CLI.Registry, as: CLIRegistry
  alias Glorbo.ProviderModel
  alias Glorbo.Repo
  alias GlorboWeb.Components.ChatDrawer
  alias GlorboWeb.Components.{StatusPill, StdoutTail}

  # Coalescing window for :agent_status churn on the viewed agent. Matches
  # the company-roster + :file_event window so the detail panel refreshes
  # at the same cadence as the rest of the dashboard.
  @agent_status_coalesce_ms 250

  @impl true
  def mount(%{"company" => co, "agent" => ag}, _session, socket) do
    cond do
      not Glorbo.Slug.valid?(co) ->
        {:ok,
         socket
         |> put_flash(:error, "Invalid company identifier.")
         |> push_navigate(to: ~p"/companies")}

      not Glorbo.Slug.valid?(ag, :agent) ->
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
      detail = load_agent_detail(base, co, ag)

      history = load_history(base, co, ag)

      socket =
        socket
        |> assign(:page_title, "#{detail.name} — #{co} — Glorbo")
        |> assign(:current_company, co)
        |> assign(:company_slug, co)
        |> assign(:agent_slug, ag)
        |> assign(:detail, detail)
        |> assign(:tab, :stdout)
        |> assign(:hovered_perm, nil)
        |> assign(:streamer_pid, nil)
        |> assign(:history, history)
        |> assign(:runs, [])
        |> assign(:runs_expanded, MapSet.new())
        |> assign(:memory, %{index: "", files: []})
        |> assign(:working_on, nil)
        |> assign(:open_file, nil)
        |> assign(:wake_open?, false)
        |> assign(:config_editing?, false)
        |> assign(:provider_options, provider_options())
        |> assign(:model_options, [])
        |> stream(:stdout, [], limit: -1000)
        |> ChatDrawer.State.wire_drawer()

      if connected?(socket) do
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:stdout")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:wake")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:#{ag}:budget")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:audit")
        Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:#{co}:agents:status")

        case GlorboWeb.StdoutStreamer.start(co, ag, base: base) do
          {:ok, pid} ->
            Process.monitor(pid)
            # Backfill the local stream from the streamer's rolling
            # buffer (task #141) — singleton streamers only replay at
            # their init, so late-subscribing mounts need this call
            # to see recent history.
            socket = backfill_stdout(socket, pid)
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
  def handle_info({:stdout_line, _co, _ag, %{id: _id} = payload}, socket) do
    # Forward the full payload — it carries `kind` + optional `ts`/`exit_code`
    # for the dispatch-card rendering in Components.StdoutTail (task #135).
    {:noreply, stream_insert(socket, :stdout, payload, at: -1, limit: -1000)}
  end

  # Realtime history: append audit records that concern this agent.
  def handle_info({:audit_append, record}, socket) when is_map(record) do
    if audit_for_this_agent?(record, socket.assigns.agent_slug) do
      row = to_history_row(stringify_keys(record))
      new_history = Enum.take([row | socket.assigns.history], 200)
      {:noreply, assign(socket, :history, new_history)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:file_event, rel, _events}, socket) do
    {:noreply, ChatDrawer.State.maybe_refresh_drawer(socket, rel)}
  end

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

  def handle_info({:agent_status, slug, _status, working_on}, socket) do
    if slug == socket.assigns[:agent_slug] do
      # Coalesce status churn for the viewed agent. A looping agent flips
      # state several times/sec, and a synchronous load_agent_detail +
      # full @detail re-render per flip thrashes the (large) detail panel's
      # layout (TODO P1 agent-detail thrash, 2026-05-22). Stash the latest
      # working-on in an *unrendered* assign — an assign not in the
      # template yields an empty diff, so no DOM is patched — and fold the
      # burst into one detail reload per window.
      socket =
        socket
        |> assign(:pending_working_on, working_on)
        |> GlorboWeb.LiveHelpers.schedule_coalesced_reload(
          :coalesced_detail_reload,
          @agent_status_coalesce_ms,
          :detail_reload_pending?
        )

      {:noreply, socket}
    else
      # Another agent flipping state has no bearing on this detail view.
      {:noreply, socket}
    end
  end

  def handle_info(:coalesced_detail_reload, socket) do
    base = GlorboWeb.LiveHelpers.base_dir()
    co = socket.assigns.company_slug
    slug = socket.assigns.agent_slug
    detail = load_agent_detail(base, co, slug)

    {:noreply,
     socket
     |> assign(:detail, detail)
     |> assign(:working_on, Map.get(socket.assigns, :pending_working_on))
     |> GlorboWeb.LiveHelpers.clear_reload_pending(:detail_reload_pending?)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("chat_drawer_post", %{"body" => body}, socket),
    do: ChatDrawer.State.post(socket, body)

  def handle_event("tab", %{"tab" => tab}, socket)
      when tab in ~w(stdout sandbox inbox history runs memory path_requests) do
    socket = assign(socket, :tab, String.to_existing_atom(tab))

    socket =
      cond do
        tab == "runs" -> assign(socket, :runs, load_runs(socket))
        tab == "memory" -> assign(socket, :memory, load_memory_files(socket))
        tab == "path_requests" -> assign(socket, :path_requests, load_path_requests(socket))
        true -> socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_run", %{"inv" => inv_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.runs_expanded, inv_id),
        do: MapSet.delete(socket.assigns.runs_expanded, inv_id),
        else: MapSet.put(socket.assigns.runs_expanded, inv_id)

    {:noreply, assign(socket, :runs_expanded, expanded)}
  end

  def handle_event("hover_perm", %{"perm" => perm}, socket) do
    {:noreply, assign(socket, :hovered_perm, perm)}
  end

  def handle_event("unhover_perm", _params, socket) do
    {:noreply, assign(socket, :hovered_perm, nil)}
  end

  def handle_event("wake_prompt", _params, socket) do
    {:noreply, assign(socket, :wake_open?, true)}
  end

  def handle_event("wake_cancel", _params, socket) do
    {:noreply, assign(socket, :wake_open?, false)}
  end

  def handle_event("wake", params, socket) do
    reason = Map.get(params, "reason", "")
    base = base_dir()

    case Glorbo.Actions.wake_agent(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           reason,
           base: base,
           actor: "director"
         ) do
      :ok ->
        {:noreply,
         socket
         |> assign(:wake_open?, false)
         |> put_flash(:info, "Woken. Writing state/wake-request.md…")}

      {:error, err} ->
        Logger.warning("wake_agent failed",
          company: socket.assigns.company_slug,
          agent: socket.assigns.agent_slug,
          reason: inspect(err)
        )

        {:noreply,
         socket
         |> assign(:wake_open?, false)
         |> put_flash(:error, "Could not wake agent.")}
    end
  end

  def handle_event("stop", _params, socket) do
    case find_agent_server(socket.assigns.company_slug, socket.assigns.agent_slug) do
      nil ->
        {:noreply, put_flash(socket, :info, "Agent is not running.")}

      pid ->
        case Glorbo.Agent.Server.stop_inflight(pid) do
          :ok -> {:noreply, put_flash(socket, :info, "Stopped in-flight dispatch.")}
          :idle -> {:noreply, put_flash(socket, :info, "Agent is idle — nothing to stop.")}
        end
    end
  rescue
    _ -> {:noreply, put_flash(socket, :error, "Could not stop agent.")}
  end

  def handle_event("retire", _params, socket) do
    slug = socket.assigns.agent_slug
    company = socket.assigns.company_slug

    if retirable?(slug) do
      do_retire(socket, company, slug)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Can't retire #{slug} — CEO is a load-bearing role and must be reassigned, not archived."
       )}
    end
  end

  # task #117 — click a file in the workspace tree to open an editor.
  # `path` is the workspace-relative path so the UI never leaks
  # absolute paths, and the server re-anchors against the known
  # workspace dir (defence in depth against traversal).
  @workspace_edit_max_bytes 512 * 1024

  def handle_event("open_file", %{"path" => rel}, socket) do
    case read_workspace_file(socket, rel) do
      {:ok, content} ->
        {:noreply, assign(socket, :open_file, %{rel: rel, content: content, error: nil})}

      {:error, :too_large} ->
        {:noreply, put_flash(socket, :error, "File is larger than 512 KB — edit on disk.")}

      {:error, :binary} ->
        {:noreply, put_flash(socket, :error, "Binary file — won't open in the editor.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "File no longer exists.")}

      {:error, :invalid_path} ->
        {:noreply, put_flash(socket, :error, "Invalid path.")}

      {:error, :not_a_regular_file} ->
        {:noreply, put_flash(socket, :error, "Path is not a regular file; refused.")}

      {:error, :symlink_in_path} ->
        {:noreply, put_flash(socket, :error, "Path contains a symlink; refused.")}

      {:error, :contract_file} ->
        {:noreply, put_flash(socket, :error, "Contract file; use the config editor.")}
    end
  end

  def handle_event("close_file", _params, socket) do
    {:noreply, assign(socket, :open_file, nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    case socket.assigns.open_file do
      %{rel: rel} ->
        case write_workspace_file(socket, rel, content) do
          :ok ->
            {:noreply,
             socket
             |> assign(:detail, refresh_files(socket))
             |> assign(:open_file, nil)
             |> put_flash(:info, "Saved #{rel}.")}

          {:error, reason} ->
            {:noreply,
             assign(socket, :open_file, %{
               socket.assigns.open_file
               | error: "save failed: #{inspect(reason)}"
             })}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # Task #143 — create an empty file under the agent dir and open the
  # editor on it. Refuses to overwrite an existing file.
  def handle_event("create_file", %{"path" => rel}, socket) do
    case Glorbo.Actions.Agents.create_workspace_file(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           rel,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:detail, refresh_files(socket))
         |> assign(:open_file, %{rel: rel, content: "", error: nil})
         |> put_flash(:info, "Created #{rel}.")}

      {:error, :already_exists} ->
        {:noreply, put_flash(socket, :error, "File already exists.")}

      {:error, :invalid_path} ->
        {:noreply, put_flash(socket, :error, "Invalid path.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create failed: #{inspect(reason)}.")}
    end
  end

  # Task #143 — soft-delete: move to history/deleted/<ts>-<basename>
  # so the Director can recover. AGENT.md and stdout.log are refused
  # outright (AGENT.md is the agent's identity; stdout.log is runtime
  # state). Other contract files deleted = agent simply falls back to
  # whatever AGENT.md says (SOUL.md / HEARTBEAT.md / etc).
  def handle_event("delete_file", %{"path" => rel}, socket) do
    if rel in ["AGENT.md", "stdout.log"] do
      {:noreply, put_flash(socket, :error, "#{rel} is load-bearing; delete refused.")}
    else
      case soft_delete(socket, rel) do
        :ok ->
          {:noreply,
           socket
           |> assign(:detail, refresh_files(socket))
           |> put_flash(:info, "Moved #{rel} to history/deleted/.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}.")}
      end
    end
  end

  # paperclip-ux-gaps §5 — the config panel is read-only on mount; the
  # director clicks "edit" to flip to a structured form that writes the
  # allow-listed keys back to AGENT.md frontmatter atomically.
  def handle_event("config_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:config_editing?, true)
     |> assign(:model_options, model_options(socket.assigns.detail.provider))}
  end

  def handle_event("config_cancel", _params, socket),
    do: {:noreply, assign(socket, :config_editing?, false)}

  # Live-update the model datalist whenever the provider field changes
  # in the config form (GEP-32 phase 4).
  def handle_event("config_form_change", params, socket) do
    {:noreply, assign(socket, :model_options, model_options(params["provider"]))}
  end

  def handle_event("config_save", params, socket) do
    # #277 — validate heartbeat cron before touching disk. A
    # malformed cron used to save silently and the heartbeat
    # scheduler would just log + skip forever; directors saw no
    # reason the agent wasn't waking. Now the save fails inline
    # with a concrete parser error.
    case validate_heartbeat(params["heartbeat"]) do
      :ok ->
        do_config_save(params, socket)

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid heartbeat cron: #{reason}. Expected a 5-field cron (e.g. \"0 * * * *\") or blank for no heartbeat."
         )}
    end
  end

  defp do_config_save(params, socket) do
    agent_md =
      Glorbo.Agent.FileLayout.agent_md(
        Path.join([
          base_dir(),
          "companies",
          socket.assigns.company_slug,
          "agents",
          socket.assigns.agent_slug
        ])
      )

    # Threatmodel: form values are client-controlled and could carry
    # anything (DevTools edits, replay attacks). Each field is checked
    # against a strict shape BEFORE we persist anything to AGENT.md.
    # Gemini deep-dive F2: previously only `network` was sanitised;
    # `provider`, `model`, `reports_to`, `autonomy` flowed through
    # verbatim. Combined with F3 (dispatcher `{model}` substitution
    # into reply_dir / reply_filename_template with no escaping) this
    # was an arbitrary-file-write primitive — e.g. `model =
    # "../../../AGENT.md"` would cause `prepare_reply_dir/2` to
    # `rm!` the agent's own contract file on the next dispatch.
    with :ok <- safe_config_identifier(params["provider"], :provider),
         :ok <- safe_config_model(params["model"], :model),
         :ok <- safe_config_slug(params["reports_to"], :reports_to),
         :ok <- safe_config_autonomy(params["autonomy"]) do
      updates =
        %{
          "provider" => params["provider"],
          "model" => params["model"],
          "reports_to" => params["reports_to"],
          "heartbeat" => params["heartbeat"],
          "network" => sanitise_network(params["network"]),
          "autonomy" => params["autonomy"]
        }
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()

      do_persist_config_save(agent_md, updates, socket)
    else
      {:error, {:invalid_identifier, {:model, ""}}} ->
        {:noreply, put_flash(socket, :error, "model cannot be empty.")}

      {:error, {:invalid_identifier, {:model, _}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid model: allowed chars are letters/digits/`._-/:`; no `..`, `//`, " <>
             "leading or trailing `/`; up to 128 chars."
         )}

      {:error, {:invalid_identifier, {field, ""}}} ->
        {:noreply, put_flash(socket, :error, "#{field} cannot be empty.")}

      {:error, {:invalid_identifier, {field, _}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid #{field}: must be 1-64 chars, letters/digits/`._-` only, " <>
             "starting with a letter."
         )}

      {:error, {:invalid_slug, {field, _}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid #{field}: must be 1-64 chars, lowercase letters/digits/`-_` only."
         )}

      {:error, {:invalid_autonomy, _}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Invalid autonomy: must be one of \"manual\", \"supervised\", or \"auto\"."
         )}
    end
  end

  # Same shape as `GlorboWeb.MCP.Args.require_safe_identifier/2`. We
  # don't call it directly because the MCP layer raises on certain
  # error shapes; here we return tagged errors that map to flash
  # messages. Identifiers (provider / model / template names) must
  # not carry path traversal, quotes, newlines, etc.
  @safe_identifier_re ~r/\A[A-Za-z][A-Za-z0-9._-]{0,63}\z/

  # `provider` is REQUIRED in AGENT.md (`validate_provider/1` returns
  # `:missing_provider` for nil/empty). nil from the form means "field
  # absent in submit" — accept silently (other code preserves the
  # existing value). `""` means a tampered submit that would persist
  # an empty contract — REJECT so the next dispatch's AGENT.md parse
  # doesn't break the agent. (Copilot review on PR #26.)
  defp safe_config_identifier(nil, _field), do: :ok
  defp safe_config_identifier("", field), do: {:error, {:invalid_identifier, {field, ""}}}

  defp safe_config_identifier(v, field) when is_binary(v) do
    if Regex.match?(@safe_identifier_re, v) do
      :ok
    else
      {:error, {:invalid_identifier, {field, v}}}
    end
  end

  defp safe_config_identifier(v, field),
    do: {:error, {:invalid_identifier, {field, v}}}

  # Model identifiers in the wild include:
  #   * provider/namespace slashes: `lmstudio/qwen/qwen3.6-35b-a3b`,
  #     `openai/gpt-4o`
  #   * Ollama-style `tag` separators: `llama2:7b`, `mistral:7b-instruct`
  # Allow `/` and `:` so legit values aren't rejected, BUT explicitly
  # forbid:
  #   * `..`  — path traversal
  #   * `//`  — empty-segment / absolute-anchor confusion
  #   * leading or trailing `/`
  # alongside the alphanum + `._-` allowlist. Anything that would let
  # an attacker write `../../../AGENT.md` through to the dispatcher's
  # `{model}` template substitution is refused here.
  @safe_model_re ~r/\A[A-Za-z0-9][A-Za-z0-9._\/:-]{0,127}\z/

  # `model` is REQUIRED in AGENT.md (same as `provider`). Same nil-vs-"" rule.
  defp safe_config_model(nil, _field), do: :ok
  defp safe_config_model("", field), do: {:error, {:invalid_identifier, {field, ""}}}

  defp safe_config_model(v, field) when is_binary(v) do
    cond do
      not Regex.match?(@safe_model_re, v) -> {:error, {:invalid_identifier, {field, v}}}
      String.contains?(v, "..") -> {:error, {:invalid_identifier, {field, v}}}
      String.contains?(v, "//") -> {:error, {:invalid_identifier, {field, v}}}
      String.ends_with?(v, "/") -> {:error, {:invalid_identifier, {field, v}}}
      true -> :ok
    end
  end

  defp safe_config_model(v, field), do: {:error, {:invalid_identifier, {field, v}}}

  # Agent slugs (reports_to) follow the project's lowercase-kebab/snake
  # convention. Looser than the identifier regex (no leading uppercase)
  # but still strictly path-safe.
  @safe_slug_re ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  defp safe_config_slug(nil, _field), do: :ok
  defp safe_config_slug("", _field), do: :ok

  defp safe_config_slug(v, field) when is_binary(v) do
    if Regex.match?(@safe_slug_re, v) do
      :ok
    else
      {:error, {:invalid_slug, {field, v}}}
    end
  end

  defp safe_config_slug(v, field), do: {:error, {:invalid_slug, {field, v}}}

  defp safe_config_autonomy(nil), do: :ok
  defp safe_config_autonomy(""), do: :ok
  defp safe_config_autonomy(v) when v in ["manual", "supervised", "auto"], do: :ok
  defp safe_config_autonomy(v), do: {:error, {:invalid_autonomy, v}}

  defp do_persist_config_save(agent_md, updates, socket) do
    case Glorbo.Filesystem.FrontmatterWriter.update_keys(agent_md, updates) do
      :ok ->
        base = base_dir()
        co = socket.assigns.company_slug
        ag = socket.assigns.agent_slug

        {:noreply,
         socket
         |> assign(:detail, load_agent_detail(base, co, ag))
         |> assign(:config_editing?, false)
         |> put_flash(:info, "Saved AGENT.md for #{ag}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not save config: #{inspect(reason)}")}
    end
  end

  # Blank / nil heartbeat = no-heartbeat agent (valid). Otherwise
  # delegate to Crontab.CronExpression.Parser so any 5-field cron
  # the scheduler accepts is allowed here.
  defp validate_heartbeat(nil), do: :ok
  defp validate_heartbeat(""), do: :ok

  defp validate_heartbeat(cron) when is_binary(cron) do
    case Crontab.CronExpression.Parser.parse(String.trim(cron)) do
      {:ok, _expr} -> :ok
      {:error, reason} -> {:error, to_string(reason)}
    end
  end

  defp validate_heartbeat(_), do: {:error, "not a string"}

  defp soft_delete(socket, rel) do
    case Glorbo.Actions.Agents.trash_workspace_file(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           rel,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp refresh_files(socket) do
    ag_dir = agent_dir(socket)

    %{
      socket.assigns.detail
      | files: scan_agent_files(ag_dir),
        workspace_tree: walk_workspace(ag_dir)
    }
  end

  defp read_workspace_file(socket, rel) do
    with {:ok, abs_path} <- resolve_workspace_path(socket, rel),
         :ok <- ensure_no_symlink_on_path(abs_path, agent_dir(socket)),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(abs_path),
         :ok <- check_size(size),
         {:ok, bytes} <- File.read(abs_path),
         :ok <- check_binary(bytes) do
      {:ok, bytes}
    else
      {:ok, %File.Stat{}} ->
        {:error, :not_a_regular_file}

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason}
      when reason in [
             :too_large,
             :binary,
             :invalid_path,
             :not_a_regular_file,
             :contract_file,
             :symlink_in_path
           ] ->
        {:error, reason}

      {:error, _} ->
        {:error, :not_found}
    end
  end

  defp write_workspace_file(socket, rel, content) do
    case Glorbo.Actions.Agents.write_workspace_file(
           socket.assigns.company_slug,
           socket.assigns.agent_slug,
           rel,
           content,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # threatmodel H9/H10 enforcement (contract-file refusal + symlink
  # guard) now lives in Glorbo.Actions.Agents; the read path below
  # keeps a local copy of the symlink walker because read-only
  # access isn't flagged by the ratchet and Actions is write-only.

  # threatmodel H10: resolve_workspace_path only compares strings;
  # an attacker-planted symlink *under* the agent dir would pass the
  # prefix check yet File.read/write would still follow it. lstat
  # every path component from the agent root to the target and
  # refuse any symlink along the way. :enoent on leaves is fine
  # (new file) — only symlinks are fatal.
  defp ensure_no_symlink_on_path(abs_path, root) do
    relative = Path.relative_to(abs_path, root)
    parts = Path.split(relative)

    Enum.reduce_while(parts, root, fn part, acc ->
      next = Path.join(acc, part)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_in_path}}
        {:ok, %File.Stat{}} -> {:cont, next}
        {:error, :enoent} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, _} = err -> err
      path when is_binary(path) -> :ok
    end
  end

  # Widened from workspace-only to full agent dir for task #143. The
  # UI now manages contract files (AGENT.md/SOUL.md/HEARTBEAT.md) +
  # their sibling dirs, not just workspace/. Traversal guard stays
  # strict — expanded path must live under the agent's own dir.
  defp resolve_workspace_path(socket, rel) do
    root = agent_dir(socket)
    candidate = Path.expand(Path.join(root, rel))

    if String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      {:error, :invalid_path}
    end
  end

  defp check_size(size) when size <= @workspace_edit_max_bytes, do: :ok
  defp check_size(_), do: {:error, :too_large}

  defp check_binary(bytes) do
    # Crude but effective — files with NUL bytes in the first 4 KiB are
    # treated as binary and refused in the editor. Plain text + UTF-8
    # markdown/JSON/YAML sail through.
    head = binary_part(bytes, 0, min(byte_size(bytes), 4096))
    if String.contains?(head, <<0>>), do: {:error, :binary}, else: :ok
  end

  # Task #141 — streamer is a singleton per agent; late-subscribing
  # LVs miss the init-time replay broadcast. We GenServer.call the
  # streamer for its rolling `recent` buffer and stream_insert each
  # payload locally so this LV sees the same history.
  defp backfill_stdout(socket, pid) do
    try do
      GlorboWeb.StdoutStreamer.backfill(pid)
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
    |> Enum.reduce(socket, fn payload, acc ->
      stream_insert(acc, :stdout, payload, at: -1, limit: -1000)
    end)
  end

  defp agent_dir(socket) do
    Path.join([
      base_dir(),
      "companies",
      socket.assigns.company_slug,
      "agents",
      socket.assigns.agent_slug
    ])
  end

  # GEP-27 — load pending path requests for this agent.
  defp load_path_requests(socket) do
    co = socket.assigns.company_slug
    ag = socket.assigns.agent_slug

    case Glorbo.PathRequestGate.list_pending(co, ag) do
      [] -> []
      reqs when is_list(reqs) -> reqs
      _ -> []
    end
  catch
    _, _ -> []
  end

  # The CEO is load-bearing in the company heartbeat contract (see
  # priv/templates/heartbeats/ceo.md + GEP-19 "assigned_to swap").
  # Retiring it breaks everything; force a Director rename/reassign
  # via CLI instead.
  defp retirable?("ceo"), do: false
  defp retirable?(slug) when is_binary(slug), do: true
  defp retirable?(_), do: false

  defp do_retire(socket, company, slug) do
    # Stop any in-flight dispatch first so we don't rename a live dir.
    _ =
      case find_agent_server(company, slug) do
        nil -> :ok
        pid -> Glorbo.Agent.Server.stop_inflight(pid)
      end

    case Glorbo.Actions.Agents.retire(company, slug,
           actor: "director",
           base: base_dir()
         ) do
      {:ok, %{archive_rel_path: archive_rel}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Retired #{slug}. Moved to #{archive_rel}.")
         |> push_navigate(to: ~p"/companies/#{company}")}

      {:error, reason} ->
        require Logger

        Logger.warning("retire_agent failed",
          company: company,
          agent: slug,
          reason: inspect(reason)
        )

        {:noreply, put_flash(socket, :error, "Could not retire agent.")}
    end
  end

  @impl true
  def terminate(_reason, _socket) do
    # Don't stop the StdoutStreamer — it's a singleton per {company,
    # agent} shared by every open AgentLive (#134). Lingering after
    # the last tab closes is fine: the poll loop is cheap, and the
    # next mount reuses the pid. Streamer supervisor restarts on crash.
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="gl-view gl-view--tall gl-agent-detail">
      <header class="gl-view__header gl-agent-detail__header">
        <div>
          <h1 class="gl-heading gl-heading--display">
            <span class="gl-muted">agents /</span> {@agent_slug}
            <StatusPill.status_pill status={@detail.pill_status} label={@detail.pill_label} />
          </h1>
          <p class="gl-overview__path">
            <span class="gl-muted">{GlorboWeb.LiveHelpers.display_base()}/companies/{@company_slug}/agents/</span>{@agent_slug}<span class="gl-muted">/AGENT.md</span>
          </p>
          <p :if={@working_on} class="gl-agent-detail__working-on gl-muted">
            working on <span class="gl-tabular">{@working_on}</span>
          </p>
        </div>
        <div class="gl-overview__actions">
          <button
            type="button"
            class="gl-btn"
            phx-click="open_file"
            phx-value-path="AGENT.md"
            title="Open AGENT.md in the in-browser editor"
          >
            ✎ edit AGENT.md
          </button>
          <.link
            navigate={~p"/companies/#{@company_slug}/dms/#{@agent_slug}"}
            class="gl-btn"
            title="Open Director ↔ #{@agent_slug} DM"
          >
            ✉ send message
          </.link>
          <.link
            navigate={assign_task_url(@company_slug, @agent_slug)}
            class="gl-btn"
            title={"Open Kanban new-task modal with assignee preset to #{@agent_slug}"}
          >
            + assign task
          </.link>
          <button
            type="button"
            class="gl-btn gl-btn--deny"
            phx-click="stop"
            data-confirm="Kill the in-flight dispatch task? Agent stays registered; only the current invocation is terminated."
            title="Kill the current dispatch Task (no-op if agent is idle)"
          >
            ⏻ stop
          </button>
          <button
            :if={retirable?(@agent_slug)}
            type="button"
            class="gl-btn gl-btn--ghost"
            phx-click="retire"
            data-confirm={"Retire #{@agent_slug}? The whole directory moves to agents/.archive/. Restore by moving the directory back. Company isolation is preserved."}
            title="Move this agent to agents/.archive/ so it stops running"
          >
            🗃 retire
          </button>
          <.wake_button />
        </div>
      </header>

      <div class="gl-agent-detail__grid" id="gl-agent-grid" phx-hook="RightPanelCollapse">
        <%!-- LEFT COLUMN --%>
        <div class="gl-agent-detail__col">
          <section class="gl-panel gl-agent-identity">
            <header class="gl-panel__header">
              <span>identity</span>
              <span class="gl-panel__hint">{@detail.role}</span>
            </header>
            <div class="gl-panel__body">
              <div class="gl-agent-identity__avatar">
                {String.slice(@agent_slug, 0, 2) |> String.upcase()}
                <span class={[
                  "gl-agent-identity__dot",
                  "gl-agent-identity__dot--" <> Atom.to_string(@detail.pill_status)
                ]}></span>
              </div>
              <div class="gl-agent-identity__name">{@detail.name}</div>
              <div class="gl-muted gl-agent-identity__reports">
                reports to <span class="gl-tabular">{@detail.reports_to || "(director)"}</span>
              </div>
              <div class="gl-muted gl-agent-identity__pid">
                pid
                <span :if={@detail.runtime} class="gl-tabular">
                  <code>{@detail.runtime.server_pid}</code>
                </span>
                <span :if={!@detail.runtime} class="gl-tabular">(not running)</span>
              </div>
            </div>
          </section>

          <%!-- task #118 — render SOUL.md if the agent has one --%>
          <section :if={@detail.soul} class="gl-panel gl-agent-soul">
            <header class="gl-panel__header">
              <span>soul</span>
              <span class="gl-panel__hint">SOUL.md</span>
            </header>
            <div class="gl-panel__body gl-agent-soul__body">
              {@detail.soul}
            </div>
          </section>

          <%!-- Task #143 — agent dir file manager (contracts + subdirs) --%>
          <section class="gl-panel gl-agent-files">
            <header class="gl-panel__header">
              <span>files</span>
              <span class="gl-panel__hint">agents/{@agent_slug}/</span>
            </header>
            <div class="gl-panel__body gl-panel__body--flush">
              <div class="gl-filetree">
                <div class="gl-filetree__section">contract files</div>

                <div
                  :for={row <- @detail.files.contracts}
                  class={[
                    "gl-filetree__node",
                    not row.exists? && "gl-filetree__node--missing"
                  ]}
                >
                  <span class="gl-filetree__prefix">├─ </span>
                  <button
                    :if={row.exists?}
                    type="button"
                    class="gl-filetree__file gl-filetree__file--clickable"
                    phx-click="open_file"
                    phx-value-path={row.rel}
                  >
                    {row.name}
                  </button>
                  <span :if={not row.exists?} class="gl-filetree__file gl-muted">
                    {row.name}
                  </span>
                  <button
                    :if={not row.exists?}
                    type="button"
                    class="gl-filetree__action gl-muted"
                    phx-click="create_file"
                    phx-value-path={row.rel}
                  >
                    + create
                  </button>
                  <button
                    :if={row.exists? and row.name not in ["AGENT.md", "stdout.log"]}
                    type="button"
                    class="gl-filetree__action gl-muted"
                    phx-click="delete_file"
                    phx-value-path={row.rel}
                    data-confirm={"Delete #{row.name}?"}
                  >
                    × delete
                  </button>
                </div>

                <div class="gl-filetree__section">directories</div>

                <div
                  :for={row <- @detail.files.subdirs}
                  class="gl-filetree__node"
                >
                  <span class="gl-filetree__prefix">├─ </span>
                  <span class="gl-filetree__dir">{row.name}/</span>
                  <span class="gl-filetree__count gl-muted">{row.count}</span>
                </div>

                <%!-- Bind-mount view (preserved from pre-#143) --%>
                <div class="gl-filetree__section">sandbox view</div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">├─ </span>/workspace
                  <span class="gl-mount-tag gl-mount-tag--rw">rw</span>
                </div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">├─ </span>/inbox
                  <span class="gl-mount-tag gl-mount-tag--ro">ro</span>
                </div>
                <div class="gl-filetree__node gl-filetree__node--mount">
                  <span class="gl-filetree__prefix">└─ </span>/outbox
                  <span class="gl-mount-tag gl-mount-tag--rw">rw</span>
                </div>

                <div class="gl-filetree__section">
                  not mounted — invisible by construction
                </div>
                <div
                  :for={entry <- @detail.not_mounted}
                  class="gl-filetree__node gl-filetree__node--hidden"
                >
                  <span class="gl-filetree__prefix">× </span>{entry}
                </div>
              </div>
            </div>
          </section>
        </div>

        <%!-- CENTER COLUMN --%>
        <div class="gl-agent-detail__col gl-agent-detail__col--center">
          <section class="gl-panel gl-agent-detail__center-panel">
            <header class="gl-panel__header">
              <span>sandboxed</span>
              <span class="gl-panel__title">invocation</span>
              <div class="gl-agent-detail__tabs">
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :stdout && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="stdout"
                >
                  stdout
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :sandbox && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="sandbox"
                >
                  sandbox argv
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :inbox && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="inbox"
                >
                  inbox/outbox
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :runs && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="runs"
                >
                  runs
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :history && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="history"
                >
                  history
                </button>
                <button
                  type="button"
                  class={["gl-agent-detail__tab", @tab == :memory && "gl-agent-detail__tab--active"]}
                  phx-click="tab"
                  phx-value-tab="memory"
                  title="File-based agent memory (GEP-21)"
                >
                  memory
                </button>
                <button
                  type="button"
                  class={[
                    "gl-agent-detail__tab",
                    @tab == :path_requests && "gl-agent-detail__tab--active"
                  ]}
                  phx-click="tab"
                  phx-value-tab="path_requests"
                  title="Sandbox path requests (GEP-27)"
                >
                  path requests
                </button>
              </div>
            </header>

            <div :if={@tab == :stdout} class="gl-panel__body gl-panel__body--flush gl-stdout-wrap">
              <StdoutTail.stdout_tail stream={@streams.stdout} />
            </div>

            <div :if={@tab == :sandbox} class="gl-panel__body gl-sandbox">
              <p class="gl-muted gl-sandbox__hint">
                Generated per-wake by <code>Glorbo.Sandbox.PermissionMapper</code>.
                Hover a permission on the right to highlight its mount.
              </p>
              <pre class="gl-sandbox__argv"><span class="gl-sandbox__cmd">bwrap</span><span class="gl-sandbox__section">── BASE SANDBOX ──</span><span :for={flag <- @detail.sandbox.base} class="gl-sandbox__line"><span class="gl-sandbox__flag">  {flag}</span></span><span class="gl-sandbox__section">── SELF — this agent's private areas ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.workspace_path} /workspace</span></span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.outbox_path} /outbox</span></span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  --ro-bind</span> <span class="gl-sandbox__arg">{@detail.sandbox.inbox_path} /inbox</span></span><span class="gl-sandbox__section">── FROM permissions: (one mount per rule) ──</span><span :for={line <- @detail.sandbox.perm_lines} class={["gl-sandbox__line", @hovered_perm == line.perm && "gl-sandbox__line--hl"]}><span :if={line.flag} class="gl-sandbox__flag">  {line.flag}</span><span :if={line.arg}> <span class="gl-sandbox__arg">{line.arg}</span></span><span :if={line.comment} class="gl-sandbox__comment">  {line.comment}</span></span><span class="gl-sandbox__section">── NETWORK ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__flag">  {@detail.sandbox.network_flag}</span><span :if={@detail.sandbox.network_comment} class="gl-sandbox__comment">  {@detail.sandbox.network_comment}</span></span><span class="gl-sandbox__section">── EXEC ──</span><span class="gl-sandbox__line"><span class="gl-sandbox__cmd">  {@detail.sandbox.exec_cmd}</span> <span class="gl-sandbox__arg">--model {@detail.model}</span></span>
              </pre>
            </div>

            <div :if={@tab == :inbox} class="gl-panel__body">
              <div class="gl-io-section">
                <div class="gl-io-section__label">── inbox/ · {@detail.inbox.count} unread ──</div>
                <div :if={@detail.inbox.latest} class="gl-io-card">
                  <div class="gl-muted gl-io-card__meta">
                    {@detail.inbox.latest.meta}
                  </div>
                  <div class="gl-io-card__title">{@detail.inbox.latest.title}</div>
                  <div class="gl-io-card__body">{@detail.inbox.latest.preview}</div>
                </div>
                <div :if={is_nil(@detail.inbox.latest)} class="gl-muted">No inbox messages.</div>
              </div>
              <div class="gl-io-section">
                <div class="gl-io-section__label">── outbox/ · pending route ──</div>
                <div :if={@detail.outbox.latest} class="gl-io-card">
                  <div class="gl-muted gl-io-card__meta">
                    {@detail.outbox.latest.meta}
                  </div>
                  <div class="gl-io-card__title">{@detail.outbox.latest.title}</div>
                  <div class="gl-io-card__body">{@detail.outbox.latest.preview}</div>
                </div>
                <div :if={is_nil(@detail.outbox.latest)} class="gl-muted">No pending outbox.</div>
              </div>
            </div>

            <div :if={@tab == :runs} class="gl-panel__body gl-agent-runs">
              <div :if={@runs == []} class="gl-muted">
                No runs yet. Each dispatch (heartbeat, director wake,
                inbox event) appears here with its tool-call summary
                once complete.
              </div>
              <ul :if={@runs != []} class="gl-agent-runs__list">
                <li
                  :for={run <- @runs}
                  class={[
                    "gl-agent-runs__row",
                    "gl-agent-runs__row--" <> Atom.to_string(run.status)
                  ]}
                >
                  <button
                    type="button"
                    class="gl-agent-runs__header"
                    phx-click="toggle_run"
                    phx-value-inv={run.invocation_id}
                    aria-expanded={MapSet.member?(@runs_expanded, run.invocation_id)}
                  >
                    <span class="gl-agent-runs__inv gl-tabular">
                      {String.slice(run.invocation_id, 0, 8)}
                    </span>
                    <span class="gl-agent-runs__trigger">
                      {run.trigger || "—"}
                    </span>
                    <span class="gl-agent-runs__task gl-muted">
                      {run.task_path || "(no task path)"}
                    </span>
                    <span
                      :if={run.tool_calls && run.tool_calls != %{}}
                      class="gl-agent-runs__tools gl-muted"
                      title={format_tool_calls(run.tool_calls)}
                    >
                      {tool_count_sum(run.tool_calls)} tools
                    </span>
                    <span class={[
                      "gl-agent-runs__status",
                      "gl-agent-runs__status--" <> Atom.to_string(run.status)
                    ]}>
                      {Atom.to_string(run.status)}
                    </span>
                    <span class="gl-agent-runs__duration gl-tabular">
                      {format_duration(run.duration_ms)}
                    </span>
                  </button>
                  <div
                    :if={MapSet.member?(@runs_expanded, run.invocation_id)}
                    class="gl-agent-runs__body"
                  >
                    <dl class="gl-agent-runs__meta">
                      <dt>model</dt>
                      <dd>{run.model || "—"}</dd>
                      <dt>provider</dt>
                      <dd>{run.provider || "—"}</dd>
                      <dt>start</dt>
                      <dd class="gl-tabular">{format_ts(run.start_ts)}</dd>
                      <dt>end</dt>
                      <dd class="gl-tabular">{format_ts(run.end_ts)}</dd>
                      <dt>exit</dt>
                      <dd>{run.exit_status || "—"}</dd>
                      <dt :if={run.tool_calls && run.tool_calls != %{}}>tool calls</dt>
                      <dd :if={run.tool_calls && run.tool_calls != %{}} class="gl-tabular">
                        {format_tool_calls(run.tool_calls)}
                      </dd>
                      <dt>tokens</dt>
                      <dd class="gl-tabular">
                        {format_tokens(run.prompt_tokens, run.completion_tokens)}
                      </dd>
                      <dt>cost</dt>
                      <dd class="gl-tabular">{format_cost(run.cost_usd_cents)}</dd>
                    </dl>
                    <div :if={run.reply_preview} class="gl-agent-runs__reply">
                      <div class="gl-muted">reply preview</div>
                      <pre class="gl-agent-runs__reply-body">{run.reply_preview}</pre>
                    </div>
                  </div>
                </li>
              </ul>
            </div>

            <div :if={@tab == :history} class="gl-panel__body gl-agent-history">
              <div :if={@history == []} class="gl-muted">
                No activity yet. Heartbeat ticks, director wakes, and dispatch
                events will appear here.
              </div>
              <ul :if={@history != []} class="gl-agent-history__list">
                <li
                  :for={row <- @history}
                  class={["gl-agent-history__row", "gl-agent-history__row--" <> row.kind]}
                >
                  <span class="gl-agent-history__ts gl-muted">{row.ts_short}</span>
                  <span class={["gl-agent-history__action", "gl-action--" <> row.class]}>
                    {row.action}
                  </span>
                  <span :if={row.detail} class="gl-agent-history__detail gl-muted">
                    {row.detail}
                  </span>
                </li>
              </ul>
            </div>

            <div :if={@tab == :memory} class="gl-panel__body gl-agent-memory">
              <p class="gl-muted gl-agent-memory__hint">
                File-based agent memory (GEP-21). Each <code>&lt;type&gt;_&lt;topic&gt;.md</code>
                file is composed into the system prompt on every wake, newest-first, capped at 20 KB total.
                Agents write via <code>outbox/memory/</code>; directors can edit the files directly.
              </p>

              <p :if={@memory.files == []} class="gl-agent-memory__empty gl-muted">
                No memories yet. The agent writes them by dropping
                <code>&lt;type&gt;_&lt;topic&gt;.md</code>
                files into its outbox.
              </p>

              <div :if={@memory.index && @memory.index != ""} class="gl-agent-memory__index">
                <header class="gl-agent-memory__section-head">
                  <span class="gl-muted">MEMORY.md · index</span>
                </header>
                <pre class="gl-agent-memory__index-body">{@memory.index}</pre>
              </div>

              <ul :if={@memory.files != []} class="gl-agent-memory__list">
                <li :for={m <- @memory.files} class="gl-agent-memory__row">
                  <header class="gl-agent-memory__row-head">
                    <span class={["gl-pill", "gl-pill--" <> m.type]}>{m.type}</span>
                    <span class="gl-agent-memory__name">{m.name}</span>
                    <span class="gl-muted gl-agent-memory__filename">{m.filename}</span>
                    <span class="gl-muted gl-agent-memory__mtime" title={m.mtime_iso}>
                      {m.mtime_rel}
                    </span>
                  </header>
                  <p :if={m.description != ""} class="gl-muted gl-agent-memory__desc">
                    {m.description}
                  </p>
                  <pre class="gl-agent-memory__body">{m.body}</pre>
                </li>
              </ul>
            </div>

            <div :if={@tab == :path_requests} class="gl-panel__body gl-agent-path-reqs">
              <div :if={@path_requests == []} class="gl-muted">
                No path requests pending. Agents request temporary
                sandbox access by writing <code>path-request-&lt;task_id&gt;.md</code>
                to their outbox.
              </div>
              <ul :if={@path_requests != []} class="gl-agent-path-reqs__list">
                <li :for={pr <- @path_requests} class="gl-agent-path-reqs__row">
                  <div class="gl-agent-path-reqs__meta">
                    <span class="gl-tabular">{pr.task_id}</span>
                    <span :if={pr.requested_at} class="gl-muted">
                      · {pr.requested_at}
                    </span>
                  </div>
                  <div class="gl-agent-path-reqs__reason">{pr.reason}</div>
                  <div class="gl-agent-path-reqs__paths">
                    <span :for={p <- pr.paths} class="gl-agent-path-reqs__tag">
                      {p["path"]} <span class="gl-muted">({p["mode"]})</span>
                    </span>
                  </div>
                </li>
              </ul>
            </div>
          </section>
        </div>

        <%!-- RIGHT COLUMN --%>
        <button
          type="button"
          class="gl-agent-detail__right-toggle"
          aria-controls="gl-agent-right"
          aria-expanded="true"
          title="Collapse/expand right panel (config · budget · permissions)"
        >
          <span class="gl-agent-detail__right-toggle-glyph" aria-hidden="true">⟩</span>
        </button>
        <div class="gl-agent-detail__col" id="gl-agent-right">
          <section :if={@detail.runtime} class="gl-panel">
            <header class="gl-panel__header">
              <span>runtime</span>
              <StatusPill.status_pill
                status={if @detail.runtime.state == :busy, do: :alive, else: :idle}
                label={to_string(@detail.runtime.state)}
              />
            </header>
            <div class="gl-panel__body">
              <dl class="gl-kv">
                <dt>server pid</dt>
                <dd><code>{@detail.runtime.server_pid}</code></dd>
                <dt :if={@detail.runtime.task_pid}>task pid</dt>
                <dd :if={@detail.runtime.task_pid}>
                  <code>{@detail.runtime.task_pid}</code>
                </dd>
                <dt :if={@detail.runtime.task_id}>task</dt>
                <dd :if={@detail.runtime.task_id}>
                  {@detail.runtime.task_id}
                  <span :if={@detail.runtime.task_trigger} class="gl-muted">
                    · {to_string(@detail.runtime.task_trigger)}
                  </span>
                </dd>
              </dl>
            </div>
          </section>

          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>config</span>
              <button
                :if={!@config_editing?}
                type="button"
                class="gl-btn gl-btn--sm"
                phx-click="config_edit"
              >
                edit
              </button>
              <span :if={!@config_editing?} class="gl-panel__hint">AGENT.md</span>
            </header>
            <div class="gl-panel__body">
              <dl :if={!@config_editing?} class="gl-kv">
                <dt>provider</dt>
                <dd class="gl-accent">{@detail.provider}</dd>
                <dt>model</dt>
                <dd>{@detail.model}</dd>
                <dt>reports_to</dt>
                <dd>{@detail.reports_to || "(director)"}</dd>
                <dt>heartbeat</dt>
                <dd>{@detail.heartbeat || "—"}</dd>
                <dt>network</dt>
                <dd><span class="gl-badge">{@detail.network}</span></dd>
                <dt>autonomy</dt>
                <dd><span class="gl-badge">{@detail.autonomy}</span></dd>
                <dt>skills</dt>
                <dd>{Enum.join(@detail.skills, ", ")}</dd>
              </dl>
              <form
                :if={@config_editing?}
                id="agent-config-form"
                phx-submit="config_save"
                phx-change="config_form_change"
                class="gl-agent-config-form"
              >
                <label class="gl-form__row">
                  <span class="gl-form__label">provider</span>
                  <input
                    type="text"
                    name="provider"
                    value={@detail.provider}
                    class="gl-input"
                    list="gl-agent-provider-options"
                    required
                  />
                  <datalist id="gl-agent-provider-options">
                    <option :for={p <- @provider_options} value={p}></option>
                  </datalist>
                </label>
                <label class="gl-form__row">
                  <span class="gl-form__label">model</span>
                  <input
                    type="text"
                    name="model"
                    value={@detail.model}
                    class="gl-input"
                    list="gl-agent-model-options"
                    required
                  />
                  <datalist id="gl-agent-model-options">
                    <option :for={m <- @model_options} value={m}></option>
                  </datalist>
                </label>
                <label class="gl-form__row">
                  <span class="gl-form__label">reports_to</span>
                  <input
                    type="text"
                    name="reports_to"
                    value={@detail.reports_to || ""}
                    class="gl-input"
                    placeholder="(director)"
                  />
                </label>
                <label class="gl-form__row">
                  <span class="gl-form__label">heartbeat</span>
                  <input
                    type="text"
                    name="heartbeat"
                    value={@detail.heartbeat || ""}
                    class="gl-input"
                    placeholder="* * * * *  (blank = on-demand)"
                  />
                </label>
                <label class="gl-form__row">
                  <span class="gl-form__label">network</span>
                  <select name="network" class="gl-input">
                    <option value="loopback" selected={@detail.network == "loopback"}>
                      loopback
                    </option>
                    <option value="proxy" selected={@detail.network == "proxy"}>proxy</option>
                    <option value="full" selected={@detail.network == "full"}>full</option>
                  </select>
                </label>
                <label class="gl-form__row">
                  <span class="gl-form__label">autonomy</span>
                  <select name="autonomy" class="gl-input">
                    <option value="manual" selected={@detail.autonomy == "manual"}>
                      manual — director approves every task
                    </option>
                    <option value="supervised" selected={@detail.autonomy == "supervised"}>
                      supervised — gated by requires_approval flag
                    </option>
                    <option value="auto" selected={@detail.autonomy == "auto"}>
                      auto — no approval gate (budget still applies)
                    </option>
                  </select>
                </label>
                <footer class="gl-agent-config-form__actions">
                  <button type="button" class="gl-btn" phx-click="config_cancel">cancel</button>
                  <button type="submit" class="gl-btn gl-btn--primary">save</button>
                </footer>
                <p class="gl-muted" style="font-size: 11px;">
                  Writes only these keys back to AGENT.md frontmatter — other
                  keys (skills, permissions, env) stay untouched. Stop the agent
                  first if you're switching provider/model so the next wake picks
                  up the change.
                </p>
              </form>
            </div>
          </section>

          <section class="gl-panel">
            <header class="gl-panel__header">
              <span>budget</span>
              <StatusPill.status_pill
                status={if @detail.budget.tracked?, do: :alive, else: :info}
                label={if @detail.budget.tracked?, do: "tracked", else: "untracked"}
              />
            </header>
            <div class="gl-panel__body">
              <div :if={@detail.budget.tracked?}>
                <div class="gl-budget-figure">
                  <span class="gl-budget-figure__used">${@detail.budget.used_str}</span>
                  <span class="gl-muted">/ ${@detail.budget.cap_str} this month</span>
                </div>
                <div class={["gl-meter", @detail.budget.cls && "gl-meter--" <> @detail.budget.cls]}>
                  <div class="gl-meter__fill" style={"width: #{@detail.budget.pct}%;"}></div>
                  <div class="gl-meter__threshold" style="left: 80%;"></div>
                </div>
                <div class="gl-muted gl-budget-sub">
                  {@detail.budget.pct}% used · alert at 80% · {if @detail.budget.pct > 80,
                    do: "ALERT FIRED",
                    else: "no alerts"}
                </div>
              </div>
              <p :if={not @detail.budget.tracked?} class="gl-muted gl-budget-untracked">
                Provider <span class="gl-accent">{@detail.provider}</span>
                has <code>usage_parser = "none"</code>. Agent opted in via
                <code>allow_untracked_budget: true</code>
                in AGENT.md.
              </p>
            </div>
          </section>

          <section class="gl-panel gl-agent-detail__perms">
            <header class="gl-panel__header">
              <span>permissions</span>
              <span class="gl-panel__hint">hover → highlights mount</span>
            </header>
            <div class="gl-panel__body gl-panel__body--flush">
              <ul class="gl-perms">
                <li
                  :for={p <- @detail.permissions}
                  class={["gl-perm", @hovered_perm == p.raw && "gl-perm--hl"]}
                  role="button"
                  tabindex="0"
                  aria-label={"Show #{p.raw} in sandbox argv"}
                  phx-mouseenter="hover_perm"
                  phx-value-perm={p.raw}
                  phx-mouseleave="unhover_perm"
                  phx-click="tab"
                  phx-keydown="tab"
                  phx-key="Enter"
                  phx-value-tab="sandbox"
                >
                  <code class="gl-perm__token">
                    <span>{p.resource}</span>
                    <span class="gl-muted">:</span>
                    <span class="gl-perm__action">{p.action}</span>
                    <span class="gl-muted">:</span>
                    <span class="gl-perm__scope">{p.scope}</span>
                  </code>
                  <span class={["gl-perm__tag", "gl-perm__tag--" <> p.kind]}>{p.kind}</span>
                </li>
                <li :if={@detail.permissions == []} class="gl-muted gl-perm gl-perm--empty">
                  No permissions — sandboxed to workspace only.
                </li>
              </ul>
            </div>
          </section>
        </div>
      </div>

      <%!-- task #117 — workspace file editor overlay --%>
      <div :if={@open_file} class="gl-modal-scrim" phx-click-away="close_file">
        <form
          id="agent-file-editor-form"
          phx-submit="save_file"
          phx-window-keydown="close_file"
          phx-key="Escape"
          class="gl-modal gl-file-editor"
        >
          <header class="gl-modal__header">
            <span class="gl-muted">workspace/</span>{@open_file.rel}
            <button
              type="button"
              class="gl-btn gl-btn--ghost gl-modal__close"
              phx-click="close_file"
              aria-label="Close"
            >
              ×
            </button>
          </header>
          <div :if={@open_file.error} class="gl-flash gl-flash--error">{@open_file.error}</div>
          <textarea
            name="content"
            rows="20"
            class="gl-input gl-file-editor__textarea"
          >{@open_file.content}</textarea>
          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn gl-btn--ghost" phx-click="close_file">
              cancel
            </button>
            <button type="submit" class="gl-btn">save</button>
          </footer>
        </form>
      </div>

      <div :if={@wake_open?} class="gl-modal-scrim" phx-click-away="wake_cancel">
        <form
          id="agent-wake-form"
          phx-submit="wake"
          phx-window-keydown="wake_cancel"
          phx-key="Escape"
          class="gl-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gl-wake-title"
        >
          <header class="gl-modal__header">
            <div id="gl-wake-title"><strong>↻ wake {@agent_slug}</strong></div>
            <button
              type="button"
              class="gl-modal__close"
              phx-click="wake_cancel"
              aria-label="Close"
            >
              ×
            </button>
          </header>

          <div class="gl-company-md-form">
            <label class="gl-form__row">
              <span class="gl-form__label">REASON</span>
              <textarea
                name="reason"
                rows="3"
                class="gl-input"
                maxlength="1024"
                placeholder="Optional — e.g. 'check the new claude-code version' or 'roadmap changed'"
                autofocus
              ></textarea>
            </label>
            <p class="gl-muted" style="font-size: 11px;">
              Writes <code>agents/{@agent_slug}/state/wake-request.md</code>.
              The agent's next invocation sees the reason as part of the wake prompt.
            </p>
          </div>

          <footer class="gl-modal__footer">
            <button type="button" class="gl-btn" phx-click="wake_cancel">cancel</button>
            <button type="submit" class="gl-btn gl-btn--primary">wake</button>
          </footer>
        </form>
      </div>
    </section>
    """
  end

  defp wake_button(assigns) do
    ~H"""
    <button
      type="button"
      class="gl-btn gl-btn--primary"
      phx-click="wake_prompt"
    >
      ↻ wake now
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Data loaders
  # ---------------------------------------------------------------------------

  defp load_agent_detail(base, co, ag) do
    ag_dir = Path.join([base, "companies", co, "agents", ag])
    agent_md = Glorbo.Agent.FileLayout.agent_md(ag_dir)

    spec =
      case Glorbo.Agent.Parser.parse_file(agent_md) do
        {:ok, s} -> s
        _ -> nil
      end

    used = load_used_usd(co, ag)
    cap = spec_cap(spec)
    {pct, cls, tracked?} = classify_budget(used, cap)

    %{
      name: agent_name(spec, ag),
      role: (spec && spec.role) || "agent",
      provider: (spec && spec.provider) || "unknown",
      model: (spec && spec.model) || "",
      reports_to: spec && spec.reports_to,
      heartbeat: spec && spec.heartbeat,
      network: (spec && to_string(spec.network)) || "loopback",
      autonomy: (spec && to_string(spec.autonomy)) || "supervised",
      skills: (spec && spec.skills) || [],
      permissions: classify_permissions(spec),
      pill_status: agent_pill_status(pct, tracked?),
      pill_label: agent_pill_label(pct, tracked?),
      budget: %{
        tracked?: tracked?,
        used_str: two_dp(used),
        cap_str: zero_dp(cap),
        pct: pct,
        cls: cls
      },
      workspace_tree: walk_workspace(ag_dir),
      not_mounted: not_mounted_list(base, co, ag),
      inbox: load_inbox_preview(ag_dir),
      outbox: load_outbox_preview(ag_dir),
      sandbox: build_sandbox_preview(spec, co, ag),
      soul: load_soul(ag_dir),
      files: scan_agent_files(ag_dir),
      runtime: load_runtime_status(co, ag)
    }
  end

  # Runtime status is derived from the Agent.Server's :status call.
  # Only useful when the server is alive; nil otherwise (agent dir
  # exists on disk but not booted — e.g. failed to parse AGENT.md,
  # or Glorbo is running but this agent's sub-supervisor crashed).
  defp load_runtime_status(company, slug) do
    case find_agent_server(company, slug) do
      nil ->
        nil

      pid ->
        try do
          status = Glorbo.Agent.Server.status(pid)

          %{
            server_pid: inspect(pid),
            state: status.state,
            task_pid: status.current_task_pid && inspect(status.current_task_pid),
            task_id: status.current_task,
            task_trigger: status.current_task_trigger
          }
        catch
          _, _ -> nil
        end
    end
  end

  # task #118 — if the agent has a SOUL.md file, render its body on
  # the identity column. We strip frontmatter since the frontmatter
  # fields (`role:`) duplicate identity data already on display.
  defp load_soul(ag_dir) do
    path = Path.join(ag_dir, "SOUL.md")

    with true <- File.exists?(path),
         {:ok, content} <- File.read(path),
         stripped <- strip_frontmatter(content),
         trimmed <- String.trim(stripped),
         true <- trimmed != "" do
      trimmed
    else
      _ -> nil
    end
  end

  defp agent_name(nil, ag), do: ag
  defp agent_name(spec, _ag), do: to_string(spec.slug)

  defp spec_cap(nil), do: 0.0
  defp spec_cap(%{budget_usd_cents_month: nil}), do: 0.0
  defp spec_cap(%{budget_usd_cents_month: c}), do: c / 100.0

  defp classify_budget(used, cap) when cap > 0 do
    pct = min(round(used / cap * 100), 100)

    cls =
      cond do
        pct > 90 -> "rose"
        pct > 80 -> "amber"
        true -> nil
      end

    {pct, cls, true}
  end

  defp classify_budget(_, _), do: {0, nil, false}

  defp agent_pill_status(pct, true) when pct > 90, do: :warn
  defp agent_pill_status(_pct, _tracked?), do: :idle

  defp agent_pill_label(pct, true) when pct > 90, do: "budget #{pct}%"
  defp agent_pill_label(_pct, _tracked?), do: "idle"

  # Permissions displayed as resource/action/scope triples + a `:kind`
  # tag — `mount` if PermissionMapper emits any bwrap flag,
  # `router` if it's application-layer only (agents:message, tasks:*,
  # chat:write, budget:read, tools:execute). Used on the right column.
  defp classify_permissions(nil), do: []

  defp classify_permissions(%{permissions: perms}) do
    Enum.map(perms, &permission_row/1)
  end

  defp permission_row({r, a, s}) do
    raw = "#{r}:#{a}:#{s}"
    kind = if filesystem_permission?(r, a), do: "mount", else: "router"
    %{raw: raw, resource: r, action: a, scope: s, kind: kind}
  end

  # Keep in sync with Glorbo.Sandbox.PermissionMapper. Conservative:
  # only report `mount` when the mapper is known to emit flags; tweak
  # when new mount-emitting permissions are added.
  defp filesystem_permission?("projects", _), do: true
  defp filesystem_permission?("chat", "read"), do: true
  defp filesystem_permission?(_, _), do: false

  # Walk the agent's workspace dir up to @workspace_tree_depth levels
  # deep. Skip dotfiles + known ephemeral caches. For files, include a
  # relative path (relative to the workspace root) so the UI can open
  # them for editing (task #117).
  @workspace_tree_depth 3
  @workspace_skip_dirs ~w(.cache .glorbo-claude .glorbo-skills node_modules .git)

  defp walk_workspace(ag_dir) do
    root = Path.join(ag_dir, "workspace")

    if File.dir?(root) do
      # Paths emitted are relative to the AGENT dir now (task #143
      # widened resolve_workspace_path from workspace-only to
      # agent-root). E.g. "workspace/notes.md" not "notes.md".
      walk_workspace_dir(ag_dir, root, 0)
    else
      []
    end
  end

  defp walk_workspace_dir(_ag_dir, _path, depth) when depth >= @workspace_tree_depth, do: []

  defp walk_workspace_dir(ag_dir, path, depth) do
    case File.ls(path) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @workspace_skip_dirs))
        |> Enum.sort()
        |> Enum.flat_map(fn e ->
          full = Path.join(path, e)

          # threatmodel H10: use lstat so symlinks in the agent
          # workspace don't get recursed or rendered as regular
          # files.
          case File.lstat(full) do
            {:ok, %File.Stat{type: :directory}} ->
              [%{name: e, kind: :dir, depth: depth, rel: Path.relative_to(full, ag_dir)}] ++
                walk_workspace_dir(ag_dir, full, depth + 1)

            {:ok, %File.Stat{type: :regular}} ->
              [%{name: e, kind: :file, depth: depth, rel: Path.relative_to(full, ag_dir)}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  # Task #143 — scan the whole agent dir (not just workspace/) and
  # return a structured listing the UI can render as a file manager.
  # Output shape:
  #
  #   %{
  #     contracts: [%{name, rel, role: :contract, exists?}],
  #     subdirs:   [%{name, rel, role: :dir, count}],
  #     scratch:   [%{name, rel, role: :file}]
  #   }
  #
  # `rel` is always relative to the agent dir (e.g. "AGENT.md",
  # "workspace/notes.md", "inbox/mentions/5.md"). Contract files are
  # the named ones the runtime expects (GEP-15) regardless of
  # existence — the UI offers create when exists?=false.
  @contract_files ~w(AGENT.md HEARTBEAT.md SOUL.md stdout.log)
  @contract_subdirs ~w(inbox outbox history state workspace)

  defp scan_agent_files(ag_dir) do
    %{
      contracts: contract_rows(ag_dir),
      subdirs: subdir_rows(ag_dir)
    }
  end

  defp contract_rows(ag_dir) do
    Enum.map(@contract_files, fn name ->
      %{name: name, rel: name, role: :contract, exists?: File.regular?(Path.join(ag_dir, name))}
    end)
  end

  defp subdir_rows(ag_dir) do
    Enum.map(@contract_subdirs, fn name ->
      dir = Path.join(ag_dir, name)
      count = if File.dir?(dir), do: count_files(dir), else: 0
      %{name: name, rel: name, role: :dir, count: count}
    end)
  end

  defp count_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.count(&File.regular?/1)

      _ ->
        0
    end
  end

  defp not_mounted_list(base, co, ag) do
    co_path = Path.join([base, "companies", co])
    agents_path = Path.join(co_path, "agents")

    siblings =
      case File.ls(agents_path) do
        {:ok, xs} ->
          xs
          |> Enum.reject(&(&1 == ag))
          |> Enum.map(&"agents/#{&1}")

        _ ->
          []
      end

    other_cos =
      case File.ls(Path.join(base, "companies")) do
        {:ok, cs} ->
          cs
          |> Enum.reject(&(&1 == co))
          |> Enum.map(&"companies/#{&1}")

        _ ->
          []
      end

    (siblings ++ other_cos) |> Enum.take(6)
  end

  defp load_inbox_preview(ag_dir) do
    load_io_preview(Path.join(ag_dir, "inbox"))
  end

  defp load_outbox_preview(ag_dir) do
    load_io_preview(Path.join(ag_dir, "outbox"))
  end

  defp load_io_preview(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        md = Enum.filter(files, &String.ends_with?(&1, ".md"))

        case Enum.sort(md) |> List.last() do
          nil ->
            %{count: 0, latest: false}

          f ->
            %{count: length(md), latest: io_card_from_file(Path.join(dir, f))}
        end

      _ ->
        %{count: 0, latest: false}
    end
  end

  defp io_card_from_file(path) do
    # Threatmodel wave 5: the agent's inbox and outbox are writable by
    # the untrusted sandboxed CLI, so a malicious agent can drop a
    # symlink that points at a host file (e.g. `~/.glorbo/config.md`)
    # and wait for a Director to open the agent detail page, at which
    # point File.read follows the link and surfaces host content in
    # the preview. `read_bounded/2` rejects any non-regular shape
    # (symlink/device/dir) AND size-caps before reading — closing the
    # B-021 unbounded-read prong (a planted multi-GB *regular* .md
    # file would otherwise OOM the dashboard BEAM heap). 1 MiB matches
    # the task/project dashboard readers; previews never need more.
    case Glorbo.Filesystem.AgentWritableFile.read_bounded(path, 1_048_576) do
      {:ok, content} -> do_io_card(content, path)
      _ -> false
    end
  end

  defp do_io_card(content, path) do
    meta =
      case Glorbo.Filesystem.Frontmatter.parse(content) do
        {:ok, m, _} -> m
        _ -> %{}
      end

    body = strip_frontmatter(content)
    title = first_heading(body) || Path.basename(path, ".md")

    preview =
      body |> String.replace(~r/^#\s+.*\n/, "") |> String.trim() |> String.slice(0, 220)

    %{
      meta: "from: #{meta["from"] || "—"} · #{meta["ts"] || meta["delivered_at"] || "—"}",
      title: title,
      preview: preview
    }
  end

  defp strip_frontmatter(content) do
    case String.split(content, ~r/\A---\s*\n/, parts: 2) do
      [_, rest] ->
        case String.split(rest, ~r/\n---\s*\n/, parts: 2) do
          [_, body] -> body
          _ -> content
        end

      _ ->
        content
    end
  end

  defp first_heading(body) do
    body
    |> String.split("\n")
    |> Enum.find(&(String.starts_with?(&1, "#") and String.length(&1) > 1))
    |> case do
      nil -> nil
      line -> line |> String.trim_leading("#") |> String.trim()
    end
  end

  defp build_sandbox_preview(spec, co, ag) do
    base = "companies/#{co}"

    perm_lines =
      (spec && spec.permissions)
      |> Kernel.||([])
      |> Enum.map(&permission_sandbox_line/1)

    network = (spec && to_string(spec.network)) || "loopback"
    {network_flag, network_comment} = network_line(network)

    %{
      base: [
        "--die-with-parent",
        "--unshare-user-try",
        "--unshare-ipc",
        "--unshare-pid",
        "--unshare-uts",
        "--unshare-cgroup-try",
        "--new-session",
        "--cap-drop ALL"
      ],
      workspace_path: "#{base}/agents/#{ag}/workspace",
      outbox_path: "#{base}/agents/#{ag}/outbox",
      inbox_path: "#{base}/agents/#{ag}/inbox",
      perm_lines: perm_lines,
      network_flag: network_flag,
      network_comment: network_comment,
      exec_cmd: provider_cmd((spec && spec.provider) || "claude-code")
    }
  end

  defp permission_sandbox_line({r, a, s}) do
    raw = "#{r}:#{a}:#{s}"
    co = "companies/acme"

    case {r, a, s} do
      {"projects", "read", "*"} ->
        %{flag: "--ro-bind", arg: "#{co}/projects /projects", comment: "← #{raw}", perm: raw}

      {"projects", "write", name} when name != "*" ->
        %{
          flag: "--bind",
          arg: "#{co}/projects/#{name} /projects/#{name}",
          comment: "← #{raw}",
          perm: raw
        }

      {"projects", "read", name} ->
        %{
          flag: "--ro-bind",
          arg: "#{co}/projects/#{name} /projects/#{name}",
          comment: "← #{raw}",
          perm: raw
        }

      {"chat", "read", "*"} ->
        %{flag: "--ro-bind", arg: "#{co}/channels /channels", comment: "← #{raw}", perm: raw}

      _ ->
        %{
          flag: nil,
          arg: nil,
          comment: "# #{raw}  (Elixir router-enforced, not a mount)",
          perm: raw
        }
    end
  end

  defp network_line("loopback"),
    do: {"--unshare-net", "# kernel netns shutdown — no egress possible"}

  defp network_line("proxy"),
    do:
      {"pasta --splice-only -T <proxy-port> --",
       "# private netns; only the allowlisted HTTPS CONNECT proxy port is reachable"}

  defp network_line("full"),
    do: {"# host netns inherited", "# explicit opt-in"}

  defp network_line(other), do: {"# network: #{other}", ""}

  # Whitelist matches Glorbo.Agent.Parser's @network_map. Anything
  # else returns nil so the caller drops the key from the updates
  # map (preserving the existing on-disk value).
  defp sanitise_network(v) when v in ["loopback", "proxy", "full"], do: v
  defp sanitise_network(_), do: nil

  defp provider_cmd("claude-code"), do: "claude"
  defp provider_cmd("gemini-cli"), do: "gemini"
  defp provider_cmd("codex"), do: "codex"
  defp provider_cmd(other), do: other

  defp load_used_usd(company_slug, agent_slug) do
    case Glorbo.Budget.Ledger.fetch(company_slug, agent_slug, current_year_month()) do
      %{cost_usd_cents: c} -> c / 100.0
      _ -> 0.0
    end
  rescue
    _ -> 0.0
  catch
    _, _ -> 0.0
  end

  # ---------------------------------------------------------------------------
  # History panel (GEP-14-adjacent — shows heartbeat + dispatch + wake activity)
  # ---------------------------------------------------------------------------

  @history_cap 200

  defp load_runs(%{assigns: %{company_slug: co, agent_slug: ag}}) do
    Glorbo.Agent.RunLog.list(base_dir(), co, ag, limit: 50)
  end

  # GEP-21 / R17b — read agent's memory directory for the Memory tab.
  # Returns `%{index: <MEMORY.md body>, files: [%{…}]}` with entries
  # sorted newest-first by mtime. Filesystem-is-truth: every tab
  # click re-reads; no cache.
  # Codex round-5 finding (PR #37, HIGH): the prior shape used
  # `File.read` (follows symlinks; no byte cap) and `File.stat`
  # (follows symlinks) with no cap on the entry list. Two
  # angles:
  #   (a) Symlink escape — an agent plants
  #       `memory/feedback_evil.md → ../../../<other-co>/agents/<other>/AGENT.md`
  #       and the dashboard renders cross-tenant content under
  #       the Memory tab.
  #   (b) DoS — agent writes many / large memory files via the
  #       outbox/memory pipeline; opening the Memory tab pegs
  #       the dashboard.
  # Defenses: per-file byte cap via
  # `AgentWritableFile.read_bounded/2` (uses lstat refusal +
  # capped read in one helper, GEP-27 round-3); entry-list cap
  # (200) post-sort; `:file.read_link_info` for stat so a
  # symlink at the index is also refused.
  @memory_file_byte_cap 256 * 1024
  @memory_entry_cap 200

  defp load_memory_files(%{assigns: %{company_slug: co, agent_slug: ag}}) do
    base = base_dir()
    dir = Path.join([base, "companies", co, "agents", ag, "memory"])

    # Codex pre-push review of 0198037: `File.ls(dir)` follows a
    # symlinked `memory/` directory; `read_bounded/2` only
    # protects the leaf. If an agent ever swaps its `memory/`
    # dir for a symlink to another company's tree, the
    # enumeration would cross tenants. Reject any symlink
    # ancestor on `dir` before listing or reading.
    if memory_dir_safe?(dir) do
      index =
        case Glorbo.Filesystem.AgentWritableFile.read_bounded(
               Path.join(dir, "MEMORY.md"),
               @memory_file_byte_cap
             ) do
          {:ok, content} -> String.trim(content)
          _ -> ""
        end

      files = load_memory_entries(dir)

      %{index: index, files: files}
    else
      %{index: "", files: []}
    end
  end

  defp memory_dir_safe?(dir) do
    Glorbo.Sandbox.SymlinkGuard.assert_no_symlink_segment!(
      dir,
      "agent_live: memory dir"
    )

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  # Codex pre-push review of 0198037: previously the 200-file
  # cap was applied AFTER reading + parsing every valid memory
  # file. Worst case 200 × 256 KiB = 50 MiB rendered into the
  # browser. Two-stage:
  #   1. lstat every candidate to collect filename + mtime
  #      (cheap — no body read).
  #   2. sort by mtime, take 200, THEN read body via
  #      `read_bounded`.
  defp load_memory_entries(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&valid_memory_file?/1)
        |> Enum.flat_map(&stat_memory_candidate(&1, dir))
        |> Enum.sort_by(& &1.mtime, :desc)
        |> Enum.take(@memory_entry_cap)
        |> Enum.flat_map(&read_memory_entry(&1, dir))

      _ ->
        []
    end
  end

  @memory_filename_re ~r/^(user|feedback|project|reference)_[a-z][a-z0-9_-]{0,63}\.md$/

  defp valid_memory_file?(name), do: Regex.match?(@memory_filename_re, name)

  # Phase 1: cheap stat-only collection. Returns the entries we
  # MIGHT keep — body read deferred until after the cap.
  defp stat_memory_candidate(filename, dir) do
    path = Path.join(dir, filename)

    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        [%{filename: filename, path: path, mtime: mtime}]

      _ ->
        []
    end
  end

  # Phase 2: bodies read AFTER sort + take, so the 200-file cap
  # bounds the actual read I/O (max 200 × 256 KiB = 50 MiB
  # WORST case, but only for the cap'd set, not the whole dir).
  defp read_memory_entry(%{filename: filename, path: path, mtime: mtime}, _dir) do
    with {:ok, content} <-
           Glorbo.Filesystem.AgentWritableFile.read_bounded(path, @memory_file_byte_cap),
         {:ok, meta, body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      type = filename |> String.split("_", parts: 2) |> List.first() || "?"

      [
        %{
          filename: filename,
          type: type,
          name: memory_display_scalar(Map.get(meta, "name"), filename),
          description: memory_display_scalar(Map.get(meta, "description"), ""),
          body: String.trim(body),
          mtime: mtime,
          mtime_iso: DateTime.from_unix!(mtime) |> DateTime.to_iso8601(),
          mtime_rel: format_relative_mtime(mtime)
        }
      ]
    else
      _ -> []
    end
  end

  defp memory_display_scalar(value, _default) when is_binary(value), do: value
  defp memory_display_scalar(nil, default), do: default
  defp memory_display_scalar(_other, default), do: default

  defp format_relative_mtime(unix_ts) when is_integer(unix_ts) do
    diff = System.os_time(:second) - unix_ts

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} h ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)} d ago"
      true -> DateTime.from_unix!(unix_ts) |> DateTime.to_date() |> Date.to_string()
    end
  end

  defp format_duration(nil), do: "—"
  defp format_duration(ms) when is_integer(ms) and ms < 1000, do: "#{ms}ms"
  defp format_duration(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

  defp format_duration(ms) when is_integer(ms) do
    m = div(ms, 60_000)
    s = rem(div(ms, 1000), 60)
    "#{m}m#{s}s"
  end

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(_), do: "—"

  # paperclip-ux-gaps §2 — render `Bash×1, Read×2` from
  # `%{"Bash" => 1, "Read" => 2}`. Sorted by count descending so
  # the heaviest tool wins the eye first.
  defp format_tool_calls(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {_name, count} -> -count end)
    |> Enum.map_join(", ", fn {name, count} -> "#{name}×#{count}" end)
  end

  defp format_tool_calls(_), do: "—"

  defp tool_count_sum(map) when is_map(map),
    do: map |> Map.values() |> Enum.sum()

  defp tool_count_sum(_), do: 0

  # #246 — always show tokens (even as "0 in / 0 out" for providers
  # that don't expose usage — that's a correct "no data" signal).
  defp format_tokens(nil, nil), do: "—"
  defp format_tokens(p, c), do: "#{p || 0} in / #{c || 0} out"

  # #246 — cost renders only when pricing is known for the
  # provider+model pair. Nil = no pricing table match = "—".
  defp format_cost(nil), do: "—"
  defp format_cost(0), do: "—"

  defp format_cost(cents) when is_integer(cents) do
    whole = div(cents, 100)
    cents_part = rem(cents, 100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "$#{whole}.#{cents_part}"
  end

  defp format_cost(_), do: "—"

  defp assign_task_url(company_slug, agent_slug) do
    return_to = "/companies/#{company_slug}/agents/#{agent_slug}"

    "/companies/#{company_slug}/kanban?" <>
      URI.encode_query(assignee: agent_slug, return_to: return_to)
  end

  # Threatmodel: previously slurped the entire monthly audit JSONL
  # via File.read + String.split + Enum.reverse, which materialised
  # every line in RAM. Audit logs grow unbounded; we stream the
  # file line-by-line and keep only a rolling window of the last
  # @history_cap matching rows so memory stays bounded by N
  # regardless of file size.
  defp load_history(base, co, ag) do
    path =
      Path.join([
        base,
        "companies",
        co,
        "audit",
        "#{current_year_month()}.jsonl"
      ])

    if File.regular?(path) do
      path
      |> File.stream!(:line, [])
      |> Enum.reduce([], &push_history_row(&1, &2, ag))
      |> Enum.reverse()
    else
      []
    end
  rescue
    _ -> []
  end

  # Append-with-cap: keep the rolling window at most @history_cap
  # items (newest at the head). Truncate the oldest from the tail.
  defp push_history_row(line, acc, ag) do
    with {:ok, entry} <- Jason.decode(line),
         true <- audit_for_this_agent?(entry, ag) do
      [to_history_row(entry) | Enum.take(acc, @history_cap - 1)]
    else
      _ -> acc
    end
  end

  # An audit record concerns this agent if any of: actor == slug, target
  # starts with `agents/<slug>`, or detail has {agent: slug}.
  defp audit_for_this_agent?(entry, slug) when is_map(entry) and is_binary(slug) do
    e = stringify_keys(entry)

    actor = to_string(e["actor"] || "")
    target = to_string(e["target"] || "")
    detail_agent = get_in(e, ["detail", "agent"]) |> to_string()

    # Codex round-5 finding (PR #37): the previous
    # `String.starts_with?(target, "agents/#{slug}")` shape
    # matched any slug with `slug` as a prefix — e.g. a sibling
    # agent named `ceo2` polluted the audit/history stream of
    # `ceo`. Match the exact `agents/<slug>` literal or the
    # `agents/<slug>/...` namespace (note the trailing slash) so
    # prefix collisions are rejected.
    agent_root = "agents/#{slug}"
    agent_prefix = agent_root <> "/"

    actor == slug or
      target == agent_root or
      String.starts_with?(target, agent_prefix) or
      detail_agent == slug
  end

  defp audit_for_this_agent?(_entry, _slug), do: false

  defp to_history_row(entry) do
    action = to_string(entry["action"] || "")

    %{
      ts_short: short_ts(entry["ts"]),
      action: action,
      class: action_class(action),
      kind: kind_for(action),
      detail: history_detail(entry)
    }
  end

  defp short_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} ->
        naive = DateTime.to_naive(dt)

        "#{naive.hour |> pad2()}:#{naive.minute |> pad2()}:#{naive.second |> pad2()}"

      _ ->
        ts
    end
  end

  defp short_ts(_), do: ""

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Map audit actions to the same CSS classes AuditEntry uses.
  defp action_class("agent.wake" <> _), do: "wake"
  defp action_class("agent.dispatch" <> _), do: "wake"
  defp action_class("agent.complete" <> _), do: "wake"
  defp action_class("agent.retry"), do: "retry"
  defp action_class("agent.heartbeat_skipped"), do: "wake"
  defp action_class("agent.wake_request"), do: "wake"
  defp action_class("budget" <> _), do: "budget"
  defp action_class("approval" <> _), do: "approval"
  defp action_class(_), do: "default"

  defp kind_for("agent.heartbeat_skipped"), do: "skipped"
  defp kind_for("agent.complete"), do: "complete"
  defp kind_for("agent.dispatch"), do: "dispatch"
  defp kind_for("agent.retry"), do: "retry"
  defp kind_for("agent.wake" <> _), do: "wake"
  defp kind_for(_), do: "default"

  defp history_detail(entry) do
    # Prefer a targeted one-line summary based on the action.
    case {entry["action"], entry["detail"]} do
      {"agent.wake", d} when is_map(d) ->
        "trigger: #{d["trigger"] || "?"}"

      {"agent.heartbeat_skipped", d} when is_map(d) ->
        "reason: #{d["reason"] || "?"}"

      {"agent.dispatch", d} when is_map(d) ->
        "provider: #{d["provider"] || "?"} · model: #{d["model"] || "?"}"

      {"agent.complete", d} when is_map(d) ->
        "exit #{d["exit_status"] || "?"} · #{d["duration_ms"] || "?"}ms"

      {"agent.retry", d} when is_map(d) ->
        "attempt #{d["attempt"] || "?"} · reason: #{d["reason"] || "?"}"

      {"agent.wake_request", d} when is_map(d) ->
        reason = d["reason"] || ""
        if reason == "", do: "director wake", else: "director: #{reason}"

      _ ->
        nil
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  # Company-scoped lookup. Matching `{:agent_server, :_, slug}` would
  # surface whichever company's agent happened to register first — a
  # hostile result when two companies both have `ceo` or `engineer`.
  # Pin the tuple key to the current company.
  defp find_agent_server(company, slug) do
    case Registry.match(Glorbo.Agent.Registry, {:agent_server, company, slug}, :_) do
      [{pid, _} | _] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Provider-name list for the Configuration tab datalist. Same
  # fallback pattern as CompanyLive — when the registry isn't booted
  # (tests using just the AgentLive harness), return a static list.
  defp provider_options do
    CLIRegistry.list()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  rescue
    _ -> ~w(claude-code codex gemini-cli hermes opencode pi)
  end

  # GEP-32 phase 4 — model combobox: return the cached model IDs for
  # the given native provider alias (empty for CLI providers or
  # anything the ModelCatalog hasn't refreshed yet). Read straight
  # from the SQLite projection so the UI survives a catalog-process
  # restart and renders identically after `glorbo reindex`.
  defp model_options(nil), do: []
  defp model_options(""), do: []

  defp model_options(provider) when is_binary(provider) do
    import Ecto.Query, only: [from: 2]

    query =
      from pm in ProviderModel,
        where: pm.alias == ^provider,
        select: pm.model_id,
        order_by: [asc: pm.model_id]

    Repo.all(query)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
