defmodule Glorbo.CLI.Parsers.StadoAcpTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Parsers.StadoAcp

  # Sample stado stats --json shape (taken from a v0.27.1 probe). The
  # parser must tolerate empty totals (zero-length test session) AND
  # populated totals across the by_model + by_tool maps.

  defp empty_session_json do
    Jason.encode!(%{
      "window_days" => 7,
      "session_id" => "acp-test",
      "total" => %{"calls" => 0, "tokens_in" => 0, "tokens_out" => 0, "cost_usd" => 0},
      "total_duration_ms" => 0,
      "by_model" => %{},
      "by_tool" => %{}
    })
  end

  defp populated_session_json do
    Jason.encode!(%{
      "window_days" => 7,
      "session_id" => "acp-test",
      "total" => %{
        "calls" => 4,
        "tokens_in" => 1234,
        "tokens_out" => 567,
        "cost_usd" => 0.0234
      },
      "total_duration_ms" => 5_120,
      "by_model" => %{
        "claude-sonnet-4-5" => %{
          "calls" => 3,
          "tokens_in" => 1000,
          "tokens_out" => 500,
          "cost_usd" => 0.020
        },
        "gpt-4o-mini" => %{
          "calls" => 1,
          "tokens_in" => 234,
          "tokens_out" => 67,
          "cost_usd" => 0.003
        }
      },
      "by_tool" => %{
        "shell" => %{"calls" => 2},
        "ripgrep" => %{"calls" => 5}
      }
    })
  end

  defp ok_command(json) do
    fn _bin, _args, _opts -> {json, 0} end
  end

  defp err_command(output, code) do
    fn _bin, _args, _opts -> {output, code} end
  end

  describe "parse/1 happy paths" do
    test "empty session returns zero usage with no model" do
      ctx = %{
        session_id: "acp-empty",
        host_binary: "/usr/local/bin/stado",
        command_fun: ok_command(empty_session_json())
      }

      assert {:ok, usage} = StadoAcp.parse({:stado_session, ctx})

      assert usage == %{
               prompt_tokens: 0,
               completion_tokens: 0,
               cost_usd: 0.0,
               duration_ms: 0,
               model: nil,
               tool_calls: %{}
             }
    end

    test "populated session totals + dominant model + tool breakdown" do
      ctx = %{
        session_id: "acp-loaded",
        host_binary: "/usr/local/bin/stado",
        command_fun: ok_command(populated_session_json())
      }

      assert {:ok, usage} = StadoAcp.parse({:stado_session, ctx})

      assert usage.prompt_tokens == 1234
      assert usage.completion_tokens == 567
      assert usage.cost_usd == 0.0234
      assert usage.duration_ms == 5_120
      # Dominant model picked by call count — claude has 3 calls, gpt has 1.
      assert usage.model == "claude-sonnet-4-5"
      assert usage.tool_calls == %{"shell" => 2, "ripgrep" => 5}
    end

    test "passes the right argv to the command" do
      captured = :counters.new(1, [])

      command_fun = fn bin, args, opts ->
        :counters.add(captured, 1, 1)
        send(self(), {:cmd, bin, args, opts})
        {empty_session_json(), 0}
      end

      ctx = %{
        session_id: "acp-xyz",
        host_binary: "/path/to/stado",
        command_fun: command_fun
      }

      assert {:ok, _} = StadoAcp.parse({:stado_session, ctx})

      assert_received {:cmd, "/path/to/stado", ["stats", "--session", "acp-xyz", "--json"], opts}
      assert opts[:stderr_to_stdout] == true
      assert :counters.get(captured, 1) == 1
    end
  end

  describe "parse/1 error paths" do
    test "missing session_id" do
      ctx = %{host_binary: "/usr/local/bin/stado", command_fun: ok_command(empty_session_json())}
      assert {:error, :missing_session_id} = StadoAcp.parse({:stado_session, ctx})
    end

    test "empty session_id" do
      ctx = %{session_id: "", host_binary: "/usr/local/bin/stado", command_fun: ok_command("")}
      assert {:error, :missing_session_id} = StadoAcp.parse({:stado_session, ctx})
    end

    test "missing host_binary" do
      ctx = %{session_id: "x", command_fun: ok_command("")}
      assert {:error, :missing_host_binary} = StadoAcp.parse({:stado_session, ctx})
    end

    test "stado exits non-zero — reports {:stado_exit, code, tail}" do
      ctx = %{
        session_id: "x",
        host_binary: "/usr/local/bin/stado",
        command_fun: err_command("session not found", 2)
      }

      assert {:error, {:stado_exit, 2, "session not found"}} =
               StadoAcp.parse({:stado_session, ctx})
    end

    test "stado emits something that isn't JSON" do
      ctx = %{
        session_id: "x",
        host_binary: "/usr/local/bin/stado",
        command_fun: ok_command("not json at all")
      }

      assert {:error, {:invalid_json, _}} = StadoAcp.parse({:stado_session, ctx})
    end

    test "stado emits a JSON array instead of an object" do
      ctx = %{
        session_id: "x",
        host_binary: "/usr/local/bin/stado",
        command_fun: ok_command(Jason.encode!([1, 2, 3]))
      }

      assert {:error, {:invalid_json, "expected an object"}} =
               StadoAcp.parse({:stado_session, ctx})
    end

    test "non-stado_session sources are rejected" do
      assert {:error, :stdout_not_supported} = StadoAcp.parse({:jsonl_file, "/tmp/x.jsonl"})
      assert {:error, :stdout_not_supported} = StadoAcp.parse({:json_file, "/tmp/x.json"})
      assert {:error, :stdout_not_supported} = StadoAcp.parse({:stdout, "anything"})
    end
  end

  describe "Parsers registry" do
    test "stado_acp is registered + module_for resolves correctly" do
      assert Glorbo.CLI.Parsers.known?("stado_acp")
      assert Glorbo.CLI.Parsers.module_for("stado_acp") == StadoAcp
    end
  end
end
