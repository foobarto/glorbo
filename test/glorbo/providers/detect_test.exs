defmodule Glorbo.Providers.DetectTest do
  use ExUnit.Case, async: true

  alias Glorbo.Providers.Detect

  defp candidate(overrides \\ %{}) do
    Map.merge(
      %{
        alias: "llamacpp",
        endpoint: "http://127.0.0.1:8080",
        shape: :openai,
        path: "/v1/models",
        fingerprint: :llamacpp
      },
      overrides
    )
  end

  defp ok_response(body, headers \\ %{}) do
    {:ok, %{status: 200, body: body, headers: headers}}
  end

  describe "run/1 — happy paths" do
    test "ollama fingerprint via /api/tags shape" do
      body = Jason.encode!(%{"models" => [%{"name" => "llama3:latest"}]})
      request_fun = fn _ -> ok_response(body) end

      [detection] =
        Detect.run(
          candidates: [
            candidate(%{alias: "ollama", shape: :ollama, path: "/api/tags", fingerprint: :ollama})
          ],
          request_fun: request_fun
        )

      assert detection.alias == "ollama"
      assert detection.status == :ready
    end

    test "llama.cpp fingerprint via Server header" do
      body = Jason.encode!(%{"data" => []})
      request_fun = fn _ -> ok_response(body, %{"server" => "llama.cpp"}) end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.alias == "llamacpp"
      assert detection.status == :ready
    end

    test "vllm fingerprint via uvicorn Server header" do
      body = Jason.encode!(%{"data" => []})
      request_fun = fn _ -> ok_response(body, %{"server" => "uvicorn"}) end

      [detection] =
        Detect.run(
          candidates: [
            candidate(%{alias: "vllm", fingerprint: :vllm, endpoint: "http://127.0.0.1:8000"})
          ],
          request_fun: request_fun
        )

      assert detection.status == :ready
    end

    test "lm-studio fingerprint via `LM Studio` Server header" do
      body = Jason.encode!(%{"data" => []})
      request_fun = fn _ -> ok_response(body, %{"server" => "LM Studio REST"}) end

      [detection] =
        Detect.run(
          candidates: [
            candidate(%{
              alias: "lm-studio",
              fingerprint: :lm_studio,
              endpoint: "http://127.0.0.1:1234"
            })
          ],
          request_fun: request_fun
        )

      assert detection.status == :ready
    end

    test "localai fingerprint via owned_by: localai" do
      body = Jason.encode!(%{"data" => [%{"id" => "x", "owned_by" => "localai"}]})
      request_fun = fn _ -> ok_response(body) end

      [detection] =
        Detect.run(
          candidates: [candidate(%{alias: "localai", fingerprint: :localai})],
          request_fun: request_fun
        )

      assert detection.status == :ready
    end
  end

  describe "run/1 — negative paths" do
    test "connection refused surfaces as :unreachable" do
      request_fun = fn _ -> {:error, :econnrefused} end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.status == :unreachable
      assert detection.detail == :econnrefused
    end

    test "non-200 HTTP status surfaces as :unreachable" do
      request_fun = fn _ -> {:ok, %{status: 500, body: "", headers: %{}}} end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.status == :unreachable
      assert detection.detail == {:http_status, 500}
    end

    test "llama.cpp probe against a server that doesn't identify itself returns :shape_mismatch" do
      body = Jason.encode!(%{"data" => []})
      request_fun = fn _ -> ok_response(body) end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.status == :shape_mismatch
    end

    test "llama.cpp probe against a vllm server reports :wrong_fingerprint" do
      body = Jason.encode!(%{"data" => []})
      request_fun = fn _ -> ok_response(body, %{"server" => "uvicorn"}) end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.status == :wrong_fingerprint
      assert detection.detail == :vllm
    end

    test "probe crashes are caught and surfaced as :unreachable" do
      request_fun = fn _ -> raise "boom" end

      [detection] = Detect.run(candidates: [candidate()], request_fun: request_fun)

      assert detection.status == :unreachable
      assert match?({:probe_crashed, _}, detection.detail)
    end
  end

  describe "candidates/0" do
    test "returns the canonical probe table" do
      aliases = Detect.candidates() |> Enum.map(& &1.alias) |> Enum.sort()
      assert aliases == ["llamacpp", "lm-studio", "localai", "ollama", "vllm"]
    end
  end

  describe "format_line/1" do
    test "renders each status code with a distinct glyph" do
      assert Detect.format_line(%{alias: "x", endpoint: "http://x", status: :ready}) =~ "✓"

      assert Detect.format_line(%{
               alias: "x",
               endpoint: "http://x",
               status: :unreachable,
               detail: :boom
             }) =~ "✗"

      assert Detect.format_line(%{
               alias: "x",
               endpoint: "http://x",
               status: :shape_mismatch,
               detail: :why
             }) =~ "~"

      assert Detect.format_line(%{
               alias: "x",
               endpoint: "http://x",
               status: :wrong_fingerprint,
               detail: :vllm
             }) =~ "~"
    end
  end
end
