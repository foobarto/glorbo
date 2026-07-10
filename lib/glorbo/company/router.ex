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
  alias Glorbo.ChannelLog
  alias Glorbo.Company.AuditLog
  alias Glorbo.Filesystem.Frontmatter
  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.Tx
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
         :ok <- reject_unauthorized_dm(to, msg),
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
  #
  # Threatmodel H3/H6 (wave 4): each segment is Path.join'd into the
  # channels/inbox filesystem tree, so anything that isn't a canonical
  # entity slug is path-traversal fuel. Reject at parse time — no `..`,
  # no absolute paths, no `/`. Agent slugs use the shared agent-specific
  # shape, which permits underscores consistently with creation/routing.
  defp parse_to("chat:" <> channel) when byte_size(channel) > 0 do
    if Glorbo.Slug.valid?(channel),
      do: {:ok, {:chat, channel}},
      else: {:error, {:invalid_message, :invalid_channel_slug}}
  end

  defp parse_to("agent:" <> slug) when byte_size(slug) > 0 do
    if Glorbo.Slug.valid?(slug, :agent),
      do: {:ok, {:agent, slug}},
      else: {:error, {:invalid_message, :invalid_agent_slug}}
  end

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

  # Security (codex B-020, write vector): director DMs are stored as
  # regular channels named `dm-director--<agent>.md`. Because
  # `required_permission_for/1` maps a chat write to
  # `{"chat", "write", <channel>}`, a broad `chat:write:*` grant would
  # otherwise let any agent append to ANOTHER agent's director DM (and,
  # via `maybe_add_dm_counterparty`, notify/wake that victim). Reserve the
  # `dm-director--` prefix: an agent may only write its OWN DM thread
  # (`dm-director--<sender>`); writes to any other agent's DM are refused
  # regardless of the wildcard. The director writes DMs through the
  # dashboard (not this Router path), so it is unaffected.
  #
  # NOTE: this closes the WRITE/spoof half of B-020. The READ half — a
  # `chat:read:*` agent gets the whole `channels/` dir RO-mounted into its
  # sandbox and can `cat` every DM — is a kernel-mount layout issue whose
  # clean fix moves DMs to a per-agent tree (GEP / on-disk-layout change);
  # left for operator review.
  defp reject_unauthorized_dm({:chat, "dm-director--" <> owner}, %{sender: sender})
       when owner != sender do
    {:error, {:invalid_message, :reserved_dm_channel}}
  end

  defp reject_unauthorized_dm(_, _), do: :ok

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
    # #238 — rotate the channel post-append; failure is logged,
    # never fails the route (message is already on disk + audited
    # by emit_route_audit/3 upstream).
    _ = maybe_rotate_channel(channel_path, channel, state)
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

    # Wave 27: refuse a pre-planted symlinked inbox ancestor before
    # mkdir_p!. Without this, an agent who later regains write to its
    # own state could redirect cross-agent direct messages.
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(dir) do
      Logger.warning(
        "[router/#{state.company}] inbox write skipped target=#{target_slug} reason=symlinked_inbox"
      )

      {:error, {:invalid_message, :symlinked_inbox}}
    else
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
    end
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

    # Wave 27: refuse a `inbox/mentions -> ../../audit` symlink
    # before mkdir_p!. Skip the mention silently if the agent has
    # planted one — the channel message is still durable.
    if File.dir?(agent_dir) and
         not Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(inbox_mentions) do
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
    ChannelLog.format_post(msg.sender, msg.body, :agent)
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

    # Gemini round-5 finding (PR #37): the prior shape did
    # `"...: \"#{msg.to}\""` (raw `#{}` interpolation into a
    # quoted YAML scalar). `validate_message/1` blocks `\n \r \0`
    # but NOT `"` — so `to: foo"bar` produced
    # `to: "foo"bar"`, corrupting the rejected.md YAML +
    # the inbox/rejections notice. Pipe every interpolated field
    # through the canonical `yaml_scalar/1` escaper.
    yaml = &Glorbo.Filesystem.FrontmatterWriter.yaml_scalar/1

    frontmatter = """
    ---
    rejection_reason: #{rejection_reason_key(reason)}
    missing: #{yaml.(format_missing(reason))}
    rejected_at: #{yaml.(DateTime.utc_now() |> DateTime.to_iso8601())}
    msg_id: #{yaml.(msg.msg_id)}
    from: #{yaml.(msg.sender)}
    to: #{yaml.(msg.to)}
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

      # Gemini round-5 finding (PR #37): same YAML-scalar
      # injection vector as `write_rejection_file/3` above. Use
      # the canonical escaper. The body line keeps `#{msg.to}`
      # as inline markdown — backticks aren't YAML-sensitive.
      yaml = &Glorbo.Filesystem.FrontmatterWriter.yaml_scalar/1

      content = """
      ---
      rejected_msg_id: #{yaml.(msg.msg_id)}
      rejection_reason: #{rejection_reason_key(reason)}
      missing: #{yaml.(format_missing(reason))}
      rejected_at: #{yaml.(DateTime.utc_now() |> DateTime.to_iso8601())}
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

      {:memory_write, filename} ->
        handle_outbox_memory_write(abs_path, sender, filename, state)

      {:memory_delete, filename} ->
        handle_outbox_memory_delete(abs_path, sender, filename, state)

      {:path_request, task_id} ->
        handle_outbox_path_request(abs_path, sender, task_id, state)

      {:proposal, id} ->
        handle_outbox_proposal(abs_path, sender, id, state)

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

        if Glorbo.Slug.valid?(project) and task_id_valid?(task_id),
          do: {:task, project, task_id},
          else: :message

      ["comments", <<_::binary>> = file] ->
        task_id = Path.basename(file, ".md")
        if task_id_valid?(task_id), do: {:comment, task_id}, else: :message

      # GEP-21 (#17b) — agent memory write
      # agents/<sender>/outbox/memory/<type>_<topic>.md
      ["memory", <<_::binary>> = file] ->
        if memory_filename_valid?(file), do: {:memory_write, file}, else: :message

      # GEP-21 (#17b) — agent memory delete marker
      # agents/<sender>/outbox/memory/delete/<type>_<topic>.md
      ["memory", "delete", <<_::binary>> = file] ->
        if memory_filename_valid?(file), do: {:memory_delete, file}, else: :message

      # GEP-27 — agent sandbox path request
      # agents/<sender>/outbox/path-request-<task_id>.md
      [<<"path-request-", _rest::binary>> = file] ->
        task_id = Path.basename(file, ".md")
        # task_id is "path-request-<actual-id>", extract the actual id
        actual_task_id = String.replace_prefix(task_id, "path-request-", "")

        if task_id_valid?(actual_task_id),
          do: {:path_request, actual_task_id},
          else: :message

      # GEP-28 D7 — agent-sourced proposal via outbox
      # agents/<sender>/outbox/proposals/<id>.md → proposals/<id>.md
      ["proposals", <<_::binary>> = file] ->
        id = Path.basename(file, ".md")

        if proposal_id_valid?(id),
          do: {:proposal, id},
          else: :message

      [<<_::binary>> = file] ->
        # Permissive shorthand: a top-level outbox file whose
        # frontmatter declares `kind: task/v1` is treated as a task
        # filing into the `inbox` project. Saves the agent from
        # having to learn the exact `tasks/<project>/` prefix.
        task_id = Path.basename(file, ".md")

        if task_id_valid?(task_id) and task_kind_frontmatter?(abs_path),
          do: {:task, "inbox", task_id},
          else: :message

      _ ->
        :message
    end
  end

  # Best-effort frontmatter peek — safe on unreadable / non-md files.
  # Uses the lstat-guarded reader so a symlinked outbox entry can't
  # trick us into reading arbitrary host files during classification.
  defp task_kind_frontmatter?(abs_path) do
    with {:ok, content} <- read_agent_writable_file(abs_path),
         {:ok, fm, _body} <- Glorbo.Filesystem.Frontmatter.parse(content) do
      to_string(Map.get(fm, "kind", "")) == "task/v1"
    else
      _ -> false
    end
  end

  # Proposal IDs follow the same shape as filesystem-friendly slugs:
  # alnum + `_-`. Matches `FileSpec.ProposalMd` path regex stem.
  @proposal_id_re ~r/\A[a-z0-9][a-z0-9_-]*\z/
  defp proposal_id_valid?(id), do: Regex.match?(@proposal_id_re, id)

  @memory_filename_re ~r/^(user|feedback|project|reference)_[a-z][a-z0-9_-]{0,63}\.md$/
  defp memory_filename_valid?(name), do: Regex.match?(@memory_filename_re, name)

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

    history_meta = %{
      actor: HomeHistory.actor_from_string("agent:" <> sender),
      action: "task.route",
      target: "companies/#{state.company}/projects/#{project}/tasks/#{task_id}.md"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        with {:ok, content} <- read_agent_writable_file(abs_path),
             {:ok, meta, _body} <- Frontmatter.parse(content),
             :ok <- require_task_kind(meta),
             :ok <- require_task_title(meta),
             {:ok, perms} <- lookup_permissions(sender, state),
             :ok <- check_project_write_permission(perms, project),
             :ok <- ensure_project_exists(project_md),
             :ok <- refuse_if_exists(dest_path),
             # Wave 26: an agent with project write can replace
             # `projects/<p>/tasks` with a symlink pointing at another
             # company's tree. Refuse symlinked ancestors before
             # `mkdir_p` so the write cannot land outside this company.
             :ok <- refuse_symlinked_ancestors(project_tasks_dir),
             :ok <- File.mkdir_p(project_tasks_dir),
             stamped_content <- stamp_with_context(content, sender),
             # Threatmodel M03 (write side): `projects/<p>/tasks/`
             # lives in a tree the sender may have RW-mounted. The
             # previous `lstat → File.write` flow had a TOCTOU race:
             # between the lstat and the write, an attacker could
             # swap `dest_path` for a symlink. Atomic exclusive
             # `:file.open` (O_EXCL semantics) refuses to follow a
             # symlink AND fails if the path already exists — closes
             # both halves of the race in one syscall.
             :ok <- exclusive_write(dest_path, stamped_content),
             :ok <- Tx.mark_path(tx_id, dest_path),
             :ok <- File.rm(abs_path) do
          emit_task_route_audit(sender, project, task_id, state)
          :ok = Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(state.base, state.company))
          maybe_request_approval(meta, dest_path, project, task_id, sender, state)
          maybe_auto_dispatch(meta, project, task_id, sender, perms, state)
          {:ok, :routed}
        end
      end)

    case history_result do
      {:ok, :routed, _tx_id} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "[router/#{state.company}] outbox task skipped sender=#{sender} project=#{project} task=#{task_id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # F10: agent-spawned sub-tasks via outbox — auto-dispatch flag.
  #
  # When an agent files a task via `outbox/tasks/<project>/<id>.md`
  # (the existing routing handled by `handle_outbox_task` above) and
  # the task frontmatter carries `auto_dispatch: true`, write a
  # synthetic inbox event for `assigned_to` so the assignee wakes
  # immediately. Without this, the new task sits at its authored
  # status and waits for the operator (or a `schedule:` tick) to
  # dispatch it — which defeats the agent's intent of "spawn this,
  # have it run now."
  #
  # Skipped when:
  #   - `auto_dispatch` is not literally `true` (parser keeps booleans
  #     strict; "true" string falls through).
  #   - The task wants director approval (we honour the gate; the
  #     operator decides when to dispatch after granting).
  #   - `assigned_to` is empty or invalid — there's nothing to wake.
  #
  # Security (codex B-025): auto_dispatch writes directly into
  # `agents/<assignee>/inbox`, which is exactly what a direct
  # `to: agent:<assignee>` message does — and that path requires
  # `agents:message:<assignee>` (see `required_permission_for/1` +
  # the SEC-01 check at the top of `route/2`). The `tasks:create`
  # permission used to file the task is NOT sufficient: the assignee
  # is taken verbatim from attacker-controllable `assigned_to`
  # frontmatter, so without this gate a `tasks:create:<project>`-only
  # agent could wake ANY agent and make it process attacker-authored
  # task content (consuming its budget + acting with its privileges).
  # auto_dispatch must obey the same authorization as the message it
  # effectively sends.
  defp maybe_auto_dispatch(meta, project, task_id, sender, perms, state) do
    cond do
      Map.get(meta, "auto_dispatch") != true ->
        :ok

      requires_director_approval?(meta) ->
        :ok

      true ->
        assignee = Map.get(meta, "assigned_to") || ""

        with true <- Glorbo.Slug.valid?(assignee, :agent),
             :ok <- ACLMapper.check_action(perms, {"agents", "message", assignee}) do
          auto_dispatch_if_ready(meta, project, task_id, sender, assignee, state)
        else
          {:error, {:permission_denied, missing}} ->
            emit_audit(state, %{
              action: "task.auto_dispatch_denied",
              actor: "agent:" <> sender,
              company: state.company,
              target: "projects/#{project}/tasks/#{task_id}.md",
              detail: %{assignee: assignee, missing: missing}
            })

            :ok

          # Invalid/empty assignee — nothing to wake.
          false ->
            :ok
        end
    end
  end

  # GEP-47 v2: the F10 auto_dispatch path must honour the same
  # dependency gate the scheduler enforces. Without this, an agent that
  # files a task with `auto_dispatch: true` + a valid assignee + an
  # unmet `depends_on` would dispatch it immediately — a silent bypass
  # of the gate `TaskScheduler.fire` applies. Mirrors the scheduler's
  # classification + audit actions for consistency.
  defp auto_dispatch_if_ready(meta, project, task_id, sender, assignee, state) do
    case Glorbo.Task.Snapshot.coerce_depends_on(Map.get(meta, "depends_on")) do
      [] ->
        write_auto_dispatch_inbox(state, sender, assignee, project, task_id)

      deps ->
        task_rel = "projects/#{project}/tasks/#{task_id}.md"
        snapshot = Glorbo.Task.Snapshot.build(state.base, state.company)

        case Glorbo.Task.DependencyGate.ready?(deps, snapshot) do
          :ok ->
            write_auto_dispatch_inbox(state, sender, assignee, project, task_id)

          {:blocked, unmet} ->
            emit_audit(state, %{
              action: "task.blocked_on_deps",
              actor: "agent:" <> sender,
              company: state.company,
              target: task_rel,
              detail: %{task_id: task_id, unmet: unmet}
            })

            :ok

          {:propagate_failure, dep_id, reason} ->
            emit_audit(state, %{
              action: "task.blocked_on_failed_dep",
              actor: "agent:" <> sender,
              company: state.company,
              target: task_rel,
              detail: %{task_id: task_id, failed_dep: dep_id, reason: reason}
            })

            :ok
        end
    end
  end

  defp requires_director_approval?(meta) do
    case Map.get(meta, "requires_approval") do
      "director" ->
        true

      :director ->
        true

      _ ->
        case Map.get(meta, "status") do
          "pending_approval" -> true
          "pending-approval" -> true
          _ -> false
        end
    end
  end

  defp write_auto_dispatch_inbox(state, sender, assignee, project, task_id) do
    inbox_dir =
      Path.join([state.base, "companies", state.company, "agents", assignee, "inbox"])

    task_rel = "projects/#{project}/tasks/#{task_id}.md"
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    filename = "auto-#{System.unique_integer([:positive])}-#{task_id}.md"

    msg_body = """
    ---
    kind: inbox-message/v1
    from: #{sender}
    task_path: #{task_rel}
    scheduled_at: "#{ts}"
    auto_dispatch: true
    ---

    Auto-dispatched on agent task creation by #{sender}.
    """

    case File.mkdir_p(inbox_dir) do
      :ok ->
        write_path = Path.join(inbox_dir, filename)

        case File.write(write_path, msg_body) do
          :ok ->
            emit_audit(state, %{
              action: "task.auto_dispatched",
              actor: "agent:" <> sender,
              company: state.company,
              target: task_rel,
              detail: %{
                task_id: task_id,
                project: project,
                assigned_to: assignee,
                inbox_message: filename
              }
            })

            :ok

          {:error, reason} ->
            Logger.warning(
              "[router/#{state.company}] auto_dispatch inbox write failed task=#{task_id} reason=#{inspect(reason)}"
            )

            :ok
        end

      {:error, reason} ->
        Logger.warning(
          "[router/#{state.company}] auto_dispatch mkdir_p failed assignee=#{assignee} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  # If the task's frontmatter asks for director approval, open a
  # sentinel + awaiting row so the task shows up in the Inbox.
  # Recognised shapes:
  #   - `requires_approval: director`  — canonical (GEP-19, TaskDefinition)
  #   - `status: pending_approval`     — agent shorthand; treat the same
  #   - `status: pending-approval`     — same, with a hyphen
  defp maybe_request_approval(meta, dest_path, project, task_id, sender, state) do
    wants_approval? =
      case Map.get(meta, "requires_approval") do
        "director" ->
          true

        :director ->
          true

        _ ->
          case Map.get(meta, "status") do
            "pending_approval" -> true
            "pending-approval" -> true
            _ -> false
          end
      end

    if wants_approval? do
      task_rel = Path.join(["projects", project, "tasks", "#{task_id}.md"])

      case Glorbo.TaskDefinition.parse_file(dest_path,
             base: state.base,
             company: state.company
           ) do
        {:ok, td} ->
          req = %{
            agent: sender,
            task_definition: %{td | task_path: task_rel},
            requesting_trigger: :outbox_filed
          }

          try do
            gate = Glorbo.Company.Supervisor.via(state.company, :approvals_gate)
            _ = Glorbo.Approvals.Gate.request_approval(gate, req)
          rescue
            e ->
              Logger.warning(
                "[router/#{state.company}] approval request raised: " <>
                  "#{Exception.message(e)} task=#{task_id} agent=#{sender}"
              )

              :ok
          catch
            kind, reason ->
              Logger.warning(
                "[router/#{state.company}] approval request #{kind}: " <>
                  "#{inspect(reason)} task=#{task_id} agent=#{sender}"
              )

              :ok
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # Append a `## Context` footer to outbox-routed tasks naming the
  # sender + ISO timestamp. Assignees can then trace provenance
  # (`filed by @ceo on 2026-04-21`) without needing the Router to
  # plumb parent-invocation state through — a strictly additive
  # mutation keyed off what Router already knows.
  defp stamp_with_context(content, sender) do
    trimmed = String.trim_trailing(content)
    ts = DateTime.utc_now() |> DateTime.to_iso8601()

    footer = """


    ## Context
    Filed via outbox by `@#{sender}` on #{ts}.
    """

    trimmed <> footer <> "\n"
  end

  # Tasks without a `title:` in frontmatter are almost certainly
  # missing the whole `---`…`---` fence (the most common mistake
  # agents make). Reject them so the Director sees the outbox file
  # still in place and can intervene.
  defp require_task_title(meta) do
    case Map.get(meta, "title") do
      t when is_binary(t) and byte_size(t) > 0 -> :ok
      _ -> {:error, :missing_title_frontmatter}
    end
  end

  # GEP-25 D9: every task file must carry `kind: task/v1`. Agents that
  # file tasks via outbox are responsible for supplying it; missing
  # kind → rejected and left in outbox for director intervention.
  defp require_task_kind(meta) do
    case Map.get(meta, "kind") do
      "task/v1" -> :ok
      other -> {:error, {:bad_kind, other}}
    end
  end

  defp check_project_write_permission(perms, project) do
    # Filing a task into <project> is authorised by any of:
    #   projects:write:<project>  — full RW on that project
    #   projects:write:*          — full RW on all projects
    #   tasks:create:<project>    — narrow "can add tasks here"
    #   tasks:create:*            — narrow "can add tasks to any project"
    checks = [
      {"projects", "write", project},
      {"projects", "write", "*"},
      {"tasks", "create", project},
      {"tasks", "create", "*"}
    ]

    if Enum.any?(checks, &match?(:ok, ACLMapper.check_action(perms, &1))) do
      :ok
    else
      {:error, {:permission_denied, "projects:write:#{project}"}}
    end
  end

  defp ensure_project_exists(project_md) do
    if File.exists?(project_md), do: :ok, else: {:error, :project_not_found}
  end

  defp refuse_if_exists(dest_path) do
    if File.exists?(dest_path), do: {:error, :task_id_collision}, else: :ok
  end

  defp refuse_symlinked_ancestors(path) do
    if Glorbo.Filesystem.AgentWritableFile.any_symlink_in_path?(path),
      do: {:error, :symlinked_ancestor},
      else: :ok
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
  #
  # threatmodel M14: the original handler blindly appended to any
  # task in any project — an agent with zero `tasks:*` or
  # `projects:*` permissions could mutate tasks anywhere in the
  # company by dropping a comment file. Check the sender's
  # permissions against the *resolved* project slug before writing.
  defp handle_outbox_comment(abs_path, sender, task_id, state) do
    with {:ok, content} <- read_agent_writable_file(abs_path),
         {:ok, body} <- strip_frontmatter(content),
         {:ok, task_path} <- find_task_file(task_id, state),
         project = project_from_task_path(task_path),
         {:ok, perms} <- lookup_permissions(sender, state),
         :ok <- check_comment_permission(perms, project),
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

  # Extract the project slug from a resolved task path
  # (`.../projects/<slug>/tasks/<id>.md`). Returns `""` if the
  # shape isn't as expected, which will make `check_comment_permission`
  # deny.
  defp project_from_task_path(task_path) do
    task_path
    |> Path.split()
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.find_value("", fn
      ["projects", slug, "tasks"] -> slug
      _ -> false
    end)
  end

  # Agent may comment on a task when it has either tasks:update:*
  # (project-scoped) or projects:write:* (directory-scoped). Matches
  # the action set the task Router already enforces for task
  # mutations elsewhere.
  defp check_comment_permission(_perms, ""), do: {:error, :permission_denied}

  defp check_comment_permission(perms, project) do
    candidates = [
      {"tasks", "update", project},
      {"tasks", "update", "*"},
      {"projects", "write", project},
      {"projects", "write", "*"}
    ]

    if Enum.any?(candidates, &match?(:ok, ACLMapper.check_action(perms, &1))) do
      :ok
    else
      {:error, :permission_denied}
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

  # GEP-30 D8 — task comments land in the sibling `.comments.md`
  # thread file, not the task body. TaskLive/KanbanLive read only
  # the thread file; appending to `task.md` here would make
  # agent-filed comments vanish from the UI.
  defp append_task_comment(task_path, sender, body) do
    thread_path = Glorbo.TaskComments.path_for(task_path)
    task_id = Path.basename(task_path, ".md")
    Glorbo.TaskComments.append(thread_path, sender, body, task_id: task_id)
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

  # GEP-21 (#17b) — agent memory write.
  #
  # Filename is already validated by `classify_outbox_file/3` against
  # `memory_filename_valid?/1` (4-type prefix + slug). Remaining
  # validations happen here:
  #
  #   1. Body size ≤ 8 KB (per-memory cap — keeps total under the 20
  #      KB read cap even with many files).
  #   2. Frontmatter `type:` matches the filename prefix.
  #
  # Atomic write: sender owns their memory dir, so we write to
  # `agents/<sender>/memory/<filename>` with a tmp+rename dance, then
  # upsert the matching line in `memory/MEMORY.md`, then delete the
  # outbox source + emit `memory.write` audit.
  @memory_max_bytes 8 * 1024

  defp handle_outbox_memory_write(abs_path, sender, filename, state) do
    memory_dir =
      Path.join([state.base, "companies", state.company, "agents", sender, "memory"])

    dest_path = Path.join(memory_dir, filename)
    memory_index = Path.join(memory_dir, "MEMORY.md")

    history_meta = %{
      actor: HomeHistory.actor_from_string("agent:" <> sender),
      action: "memory.write",
      target: "companies/#{state.company}/agents/#{sender}/memory/#{filename}"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        # threatmodel M03: the outbox file is agent-authored — it can
        # be a symlink pointing at another agent's memory directory or
        # any host-writable file. `File.read` + atomic_write would then
        # read from / overwrite the target. lstat and refuse non-regular
        # files on both the source (outbox) and the destination.
        with :ok <- ensure_regular_file_lstat(abs_path),
             :ok <- ensure_regular_file_lstat(dest_path),
             {:ok, content} <- File.read(abs_path),
             :ok <- check_memory_body_size(content),
             {:ok, meta, _body} <- Frontmatter.parse(content),
             :ok <- check_memory_kind(meta),
             :ok <- check_memory_scalar_fields(meta),
             :ok <- check_memory_type_matches_filename(meta, filename),
             :ok <- File.mkdir_p(memory_dir),
             :ok <- atomic_write(dest_path, content),
             :ok <- Tx.mark_path(tx_id, dest_path),
             :ok <- upsert_memory_index(memory_dir, filename, meta),
             :ok <- Tx.mark_path(tx_id, memory_index),
             :ok <- File.rm(abs_path) do
          emit_memory_audit(sender, "memory.write", filename, byte_size(content), state)
          :ok = Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(state.base, state.company))
          {:ok, :written}
        end
      end)

    case history_result do
      {:ok, :written, _tx_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[router/#{state.company}] memory write rejected sender=#{sender} file=#{filename} reason=#{inspect(reason)}"
        )

        # Audit the rejection so directors can spot persistent failures;
        # drop the outbox file so the agent doesn't retry forever on
        # the same bad input.
        _ =
          state.audit_fun.(state.company, %{
            actor: sender,
            action: "memory.rejected",
            target: "agents/#{sender}/memory/#{filename}",
            detail: %{reason: inspect(reason)}
          })

        _ = File.rm(abs_path)
        :ok
    end
  end

  # GEP-21 (#17b) — agent memory delete. Source is an empty marker
  # file at `agents/<sender>/outbox/memory/delete/<filename>`. Body is
  # ignored. We remove the matching memory file + index line + emit
  # `memory.delete`.
  defp handle_outbox_memory_delete(abs_path, sender, filename, state) do
    memory_dir =
      Path.join([state.base, "companies", state.company, "agents", sender, "memory"])

    target_path = Path.join(memory_dir, filename)

    if File.exists?(target_path) do
      case File.rm(target_path) do
        :ok ->
          :ok = remove_memory_index_line(memory_dir, filename)
          _ = File.rm(abs_path)
          emit_memory_audit(sender, "memory.delete", filename, 0, state)

        {:error, reason} ->
          Logger.warning(
            "[router/#{state.company}] memory delete failed sender=#{sender} file=#{filename} reason=#{inspect(reason)}"
          )

          :ok
      end
    else
      Logger.info(
        "[router/#{state.company}] memory delete no-op sender=#{sender} file=#{filename} (target missing)"
      )

      _ = File.rm(abs_path)
      :ok
    end
  end

  # GEP-27 — agent sandbox path request.
  #
  # Agent writes `outbox/path-request-<task_id>.md`. Router reads,
  # validates, and forwards to PathRequestGate. The outbox file is
  # archived on accept, dropped on reject.
  defp handle_outbox_path_request(abs_path, sender, task_id, state) do
    with {:ok, content} <- read_agent_writable_file(abs_path),
         {:ok, meta, _body} <- Frontmatter.parse(content),
         :ok <- require_path_request_kind(meta),
         :ok <- require_path_request_paths(meta),
         :ok <- require_path_request_reason(meta),
         :ok <- forward_to_path_request_gate(sender, task_id, meta, state) do
      _ = File.rm(abs_path)
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "[router/#{state.company}] path request rejected sender=#{sender} task=#{task_id} reason=#{inspect(reason)}"
        )

        _ =
          state.audit_fun.(state.company, %{
            actor: sender,
            action: "path_access.rejected",
            target: task_id,
            detail: %{reason: inspect(reason), agent: sender}
          })

        _ = File.rm(abs_path)
        :ok
    end
  end

  defp require_path_request_kind(meta) do
    case Map.get(meta, "kind") do
      "path-request/v1" -> :ok
      other -> {:error, {:path_request_bad_kind, other}}
    end
  end

  defp require_path_request_paths(meta) do
    case Map.get(meta, "paths") do
      paths when is_list(paths) and paths != [] -> :ok
      _ -> {:error, :path_request_missing_paths}
    end
  end

  defp require_path_request_reason(meta) do
    case Map.get(meta, "reason") do
      reason when is_binary(reason) and byte_size(reason) >= 10 -> :ok
      _ -> {:error, :path_request_missing_reason}
    end
  end

  # GEP-28 D7 — agent-sourced proposal write via outbox.
  #
  # Two modes dispatched by destination existence:
  #
  #   create: no existing `proposals/<id>.md`. Sender needs
  #     `proposals:propose:*`. Status must be `pending-approval`. Router
  #     stamps `proposed_by: <sender>` (forge-proof — the outbox owner
  #     cannot be spoofed). `approved_by` / `approved_at` / `denial_reason`
  #     / `superseded_by` must all be null.
  #
  #   flip: existing `proposals/<id>.md`. Sender needs
  #     `proposals:decide:*`. New `status ∈ {approved, denied, superseded}`.
  #     `id` / `subtype` / `proposed_by` / `proposed_at` preserved from the
  #     on-disk file. For `approved`/`denied`: sender ≠ existing
  #     `proposed_by` (no self-approval). Router stamps
  #     `approved_by: <sender>` + `approved_at: <now>`.
  #
  # On reject the outbox source is dropped so the agent doesn't retry on
  # the same bad input; a `proposal.rejected` audit records the reason.
  defp handle_outbox_proposal(abs_path, sender, id, state) do
    dest_path = Path.join([state.base, "companies", state.company, "proposals", "#{id}.md"])

    history_meta = %{
      actor: HomeHistory.actor_from_string("agent:" <> sender),
      action: "proposal.route",
      target: "companies/#{state.company}/proposals/#{id}.md"
    }

    history_result =
      Tx.with_tx(history_meta, fn tx_id ->
        # Validation is strict; post-commit cleanup is best-effort. A
        # successful commit must not be re-surfaced as a rejection just
        # because we couldn't clean the outbox source — the proposal is
        # already on disk.
        case validate_outbox_proposal(abs_path, sender, id, dest_path, state) do
          {:ok, final_content, outcome} ->
            :ok = File.mkdir_p(Path.dirname(dest_path))
            :ok = atomic_write(dest_path, final_content)
            :ok = Tx.mark_path(tx_id, dest_path)
            maybe_audit_auto_approve(outcome, sender, id, state)
            :ok = Tx.mark_path(tx_id, HomeHistory.audit_jsonl_path(state.base, state.company))
            cleanup_outbox_source(abs_path, sender, id, state)
            {:ok, :routed}

          {:error, _} = err ->
            err
        end
      end)

    case history_result do
      {:ok, :routed, _tx_id} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[router/#{state.company}] proposal rejected sender=#{sender} id=#{id} reason=#{inspect(reason)}"
        )

        _ =
          state.audit_fun.(state.company, %{
            actor: sender,
            action: "proposal.rejected",
            target: "proposals/#{id}.md",
            detail: %{reason: inspect(reason)}
          })

        _ = File.rm(abs_path)
        :ok
    end
  end

  defp validate_outbox_proposal(abs_path, sender, id, dest_path, state) do
    with {:ok, content} <- read_agent_writable_file(abs_path),
         {:ok, meta, body} <- Frontmatter.parse(content),
         :ok <- require_proposal_kind(meta),
         :ok <- require_proposal_id_match(meta, id),
         :ok <- require_proposal_subtype(meta),
         {:ok, perms} <- lookup_permissions(sender, state),
         {:ok, merged_meta, final_body, outcome} <-
           validate_and_merge_proposal(meta, body, dest_path, sender, perms, state) do
      {:ok, serialize_proposal(merged_meta, final_body), outcome}
    end
  end

  # Post-commit: the proposal is written. If we can't rm the outbox
  # source, log loudly but succeed — otherwise the next file_event
  # would try to replay an already-committed write and emit a bogus
  # rejection audit.
  defp cleanup_outbox_source(abs_path, sender, id, state) do
    case File.rm(abs_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[router/#{state.company}] proposal post-commit rm failed sender=#{sender} id=#{id} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp require_proposal_kind(meta) do
    case Map.get(meta, "kind") do
      "proposal/v1" -> :ok
      other -> {:error, {:proposal_bad_kind, other}}
    end
  end

  defp require_proposal_id_match(meta, id) do
    case Map.get(meta, "id") do
      ^id -> :ok
      other -> {:error, {:proposal_id_mismatch, other, id}}
    end
  end

  defp require_proposal_subtype(meta) do
    case Map.get(meta, "subtype") do
      s when is_binary(s) and byte_size(s) > 0 -> :ok
      _ -> {:error, :proposal_missing_subtype}
    end
  end

  # Dispatch create vs flip by destination existence. Merges in the
  # Router-stamped fields so agents cannot forge `proposed_by` /
  # `approved_by`.
  #
  # Returns `{:ok, merged_meta, body_to_write}` — the flip path
  # preserves the existing body (agents can't rewrite a proposal's
  # rationale when deciding it); the create path uses the incoming
  # body verbatim.
  defp validate_and_merge_proposal(meta, body, dest_path, sender, perms, state) do
    if File.exists?(dest_path) do
      case flip_proposal(meta, dest_path, sender, perms) do
        {:ok, merged, flipped_body} -> {:ok, merged, flipped_body, :flipped}
        other -> other
      end
    else
      create_proposal(meta, body, sender, perms, state)
    end
  end

  defp create_proposal(meta, body, sender, perms, state) do
    with :ok <- ACLMapper.check_action(perms, {"proposals", "propose", "*"}),
         :ok <- require_create_status(meta),
         :ok <- require_nil_approval_fields(meta) do
      stamped =
        meta
        |> Map.put("proposed_by", sender)
        |> Map.put_new_lazy("proposed_at", &iso_now/0)
        |> Map.put("requires_approval", Map.get(meta, "requires_approval", "director"))

      case maybe_auto_approve_hire(stamped, state) do
        {:auto_approved, auto_meta} -> {:ok, auto_meta, body, :auto_approved}
        :no -> {:ok, stamped, body, :created}
      end
    end
  end

  # GEP-28 §Goals #4 — auto-approve a `hire` proposal when the
  # company has room under `headcount_budget`. Any other subtype,
  # no budget, or an over-budget count falls through to Director
  # approval (existing behaviour). Counts CURRENT agents on disk
  # as the source of truth; "+1 for the incoming hire" is implied
  # by treating `current < budget` as the condition, not
  # `current + 1 <= budget` — a proposal that would push you
  # exactly to the budget cap is allowed, a proposal that exceeds
  # it is not. The proposed agent isn't written yet (the proposal
  # is the trigger for the Director to run `glorbo new agent`), so
  # we don't double-count.
  defp maybe_auto_approve_hire(%{"subtype" => "hire"} = meta, state) do
    with {:ok, budget} <- read_headcount_budget(state),
         true <- is_integer(budget) and budget > 0,
         current <- count_current_agents(state),
         true <- current < budget do
      auto_meta =
        meta
        |> Map.put("status", "approved")
        |> Map.put("approved_by", "system/auto-approve-hire")
        |> Map.put("approved_at", iso_now())
        |> Map.put("denial_reason", nil)
        |> Map.put("superseded_by", nil)

      {:auto_approved, auto_meta}
    else
      _ -> :no
    end
  end

  defp maybe_auto_approve_hire(_meta, _state), do: :no

  defp read_headcount_budget(state) do
    path = Path.join([state.base, "companies", state.company, "company.md"])

    case File.read(path) do
      {:ok, content} ->
        case Frontmatter.parse(content) do
          {:ok, meta, _body} -> {:ok, Map.get(meta, "headcount_budget")}
          _ -> {:ok, nil}
        end

      _ ->
        {:ok, nil}
    end
  end

  defp count_current_agents(state) do
    agents_dir = Path.join([state.base, "companies", state.company, "agents"])

    case File.ls(agents_dir) do
      {:ok, entries} ->
        entries
        |> Enum.count(fn entry ->
          File.dir?(Path.join(agents_dir, entry)) and
            File.regular?(Path.join([agents_dir, entry, "AGENT.md"]))
        end)

      _ ->
        0
    end
  end

  defp maybe_audit_auto_approve(:auto_approved, sender, id, state) do
    _ =
      state.audit_fun.(state.company, %{
        actor: "system/auto-approve-hire",
        action: "proposal.auto_approved",
        target: "proposals/#{id}.md",
        detail: %{proposed_by: sender, reason: "within headcount_budget"}
      })

    :ok
  end

  defp maybe_audit_auto_approve(_outcome, _sender, _id, _state), do: :ok

  defp flip_proposal(meta, dest_path, sender, perms) do
    with :ok <- ACLMapper.check_action(perms, {"proposals", "decide", "*"}),
         {:ok, existing_content} <- File.read(dest_path),
         {:ok, existing_meta, existing_body} <- Frontmatter.parse(existing_content),
         {:ok, new_status} <- require_flip_status(meta),
         proposed_by = Map.get(existing_meta, "proposed_by"),
         :ok <- reject_self_approval(new_status, sender, proposed_by) do
      merged =
        existing_meta
        |> Map.put("status", new_status)
        |> put_flip_fields(new_status, sender, meta)

      {:ok, merged, existing_body}
    end
  end

  defp require_create_status(meta) do
    case Map.get(meta, "status") do
      "pending-approval" -> :ok
      other -> {:error, {:proposal_bad_create_status, other}}
    end
  end

  defp require_nil_approval_fields(meta) do
    offenders =
      ["approved_by", "approved_at", "denial_reason", "superseded_by"]
      |> Enum.filter(fn k -> has_nonempty?(meta, k) end)

    case offenders do
      [] -> :ok
      list -> {:error, {:proposal_create_has_approval_fields, list}}
    end
  end

  defp require_flip_status(meta) do
    case Map.get(meta, "status") do
      s when s in ["approved", "denied", "superseded"] -> {:ok, s}
      other -> {:error, {:proposal_bad_flip_status, other}}
    end
  end

  defp reject_self_approval(status, sender, proposed_by)
       when status in ["approved", "denied"] do
    if is_binary(proposed_by) and proposed_by == sender do
      {:error, :proposal_self_approval}
    else
      :ok
    end
  end

  defp reject_self_approval(_status, _sender, _proposed_by), do: :ok

  # Stale-field cleanup on flip: when transitioning into any terminal
  # state, clear fields that belonged to a different terminal state. A
  # `denied` proposal later flipped to `approved` must not carry its
  # old `denial_reason`, and vice versa.
  defp put_flip_fields(meta, "approved", sender, _new_meta) do
    meta
    |> Map.put("approved_by", sender)
    |> Map.put("approved_at", iso_now())
    |> Map.put("denial_reason", nil)
    |> Map.put("superseded_by", nil)
  end

  defp put_flip_fields(meta, "denied", sender, new_meta) do
    meta =
      meta
      |> Map.put("approved_by", sender)
      |> Map.put("approved_at", iso_now())
      |> Map.put("superseded_by", nil)

    case Map.get(new_meta, "denial_reason") do
      r when is_binary(r) and byte_size(r) > 0 -> Map.put(meta, "denial_reason", r)
      _ -> meta
    end
  end

  defp put_flip_fields(meta, "superseded", _sender, new_meta) do
    meta =
      meta
      |> Map.put("approved_by", nil)
      |> Map.put("approved_at", nil)
      |> Map.put("denial_reason", nil)

    case Map.get(new_meta, "superseded_by") do
      sb when is_binary(sb) and byte_size(sb) > 0 -> Map.put(meta, "superseded_by", sb)
      _ -> meta
    end
  end

  defp has_nonempty?(meta, key) do
    case Map.get(meta, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Canonical key order matches `FileSpec.ProposalMd.canonical_key_order/0`;
  # unknown keys land after the canonical set alphabetically for a
  # stable round-trip. Uses `FrontmatterWriter.yaml_scalar/1` so strings
  # with YAML-significant characters are properly quoted (no raw
  # `inspect/1` fallback that could corrupt the file).
  @proposal_key_order ~w(kind id subtype status proposed_by requires_approval proposed_at approved_by approved_at denial_reason superseded_by)
  # Threatmodel T7: agent-supplied proposal keys land verbatim on the
  # left-hand side of YAML `k: v` lines. A crafted key like
  # `"zzz:\nstatus"` serialized raw would produce a second `status`
  # line that overrides the Router-stamped approval field after the
  # file is re-parsed. Filter the extras map to only allow
  # identifier-shaped keys; anything else is silently dropped.
  @proposal_extra_key_re ~r/\A[a-z][a-z0-9_]{0,63}\z/

  defp serialize_proposal(meta, body) do
    canonical = for k <- @proposal_key_order, Map.has_key?(meta, k), do: {k, Map.get(meta, k)}

    extras =
      meta
      |> Map.drop(@proposal_key_order)
      |> Enum.filter(fn {k, _v} ->
        is_binary(k) and Regex.match?(@proposal_extra_key_re, k)
      end)
      |> Enum.sort_by(fn {k, _} -> k end)

    yaml_lines =
      Enum.map_join(canonical ++ extras, "\n", fn {k, v} ->
        "#{k}: #{Glorbo.Filesystem.FrontmatterWriter.yaml_scalar(v)}"
      end)

    body_trimmed = body |> to_string() |> String.trim_leading()

    "---\n#{yaml_lines}\n---\n\n#{body_trimmed}"
    |> ensure_trailing_newline()
  end

  defp ensure_trailing_newline(s) do
    if String.ends_with?(s, "\n"), do: s, else: s <> "\n"
  end

  defp forward_to_path_request_gate(sender, task_id, meta, state) do
    gate_server =
      {:via, Registry,
       {Glorbo.Agent.Registry, {:company_child, state.company, :path_request_gate}}}

    request_meta = %{
      task_id: task_id,
      paths: Map.get(meta, "paths"),
      reason: Map.get(meta, "reason")
    }

    try do
      GenServer.call(gate_server, {:handle_request, sender, request_meta, []})
    catch
      _, _ ->
        {:error, :path_request_gate_unavailable}
    end
  end

  defp check_memory_body_size(content) do
    case byte_size(content) <= @memory_max_bytes do
      true -> :ok
      false -> {:error, {:memory_too_large, byte_size(content), @memory_max_bytes}}
    end
  end

  defp check_memory_kind(meta) do
    case Map.get(meta, "kind") do
      "agent-memory/v1" -> :ok
      other -> {:error, {:memory_bad_kind, other}}
    end
  end

  # Codex L94: YAML mappings/sequences in scalar slots (name,
  # description, type) must be rejected before write — otherwise
  # `to_string/1` raises or `inspect/1` blows up MEMORY.md / the UI.
  @memory_scalar_keys ~w(name description type)

  defp check_memory_scalar_fields(meta) do
    case Enum.find(@memory_scalar_keys, &(not memory_scalar_value_ok?(Map.get(meta, &1)))) do
      nil -> :ok
      key -> {:error, {:memory_non_scalar_field, key}}
    end
  end

  defp memory_scalar_value_ok?(nil), do: true
  defp memory_scalar_value_ok?(value) when is_binary(value), do: true
  defp memory_scalar_value_ok?(_), do: false

  defp check_memory_type_matches_filename(meta, filename) do
    declared = meta |> Map.get("type") |> to_string()

    filename_prefix =
      filename
      |> String.split("_", parts: 2)
      |> List.first()
      |> to_string()

    case declared == filename_prefix do
      true -> :ok
      false -> {:error, {:memory_type_mismatch, declared, filename_prefix}}
    end
  end

  # Write with tmp+rename so a partial write never leaves a
  # half-written memory file for the reader. Wave 24: random
  # suffix + `:file.open([:exclusive])` so the agent-RW
  # `agents/<slug>/memory/` dir can't host a pre-planted
  # symlink at a predictable `<> ".tmp"` name.
  defp atomic_write(dest_path, content) do
    rand_suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp = "#{dest_path}.tmp-#{System.unique_integer([:positive, :monotonic])}-#{rand_suffix}"

    case :file.open(tmp, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :ok = :file.close(fd)

        case result do
          :ok ->
            case File.rename(tmp, dest_path) do
              :ok ->
                :ok

              {:error, reason} ->
                _ = File.rm(tmp)
                {:error, {:rename_failed, reason}}
            end

          {:error, _} = err ->
            _ = File.rm(tmp)
            err
        end

      {:error, _} = err ->
        err
    end
  end

  # threatmodel M03 helpers — delegate to the canonical
  # `Glorbo.Filesystem.AgentWritableFile` seam so every host-side
  # read/write that crosses an agent-writable boundary goes through
  # one lstat-before-touch policy. Local thin wrappers preserve the
  # error shapes each caller site already matches on.
  defp ensure_regular_file_lstat(path) do
    case Glorbo.Filesystem.AgentWritableFile.ensure_writable(path) do
      :ok -> :ok
      {:error, {:not_regular_file, _}} -> {:error, :not_a_regular_file}
      {:error, {:stat_failed, reason}} -> {:error, reason}
    end
  end

  # Atomic exclusive write — refuses to follow symlinks AND fails
  # `{:error, :eexist}` if the path already exists. Closes the
  # TOCTOU race between an `lstat` check and the subsequent write.
  defp exclusive_write(path, content) do
    case :file.open(path, [:write, :raw, :exclusive, :binary]) do
      {:ok, fd} ->
        result = :file.write(fd, content)
        :ok = :file.close(fd)

        case result do
          :ok ->
            :ok

          {:error, reason} ->
            _ = File.rm(path)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_agent_writable_file(path) do
    Glorbo.Filesystem.AgentWritableFile.read(path)
  end

  # Rewrite MEMORY.md: replace an existing line for this filename
  # (matched by the `(filename)` marker in the markdown link), or
  # append a new line at the end. All other lines preserved verbatim.
  #
  # Line format (per GEP-21):
  #   - [<name>](<filename>) — <description>
  #
  # `<name>` and `<description>` come from memory frontmatter;
  # fall back to filename-derived defaults if either is missing.
  defp upsert_memory_index(memory_dir, filename, meta) do
    index_path = Path.join(memory_dir, "MEMORY.md")
    existing = existing_index_lines(index_path)
    new_line = index_line_for(filename, meta)
    match_marker = "(#{filename})"

    updated =
      case Enum.find_index(existing, &String.contains?(&1, match_marker)) do
        nil -> existing ++ [new_line]
        idx -> List.replace_at(existing, idx, new_line)
      end

    atomic_write(index_path, render_memory_index(updated))
  end

  defp render_memory_index(lines) do
    "---\nkind: agent-memory-index/v1\n---\n" <> Enum.join(lines, "\n") <> "\n"
  end

  defp remove_memory_index_line(memory_dir, filename) do
    index_path = Path.join(memory_dir, "MEMORY.md")
    existing = existing_index_lines(index_path)
    match_marker = "(#{filename})"
    filtered = Enum.reject(existing, &String.contains?(&1, match_marker))

    cond do
      filtered == existing ->
        :ok

      filtered == [] ->
        File.rm(index_path)
        |> case do
          :ok -> :ok
          {:error, :enoent} -> :ok
          err -> err
        end

      true ->
        atomic_write(index_path, render_memory_index(filtered))
    end
  end

  defp existing_index_lines(index_path) do
    case File.read(index_path) do
      {:ok, content} ->
        # Skip frontmatter block; only entry lines remain.
        body =
          case Frontmatter.parse(content) do
            {:ok, _fm, body} -> body
            _ -> content
          end

        body
        |> String.split("\n", trim: false)
        |> Enum.reject(&(String.trim(&1) == ""))

      _ ->
        []
    end
  end

  defp index_line_for(filename, meta) do
    name =
      meta
      |> Map.get("name")
      |> memory_index_scalar(filename_default_name(filename))
      |> String.trim()
      |> cap_line(100)

    description =
      meta
      |> Map.get("description")
      |> memory_index_scalar("")
      |> String.trim()
      |> cap_line(120)

    case description do
      "" -> "- [#{name}](#{filename})"
      d -> "- [#{name}](#{filename}) — #{d}"
    end
  end

  defp filename_default_name(filename) do
    filename
    |> Path.rootname(".md")
    |> String.replace("_", " ")
  end

  defp memory_index_scalar(value, _default) when is_binary(value), do: value
  defp memory_index_scalar(nil, default), do: default
  defp memory_index_scalar(_other, default), do: default

  defp cap_line(s, max) do
    case byte_size(s) > max do
      true -> binary_part(s, 0, max) <> "…"
      false -> s
    end
  end

  defp emit_memory_audit(sender, action, filename, bytes, state) do
    state.audit_fun.(state.company, %{
      actor: sender,
      action: action,
      target: "agents/#{sender}/memory/#{filename}",
      detail: %{bytes: bytes}
    })
  rescue
    _ -> :ok
  end

  # Classic message route — requires `to:` frontmatter pointing at a
  # channel or agent slug. Rejected messages land in
  # `history/<msg_id>.rejected.md` per the original pipeline.
  defp handle_outbox_message(abs_path, sender, state) do
    with {:ok, content} <- read_agent_writable_file(abs_path),
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

  # `meta` is always a map here — Frontmatter.parse/1 is specced
  # `{:ok, map(), binary()} | {:error, term()}` and the caller binds it via
  # `{:ok, meta, _} <-`, so a non-map extract_to/1 clause is provably dead.
  defp extract_to(%{} = meta) do
    case Map.get(meta, "to") do
      nil -> {:error, :missing_to}
      to when is_binary(to) and to != "" -> {:ok, to}
      _ -> {:error, :invalid_to}
    end
  end

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
  # #238 — channel rotation (post-append, best-effort)
  # ---------------------------------------------------------------------------

  defp maybe_rotate_channel(path, channel, state) do
    case Glorbo.Chat.Rotation.maybe_rotate(path) do
      {:rotated, archive_path, kept} ->
        state.audit_fun.(state.company, %{
          company: state.company,
          actor: "system",
          action: "channel.rotate",
          target: "channels/#{channel}.md",
          archive_path: archive_path,
          kept_messages: kept
        })

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
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
