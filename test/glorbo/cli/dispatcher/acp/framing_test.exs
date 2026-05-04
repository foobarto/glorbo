defmodule Glorbo.CLI.Dispatcher.Acp.FramingTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Dispatcher.Acp.Framing
  alias Glorbo.CLI.Dispatcher.Acp.Message
  alias Glorbo.CLI.Dispatcher.Acp.RpcError

  describe "encode/1" do
    test "request — emits jsonrpc + id + method + params, terminated by \\n" do
      msg = Message.new_request(1, "session/prompt", %{"sessionId" => "s-1", "prompt" => "hi"})
      bytes = msg |> Framing.encode() |> IO.iodata_to_binary()

      assert String.ends_with?(bytes, "\n")

      decoded = bytes |> String.trim_trailing("\n") |> Jason.decode!()
      assert decoded["jsonrpc"] == "2.0"
      assert decoded["id"] == 1
      assert decoded["method"] == "session/prompt"
      assert decoded["params"] == %{"sessionId" => "s-1", "prompt" => "hi"}
    end

    test "request without params drops the field rather than sending null" do
      msg = Message.new_request(7, "shutdown")
      bytes = msg |> Framing.encode() |> IO.iodata_to_binary()

      decoded = bytes |> String.trim_trailing("\n") |> Jason.decode!()
      refute Map.has_key?(decoded, "params")
    end

    test "notification — no id field" do
      msg = Message.new_notification("session/cancel", %{"sessionId" => "s-1"})
      bytes = msg |> Framing.encode() |> IO.iodata_to_binary()

      decoded = bytes |> String.trim_trailing("\n") |> Jason.decode!()
      refute Map.has_key?(decoded, "id")
      assert decoded["method"] == "session/cancel"
    end

    test "response — id + result, no error" do
      msg = Message.new_response(2, %{"sessionId" => "s-1"})
      bytes = msg |> Framing.encode() |> IO.iodata_to_binary()

      decoded = bytes |> String.trim_trailing("\n") |> Jason.decode!()
      assert decoded["id"] == 2
      assert decoded["result"] == %{"sessionId" => "s-1"}
      refute Map.has_key?(decoded, "error")
    end

    test "error_response — id + error.code + error.message, no result" do
      msg = Message.new_error_response(3, Message.invalid_params_code(), "bad shape")
      bytes = msg |> Framing.encode() |> IO.iodata_to_binary()

      decoded = bytes |> String.trim_trailing("\n") |> Jason.decode!()
      assert decoded["id"] == 3
      refute Map.has_key?(decoded, "result")
      assert decoded["error"]["code"] == -32_602
      assert decoded["error"]["message"] == "bad shape"
      refute Map.has_key?(decoded["error"], "data")
    end
  end

  describe "decode_message/1" do
    test "round-trips a request" do
      original = Message.new_request(1, "initialize", %{"protocolVersion" => 1})

      assert {:ok, decoded} =
               original |> Framing.encode() |> IO.iodata_to_binary() |> Framing.decode_message()

      # params come back as string-keyed maps after JSON round-trip
      assert decoded == {:request, 1, "initialize", %{"protocolVersion" => 1}}
    end

    test "round-trips a notification" do
      original = Message.new_notification("session/update", %{"sessionId" => "s-1", "kind" => "text", "text" => "hello"})

      assert {:ok, decoded} =
               original |> Framing.encode() |> IO.iodata_to_binary() |> Framing.decode_message()

      assert decoded ==
               {:notification, "session/update",
                %{"sessionId" => "s-1", "kind" => "text", "text" => "hello"}}
    end

    test "round-trips a successful response" do
      original = Message.new_response(2, %{"text" => "answer"})

      assert {:ok, decoded} =
               original |> Framing.encode() |> IO.iodata_to_binary() |> Framing.decode_message()

      assert decoded == {:response, 2, %{"text" => "answer"}}
    end

    test "round-trips an error response" do
      original = Message.new_error_response(3, Message.method_not_found_code(), "no such method")

      assert {:ok, {:error_response, 3, %RpcError{} = err}} =
               original |> Framing.encode() |> IO.iodata_to_binary() |> Framing.decode_message()

      assert err.code == -32_601
      assert err.message == "no such method"
    end

    test "accepts a line with or without trailing newline" do
      original = Message.new_response(4, nil)
      raw = original |> Framing.encode() |> IO.iodata_to_binary()

      assert {:ok, msg} = Framing.decode_message(raw)
      assert {:ok, ^msg} = Framing.decode_message(String.trim_trailing(raw, "\n"))
    end

    test "rejects empty / whitespace-only lines" do
      assert {:error, :empty} = Framing.decode_message("")
      assert {:error, :empty} = Framing.decode_message("   \n")
      assert {:error, :empty} = Framing.decode_message("\n\n")
    end

    test "reports json parse errors with a structured tag" do
      assert {:error, {:json_parse, _}} = Framing.decode_message("{not json}")
    end

    test "rejects wrong jsonrpc version" do
      bad = Jason.encode!(%{"jsonrpc" => "1.0", "id" => 1, "method" => "x"})
      assert {:error, {:invalid, _msg}} = Framing.decode_message(bad)
    end

    test "rejects message with neither method nor result/error" do
      bad = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1})
      assert {:error, {:invalid, _msg}} = Framing.decode_message(bad)
    end

    test "rejects malformed error object" do
      bad = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "error" => %{"only_message" => "x"}})
      assert {:error, {:invalid, _msg}} = Framing.decode_message(bad)
    end
  end

  describe "parse_stream/2" do
    test "splits multiple complete lines into separate messages" do
      m1 = Message.new_request(1, "initialize") |> Framing.encode() |> IO.iodata_to_binary()
      m2 = Message.new_notification("session/update", %{"k" => "v"}) |> Framing.encode() |> IO.iodata_to_binary()
      m3 = Message.new_response(1, %{}) |> Framing.encode() |> IO.iodata_to_binary()

      chunk = m1 <> m2 <> m3

      assert {messages, ""} = Framing.parse_stream("", chunk)
      assert length(messages) == 3
      assert match?({:ok, {:request, 1, "initialize", _}}, Enum.at(messages, 0))
      assert match?({:ok, {:notification, "session/update", _}}, Enum.at(messages, 1))
      assert match?({:ok, {:response, 1, _}}, Enum.at(messages, 2))
    end

    test "keeps partial line as remainder for next chunk" do
      raw = Message.new_request(1, "initialize") |> Framing.encode() |> IO.iodata_to_binary()
      mid = byte_size(raw) - 5
      <<first::binary-size(mid), rest::binary>> = raw

      assert {[], remainder} = Framing.parse_stream("", first)
      assert remainder == first

      # Continue with the rest — now the line completes.
      assert {[{:ok, {:request, 1, "initialize", _}}], ""} =
               Framing.parse_stream(remainder, rest)
    end

    test "drops empty lines silently" do
      m = Message.new_response(1, nil) |> Framing.encode() |> IO.iodata_to_binary()
      chunk = "\n\n" <> m <> "\n"

      assert {[{:ok, {:response, 1, nil}}], ""} = Framing.parse_stream("", chunk)
    end

    test "yields error tuples for malformed lines without dropping surrounding good ones" do
      good1 = Message.new_response(1, nil) |> Framing.encode() |> IO.iodata_to_binary()
      good2 = Message.new_response(2, nil) |> Framing.encode() |> IO.iodata_to_binary()
      bad = "{garbage}\n"

      assert {messages, ""} = Framing.parse_stream("", good1 <> bad <> good2)
      assert length(messages) == 3
      assert {:ok, {:response, 1, nil}} = Enum.at(messages, 0)
      assert {:error, {:json_parse, _}} = Enum.at(messages, 1)
      assert {:ok, {:response, 2, nil}} = Enum.at(messages, 2)
    end

    test "remainder accumulates across multiple partial reads" do
      raw = Message.new_request(42, "session/prompt", %{"sessionId" => "s"}) |> Framing.encode() |> IO.iodata_to_binary()

      # Split into 3 chunks
      {a, rest1} = String.split_at(raw, 5)
      {b, c} = String.split_at(rest1, 5)

      {[], rem1} = Framing.parse_stream("", a)
      {[], rem2} = Framing.parse_stream(rem1, b)
      {messages, ""} = Framing.parse_stream(rem2, c)

      assert [{:ok, {:request, 42, "session/prompt", %{"sessionId" => "s"}}}] = messages
    end
  end
end
