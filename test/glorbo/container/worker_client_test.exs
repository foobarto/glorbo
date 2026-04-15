defmodule Glorbo.Container.WorkerClientTest do
  use ExUnit.Case, async: true

  alias Glorbo.Container.WorkerClient

  @base "/tmp/glorbo-worker-client-test"

  describe "post_run/4" do
    test "builds a POST request to /run over the company's Unix socket" do
      capture = :counters.new(1, [])

      request_fun = fn req, sock, _timeout ->
        send(self(), {:captured_request, req, sock})
        :counters.add(capture, 1, 1)
        {:ok, %{"ok" => true}}
      end

      body = %{task_path: "/company/agents/ceo/inbox/task.md"}

      assert {:ok, %{"ok" => true}} =
               WorkerClient.post_run("acme", "ceo", body,
                 base: @base,
                 request_fun: request_fun
               )

      assert_received {:captured_request, req, sock}
      assert sock == Path.join([@base, "runtime", "sockets", "acme", "ceo.sock"])
      # Finch request struct carries the path; smoke-check it routes to /run.
      assert req.path == "/run"
      assert req.method == "POST"
      assert :counters.get(capture, 1) == 1
    end
  end

  describe "post_cancel/4" do
    test "POSTs /cancel with a request_id body" do
      request_fun = fn req, _sock, _timeout ->
        send(self(), {:captured_request, req})
        {:ok, %{"ok" => true, "cancelled" => true}}
      end

      assert {:ok, %{"cancelled" => true}} =
               WorkerClient.post_cancel("acme", "ceo", "req-123",
                 base: @base,
                 request_fun: request_fun
               )

      assert_received {:captured_request, req}
      assert req.path == "/cancel"
      # Body is encoded JSON — decode to verify shape.
      decoded = Jason.decode!(req.body)
      assert decoded == %{"request_id" => "req-123"}
    end
  end

  describe "retry-connect backoff (D-39)" do
    test "retries on econnrefused until a non-retryable result arrives" do
      attempts = :counters.new(1, [])

      request_fun = fn _req, _sock, _timeout ->
        n = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if n < 2 do
          {:error, %Mint.TransportError{reason: :econnrefused}}
        else
          {:ok, %{"ok" => true, "attempt" => n}}
        end
      end

      assert {:ok, %{"attempt" => 2}} =
               WorkerClient.post_run("acme", "ceo", %{},
                 base: @base,
                 request_fun: request_fun
               )

      # 2 retries + final success = 3 calls.
      assert :counters.get(attempts, 1) == 3
    end

    test "retries on enoent (socket not yet created) then succeeds" do
      attempts = :counters.new(1, [])

      request_fun = fn _req, _sock, _timeout ->
        n = :counters.get(attempts, 1)
        :counters.add(attempts, 1, 1)

        if n < 1 do
          {:error, %Mint.TransportError{reason: :enoent}}
        else
          {:ok, %{"ok" => true}}
        end
      end

      assert {:ok, %{"ok" => true}} =
               WorkerClient.post_run("acme", "ceo", %{},
                 base: @base,
                 request_fun: request_fun
               )

      assert :counters.get(attempts, 1) == 2
    end

    test "returns non-retryable errors without further retries" do
      attempts = :counters.new(1, [])

      request_fun = fn _req, _sock, _timeout ->
        :counters.add(attempts, 1, 1)
        {:error, {:http_status, 500, "boom"}}
      end

      assert {:error, {:http_status, 500, "boom"}} =
               WorkerClient.post_run("acme", "ceo", %{},
                 base: @base,
                 request_fun: request_fun
               )

      assert :counters.get(attempts, 1) == 1
    end
  end
end
