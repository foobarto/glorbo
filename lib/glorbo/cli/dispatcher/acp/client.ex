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

  ## Per-phase timeout

  Each `read` call has a deadline. Default 30s per phase; override via
  `:phase_timeout_ms` opt. The streaming phase resets the deadline on
  every successful chunk so a long answer doesn't trip the timer as
  long as the peer is making progress.
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
    audit_fun = Keyword.get(opts, :audit_fun, &__MODULE__.noop_audit/3)

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
      chunks: 0,
      ignored_updates: 0,
      audit_fun: audit_fun
    }

    audit_fun.(:meta, :dispatch_start, %{prompt_size: byte_size(prompt)})

    result =
      with {:ok, state} <- phase_initialize(state),
           {:ok, state} <- phase_session_new(state),
           {:ok, state} <- phase_session_prompt(state, prompt),
           {:ok, state} <- phase_shutdown(state) do
        ok = %{
          reply: state.reply |> Enum.reverse() |> Elixir.IO.iodata_to_binary(),
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
    request = Message.new_request(id, "session/new", %{})

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
      {:ok, {:notification, "session/update", params}, state} ->
        state = absorb_update(state, params)
        drain_session_prompt(state, prompt_id)

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
    %{state | reply: [text | state.reply], chunks: state.chunks + 1}
  end

  # Some ACP variants surface the chunk fields at the top of params
  # rather than nested under "update". Accept both shapes; other update
  # kinds (tool calls, status changes) are counted but not extracted.
  defp absorb_update(state, %{"kind" => "agent_message_chunk", "text" => text})
       when is_binary(text) do
    %{state | reply: [text | state.reply], chunks: state.chunks + 1}
  end

  # stado uses kind="text" for text delta events (stado internal/acp/server.go:200).
  defp absorb_update(state, %{"kind" => "text", "text" => text})
       when is_binary(text) do
    %{state | reply: [text | state.reply], chunks: state.chunks + 1}
  end

  defp absorb_update(state, %{"update" => %{"kind" => "text", "text" => text}})
       when is_binary(text) do
    %{state | reply: [text | state.reply], chunks: state.chunks + 1}
  end

  defp absorb_update(state, _other_params) do
    %{state | ignored_updates: state.ignored_updates + 1}
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
    case state.io.read.(state.phase_timeout_ms) do
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
          :exhausted -> {:error, {:provider_protocol_error, {:eof_in_phase, phase}}}
        end

      {:ok, chunk} when is_binary(chunk) ->
        {parsed, remainder} = Framing.parse_stream(state.buffer, chunk)
        state = %{state | buffer: remainder, pending: parsed}
        next_message(state, phase)

      {:error, :timeout} ->
        # Same defensive drain on timeout — covers the rare case where
        # the peer's final write arrived between the receive's after
        # firing and us reporting the timeout (TODO B7).
        case final_drain(state, phase) do
          {:ok, state} -> next_message(state, phase)
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
        {parsed, remainder} = Framing.parse_stream(state.buffer, chunk)
        {:ok, %{state | buffer: remainder, pending: parsed}}

      _ ->
        :exhausted
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
end
