defmodule Glorbo.CLI.Dispatcher.Acp.Client do
  @moduledoc """
  ACP (Agent Client Protocol) JSON-RPC client state machine — GEP-45
  Phase 1b sub-slice 1b.3 + 1b.4.

  Drives a single agent dispatch as one ACP conversation:

      initialize → response (protocolVersion + capabilities)
      session/new → response (sessionId)
      session/prompt → … session/update notifications … → response (terminal)
      shutdown → response

  Pure module: no Port spawning, no bwrap composition. The caller
  hands in an `%IO{}` struct with `read` / `write` / `close` callbacks
  and the client drives the conversation through them. Tests inject a
  mock peer (see the unit tests at `test/glorbo/cli/dispatcher/acp/`);
  production wiring (GEP-45 Phase 1b sub-slice 1b.5) wraps a `Port`
  opened via `Glorbo.Sandbox.Bwrap.start_acp/2` in an `%IO{}` and
  reuses the exact same state machine.

  ## Errors

  Every failure maps to one of the categories the existing dispatcher
  uses (matching the spec in GEP-45 §"Dispatcher branch"):

    * `{:provider_protocol_error, reason}` — framing error, unexpected
      message kind, missing required field, response id mismatch, etc.
    * `{:provider_returned_error, %RpcError{}}` — peer responded to a
      request with a JSON-RPC error.
    * `{:provider_timeout, phase}` — `read/1` did not produce a
      complete message before the per-phase deadline expired.

  These flow up through the dispatcher unchanged.

  ## Reply assembly

  `session/update` notifications carry text in
  `params.update.{kind: "agent_message_chunk", text: "…"}` per the ACP
  spec (Zed convention). The client appends every text chunk into a
  single buffer and returns it as `:reply`. Other update kinds are
  counted but not surfaced in v1; future iterations may pass them to
  the audit log.

  ## Per-phase timeout + total deadline

  Each `read` call has a per-phase deadline (`:phase_timeout_ms`,
  default 600s). The streaming phase resets it on every successful
  chunk so a long answer doesn't trip the timer while the peer makes
  progress. Because that per-read timer alone never fires for a
  steadily-chatty peer, an **absolute conversation deadline**
  (`:conversation_timeout_ms`, default 30 min) bounds the whole
  conversation regardless of chunk cadence — once it passes the run
  aborts with `{:provider_timeout, :conversation_deadline}` (C-049).

  ## DoS bounds (untrusted peer)

  ACP stdout is untrusted external-CLI output. Three bounds protect the
  host from a malicious/looping peer:

    * **Reply byte cap** (`:reply_max_bytes`) — accumulated reply bytes
      are checked DURING streaming; exceeding aborts with
      `{:provider_protocol_error, {:reply_too_large, …}}` rather than
      growing BEAM heap until the post-run check (C-049 / D-155 / D-156).
    * **Max-line cap** (`:max_line_bytes`, default 16 MiB) — an
      unterminated (newline-free) stream is rejected via
      `Framing.parse_stream/3` once the buffer exceeds the cap (D-154).
    * **Audit-frame budget** (`:audit_frames_max`, default 5_000) —
      per-frame audit emissions stop past the cap (one
      `meta.audit_truncated` summary is emitted), and peer-controlled
      strings are truncated to 256 bytes, bounding audit-log growth
      (C-044 / C-048).
  """

  alias Glorbo.CLI.Dispatcher.Acp.Framing
  alias Glorbo.CLI.Dispatcher.Acp.Message
  alias Glorbo.CLI.Dispatcher.Acp.RpcError

  defmodule IO do
    @moduledoc """
    Transport seam for the ACP client. The state machine pulls bytes
    via `read.(timeout_ms)` and pushes them via `write.(iodata)`. The
    `close.()` callback runs once the conversation terminates (success
    or failure) so the caller can release the underlying Port.

    `read` returns raw stdout bytes the kernel happens to have
    delivered; the client owns the line buffer via
    `Framing.parse_stream/2` so partial-line reads are fine.
    """
    @type t :: %__MODULE__{
            read: (non_neg_integer() -> {:ok, binary()} | {:error, term()}),
            write: (iodata() -> :ok | {:error, term()}),
            close: (-> :ok)
          }
    @enforce_keys [:read, :write]
    defstruct [:read, :write, close: &__MODULE__.noop_close/0]

    @doc false
    @spec noop_close() :: :ok
    def noop_close, do: :ok
  end

  @default_phase_timeout_ms 600_000
  @default_protocol_version 1

  # Total wall-clock ceiling for one ACP conversation (C-049 / D-155 /
  # D-156). The per-phase read timeout resets on every chunk, so a peer
  # emitting one frame just under the per-read deadline forever never
  # trips it. This absolute deadline — tracked from run start — bounds
  # the whole conversation regardless of how chatty the peer is.
  # Default 30 min; the dispatcher overrides with the agent's
  # `timeout_seconds` via `:conversation_timeout_ms`.
  @default_conversation_timeout_ms 30 * 60 * 1_000

  # Running cap on assembled reply bytes (C-049 / D-155 / D-156).
  # `reply_max_bytes` was previously checked only AFTER the run
  # returned, so an endless `agent_message_chunk` stream could exhaust
  # BEAM memory before the post-hoc check ran. We now accumulate the
  # byte count DURING streaming and abort the moment it is exceeded.
  # Default mirrors the framing line cap (16 MiB); the dispatcher
  # overrides with the provider's `reply_max_bytes` via
  # `:reply_max_bytes`.
  @default_reply_max_bytes 16 * 1024 * 1024

  # Max number of per-frame audit events emitted per dispatch (C-044 /
  # C-048). Beyond this we stop auditing individual frames and emit a
  # single `meta.audit_truncated` summary, so a peer streaming endless
  # notifications cannot inflate the fsync-per-line `_system` audit log.
  @default_audit_frames_max 5_000

  # Max byte length of any peer-controlled string (error message,
  # session_update kind, method) persisted into an audit detail
  # (C-044 / C-048). Truncated before it reaches the audit callback.
  @audit_string_max 256

  @doc false
  @spec noop_audit(atom(), atom(), map()) :: :ok
  def noop_audit(_role, _kind, _detail), do: :ok

  @type ok_result :: %{
          reply: String.t(),
          session_id: String.t() | nil,
          chunks: non_neg_integer(),
          ignored_updates: non_neg_integer()
        }

  @type error_reason ::
          {:provider_protocol_error, term()}
          | {:provider_returned_error, RpcError.t()}
          | {:provider_timeout, atom()}

  @doc """
  Run a single ACP conversation through `io` to deliver `prompt` and
  collect the assembled reply text.

  ## Options

    * `:protocol_version` (integer, default `1`) — sent in the
      initialize params; the peer's response is compared for parity
      and a mismatch becomes `:provider_protocol_error`.
    * `:client_info` (map, default `%{name: "glorbo", version: "1"}`)
      — passed through in initialize params.
    * `:phase_timeout_ms` (integer, default 600_000) — read deadline
      for each phase. Streaming phase resets the deadline on every
      chunk.
    * `:conversation_timeout_ms` (integer, default 1_800_000) —
      absolute wall-clock ceiling for the whole conversation,
      independent of the per-read reset (C-049).
    * `:reply_max_bytes` (integer, default 16 MiB) — running cap on
      assembled reply bytes; checked during streaming (C-049).
    * `:max_line_bytes` (integer, default 16 MiB) — cap on an
      unterminated stdout line / buffer remainder (D-154).
    * `:audit_frames_max` (integer, default 5_000) — per-dispatch cap
      on per-frame audit emissions (C-044 / C-048).
    * `:audit_fun` (`(role, kind, detail -> :ok)`, default no-op) —
      callback invoked for every protocol-level event so the
      dispatcher can persist a replayable trace. Roles: `:client`
      (we sent), `:peer` (we received), `:meta` (start/complete/
      error). Kinds match the ACP method names plus `:start` /
      `:complete` / `:error` bookends.
  """
  @spec run(IO.t(), String.t(), keyword()) ::
          {:ok, ok_result()} | {:error, error_reason()}
  def run(%IO{} = io, prompt, opts \\ []) when is_binary(prompt) do
    raw_audit_fun = Keyword.get(opts, :audit_fun, &__MODULE__.noop_audit/3)

    conversation_timeout_ms =
      Keyword.get(opts, :conversation_timeout_ms, @default_conversation_timeout_ms)

    state = %{
      io: io,
      buffer: "",
      pending: [],
      next_id: 1,
      phase_timeout_ms: Keyword.get(opts, :phase_timeout_ms, @default_phase_timeout_ms),
      protocol_version: Keyword.get(opts, :protocol_version, @default_protocol_version),
      client_info: Keyword.get(opts, :client_info, %{"name" => "glorbo", "version" => "1"}),
      session_id: nil,
      reply: [],
      reply_bytes: 0,
      reply_max_bytes: Keyword.get(opts, :reply_max_bytes, @default_reply_max_bytes),
      max_line_bytes: Keyword.get(opts, :max_line_bytes, Framing.default_max_line_bytes()),
      chunks: 0,
      ignored_updates: 0,
      tool_summary: nil,
      resume_session_id: Keyword.get(opts, :resume_session_id),
      # C-049: absolute monotonic deadline for the whole conversation.
      deadline_mono: System.monotonic_time(:millisecond) + conversation_timeout_ms,
      # C-044 / C-048: per-dispatch audit-frame budget + truncation.
      # The counter ref is dispatch-local mutable state so the
      # side-effect-only audit helpers don't need to thread state.
      audit_frames_max: Keyword.get(opts, :audit_frames_max, @default_audit_frames_max),
      audit_frame_counter: :counters.new(1, [:atomics])
    }

    # Wrap the caller's audit callback so the per-frame cap + string
    # truncation apply uniformly to every emission. `:meta` bookends
    # (start/complete/error/audit_truncated) always pass through; only
    # peer/client per-frame events count against the budget.
    audit_fun = fn role, kind, detail ->
      audit_with_budget(state, raw_audit_fun, role, kind, detail)
    end

    state = Map.put(state, :audit_fun, audit_fun)

    audit_fun.(:meta, :dispatch_start, %{prompt_size: byte_size(prompt)})

    result =
      with {:ok, state} <- phase_initialize(state),
           {:ok, state} <- phase_session_new(state),
           {:ok, state} <- phase_session_prompt(state, prompt),
           {:ok, state} <- phase_shutdown(state) do
        reply_text = state.reply |> Enum.reverse() |> Elixir.IO.iodata_to_binary()

        reply_text =
          if reply_text == "" and not is_nil(state.tool_summary) do
            synthesize_tool_summary_reply(state.tool_summary)
          else
            reply_text
          end

        ok = %{
          reply: reply_text,
          session_id: state.session_id,
          chunks: state.chunks,
          ignored_updates: state.ignored_updates
        }

        audit_fun.(:meta, :dispatch_complete, %{
          session_id: state.session_id,
          chunks: state.chunks,
          ignored_updates: state.ignored_updates,
          reply_size: byte_size(ok.reply)
        })

        {:ok, ok}
      end

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> audit_fun.(:meta, :dispatch_error, %{reason: inspect(reason)})
    end

    _ = io.close.()
    result
  end

  # ---------- phases ----------

  defp phase_initialize(state) do
    {id, state} = take_id(state)

    request =
      Message.new_request(id, "initialize", %{
        "protocolVersion" => state.protocol_version,
        "clientCapabilities" => %{},
        "clientInfo" => state.client_info
      })

    with :ok <- send_message(state, request),
         {:ok, msg, state} <- await_response(state, id, :initialize) do
      classify_initialize_response(msg, id, state)
    end
  end

  defp classify_initialize_response(
         {:response, id, %{"protocolVersion" => v} = _result},
         id,
         state
       ) do
    if v == state.protocol_version do
      {:ok, state}
    else
      {:error,
       {:provider_protocol_error,
        "protocolVersion mismatch: client=#{state.protocol_version} server=#{inspect(v)}"}}
    end
  end

  defp classify_initialize_response({:response, id, _other}, id, _state) do
    {:error, {:provider_protocol_error, "initialize response missing protocolVersion"}}
  end

  defp classify_initialize_response({:error_response, id, %RpcError{} = err}, id, _state) do
    {:error, {:provider_returned_error, err}}
  end

  defp phase_session_new(state) do
    {id, state} = take_id(state)

    # F6: stado v0.46.0 supports session resume via
    # `session/new {"resumeSession": "<UUID>"}`. When the caller passed
    # a prior session id (typically read from the per-task session
    # file by the dispatcher), thread it through so the agent picks
    # up the prior worktree + reasoning context. Without resume the
    # agent rebuilds context from scratch on every phase.
    params =
      case state.resume_session_id do
        nil -> %{}
        "" -> %{}
        sid when is_binary(sid) -> %{"resumeSession" => sid}
      end

    request = Message.new_request(id, "session/new", params)

    with :ok <- send_message(state, request),
         {:ok, msg, state} <- await_response(state, id, :session_new) do
      classify_session_new_response(msg, id, state)
    end
  end

  defp classify_session_new_response({:response, id, %{"sessionId" => sid}}, id, state)
       when is_binary(sid) do
    {:ok, %{state | session_id: sid}}
  end

  defp classify_session_new_response({:response, id, _other}, id, _state) do
    {:error, {:provider_protocol_error, "session/new response missing sessionId"}}
  end

  defp classify_session_new_response({:error_response, id, %RpcError{} = err}, id, _state) do
    {:error, {:provider_returned_error, err}}
  end

  defp phase_session_prompt(state, prompt) do
    {id, state} = take_id(state)

    request =
      Message.new_request(id, "session/prompt", %{
        "sessionId" => state.session_id,
        "prompt" => prompt
      })

    with :ok <- send_message(state, request) do
      drain_session_prompt(state, id)
    end
  end

  defp drain_session_prompt(state, prompt_id) do
    case next_message(state, :session_prompt) do
      # F7: stado v0.46.0 emits session/update kind=approval and blocks
      # the turn until session/approval_response arrives. In headless
      # dispatch we always auto-deny (allow=false, cancelled=false).
      # Both wrapped and unwrapped wire shapes occur; intercept before
      # absorb_update so the approval doesn't get silently counted as
      # an ignored update.
      {:ok, {:notification, "session/update", %{"kind" => "approval", "requestId" => req_id}},
       state} ->
        with {:ok, state} <- send_approval_response(state, req_id) do
          drain_session_prompt(state, prompt_id)
        end

      {:ok,
       {:notification, "session/update",
        %{"update" => %{"kind" => "approval", "requestId" => req_id}}}, state} ->
        with {:ok, state} <- send_approval_response(state, req_id) do
          drain_session_prompt(state, prompt_id)
        end

      # F5: kind=choice events follow the same blocking-on-response
      # pattern as approval. Headless dispatch always cancels — no
      # operator to surface choices to. Surfacing choices to a real
      # UI is a future GEP. We intentionally don't include a choice
      # index in the response: cancelled=true is the unambiguous
      # signal that no option was selected.
      {:ok, {:notification, "session/update", %{"kind" => "choice", "requestId" => req_id}},
       state} ->
        with {:ok, state} <- send_choice_response(state, req_id) do
          drain_session_prompt(state, prompt_id)
        end

      {:ok,
       {:notification, "session/update",
        %{"update" => %{"kind" => "choice", "requestId" => req_id}}}, state} ->
        with {:ok, state} <- send_choice_response(state, req_id) do
          drain_session_prompt(state, prompt_id)
        end

      {:ok, {:notification, "session/update", params}, state} ->
        case absorb_update(state, params) do
          {:ok, state} -> drain_session_prompt(state, prompt_id)
          {:error, _} = err -> err
        end

      {:ok, {:notification, _other_method, _params}, state} ->
        drain_session_prompt(%{state | ignored_updates: state.ignored_updates + 1}, prompt_id)

      {:ok, {:response, ^prompt_id, _result}, state} ->
        {:ok, state}

      {:ok, {:error_response, ^prompt_id, %RpcError{} = err}, _state} ->
        {:error, {:provider_returned_error, err}}

      {:ok, {:response, other_id, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "unexpected response id during prompt: got #{inspect(other_id)} expected #{inspect(prompt_id)}"}}

      {:ok, {:error_response, other_id, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "unexpected error response id during prompt: got #{inspect(other_id)} expected #{inspect(prompt_id)}"}}

      {:ok, {:request, _, _, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "peer sent a request mid-prompt; bidirectional ACP not yet supported"}}

      {:error, _} = err ->
        err
    end
  end

  defp phase_shutdown(state) do
    {id, state} = take_id(state)
    request = Message.new_request(id, "shutdown", %{})

    case send_message(state, request) do
      :ok ->
        # Best-effort drain. A peer that hangs up before responding is
        # acceptable — we already have the reply.
        case await_response(state, id, :shutdown) do
          {:ok, _msg, state} -> {:ok, state}
          {:error, {:provider_timeout, :shutdown}} -> {:ok, state}
          {:error, {:provider_protocol_error, {:eof_in_phase, :shutdown}}} -> {:ok, state}
          {:error, _} = err -> err
        end

      {:error, _} ->
        # If we can't even write the shutdown frame the peer is
        # probably gone — still report success since we have the
        # reply and the parent will collect the bwrap process anyway.
        {:ok, state}
    end
  end

  # ---------- update absorption ----------

  defp absorb_update(state, %{"update" => %{"kind" => "agent_message_chunk", "text" => text}})
       when is_binary(text) do
    append_chunk(state, text)
  end

  # Some ACP variants surface the chunk fields at the top of params
  # rather than nested under "update". Accept both shapes; other update
  # kinds (tool calls, status changes) are counted but not extracted.
  defp absorb_update(state, %{"kind" => "agent_message_chunk", "text" => text})
       when is_binary(text) do
    append_chunk(state, text)
  end

  # stado uses kind="text" for text delta events (stado internal/acp/server.go:200).
  defp absorb_update(state, %{"kind" => "text", "text" => text})
       when is_binary(text) do
    append_chunk(state, text)
  end

  defp absorb_update(state, %{"update" => %{"kind" => "text", "text" => text}})
       when is_binary(text) do
    append_chunk(state, text)
  end

  # F9: stado v0.46.0 emits kind=tool_summary on any turn with ≥1 tool
  # call but 0 text deltas. Capture the latest one so result-assembly
  # can synthesize a non-empty reply when no text chunks arrived. Wire
  # format (camelCase): {kind: "tool_summary", toolCount: N,
  # lastTool: "shell__bash", lastError: bool}. Both wrapped and
  # unwrapped shapes appear on the wire.
  defp absorb_update(state, %{"update" => %{"kind" => "tool_summary"} = summary}) do
    {:ok, %{state | tool_summary: summary}}
  end

  defp absorb_update(state, %{"kind" => "tool_summary"} = summary) do
    {:ok, %{state | tool_summary: summary}}
  end

  defp absorb_update(state, _other_params) do
    {:ok, %{state | ignored_updates: state.ignored_updates + 1}}
  end

  # Append one text chunk to the reply, enforcing the running reply-byte
  # cap DURING streaming (C-049 / D-155 / D-156). Aborting here — rather
  # than after the whole conversation drains — bounds BEAM heap and
  # terminates a peer that emits an endless `agent_message_chunk`
  # stream. `reply_too_large` is reported under `:provider_protocol_error`
  # so the dispatcher's existing error handling surfaces it.
  defp append_chunk(state, text) when is_binary(text) do
    new_bytes = state.reply_bytes + byte_size(text)

    if new_bytes > state.reply_max_bytes do
      {:error,
       {:provider_protocol_error, {:reply_too_large, new_bytes, state.reply_max_bytes}}}
    else
      {:ok,
       %{
         state
         | reply: [text | state.reply],
           reply_bytes: new_bytes,
           chunks: state.chunks + 1
       }}
    end
  end

  defp synthesize_tool_summary_reply(summary) when is_map(summary) do
    count = Map.get(summary, "toolCount", 0)
    last_tool = Map.get(summary, "lastTool", "?")
    status = if Map.get(summary, "lastError", false), do: "error", else: "ok"
    "[#{count} tool call(s); last=#{last_tool}; #{status}]"
  end

  # F7: auto-deny ACP approval requests in headless dispatch. Sent as
  # a JSON-RPC notification (no id, no expected response) per the
  # stado v0.46.0 wire contract.
  defp send_approval_response(state, request_id) do
    notification =
      Message.new_notification("session/approval_response", %{
        "sessionId" => state.session_id,
        "requestId" => request_id,
        "allow" => false,
        "cancelled" => false
      })

    case send_message(state, notification) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  # F5: auto-cancel ACP choice prompts in headless dispatch. Sent as
  # a notification (no id). No choice index is included; cancelled=
  # true is the unambiguous signal that the agent should treat the
  # choice as withdrawn.
  defp send_choice_response(state, request_id) do
    notification =
      Message.new_notification("session/choice_response", %{
        "sessionId" => state.session_id,
        "requestId" => request_id,
        "cancelled" => true
      })

    case send_message(state, notification) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  # ---------- transport plumbing ----------

  defp send_message(state, msg) do
    iodata = Framing.encode(msg)
    audit_outbound(state, msg, Elixir.IO.iodata_length(iodata))

    case state.io.write.(iodata) do
      :ok -> :ok
      {:error, reason} -> {:error, {:provider_protocol_error, {:write_failed, reason}}}
    end
  end

  defp audit_outbound(state, {:request, id, method, _params}, byte_size) do
    state.audit_fun.(:client, :request, %{id: id, method: method, byte_size: byte_size})
  end

  defp audit_outbound(state, {:notification, method, _params}, byte_size) do
    state.audit_fun.(:client, :notification, %{method: method, byte_size: byte_size})
  end

  defp audit_outbound(state, {:response, id, _result}, byte_size) do
    state.audit_fun.(:client, :response, %{id: id, byte_size: byte_size})
  end

  defp audit_outbound(state, {:error_response, id, %RpcError{code: code}}, byte_size) do
    state.audit_fun.(:client, :error_response, %{id: id, code: code, byte_size: byte_size})
  end

  # `await_response/3` drains messages until one with the matching
  # request id arrives. Notifications during the init/session_new/
  # shutdown phases are dropped silently — only the streaming phase
  # surfaces them.
  defp await_response(state, expected_id, phase) do
    case next_message(state, phase) do
      {:ok, {:response, ^expected_id, _} = msg, state} ->
        {:ok, msg, state}

      {:ok, {:error_response, ^expected_id, _} = msg, state} ->
        {:ok, msg, state}

      {:ok, {:notification, _, _}, state} ->
        await_response(state, expected_id, phase)

      {:ok, {:response, other, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "response id mismatch in #{phase}: got #{inspect(other)} expected #{inspect(expected_id)}"}}

      {:ok, {:error_response, other, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "error response id mismatch in #{phase}: got #{inspect(other)} expected #{inspect(expected_id)}"}}

      {:ok, {:request, _, _, _}, _state} ->
        {:error,
         {:provider_protocol_error,
          "peer sent unsolicited request during #{phase}; not supported in v1"}}

      {:error, _} = err ->
        err
    end
  end

  # Pull the next message. Tries the parsed-pending queue first; if
  # empty, reads bytes from the IO seam and parses them via
  # `Framing.parse_stream/2`.
  defp next_message(%{pending: [head | tail]} = state, phase) do
    case head do
      {:ok, msg} ->
        audit_inbound(state, msg)
        {:ok, msg, %{state | pending: tail}}

      {:error, reason} ->
        {:error, {:provider_protocol_error, {:parse_failed, phase, reason}}}
    end
  end

  defp next_message(%{pending: []} = state, phase) do
    # C-049: bound each read by whichever is smaller — the per-phase
    # timeout or the time left on the absolute conversation deadline.
    # Once the conversation deadline passes, abort regardless of how
    # recently the peer sent a chunk (the per-read timeout alone resets
    # on every chunk and never fires for a steadily-chatty peer).
    case read_timeout(state) do
      {:expired, _} ->
        {:error, {:provider_timeout, :conversation_deadline}}

      {:ok, timeout_ms} ->
        do_next_read(state, phase, timeout_ms)
    end
  end

  defp do_next_read(state, phase, timeout_ms) do
    case state.io.read.(timeout_ms) do
      {:ok, ""} ->
        # Port closed (peer hung up). Before reporting EOF, do a
        # non-blocking drain of any final bytes the peer wrote
        # immediately before closing — for stado in particular, a
        # `MaxTurns`-exhaustion error response and the port close
        # arrive back-to-back, and depending on receive ordering the
        # error frame may still be in our buffer / mailbox at this
        # point. Surface that frame instead of the generic eof so
        # the caller sees `:provider_returned_error` rather than
        # `:eof_in_phase` (TODO B7).
        case final_drain(state, phase) do
          {:ok, state} -> next_message(state, phase)
          {:error, _} = err -> err
          :exhausted -> {:error, {:provider_protocol_error, {:eof_in_phase, phase}}}
        end

      {:ok, chunk} when is_binary(chunk) ->
        # D-154: cap the unterminated-line remainder so a peer that
        # streams bytes without ever sending `\n` can't grow the
        # buffer without bound.
        case Framing.parse_stream(state.buffer, chunk, state.max_line_bytes) do
          {:error, {:line_too_large, _} = reason} ->
            {:error, {:provider_protocol_error, reason}}

          {parsed, remainder} ->
            state = %{state | buffer: remainder, pending: parsed}
            next_message(state, phase)
        end

      {:error, :timeout} ->
        # Same defensive drain on timeout — covers the rare case where
        # the peer's final write arrived between the receive's after
        # firing and us reporting the timeout (TODO B7).
        case final_drain(state, phase) do
          {:ok, state} -> next_message(state, phase)
          {:error, _} = err -> err
          :exhausted -> {:error, {:provider_timeout, phase}}
        end

      {:error, reason} ->
        {:error, {:provider_protocol_error, {:read_failed, reason}}}
    end
  end

  # Non-blocking drain after EOF/timeout. Polls the IO seam once with
  # zero timeout to grab any final bytes still in the kernel pipe /
  # BEAM mailbox, parses them into the pending queue, and returns
  # `{:ok, state}` if anything was harvested. Returns `:exhausted`
  # when truly nothing more is available.
  defp final_drain(state, _phase) do
    case state.io.read.(0) do
      {:ok, ""} ->
        :exhausted

      {:ok, chunk} when is_binary(chunk) and byte_size(chunk) > 0 ->
        case Framing.parse_stream(state.buffer, chunk, state.max_line_bytes) do
          {:error, {:line_too_large, _} = reason} ->
            {:error, {:provider_protocol_error, reason}}

          {parsed, remainder} ->
            {:ok, %{state | buffer: remainder, pending: parsed}}
        end

      _ ->
        :exhausted
    end
  end

  # ---------- audit budget + truncation (C-044 / C-048) ----------

  # Gate every audit emission through a per-dispatch frame budget and
  # truncate peer-controlled strings. `:meta` bookends
  # (start/complete/error/audit_truncated) always pass through and do
  # not count against the budget — they are Glorbo-generated, bounded,
  # and one-shot. Per-frame `:client`/`:peer` events count: once the
  # cap is hit we stop emitting them and emit a single
  # `meta.audit_truncated` summary instead, preventing a peer that
  # streams endless notifications from inflating the fsync-per-line
  # `_system` audit log (and exhausting disk).
  defp audit_with_budget(_state, raw_audit_fun, :meta, kind, detail) do
    raw_audit_fun.(:meta, kind, truncate_detail(detail))
  end

  defp audit_with_budget(state, raw_audit_fun, role, kind, detail) do
    counter = state.audit_frame_counter
    :counters.add(counter, 1, 1)
    count = :counters.get(counter, 1)

    cond do
      count <= state.audit_frames_max ->
        raw_audit_fun.(role, kind, truncate_detail(detail))

      count == state.audit_frames_max + 1 ->
        # First frame past the cap: emit one summary, then go silent.
        raw_audit_fun.(:meta, :audit_truncated, %{
          frame_cap: state.audit_frames_max,
          note: "per-frame ACP audit suppressed beyond cap"
        })

      true ->
        :ok
    end
  end

  # Truncate any binary value in an audit detail map to a sane max so a
  # peer-controlled error message / kind / method can't write an
  # oversized line to the audit log (C-044 / C-048).
  defp truncate_detail(detail) when is_map(detail) do
    Map.new(detail, fn
      {k, v} when is_binary(v) -> {k, truncate_string(v)}
      kv -> kv
    end)
  end

  defp truncate_detail(detail), do: detail

  defp truncate_string(s) when is_binary(s) do
    if byte_size(s) > @audit_string_max do
      binary_part(s, 0, @audit_string_max) <> "…[truncated]"
    else
      s
    end
  end

  # ---------- audit helpers (inbound) ----------

  defp audit_inbound(state, {:response, id, _result}) do
    state.audit_fun.(:peer, :response, %{id: id})
  end

  defp audit_inbound(state, {:error_response, id, %RpcError{code: code, message: m}}) do
    state.audit_fun.(:peer, :error_response, %{id: id, code: code, message: m})
  end

  defp audit_inbound(state, {:notification, "session/update", params}) do
    {kind, text_size} = update_summary(params)
    state.audit_fun.(:peer, :session_update, %{kind: kind, text_size: text_size})
  end

  defp audit_inbound(state, {:notification, method, _params}) do
    state.audit_fun.(:peer, :notification, %{method: method})
  end

  defp audit_inbound(state, {:request, id, method, _params}) do
    state.audit_fun.(:peer, :request, %{id: id, method: method})
  end

  defp update_summary(%{"update" => %{"kind" => kind, "text" => text}}) when is_binary(text),
    do: {kind, byte_size(text)}

  defp update_summary(%{"kind" => kind, "text" => text}) when is_binary(text),
    do: {kind, byte_size(text)}

  defp update_summary(%{"update" => %{"kind" => kind}}), do: {kind, 0}
  defp update_summary(%{"kind" => kind}), do: {kind, 0}
  defp update_summary(_), do: {"unknown", 0}

  # ---------- helpers ----------

  defp take_id(state), do: {state.next_id, %{state | next_id: state.next_id + 1}}

  # C-049: compute the read timeout as the smaller of the per-phase
  # timeout and the time remaining on the absolute conversation
  # deadline. `{:expired, _}` when the deadline has already passed.
  defp read_timeout(state) do
    remaining = state.deadline_mono - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:expired, remaining}
    else
      {:ok, min(state.phase_timeout_ms, remaining)}
    end
  end
end
