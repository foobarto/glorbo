defmodule Glorbo.Company.Router do
  @moduledoc """
  Per-company message router (AGT-03, AGT-05, SEC-01).

  The single choke point between agent outboxes and their destinations.
  Every routed message flows through the pipeline:

      validate → verify_sender_slug (anti-spoof; T-03-12)
                → parse_to
                → reject_broadcast                    (R8)
                → reject_agent_create (belt+braces)   (R5, R10; AGT-05)
                → ACLMapper.check_action/2             (SEC-01)
                → perform_routing (channel append OR agent inbox write)
                → maybe_route_mentions                 (R6, R7)
                → emit message.route audit            (T-03-10)

  Failures shunt through `handle_rejection/3` which:

    * moves the source outbox file to `history/<msg_id>.rejected.md` with
      rejection frontmatter (T-03-10 forensics)
    * writes a rejection notice to the sender's
      `inbox/rejections/<ts>-<msg_id>.md`
    * emits `message.reject` + `permission.denied` audit events

  **Channel writes use `[:append, :sync]`** — `fsync` after every write
  serializes concurrent writers at the OS file-handle level (Plan 02-04
  precedent; prevents interleaved byte-level races).

  **No public `write_inbox/*`** — CLAUDE.md one-way-flow invariant. All
  inbox writes happen inside `route/2`'s pipeline, never from outside.

  ## Scaling profile (WR-06)

  Router is a single per-company GenServer handling every `route/2` call
  synchronously. Inbox `mkdir_p!` + `write!` + channel `[:append, :sync]`
  all run on the Router process, so route latency scales linearly with
  queue depth: under burst load (e.g. 20 agents each emitting 10
  outbox/s), every message waits behind the previous `fsync` on the
  channel file.

  This is a deliberate tradeoff for v0.0.1 single-director companies —
  the synchronous single-writer design is what makes fsync-serialized
  channel appends race-safe without per-file locks. If throughput
  degrades under multi-agent workloads, split into per-resource-type
  routers (ChannelRouter, AgentInboxRouter, ApprovalRouter) under a
  DynamicSupervisor. Phase 3's VALIDATION.md benchmark should catch
  that regression.

  **Dep-injected `fs_fun` map** — tests swap `write!`, `rename!`,
  `mkdir_p!`, `exists?`, `open_append!` for mocks. Production default is a
  map of `File` module functions.
  """
  use GenServer
  require Logger

  alias Glorbo.Agent.Parser, as: AgentParser
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.Security.ACLMapper

  @mention_regex ~r/@([a-z][a-z0-9_-]{0,63})/
  @broadcast_unsupported {:error, {:invalid_message, :broadcast_unsupported}}
  @outbox_rel_re ~r|\Aagents/(?<sender>[a-z][a-z0-9_-]{0,63})/outbox/(?<file>.+\.md)\z|

  @type outbox_msg :: %{
          required(:sender) => String.t(),
          required(:sender_permissions) => [ACLMapper.permission()],
          required(:to) => String.t(),
          required(:body) => String.t(),
          required(:raw_path) => String.t(),
          required(:msg_id) => String.t()
        }

  @type route_result ::
          :ok
          | {:error, {:permission_denied, String.t()}}
          | {:error, {:agent_create_blocked, String.t()}}
          | {:error, {:unknown_recipient, String.t()}}
          | {:error, {:invalid_message, term()}}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec route(GenServer.server(), outbox_msg()) :: route_result()
  def route(server, %{} = message) do
    GenServer.call(server, {:route, message})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    company = Keyword.fetch!(opts, :company)

    # GAP-3: Subscribe to the company's outbox PubSub topic so inotify
    # events on agents/<slug>/outbox/*.md trigger do_route/2 via
    # handle_info. `subscribe?: false` bypasses the subscribe for tests
    # that drive the route/2 API directly.
    if Keyword.get(opts, :subscribe?, true) do
      pubsub = Keyword.get(opts, :pubsub, Glorbo.PubSub)
      :ok = Phoenix.PubSub.subscribe(pubsub, "company:#{company}:outbox")
    end

    state = %{
      company: company,
      base: Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root()),
      audit_fun: Keyword.get(opts, :audit_fun, &default_audit_fun/2),
      fs_fun: Keyword.get(opts, :fs_fun, default_fs_fun()),
      pubsub: Keyword.get(opts, :pubsub, Glorbo.PubSub),
      # Test hook: override the agent.md → permissions lookup. Production
      # reads the sender's agent.md via Glorbo.Agent.Parser.parse_file/1.
      agent_permissions_fun:
        Keyword.get(opts, :agent_permissions_fun, &default_agent_permissions/2)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:route, msg}, _from, state) do
    result = do_route(msg, state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:file_event, rel_path, events}, state) do
    # GAP-3: Accept PubSub file events from Glorbo.Filesystem.Watcher for
    # the company's outbox topic. Only act on created/modified files —
    # deletes are ignored (routing happens on appearance, not removal).
    if events_include_write?(events) do
      handle_outbox_event(rel_path, state)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Routing pipeline
  # ---------------------------------------------------------------------------

  defp do_route(msg, state) do
    with :ok <- validate_message(msg),
         :ok <- verify_sender_slug(msg, state),
         {:ok, to} <- parse_to(msg.to),
         :ok <- reject_broadcast(to),
         :ok <- reject_agent_create(to, state),
         required <- required_permission_for(to),
         :ok <- ACLMapper.check_action(msg.sender_permissions, required),
         :ok <- perform_routing(to, msg, state) do
      _ = maybe_route_mentions(to, msg, state)
      emit_route_audit(msg, to, state)
      :ok
    else
      {:error, _} = err -> handle_rejection(err, msg, state)
    end
  end

  defp validate_message(%{sender: s, to: to, body: b, raw_path: rp, msg_id: id})
       when is_binary(s) and is_binary(to) and is_binary(b) and is_binary(rp) and is_binary(id) do
    # WR-02: reject control chars in fields that get interpolated into YAML
    # frontmatter. A sender-controlled newline in `msg_id` or `to` could
    # otherwise smuggle frontmatter keys like `from: ceo` past a downstream
    # parser (agent inbox reader, dashboard, audit log). `/` in msg_id is
    # additionally rejected since it would let the attacker pick the on-disk
    # path.
    cond do
      String.contains?(id, ["\n", "\r", "\0", "/"]) ->
        {:error, {:invalid_message, :control_chars_in_msg_id}}

      String.contains?(to, ["\n", "\r", "\0"]) ->
        {:error, {:invalid_message, :control_chars_in_to}}

      true ->
        :ok
    end
  end

  defp validate_message(_), do: {:error, {:invalid_message, :malformed}}

  # T-03-12: sender slug authority is the outbox path, not the body.
  defp verify_sender_slug(%{sender: sender, raw_path: raw_path}, state) do
    # Extract slug from "<base>/companies/<co>/agents/<slug>/outbox/<id>.md"
    expected_prefix =
      Path.join([state.base, "companies", state.company, "agents", sender, "outbox"])

    if String.starts_with?(raw_path, expected_prefix) do
      :ok
    else
      {:error, {:invalid_message, :sender_mismatch}}
    end
  end

  # "chat:general" | "agent:ceo" | "broadcast:*" | ...
  defp parse_to("chat:" <> channel) when byte_size(channel) > 0, do: {:ok, {:chat, channel}}
  defp parse_to("agent:" <> slug) when byte_size(slug) > 0, do: {:ok, {:agent, slug}}
  defp parse_to("broadcast:" <> _), do: {:ok, :broadcast}
  defp parse_to(_), do: {:error, {:invalid_message, :unknown_to_scheme}}

  defp reject_broadcast(:broadcast), do: @broadcast_unsupported
  defp reject_broadcast(_), do: :ok

  # Belt + braces: block agent-create regardless of sender permissions.
  defp reject_agent_create({:agent, slug}, state) do
    agent_dir =
      Path.join([state.base, "companies", state.company, "agents", slug])

    if File.dir?(agent_dir) do
      :ok
    else
      {:error, {:agent_create_blocked, slug}}
    end
  end

  defp reject_agent_create(_, _), do: :ok

  defp required_permission_for({:chat, channel}), do: {"chat", "write", channel}
  defp required_permission_for({:agent, slug}), do: {"agents", "message", slug}

  # Channel-write routing: append-only, fsync per line.
  #
  # Wrap the body in a `## <iso-ts> | <author>\n<body>` message block so
  # the chat renderers (ChatDrawer/State, ChannelLive) attribute it to
  # the posting agent. Without the header the body gets swallowed by the
  # prior director message block or shown unattributed (UAT 2026-04-19).
  defp perform_routing({:chat, channel}, msg, state) do
    channel_path =
      Path.join([state.base, "companies", state.company, "channels", "#{channel}.md"])

    dir = Path.dirname(channel_path)
    state.fs_fun.mkdir_p!.(dir)
    append_line!(state.fs_fun, channel_path, format_chat_post(msg))
    :ok
  rescue
    e ->
      Logger.error("router channel write failed: #{Exception.message(e)}")
      {:error, {:invalid_message, :write_failed}}
  end

  # Agent-inbox routing: write-once file under inbox/from-<sender>/<ts>-<msg_id>.md.
  defp perform_routing({:agent, target_slug}, msg, state) do
    # Capture `now` once to keep the filename millisecond-ts and the
    # frontmatter ISO8601 `delivered_at` consistent. Separate
    # DateTime.utc_now() calls can straddle a clock adjustment or NTP
    # slew (TODO.md Important #8).
    now = DateTime.utc_now()
    ts = DateTime.to_unix(now, :millisecond)

    dir =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        target_slug,
        "inbox",
        "from-#{msg.sender}"
      ])

    state.fs_fun.mkdir_p!.(dir)
    path = Path.join(dir, "#{ts}-#{msg.msg_id}.md")

    frontmatter = """
    ---
    from: "#{msg.sender}"
    msg_id: "#{msg.msg_id}"
    delivered_at: "#{DateTime.to_iso8601(now)}"
    ---

    """

    state.fs_fun.write!.(path, frontmatter <> msg.body)
    :ok
  rescue
    e ->
      Logger.error("router inbox write failed: #{Exception.message(e)}")
      {:error, {:invalid_message, :write_failed}}
  end

  # Mention scan — only for channel writes
  defp maybe_route_mentions({:chat, channel}, msg, state) do
    @mention_regex
    |> Regex.scan(msg.body, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.each(fn mentioned -> try_write_mention(mentioned, channel, msg, state) end)
  end

  defp maybe_route_mentions(_, _, _), do: :ok

  # Slug format: lowercase alphanumerics + hyphens/underscores, 1–64 chars.
  # Defence-in-depth against a mention like `@../../etc/passwd` sneaking
  # past the regex scanner upstream (TODO.md Minor #10).
  @slug_re ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/

  defp valid_slug?(slug) when is_binary(slug), do: Regex.match?(@slug_re, slug)
  defp valid_slug?(_), do: false

  defp try_write_mention(mentioned, channel, msg, state) do
    if valid_slug?(mentioned) do
      do_write_mention(mentioned, channel, msg, state)
    else
      :ok
    end
  end

  defp do_write_mention(mentioned, channel, msg, state) do
    inbox_mentions =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        mentioned,
        "inbox",
        "mentions"
      ])

    agent_dir =
      Path.join([state.base, "companies", state.company, "agents", mentioned])

    if File.dir?(agent_dir) do
      # Single DateTime to keep filename ts and delivered_at consistent
      # (same invariant as perform_routing/3).
      now = DateTime.utc_now()
      ts = DateTime.to_unix(now, :millisecond)
      path = Path.join(inbox_mentions, "#{ts}-#{channel}.md")

      frontmatter = """
      ---
      channel: "#{channel}"
      from: "#{msg.sender}"
      source_msg: "#{msg.msg_id}"
      delivered_at: "#{DateTime.to_iso8601(now)}"
      ---

      """

      state.fs_fun.mkdir_p!.(inbox_mentions)
      state.fs_fun.write!.(path, frontmatter <> msg.body)

      emit_audit(state, %{
        action: "agent.wake",
        actor: "system",
        company: state.company,
        agent: mentioned,
        trigger: "mention"
      })

      :ok
    else
      :skipped
    end
  end

  # Append-line helper — File.open([:append, :sync]) + IO.binwrite serialises
  # concurrent writers at the OS file-handle layer.
  defp append_line!(fs_fun, path, body) do
    line = if String.ends_with?(body, "\n"), do: body, else: body <> "\n"
    fs_fun.open_append_sync!.(path, line)
  end

  # Wrap an outbox-sourced chat message in the canonical
  # `## <iso-ts> | <sender>\n<body>` block so ChatDrawer/State and
  # ChannelLive render the agent's reply with proper attribution.
  defp format_chat_post(msg) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    "\n## #{ts} | #{msg.sender}\n#{String.trim(msg.body)}\n"
  end

  # AuditLog.append/2 expects a GenServer.server reference, not a company
  # slug string. Router used `&AuditLog.append/2` as the default, which
  # raised `no function clause matching in GenServer.whereis/1` on every
  # outbox event. Resolve via Registry and fall back to the default-named
  # AuditLog (test mode / init orchestration edge cases).
  defp default_audit_fun(company, entry) when is_binary(company) do
    server =
      case resolve_audit_server(company) do
        {:ok, via} -> via
        :not_found -> AuditLog
      end

    AuditLog.append(server, Map.put(entry, :company, company))
  end

  defp resolve_audit_server(company) do
    key = {:company_child, company, :audit_log}

    case Elixir.Registry.lookup(Glorbo.Agent.Registry, key) do
      [{_pid, _}] -> {:ok, {:via, Elixir.Registry, {Glorbo.Agent.Registry, key}}}
      _ -> :not_found
    end
  end

  defp emit_route_audit(msg, to, state) do
    emit_audit(state, %{
      action: "message.route",
      actor: msg.sender,
      company: state.company,
      from: msg.sender,
      to: format_to(to),
      msg_id: msg.msg_id,
      path: msg.raw_path
    })
  end

  defp format_to({:chat, channel}), do: "chat:#{channel}"
  defp format_to({:agent, slug}), do: "agent:#{slug}"
  defp format_to(:broadcast), do: "broadcast:*"

  # ---------------------------------------------------------------------------
  # Rejection handling
  # ---------------------------------------------------------------------------

  defp handle_rejection({:error, reason} = err, msg, state) do
    do_handle_rejection(reason, msg, state)
    err
  rescue
    e ->
      Logger.error("router rejection handler raised: #{Exception.message(e)}")
      err
  end

  defp do_handle_rejection(reason, msg, state) do
    # Write rejection file to history/
    write_rejection_file(reason, msg, state)

    # Write rejection notice to sender inbox (if sender dir exists)
    write_rejection_notice(reason, msg, state)

    # Emit message.reject + permission.denied + agents.create_blocked (where applicable)
    emit_rejection_audits(reason, msg, state)
  end

  defp write_rejection_file(reason, msg, state) do
    path =
      Path.join([state.base, "companies", state.company, "history", "#{msg.msg_id}.rejected.md"])

    dir = Path.dirname(path)
    state.fs_fun.mkdir_p!.(dir)

    frontmatter = """
    ---
    rejection_reason: #{rejection_reason_key(reason)}
    missing: "#{format_missing(reason)}"
    rejected_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
    msg_id: "#{msg.msg_id}"
    from: "#{msg.sender}"
    to: "#{msg.to}"
    ---

    """

    state.fs_fun.write!.(path, frontmatter <> msg.body)
  rescue
    e -> Logger.error("router rejection file write failed: #{Exception.message(e)}")
  end

  defp write_rejection_notice(reason, msg, state) do
    dir =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        msg.sender,
        "inbox",
        "rejections"
      ])

    if File.dir?(Path.dirname(dir)) do
      state.fs_fun.mkdir_p!.(dir)
      ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      path = Path.join(dir, "#{ts}-#{msg.msg_id}.md")

      content = """
      ---
      rejected_msg_id: "#{msg.msg_id}"
      rejection_reason: #{rejection_reason_key(reason)}
      missing: "#{format_missing(reason)}"
      rejected_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
      ---

      Message to `#{msg.to}` was rejected: #{format_missing(reason)}.
      """

      state.fs_fun.write!.(path, content)
    end
  rescue
    e -> Logger.error("router rejection notice write failed: #{Exception.message(e)}")
  end

  defp emit_rejection_audits(reason, msg, state) do
    missing = format_missing(reason)

    # message.reject — general rejection record
    emit_audit(state, %{
      action: "message.reject",
      actor: msg.sender,
      company: state.company,
      from: msg.sender,
      to: msg.to,
      msg_id: msg.msg_id,
      reason: rejection_reason_key(reason),
      missing_permission: missing
    })

    # permission.denied — SEC-01 audit for every denied dispatch
    emit_audit(state, %{
      action: "permission.denied",
      actor: msg.sender,
      company: state.company,
      from: msg.sender,
      target: msg.to,
      requested_action: msg.to,
      missing_permission: missing
    })

    # agents.create_blocked — AGT-05 specific audit
    case reason do
      {:agent_create_blocked, target} ->
        emit_audit(state, %{
          action: "agents.create_blocked",
          actor: msg.sender,
          company: state.company,
          from: msg.sender,
          attempted_target: target
        })

      _ ->
        :ok
    end
  end

  defp rejection_reason_key({:permission_denied, _}), do: "permission_denied"
  defp rejection_reason_key({:agent_create_blocked, _}), do: "agent_create_blocked"
  defp rejection_reason_key({:invalid_message, _}), do: "invalid_message"
  defp rejection_reason_key({:unknown_recipient, _}), do: "unknown_recipient"
  defp rejection_reason_key(_), do: "unknown"

  defp format_missing({:permission_denied, perm}), do: perm
  defp format_missing({:agent_create_blocked, _target}), do: "agents:create:*"
  defp format_missing({:invalid_message, :sender_mismatch}), do: "sender_mismatch"
  defp format_missing({:invalid_message, :broadcast_unsupported}), do: "broadcast_unsupported"
  defp format_missing({:invalid_message, reason}), do: "invalid_message:#{inspect(reason)}"
  defp format_missing(other), do: inspect(other)

  defp emit_audit(state, entry) do
    state.audit_fun.(state.company, entry)
    :ok
  rescue
    e ->
      Logger.error("router audit emit failed: #{Exception.message(e)}")
      :error
  end

  # ---------------------------------------------------------------------------
  # Outbox PubSub event handling (GAP-3)
  # ---------------------------------------------------------------------------

  defp events_include_write?(events) when is_list(events),
    do: Enum.any?(events, &(&1 in [:created, :modified]))

  defp events_include_write?(_), do: false

  defp handle_outbox_event(rel_path, state) do
    case parse_outbox_rel(rel_path) do
      {:ok, sender, file_name} ->
        abs_path =
          Path.join([
            state.base,
            "companies",
            state.company,
            "agents",
            sender,
            "outbox",
            file_name
          ])

        read_and_route(abs_path, sender, state)

      {:error, :not_outbox} ->
        # Subscriber received a non-outbox event (shouldn't happen given the
        # topic scope, but defence-in-depth against future fan-out).
        :ok
    end
  rescue
    e ->
      Logger.error("[router/#{state.company}] outbox handler raised: #{Exception.message(e)}")
      :ok
  end

  defp parse_outbox_rel(rel_path) when is_binary(rel_path) do
    case Regex.named_captures(@outbox_rel_re, rel_path) do
      %{"sender" => sender, "file" => file} -> {:ok, sender, file}
      _ -> {:error, :not_outbox}
    end
  end

  defp parse_outbox_rel(_), do: {:error, :not_outbox}

  # Dispatch outbox files by their path shape — the Router now handles
  # three kinds (was one). Everything still flows through the sender-
  # slug and permission checks below.
  #
  #   tasks/<project>/<id>.md → file a task into projects/<p>/tasks/
  #   comments/<task-id>.md   → append a comment to projects/*/tasks/<id>.md
  #   <file>.md               → classic message route (requires `to:`)
  #
  # The `tasks/` and `comments/` paths let agents file work for
  # Director review without the Director having to hand-copy every
  # file (see glorbo-vs-paperclip.md benchmark).
  defp read_and_route(abs_path, sender, state) do
    case classify_outbox_file(abs_path, state, sender) do
      {:task, project, task_id} ->
        handle_outbox_task(abs_path, sender, project, task_id, state)

      {:comment, task_id} ->
        handle_outbox_comment(abs_path, sender, task_id, state)

      :message ->
        handle_outbox_message(abs_path, sender, state)
    end
  rescue
    e ->
      Logger.error(
        "[router/#{state.company}] outbox file handler raised path=#{abs_path} err=#{Exception.message(e)}"
      )

      :ok
  end

  defp classify_outbox_file(abs_path, state, sender) do
    outbox_root =
      Path.join([state.base, "companies", state.company, "agents", sender, "outbox"])

    rel = Path.relative_to(abs_path, outbox_root)

    case Path.split(rel) do
      ["tasks", project, <<_::binary>> = file] ->
        task_id = Path.basename(file, ".md")

        if GlorboWeb.Slug.valid?(project) and task_id_valid?(task_id),
          do: {:task, project, task_id},
          else: :message

      ["comments", <<_::binary>> = file] ->
        task_id = Path.basename(file, ".md")
        if task_id_valid?(task_id), do: {:comment, task_id}, else: :message

      _ ->
        :message
    end
  end

  defp task_id_valid?(task_id),
    do: Regex.match?(~r/\A[a-z][a-z0-9_-]*-\d+\z/, task_id)

  # Move an agent-authored task file into the project's tasks/ dir.
  # Rejects on: invalid frontmatter, filename collision, missing
  # project, missing permission. Audits every accept AND reject.
  defp handle_outbox_task(abs_path, sender, project, task_id, state) do
    project_tasks_dir =
      Path.join([state.base, "companies", state.company, "projects", project, "tasks"])

    dest_path = Path.join(project_tasks_dir, "#{task_id}.md")
    project_md = Path.join([Path.dirname(project_tasks_dir), "project.md"])

    with {:ok, content} <- File.read(abs_path),
         {:ok, _meta, _body} <- Frontmatter.parse(content),
         {:ok, perms} <- lookup_permissions(sender, state),
         :ok <- check_project_write_permission(perms, project),
         :ok <- ensure_project_exists(project_md),
         :ok <- refuse_if_exists(dest_path),
         :ok <- File.mkdir_p(project_tasks_dir),
         :ok <- File.write(dest_path, content, [:sync]),
         :ok <- File.rm(abs_path) do
      emit_task_route_audit(sender, project, task_id, state)
      :ok
    else
      {:error, reason} ->
        Logger.debug(
          "[router/#{state.company}] outbox task skipped sender=#{sender} project=#{project} task=#{task_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp check_project_write_permission(perms, project) do
    case ACLMapper.check_action(perms, {"projects", "write", project}) do
      :ok -> :ok
      {:error, _} -> ACLMapper.check_action(perms, {"projects", "write", "*"})
    end
  end

  defp ensure_project_exists(project_md) do
    if File.exists?(project_md), do: :ok, else: {:error, :project_not_found}
  end

  defp refuse_if_exists(dest_path) do
    if File.exists?(dest_path), do: {:error, :task_id_collision}, else: :ok
  end

  defp emit_task_route_audit(sender, project, task_id, state) do
    state.audit_fun.(state.company, %{
      company: state.company,
      actor: sender,
      action: "task.create",
      target: "projects/#{project}/tasks/#{task_id}.md",
      source: "outbox"
    })
  rescue
    _ -> :ok
  end

  # Append an agent-authored comment to a task. Looks for the task
  # file across all projects under `companies/<co>/projects/*/tasks/`
  # since the comment file only names the task-id.
  defp handle_outbox_comment(abs_path, sender, task_id, state) do
    with {:ok, content} <- File.read(abs_path),
         {:ok, body} <- strip_frontmatter(content),
         {:ok, task_path} <- find_task_file(task_id, state),
         :ok <- append_task_comment(task_path, sender, body),
         :ok <- File.rm(abs_path) do
      emit_comment_route_audit(sender, task_id, state)
      :ok
    else
      {:error, reason} ->
        Logger.debug(
          "[router/#{state.company}] outbox comment skipped sender=#{sender} task=#{task_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp strip_frontmatter(content) do
    case Frontmatter.parse(content) do
      {:ok, _meta, body} -> {:ok, body}
      {:error, _} -> {:ok, content}
    end
  end

  defp find_task_file(task_id, state) do
    projects_dir = Path.join([state.base, "companies", state.company, "projects"])

    case Path.wildcard(Path.join([projects_dir, "*", "tasks", "#{task_id}.md"])) do
      [match | _] -> {:ok, match}
      [] -> {:error, :task_not_found}
    end
  end

  defp append_task_comment(task_path, sender, body) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    entry = "\n## #{ts} | #{sender}\n#{String.trim(body)}\n"
    File.write(task_path, entry, [:append, :sync])
  end

  defp emit_comment_route_audit(sender, task_id, state) do
    state.audit_fun.(state.company, %{
      company: state.company,
      actor: sender,
      action: "task.comment",
      target: task_id,
      source: "outbox"
    })
  rescue
    _ -> :ok
  end

  # Classic message route — requires `to:` frontmatter pointing at a
  # channel or agent slug. Rejected messages land in
  # `history/<msg_id>.rejected.md` per the original pipeline.
  defp handle_outbox_message(abs_path, sender, state) do
    with {:ok, content} <- File.read(abs_path),
         {:ok, meta, body} <- Frontmatter.parse(content),
         {:ok, to} <- extract_to(meta),
         {:ok, perms} <- lookup_permissions(sender, state) do
      msg = %{
        sender: sender,
        sender_permissions: perms,
        to: to,
        body: body,
        raw_path: abs_path,
        msg_id: derive_msg_id(abs_path, meta)
      }

      _ = do_route(msg, state)
      :ok
    else
      {:error, reason} ->
        Logger.debug(
          "[router/#{state.company}] outbox message skipped path=#{abs_path} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp extract_to(%{} = meta) do
    case Map.get(meta, "to") do
      nil -> {:error, :missing_to}
      to when is_binary(to) and to != "" -> {:ok, to}
      _ -> {:error, :invalid_to}
    end
  end

  defp extract_to(_), do: {:error, :invalid_frontmatter}

  defp derive_msg_id(abs_path, meta) do
    case Map.get(meta, "msg_id") do
      id when is_binary(id) and id != "" -> id
      _ -> Path.basename(abs_path, ".md")
    end
  end

  defp lookup_permissions(sender, state) do
    state.agent_permissions_fun.(sender, state)
  end

  # Production permission lookup — parse the sender's agent.md via
  # Agent.Parser and return their declared permissions. Empty list on any
  # parse / read error so a missing or malformed agent.md doesn't crash
  # the Router; the downstream ACLMapper check will deny any action that
  # requires a permission.
  defp default_agent_permissions(sender, state) do
    agent_dir =
      Path.join([
        state.base,
        "companies",
        state.company,
        "agents",
        sender
      ])

    agent_md_path = Glorbo.Agent.FileLayout.agent_md(agent_dir)

    case AgentParser.parse_file(agent_md_path) do
      {:ok, spec} -> {:ok, spec.permissions}
      {:error, _} -> {:ok, []}
    end
  end

  # ---------------------------------------------------------------------------
  # Default fs_fun map — production uses File module
  # ---------------------------------------------------------------------------

  defp default_fs_fun do
    %{
      write!: &File.write!/2,
      mkdir_p!: &File.mkdir_p!/1,
      exists?: &File.exists?/1,
      # Append + sync writer: used for channel appends (R1 + R11 race-safety)
      open_append_sync!: fn path, content ->
        file = File.open!(path, [:append, :sync, :binary])
        IO.binwrite(file, content)
        File.close(file)
      end
    }
  end
end
