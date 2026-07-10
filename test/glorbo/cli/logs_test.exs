defmodule Glorbo.CLI.LogsTest do
  @moduledoc """
  Plan 05-02 Task 3 — `Glorbo.CLI.Logs`.

  Seeds an acme company with 100 audit JSONL lines spanning the current
  month and an agent stdout.log, then exercises the backfill + routing
  logic. `--follow` mode is intentionally not exercised here (it blocks
  forever; run it under `:integration` manually via a test harness that
  sends `:file_event, :stop`).
  """
  use GlorboTest.CLICase, async: false

  alias Glorbo.CLI.Logs

  setup %{glorbo_home: home} do
    company = "acme"
    agent = "ceo"

    # Seed the portability fixture (minimal company + agent + 1 audit
    # entry + empty stdout.log).
    Glorbo.Test.PortabilityFixtures.write_minimal_company(home, company, agent)

    # Append 99 more audit lines so backfill assertions are deterministic.
    month = DateTime.utc_now() |> Calendar.strftime("%Y-%m")
    audit_path = Path.join([home, "companies", company, "audit", "#{month}.jsonl"])

    Enum.each(2..100, fn i ->
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      line =
        Jason.encode!(%{
          ts: now,
          actor: "system",
          action: "test.event.#{i}",
          target: "seq-#{i}",
          detail: %{seq: i}
        }) <> "\n"

      File.write!(audit_path, line, [:append])
    end)

    {:ok, home: home, company: company, agent: agent}
  end

  describe "logs <company> — audit JSONL" do
    test "backfills 50 lines by default (D-14)", %{company: co} do
      assert {:logs, 0, out} = Logs.run([co])

      lines =
        out
        |> String.split("\n", trim: true)
        |> length()

      assert lines == 50, "expected 50 lines, got #{lines}"
    end

    test "--lines 10 respected", %{company: co} do
      assert {:logs, 0, out} = Logs.run([co, "--lines", "10"])

      lines = out |> String.split("\n", trim: true) |> length()
      assert lines == 10
    end

    test "--lines 0 produces empty output", %{company: co} do
      assert {:logs, 0, out} = Logs.run([co, "--lines", "0"])

      assert out == ""
    end

    test "pretty-prints audit line with ts / actor / action / target / detail",
         %{company: co} do
      assert {:logs, 0, out} = Logs.run([co, "--lines", "1"])

      # Backfills the MOST RECENT line (seq-100 since we appended 2..100).
      assert out =~ "test.event.100"
      assert out =~ "seq-100"
      assert out =~ "system"
    end

    test "missing company returns exit 1 with actionable message" do
      assert {:logs, 1, msg} = Logs.run(["bogus"])
      assert msg =~ "No audit log found"
      assert msg =~ "bogus"
    end
  end

  describe "logs <company> <agent> — raw stdout" do
    test "routes to agents/<ag>/stdout.log and emits raw content",
         %{home: home, company: co, agent: ag} do
      # Write 20 lines into stdout.log.
      path = Path.join([home, "companies", co, "agents", ag, "stdout.log"])
      File.write!(path, Enum.map_join(1..20, "", fn i -> "line-#{i}\n" end))

      assert {:logs, 0, out} = Logs.run([co, ag])

      # All 20 lines should be present (< 50 default).
      for i <- 1..20 do
        assert out =~ "line-#{i}"
      end
    end

    test "missing agent stdout.log returns exit 1", %{company: co} do
      assert {:logs, 1, msg} = Logs.run([co, "nonexistent-agent"])
      assert msg =~ "No stdout log found"
      assert msg =~ "nonexistent-agent"
    end

    # C-117: agent stdout is attacker-controlled; terminal control / ANSI /
    # OSC escape sequences must be stripped before they reach the operator's
    # terminal.
    test "strips ANSI/OSC/control escapes from stdout backfill by default",
         %{home: home, company: co, agent: ag} do
      path = Path.join([home, "companies", co, "agents", ag, "stdout.log"])

      File.write!(path, [
        # SGR colour (CSI), then visible text
        "\e[31mred-text\e[0m\n",
        # OSC 0 window-title set (BEL-terminated)
        "\e]0;pwned-title\a after-osc\n",
        # OSC 8 hyperlink (ST-terminated)
        "\e]8;;http://evil\e\\link\e]8;;\e\\ tail\n",
        # bare control bytes + backspace overwrite trick
        "vis\bible\x1b[2Kafter-clear\n"
      ])

      assert {:logs, 0, out} = Logs.run([co, ag])

      # No raw ESC, BEL, or backspace bytes survive.
      refute String.contains?(out, "\e")
      refute String.contains?(out, "\a")
      refute String.contains?(out, "\b")
      # The OSC title payload must not leak through as an active escape.
      refute String.contains?(out, "\e]0;")
      # Visible text is preserved.
      assert out =~ "red-text"
      assert out =~ "after-osc"
      assert out =~ "link"
      assert out =~ "after-clear"
    end

    test "--raw preserves stdout verbatim for trusted debugging",
         %{home: home, company: co, agent: ag} do
      path = Path.join([home, "companies", co, "agents", ag, "stdout.log"])
      File.write!(path, "\e[31mred\e[0m\n")

      assert {:logs, 0, out} = Logs.run([co, ag, "--raw"])
      assert String.contains?(out, "\e[31m")
    end
  end

  describe "argv / help" do
    test "empty args returns usage" do
      assert {:logs, 1, msg} = Logs.run([])
      assert msg =~ "Usage: glorbo logs"
    end

    test "--help returns help text" do
      assert {:logs, 0, out} = Logs.run(["--help"])
      assert out =~ "glorbo logs"
      assert out =~ "USAGE"
      assert out =~ "--lines"
      assert out =~ "--follow"
    end

    test "three-positional argv returns usage" do
      assert {:logs, 1, msg} = Logs.run(["a", "b", "c"])
      assert msg =~ "Usage: glorbo logs"
    end
  end

  describe "incremental reader" do
    test "returns the offset actually consumed, not a later stat size", %{home: home} do
      path = Path.join(home, "incremental.log")
      File.write!(path, "old-newest")

      assert {:ok, "newest", 10} = Logs.read_incremental(path, 4)

      File.write!(path, "-later", [:append])
      assert {:ok, "-later", 16} = Logs.read_incremental(path, 10)
    end

    test "a truncated followed file resets the consumed offset to zero", %{home: home} do
      path = Path.join(home, "follow-truncated.log")
      File.write!(path, "replacement")

      assert {:ok, "replacement", 11} = Logs.read_follow_chunk(path, 100)
    end
  end
end
