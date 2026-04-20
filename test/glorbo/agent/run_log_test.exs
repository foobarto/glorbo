defmodule Glorbo.Agent.RunLogTest do
  use ExUnit.Case, async: true

  alias Glorbo.Agent.RunLog

  describe "group_runs/2" do
    test "pairs dispatch + complete entries by invocation_id" do
      entries = [
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "abc123",
          "detail" => %{
            "provider" => "opencode",
            "model" => "lmstudio/qwen/qwen3.6-35b-a3b",
            "trigger" => "heartbeat",
            "task_path" => "projects/foo/tasks/bar.md"
          }
        },
        %{
          "action" => "agent.complete",
          "ts" => "2026-04-20T10:00:42Z",
          "agent" => "ceo",
          "invocation_id" => "abc123",
          "detail" => %{
            "duration_ms" => 42_000,
            "exit_status" => "0",
            "reply_preview" => "all done"
          }
        }
      ]

      assert [run] = RunLog.group_runs(entries, "ceo")
      assert run.invocation_id == "abc123"
      assert run.status == :complete
      assert run.provider == "opencode"
      assert run.model == "lmstudio/qwen/qwen3.6-35b-a3b"
      assert run.trigger == "heartbeat"
      assert run.task_path == "projects/foo/tasks/bar.md"
      assert run.duration_ms == 42_000
      assert run.exit_status == "0"
      assert run.reply_preview == "all done"
      assert %DateTime{} = run.start_ts
      assert %DateTime{} = run.end_ts
    end

    test "returns running status when only dispatch is present (mid-run)" do
      entries = [
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "mid-run-1"
        }
      ]

      assert [run] = RunLog.group_runs(entries, "ceo")
      assert run.status == :running
      assert is_nil(run.end_ts)
    end

    test "filters out other agents" do
      entries = [
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "ceo-1"
        },
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:01:00Z",
          "agent" => "researcher",
          "invocation_id" => "r-1"
        }
      ]

      assert [run] = RunLog.group_runs(entries, "ceo")
      assert run.invocation_id == "ceo-1"
    end

    test "ignores entries without invocation_id" do
      entries = [
        %{"action" => "task.create", "ts" => "2026-04-20T10:00:00Z", "agent" => "ceo"},
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "has-id"
        }
      ]

      assert [run] = RunLog.group_runs(entries, "ceo")
      assert run.invocation_id == "has-id"
    end

    test "sorts newest-first by start_ts" do
      entries = [
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "old"
        },
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:30:00Z",
          "agent" => "ceo",
          "invocation_id" => "new"
        }
      ]

      assert [%{invocation_id: "new"}, %{invocation_id: "old"}] =
               RunLog.group_runs(entries, "ceo")
    end
  end

  describe "list/4" do
    test "returns [] when the audit file doesn't exist" do
      assert RunLog.list("/nonexistent/path", "co", "ceo") == []
    end

    test "reads the month's JSONL and groups runs" do
      tmp = Path.join(System.tmp_dir!(), "runlog-test-#{System.unique_integer([:positive])}")
      audit_dir = Path.join([tmp, "companies", "acme", "audit"])
      File.mkdir_p!(audit_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)

      lines = [
        %{
          "action" => "agent.dispatch",
          "ts" => "2026-04-20T10:00:00Z",
          "agent" => "ceo",
          "invocation_id" => "run-a"
        },
        %{
          "action" => "agent.complete",
          "ts" => "2026-04-20T10:00:05Z",
          "agent" => "ceo",
          "invocation_id" => "run-a",
          "detail" => %{"exit_status" => "0"}
        }
      ]

      File.write!(
        Path.join(audit_dir, "2026-04.jsonl"),
        Enum.map_join(lines, "\n", &Jason.encode!/1)
      )

      assert [run] = RunLog.list(tmp, "acme", "ceo", month: "2026-04")
      assert run.invocation_id == "run-a"
      assert run.status == :complete
    end

    test "honors limit" do
      tmp = Path.join(System.tmp_dir!(), "runlog-limit-#{System.unique_integer([:positive])}")
      audit_dir = Path.join([tmp, "companies", "acme", "audit"])
      File.mkdir_p!(audit_dir)
      on_exit(fn -> File.rm_rf!(tmp) end)

      lines =
        Enum.flat_map(1..5, fn i ->
          iso = "2026-04-20T10:0#{i}:00Z"

          [
            %{
              "action" => "agent.dispatch",
              "ts" => iso,
              "agent" => "ceo",
              "invocation_id" => "inv-#{i}"
            }
          ]
        end)

      File.write!(
        Path.join(audit_dir, "2026-04.jsonl"),
        Enum.map_join(lines, "\n", &Jason.encode!/1)
      )

      assert length(RunLog.list(tmp, "acme", "ceo", month: "2026-04", limit: 2)) == 2
    end
  end
end
