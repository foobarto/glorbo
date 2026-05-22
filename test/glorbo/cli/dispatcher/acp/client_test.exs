defmodule Glorbo.CLI.Dispatcher.Acp.ClientTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Dispatcher.Acp.Client
  alias Glorbo.CLI.Dispatcher.Acp.Framing
  alias Glorbo.CLI.Dispatcher.Acp.Message

  # ----- mock peer helpers -----
  #
  # The mock peer is a tiny Agent that holds:
  #   * `:script` — list of canned responder functions, each receiving
  #     the most recent inbound request and returning a list of
  #     outbound iodata frames the client should see next.
  #   * `:inbound` — bytes the client wrote, in order. Tests assert
  #     the conversation shape against this.
  #   * `:outbound` — pending bytes for the client to read; the read
  #     callback drains a chunk on demand.
  #
  # The IO struct's `write` callback runs the next responder against
  # the just-written request and appends its output to outbound.
  # `read` returns whatever's queued (and waits if nothing is yet —
  # though in practice every test pre-queues responses through write).

  defp start_peer(script) when is_list(script) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{script: script, inbound: [], outbound: ""}
      end)

    agent
  end

  defp peer_io(agent) do
    %Client.IO{
      write: fn iodata ->
        bytes = IO.iodata_to_binary(iodata)

        Agent.update(agent, fn st ->
          st = %{st | inbound: st.inbound ++ [bytes]}
          drive_script(st, bytes)
        end)

        :ok
      end,
      read: fn _timeout_ms ->
        Agent.get_and_update(agent, fn st ->
          {{:ok, st.outbound}, %{st | outbound: ""}}
        end)
      end,
      close: fn -> :ok end
    }
  end

  defp drive_script(%{script: []} = st, _bytes), do: st

  defp drive_script(%{script: [responder | rest]} = st, bytes) do
    {:ok, msg} = Framing.decode_message(bytes)
    frames = responder.(msg)
    out_bytes = Enum.map_join(frames, "", &IO.iodata_to_binary/1)
    %{st | script: rest, outbound: st.outbound <> out_bytes}
  end

  defp peer_inbound(agent) do
    Agent.get(agent, & &1.inbound)
    |> Enum.map(fn raw ->
      {:ok, msg} = Framing.decode_message(raw)
      msg
    end)
  end

  # ----- canned responder builders -----

  defp init_response_to({:request, id, "initialize", %{"protocolVersion" => v}}) do
    [
      Framing.encode(
        Message.new_response(id, %{
          "protocolVersion" => v,
          "agentCapabilities" => %{},
          "agentInfo" => %{"name" => "mock-stado", "version" => "0.1"}
        })
      )
    ]
  end

  defp session_new_response_to({:request, id, "session/new", %{}}) do
    [Framing.encode(Message.new_response(id, %{"sessionId" => "s-mock-1"}))]
  end

  defp prompt_with_chunks_then_done(chunks) do
    fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
      update_frames =
        Enum.map(chunks, fn text ->
          Framing.encode(
            Message.new_notification("session/update", %{
              "sessionId" => sid,
              "update" => %{"kind" => "agent_message_chunk", "text" => text}
            })
          )
        end)

      done_frame = Framing.encode(Message.new_response(id, %{"stopReason" => "end_turn"}))
      update_frames ++ [done_frame]
    end
  end

  defp shutdown_response_to({:request, id, "shutdown", _}) do
    [Framing.encode(Message.new_response(id, %{}))]
  end

  # ----- happy path -----

  describe "run/3 happy path" do
    test "initialize → session/new → prompt → drain chunks → shutdown" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done(["hello, ", "world", "!"]),
          &shutdown_response_to/1
        ])

      assert {:ok, result} = Client.run(peer_io(agent), "say hi")

      assert result.reply == "hello, world!"
      assert result.session_id == "s-mock-1"
      assert result.chunks == 3
      assert result.ignored_updates == 0

      msgs = peer_inbound(agent)

      assert [
               {:request, 1, "initialize", _},
               {:request, 2, "session/new", _},
               {:request, 3, "session/prompt",
                %{"sessionId" => "s-mock-1", "prompt" => "say hi"}},
               {:request, 4, "shutdown", _}
             ] = msgs
    end

    test "increments chunks counter, surfaces session_id, and ignores non-text updates" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
            chunk1 =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{"kind" => "agent_message_chunk", "text" => "A"}
                })
              )

            tool_call =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{"kind" => "tool_call", "name" => "shell", "args" => %{}}
                })
              )

            chunk2 =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{"kind" => "agent_message_chunk", "text" => "B"}
                })
              )

            done = Framing.encode(Message.new_response(id, %{"stopReason" => "end_turn"}))
            [chunk1, tool_call, chunk2, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, result} = Client.run(peer_io(agent), "x")
      assert result.reply == "AB"
      assert result.chunks == 2
      assert result.ignored_updates == 1
    end

    test "tolerates the flatter chunk shape (kind+text at top of params)" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
            chunk =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "kind" => "agent_message_chunk",
                  "text" => "flat"
                })
              )

            done = Framing.encode(Message.new_response(id, %{}))
            [chunk, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "flat", chunks: 1}} = Client.run(peer_io(agent), "x")
    end

    test "tolerates a peer that hangs up after the prompt response (no shutdown reply)" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done(["ok"]),
          # Peer ignores the shutdown frame entirely.
          fn _shutdown_req -> [] end
        ])

      # phase_timeout_ms low so the test doesn't sleep 30s.
      assert {:ok, %{reply: "ok"}} =
               Client.run(peer_io(agent), "x", phase_timeout_ms: 100)
    end

    # F9: stado v0.46.0 emits kind=tool_summary on tool-only turns.
    test "synthesizes reply from wrapped kind=tool_summary when no text chunks arrived" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
            summary =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{
                    "kind" => "tool_summary",
                    "toolCount" => 5,
                    "lastTool" => "shell__bash",
                    "lastError" => false
                  }
                })
              )

            done = Framing.encode(Message.new_response(id, %{"stopReason" => "end_turn"}))
            [summary, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, result} = Client.run(peer_io(agent), "x")
      assert result.reply == "[5 tool call(s); last=shell__bash; ok]"
      assert result.chunks == 0
    end

    test "synthesizes reply from unwrapped kind=tool_summary with lastError=true" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
            summary =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "kind" => "tool_summary",
                  "toolCount" => 1,
                  "lastTool" => "shell__bash",
                  "lastError" => true
                })
              )

            done = Framing.encode(Message.new_response(id, %{}))
            [summary, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "[1 tool call(s); last=shell__bash; error]"}} =
               Client.run(peer_io(agent), "x")
    end

    test "text chunks win over tool_summary when both arrive" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", %{"sessionId" => sid}} ->
            summary =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{
                    "kind" => "tool_summary",
                    "toolCount" => 2,
                    "lastTool" => "shell__bash",
                    "lastError" => false
                  }
                })
              )

            chunk =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{"kind" => "agent_message_chunk", "text" => "real reply"}
                })
              )

            done = Framing.encode(Message.new_response(id, %{}))
            [summary, chunk, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "real reply", chunks: 1}} = Client.run(peer_io(agent), "x")
    end

    # F7: stado v0.46.0 emits kind=approval and waits for session/
    # approval_response. In headless dispatch we always auto-deny.
    test "auto-denies wrapped kind=approval and continues draining" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, _id, "session/prompt", %{"sessionId" => sid}} ->
            approval =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{
                    "kind" => "approval",
                    "requestId" => "req-uuid-1",
                    "title" => "Allow shell.bash?",
                    "body" => "rm -rf /tmp"
                  }
                })
              )

            [approval]
          end,
          fn {:notification, "session/approval_response", _params} ->
            chunk =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => "s-mock-1",
                  "update" => %{
                    "kind" => "agent_message_chunk",
                    "text" => "approved-and-continued"
                  }
                })
              )

            # session/prompt was request id 3 (init=1, session/new=2, prompt=3).
            done = Framing.encode(Message.new_response(3, %{}))
            [chunk, done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "approved-and-continued"}} = Client.run(peer_io(agent), "x")

      assert Enum.any?(peer_inbound(agent), fn
               {:notification, "session/approval_response",
                %{
                  "sessionId" => "s-mock-1",
                  "requestId" => "req-uuid-1",
                  "allow" => false,
                  "cancelled" => false
                }} ->
                 true

               _ ->
                 false
             end),
             "glorbo did not send session/approval_response"
    end

    # F6: stado v0.46.0 supports session resume via resumeSession.
    test "passes resumeSession in session/new params when :resume_session_id opt set" do
      agent =
        start_peer([
          &init_response_to/1,
          fn {:request, id, "session/new", params} ->
            assert params == %{"resumeSession" => "prior-uuid-abc"},
                   "session/new params should carry resumeSession"

            [Framing.encode(Message.new_response(id, %{"sessionId" => "prior-uuid-abc"}))]
          end,
          prompt_with_chunks_then_done(["resumed"]),
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "resumed", session_id: "prior-uuid-abc"}} =
               Client.run(peer_io(agent), "x", resume_session_id: "prior-uuid-abc")
    end

    test "session/new params is empty map when :resume_session_id is nil/absent" do
      agent =
        start_peer([
          &init_response_to/1,
          fn {:request, id, "session/new", params} ->
            assert params == %{}, "session/new params should be empty when no resume"
            [Framing.encode(Message.new_response(id, %{"sessionId" => "fresh-1"}))]
          end,
          prompt_with_chunks_then_done(["fresh"]),
          &shutdown_response_to/1
        ])

      assert {:ok, %{session_id: "fresh-1"}} = Client.run(peer_io(agent), "x")
    end

    test "auto-denies unwrapped kind=approval (top-of-params shape)" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, _id, "session/prompt", %{"sessionId" => sid}} ->
            # Unwrapped: kind/requestId at the top of params.
            approval =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "kind" => "approval",
                  "requestId" => "req-uuid-2",
                  "title" => "Allow file write?",
                  "body" => "/etc/passwd"
                })
              )

            [approval]
          end,
          fn {:notification, "session/approval_response", _params} ->
            done = Framing.encode(Message.new_response(3, %{}))
            [done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: ""}} = Client.run(peer_io(agent), "x")

      assert Enum.any?(peer_inbound(agent), fn
               {:notification, "session/approval_response",
                %{"requestId" => "req-uuid-2", "allow" => false, "cancelled" => false}} ->
                 true

               _ ->
                 false
             end)
    end

    # F5: kind=choice handling — same pattern as F7, headless cancels.
    test "auto-cancels wrapped kind=choice and continues draining" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, _id, "session/prompt", %{"sessionId" => sid}} ->
            choice =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "update" => %{
                    "kind" => "choice",
                    "requestId" => "choice-uuid-1",
                    "title" => "Pick a target",
                    "options" => ["10.0.0.1", "10.0.0.2"]
                  }
                })
              )

            [choice]
          end,
          fn {:notification, "session/choice_response", _params} ->
            done = Framing.encode(Message.new_response(3, %{}))
            [done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: ""}} = Client.run(peer_io(agent), "x")

      assert Enum.any?(peer_inbound(agent), fn
               {:notification, "session/choice_response",
                %{
                  "sessionId" => "s-mock-1",
                  "requestId" => "choice-uuid-1",
                  "cancelled" => true
                }} ->
                 true

               _ ->
                 false
             end),
             "glorbo did not send session/choice_response"
    end

    test "auto-cancels unwrapped kind=choice (top-of-params shape)" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, _id, "session/prompt", %{"sessionId" => sid}} ->
            choice =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => sid,
                  "kind" => "choice",
                  "requestId" => "choice-uuid-2",
                  "options" => ["a", "b"]
                })
              )

            [choice]
          end,
          fn {:notification, "session/choice_response", _params} ->
            done = Framing.encode(Message.new_response(3, %{}))
            [done]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, _} = Client.run(peer_io(agent), "x")

      assert Enum.any?(peer_inbound(agent), fn
               {:notification, "session/choice_response",
                %{"requestId" => "choice-uuid-2", "cancelled" => true}} ->
                 true

               _ ->
                 false
             end)
    end
  end

  # ----- error paths -----

  describe "run/3 error paths" do
    test "initialize: protocolVersion mismatch becomes :provider_protocol_error" do
      agent =
        start_peer([
          fn {:request, id, "initialize", _} ->
            [Framing.encode(Message.new_response(id, %{"protocolVersion" => 99}))]
          end
        ])

      assert {:error, {:provider_protocol_error, msg}} = Client.run(peer_io(agent), "x")
      assert msg =~ "protocolVersion mismatch"
    end

    test "initialize: missing protocolVersion field becomes :provider_protocol_error" do
      agent =
        start_peer([
          fn {:request, id, "initialize", _} ->
            [Framing.encode(Message.new_response(id, %{"agentCapabilities" => %{}}))]
          end
        ])

      assert {:error, {:provider_protocol_error, msg}} = Client.run(peer_io(agent), "x")
      assert msg =~ "missing protocolVersion"
    end

    test "initialize: peer returns JSON-RPC error → :provider_returned_error" do
      agent =
        start_peer([
          fn {:request, id, "initialize", _} ->
            [
              Framing.encode(
                Message.new_error_response(
                  id,
                  Message.invalid_request_code(),
                  "no such protocol"
                )
              )
            ]
          end
        ])

      assert {:error, {:provider_returned_error, %{code: -32_600, message: "no such protocol"}}} =
               Client.run(peer_io(agent), "x")
    end

    test "session/new: missing sessionId → :provider_protocol_error" do
      agent =
        start_peer([
          &init_response_to/1,
          fn {:request, id, "session/new", _} ->
            [Framing.encode(Message.new_response(id, %{"unrelated" => true}))]
          end
        ])

      assert {:error, {:provider_protocol_error, msg}} = Client.run(peer_io(agent), "x")
      assert msg =~ "session/new response missing sessionId"
    end

    test "session/prompt: peer error response → :provider_returned_error" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", _} ->
            [
              Framing.encode(
                Message.new_error_response(
                  id,
                  Message.internal_error_code(),
                  "model unavailable"
                )
              )
            ]
          end
        ])

      assert {:error, {:provider_returned_error, %{code: -32_603, message: "model unavailable"}}} =
               Client.run(peer_io(agent), "x")
    end

    test "session/prompt: response id mismatch → :provider_protocol_error" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, _id, "session/prompt", _} ->
            # Reply with id 999 — does not match the request id (3).
            [Framing.encode(Message.new_response(999, %{}))]
          end
        ])

      assert {:error, {:provider_protocol_error, msg}} = Client.run(peer_io(agent), "x")
      assert msg =~ "unexpected response id during prompt"
    end

    test "read returns :timeout → {:provider_timeout, phase}" do
      io = %Client.IO{
        write: fn _ -> :ok end,
        read: fn _ -> {:error, :timeout} end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_timeout, :initialize}} = Client.run(io, "x")
    end

    test "read returns transport error → :provider_protocol_error{:read_failed, …}" do
      io = %Client.IO{
        write: fn _ -> :ok end,
        read: fn _ -> {:error, :broken_pipe} end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_protocol_error, {:read_failed, :broken_pipe}}} =
               Client.run(io, "x")
    end

    test "write fails → :provider_protocol_error{:write_failed, …}" do
      io = %Client.IO{
        write: fn _ -> {:error, :epipe} end,
        read: fn _ -> {:ok, ""} end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_protocol_error, {:write_failed, :epipe}}} =
               Client.run(io, "x")
    end

    test "EOF during initialize → :provider_protocol_error{:eof_in_phase, …}" do
      io = %Client.IO{
        write: fn _ -> :ok end,
        # Empty string is the canonical EOF signal in our IO contract.
        read: fn _ -> {:ok, ""} end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_protocol_error, {:eof_in_phase, :initialize}}} =
               Client.run(io, "x")
    end

    test "garbage bytes from peer → :provider_protocol_error{:parse_failed, …}" do
      garbage_agent =
        Agent.start_link(fn -> %{outbound: "{not json}\n", inbound: []} end)

      {:ok, garbage_pid} = garbage_agent

      io = %Client.IO{
        write: fn iodata ->
          Agent.update(garbage_pid, fn st ->
            %{st | inbound: st.inbound ++ [IO.iodata_to_binary(iodata)]}
          end)

          :ok
        end,
        read: fn _ ->
          Agent.get_and_update(garbage_pid, fn st ->
            {{:ok, st.outbound}, %{st | outbound: ""}}
          end)
        end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_protocol_error, {:parse_failed, :initialize, {:json_parse, _}}}} =
               Client.run(io, "x")
    end
  end

  # ----- audit emission (GEP-45 Phase 3) -----

  describe "audit_fun emission" do
    setup do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      audit_fun = fn role, kind, detail ->
        Agent.update(agent, fn list -> [{role, kind, detail} | list] end)
        :ok
      end

      {:ok, audit_agent: agent, audit_fun: audit_fun}
    end

    defp audit_log(agent), do: Agent.get(agent, fn list -> Enum.reverse(list) end)

    test "happy path emits dispatch_start, request/response per phase, session_update per chunk, dispatch_complete",
         %{audit_agent: agent, audit_fun: audit_fun} do
      mock =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done(["Hi ", "there"]),
          &shutdown_response_to/1
        ])

      assert {:ok, _} = Client.run(peer_io(mock), "say hi", audit_fun: audit_fun)

      log = audit_log(agent)

      # Bookends.
      assert {:meta, :dispatch_start, %{prompt_size: 6}} = List.first(log)
      assert {:meta, :dispatch_complete, summary} = List.last(log)
      assert summary.session_id == "s-mock-1"
      assert summary.chunks == 2
      assert summary.reply_size == byte_size("Hi there")

      # 4 outbound requests (initialize, session/new, session/prompt, shutdown).
      client_methods =
        for {:client, :request, %{method: m}} <- log, do: m

      assert client_methods == ["initialize", "session/new", "session/prompt", "shutdown"]

      # 4 peer responses matching those request ids.
      peer_responses =
        for {:peer, :response, %{id: id}} <- log, do: id

      assert peer_responses == [1, 2, 3, 4]

      # 2 session/update events with text_size capturing the chunk payload.
      updates = for {:peer, :session_update, detail} <- log, do: detail
      assert length(updates) == 2

      assert Enum.all?(updates, fn d -> d.kind == "agent_message_chunk" end)
      assert Enum.map(updates, & &1.text_size) == [3, 5]
    end

    test "peer JSON-RPC error emits :peer.error_response and :meta.dispatch_error",
         %{audit_agent: agent, audit_fun: audit_fun} do
      mock =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", _} ->
            [
              Framing.encode(
                Message.new_error_response(
                  id,
                  Message.internal_error_code(),
                  "no provider configured"
                )
              )
            ]
          end
        ])

      assert {:error, {:provider_returned_error, _}} =
               Client.run(peer_io(mock), "x", audit_fun: audit_fun)

      log = audit_log(agent)

      # Inbound error_response captured with code + message.
      assert {:peer, :error_response, %{id: 3, code: -32_603, message: "no provider configured"}} =
               Enum.find(log, fn
                 {:peer, :error_response, _} -> true
                 _ -> false
               end)

      # Final meta event records the failure shape.
      assert {:meta, :dispatch_error, %{reason: reason}} = List.last(log)
      assert reason =~ "provider_returned_error"
    end
  end

  # ----- partial-line / multi-frame chunking -----

  describe "transport chunk handling" do
    test "drains multiple frames delivered in one read" do
      # The session/new response and the first prompt update arrive in
      # the same kernel chunk. The state machine should consume them
      # one at a time.
      agent =
        start_peer([
          &init_response_to/1,
          fn {:request, id, "session/new", _} ->
            # Prepare the session/new response AND the first prompt
            # update in the same outbound chunk; the prompt update
            # actually depends on the next request being sent, so we
            # emit only session/new here. The next responder fires
            # when the prompt request lands.
            [Framing.encode(Message.new_response(id, %{"sessionId" => "sx"}))]
          end,
          fn {:request, id, "session/prompt", _} ->
            chunk =
              Framing.encode(
                Message.new_notification("session/update", %{
                  "sessionId" => "sx",
                  "update" => %{"kind" => "agent_message_chunk", "text" => "merged"}
                })
              )

            done = Framing.encode(Message.new_response(id, %{}))

            # Combine into one outbound binary: the IO.read callback
            # returns the whole concatenation in a single read.
            combined = IO.iodata_to_binary(chunk) <> IO.iodata_to_binary(done)
            [combined]
          end,
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "merged"}} = Client.run(peer_io(agent), "x")
    end
  end

  # ----- DoS caps (C-049 / D-154 / D-155 / D-156 / C-044 / C-048) -----

  describe "reply byte cap (C-049 / D-155 / D-156)" do
    test "aborts mid-stream with :reply_too_large once accumulated chunks exceed reply_max_bytes" do
      # Two 600-byte chunks against a 1000-byte cap: the second pushes
      # the running total over the cap and must abort DURING streaming,
      # not after the whole conversation drains.
      big = String.duplicate("a", 600)

      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done([big, big]),
          &shutdown_response_to/1
        ])

      assert {:error, {:provider_protocol_error, {:reply_too_large, total, 1000}}} =
               Client.run(peer_io(agent), "x", reply_max_bytes: 1000)

      assert total > 1000
    end

    test "reply within the cap succeeds" do
      agent =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done(["short"]),
          &shutdown_response_to/1
        ])

      assert {:ok, %{reply: "short"}} = Client.run(peer_io(agent), "x", reply_max_bytes: 1000)
    end
  end

  describe "conversation wall-clock deadline (C-049)" do
    test "aborts with {:provider_timeout, :conversation_deadline} when the total deadline passes" do
      # A peer that always returns a valid session/update notification
      # on every read — never a terminal response. With per-read timeout
      # alone this loops forever; the absolute conversation deadline must
      # terminate it.
      {:ok, phase} = Agent.start_link(fn -> :init end)

      io = %Client.IO{
        write: fn iodata ->
          {:ok, msg} = Framing.decode_message(IO.iodata_to_binary(iodata))

          case msg do
            {:request, _id, "initialize", _} -> Agent.update(phase, fn _ -> :init_done end)
            {:request, _id, "session/new", _} -> Agent.update(phase, fn _ -> :session_done end)
            {:request, _id, "session/prompt", _} -> Agent.update(phase, fn _ -> :prompting end)
            _ -> :ok
          end

          :ok
        end,
        read: fn _timeout ->
          case Agent.get(phase, & &1) do
            :init_done ->
              {:ok,
               IO.iodata_to_binary(
                 Framing.encode(
                   Message.new_response(1, %{"protocolVersion" => 1, "agentCapabilities" => %{}})
                 )
               )}

            :session_done ->
              {:ok,
               IO.iodata_to_binary(
                 Framing.encode(Message.new_response(2, %{"sessionId" => "s"}))
               )}

            :prompting ->
              # Endless stream of valid (non-terminal) notifications,
              # one per read — never the terminal prompt response.
              {:ok,
               IO.iodata_to_binary(
                 Framing.encode(
                   Message.new_notification("session/update", %{
                     "sessionId" => "s",
                     "update" => %{"kind" => "status", "state" => "thinking"}
                   })
                 )
               )}

            _ ->
              {:ok, ""}
          end
        end,
        close: fn -> :ok end
      }

      # 50 ms conversation budget, 10 s per-read timeout (so the per-read
      # timer alone would never fire). Must abort on the conversation
      # deadline well before that.
      assert {:error, {:provider_timeout, :conversation_deadline}} =
               Client.run(io, "x", conversation_timeout_ms: 50, phase_timeout_ms: 10_000)
    end
  end

  describe "unbounded buffer cap (D-154 wired through client)" do
    test "aborts with :line_too_large when peer streams bytes without a newline" do
      # Peer that drives init+session, then on the prompt read returns a
      # large newline-free chunk that exceeds the client max_line_bytes.
      {:ok, phase} = Agent.start_link(fn -> :init end)

      io = %Client.IO{
        write: fn iodata ->
          {:ok, msg} = Framing.decode_message(IO.iodata_to_binary(iodata))

          case msg do
            {:request, _id, "initialize", _} -> Agent.update(phase, fn _ -> :init_done end)
            {:request, _id, "session/new", _} -> Agent.update(phase, fn _ -> :session_done end)
            {:request, _id, "session/prompt", _} -> Agent.update(phase, fn _ -> :prompting end)
            _ -> :ok
          end

          :ok
        end,
        read: fn _timeout ->
          case Agent.get(phase, & &1) do
            :init_done ->
              {:ok,
               IO.iodata_to_binary(
                 Framing.encode(
                   Message.new_response(1, %{"protocolVersion" => 1, "agentCapabilities" => %{}})
                 )
               )}

            :session_done ->
              {:ok,
               IO.iodata_to_binary(Framing.encode(Message.new_response(2, %{"sessionId" => "s"})))}

            :prompting ->
              # 200 newline-free bytes against a 100-byte cap.
              {:ok, String.duplicate("x", 200)}

            _ ->
              {:ok, ""}
          end
        end,
        close: fn -> :ok end
      }

      assert {:error, {:provider_protocol_error, {:line_too_large, _}}} =
               Client.run(io, "x", max_line_bytes: 100, phase_timeout_ms: 5_000)
    end
  end

  describe "audit frame cap + string truncation (C-044 / C-048)" do
    test "stops per-frame auditing past the cap and emits one audit_truncated summary" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      audit_fun = fn role, kind, detail ->
        Agent.update(agent, fn list -> [{role, kind, detail} | list] end)
        :ok
      end

      # 40 text chunks; cap per-frame audits at 5. The peer-frame audits
      # (request/response/session_update) get suppressed past the cap.
      chunks = for i <- 1..40, do: "c#{i}"

      mock =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          prompt_with_chunks_then_done(chunks),
          &shutdown_response_to/1
        ])

      assert {:ok, _} =
               Client.run(peer_io(mock), "x", audit_fun: audit_fun, audit_frames_max: 5)

      log = Agent.get(agent, fn list -> Enum.reverse(list) end)

      # Per-frame (:client / :peer) events must be capped at 5.
      frame_events = Enum.filter(log, fn {role, _, _} -> role in [:client, :peer] end)
      assert length(frame_events) == 5

      # Exactly one truncation summary emitted.
      truncations = Enum.filter(log, fn {role, kind, _} -> role == :meta and kind == :audit_truncated end)
      assert length(truncations) == 1

      # :meta bookends still pass through (not counted against the cap).
      assert Enum.any?(log, fn {role, kind, _} -> role == :meta and kind == :dispatch_start end)
      assert Enum.any?(log, fn {role, kind, _} -> role == :meta and kind == :dispatch_complete end)
    end

    test "truncates an oversized peer-controlled error message in the audit detail" do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      audit_fun = fn role, kind, detail ->
        Agent.update(agent, fn list -> [{role, kind, detail} | list] end)
        :ok
      end

      huge_message = String.duplicate("E", 5_000)

      mock =
        start_peer([
          &init_response_to/1,
          &session_new_response_to/1,
          fn {:request, id, "session/prompt", _} ->
            [
              Framing.encode(Message.new_error_response(id, -32000, huge_message))
            ]
          end
        ])

      assert {:error, {:provider_returned_error, _}} =
               Client.run(peer_io(mock), "x", audit_fun: audit_fun)

      log = Agent.get(agent, fn list -> Enum.reverse(list) end)

      err_event =
        Enum.find(log, fn {role, kind, _} -> role == :peer and kind == :error_response end)

      assert {:peer, :error_response, %{message: m}} = err_event
      # Truncated well below the original 5000 bytes.
      assert byte_size(m) < 300
      assert String.ends_with?(m, "…[truncated]")
    end
  end
end
