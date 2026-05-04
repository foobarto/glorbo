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
end
