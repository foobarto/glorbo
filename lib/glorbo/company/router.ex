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

  **Dep-injected `fs_fun` map** — tests swap `write!`, `rename!`,
  `mkdir_p!`, `exists?`, `open_append!` for mocks. Production default is a
  map of `File` module functions.
  """
  use GenServer
  require Logger

  alias Glorbo.Company.AuditLog
  alias Glorbo.Security.ACLMapper

  @mention_regex ~r/@([a-z][a-z0-9_-]{0,63})/
  @broadcast_unsupported {:error, {:invalid_message, :broadcast_unsupported}}

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
    state = %{
      company: Keyword.fetch!(opts, :company),
      base: Keyword.get(opts, :base, Path.expand("~/.glorbo")),
      audit_fun: Keyword.get(opts, :audit_fun, &AuditLog.append/2),
      fs_fun: Keyword.get(opts, :fs_fun, default_fs_fun())
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:route, msg}, _from, state) do
    result = do_route(msg, state)
    {:reply, result, state}
  end

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
  defp perform_routing({:chat, channel}, msg, state) do
    channel_path =
      Path.join([state.base, "companies", state.company, "channels", "#{channel}.md"])

    dir = Path.dirname(channel_path)
    state.fs_fun.mkdir_p!.(dir)
    append_line!(state.fs_fun, channel_path, msg.body)
    :ok
  rescue
    e ->
      Logger.error("router channel write failed: #{Exception.message(e)}")
      {:error, {:invalid_message, :write_failed}}
  end

  # Agent-inbox routing: write-once file under inbox/from-<sender>/<ts>-<msg_id>.md.
  defp perform_routing({:agent, target_slug}, msg, state) do
    ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

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
    delivered_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
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

  defp try_write_mention(mentioned, channel, msg, state) do
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
      ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
      path = Path.join(inbox_mentions, "#{ts}-#{channel}.md")

      frontmatter = """
      ---
      channel: "#{channel}"
      from: "#{msg.sender}"
      source_msg: "#{msg.msg_id}"
      delivered_at: "#{DateTime.utc_now() |> DateTime.to_iso8601()}"
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
