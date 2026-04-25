defmodule Glorbo.HomeHistory.WatcherBridgeTest do
  @moduledoc """
  GEP-33 Phase 3 — `Glorbo.HomeHistory.WatcherBridge` observes
  filesystem-watcher events and emits `External` history commits
  for manual edits to tracked-scope paths.
  """

  use ExUnit.Case, async: true

  alias Glorbo.HomeHistory
  alias Glorbo.HomeHistory.WatcherBridge

  @debounce_ms 50

  setup do
    base =
      Path.join(System.tmp_dir!(), "glorbo-history-bridge-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "companies/acme/agents/ceo"))
    File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: acme\n---\n")
    File.write!(Path.join(base, "companies/acme/agents/ceo/AGENT.md"), "---\nname: CEO\n---\n")
    {:ok, _} = HomeHistory.init(base: base)

    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  defp start_bridge(base) do
    {:ok, pid} =
      WatcherBridge.start_link(name: nil, base: base, debounce_ms: @debounce_ms)

    pid
  end

  describe "observe/3 — manual edit capture" do
    test "tracked-scope manual edit produces an External commit", %{base: base} do
      bridge = start_bridge(base)

      path = Path.join(base, "companies/acme/company.md")
      File.write!(path, "---\nname: edited-by-vim\n---\n")

      WatcherBridge.observe("acme", "company.md", server: bridge)

      Process.sleep(@debounce_ms * 4)

      {:ok, [head | _]} = HomeHistory.log(base: base, limit: 5)
      assert head.subject == "external.edit: companies/acme/company.md"
      assert head.author_name == "External"

      {body, 0} = System.cmd("git", ["log", "-1", "--pretty=%B"], cd: base)
      assert body =~ "Glorbo-Actor: external"
      assert body =~ "Glorbo-Source: watcher"
    end

    test "untracked-scope path is silently dropped", %{base: base} do
      bridge = start_bridge(base)

      # `companies/acme/agents/ceo/inbox/wake.md` is excluded scope
      # (per-agent inbox). The bridge filters via `tracked?/2` and
      # never fires `commit_marked`.
      File.mkdir_p!(Path.join(base, "companies/acme/agents/ceo/inbox"))
      File.write!(Path.join(base, "companies/acme/agents/ceo/inbox/wake.md"), "x")

      {:ok, [%{sha: initial_sha}]} = HomeHistory.log(base: base, limit: 1)

      WatcherBridge.observe("acme", "agents/ceo/inbox/wake.md", server: bridge)

      Process.sleep(@debounce_ms * 4)

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    test "no-diff path is a clean no-op (no empty commit)", %{base: base} do
      bridge = start_bridge(base)

      {:ok, [%{sha: initial_sha}]} = HomeHistory.log(base: base, limit: 1)

      # Path is in scope, exists, but unchanged from HEAD — diff
      # check returns clean → no commit.
      WatcherBridge.observe("acme", "company.md", server: bridge)

      Process.sleep(@debounce_ms * 4)

      {:ok, [head]} = HomeHistory.log(base: base, limit: 5)
      assert head.sha == initial_sha
    end

    test "rapid burst on same path coalesces into one commit",
         %{base: base} do
      bridge = start_bridge(base)

      path = Path.join(base, "companies/acme/company.md")

      # First burst — one commit lands.
      File.write!(path, "---\nname: edit-1\n---\n")

      Enum.each(1..5, fn _ ->
        WatcherBridge.observe("acme", "company.md", server: bridge)
        Process.sleep(div(@debounce_ms, 5))
      end)

      Process.sleep(@debounce_ms * 4)

      {:ok, log} = HomeHistory.log(base: base, limit: 10)

      external_count =
        Enum.count(log, &(&1.subject == "external.edit: companies/acme/company.md"))

      # Per-key debounce coalesces the 5 observe calls into one
      # firing → at most one external commit lands for the burst.
      assert external_count == 1
    end

    test "two distinct paths produce two distinct commits",
         %{base: base} do
      bridge = start_bridge(base)

      a = Path.join(base, "companies/acme/company.md")
      b = Path.join(base, "companies/acme/agents/ceo/AGENT.md")
      File.write!(a, "---\nname: edit-a\n---\n")
      File.write!(b, "---\nname: edit-b\n---\n")

      WatcherBridge.observe("acme", "company.md", server: bridge)
      WatcherBridge.observe("acme", "agents/ceo/AGENT.md", server: bridge)

      Process.sleep(@debounce_ms * 4)

      {:ok, log} = HomeHistory.log(base: base, limit: 10)

      subjects = Enum.map(log, & &1.subject)
      assert "external.edit: companies/acme/company.md" in subjects
      assert "external.edit: companies/acme/agents/ceo/AGENT.md" in subjects
    end
  end

  describe "observe/3 — resilience" do
    test "cast to unregistered server is a silent no-op" do
      # No `server: pid` — defaults to module name; nothing
      # registered → silent drop, no raise.
      assert :ok = WatcherBridge.observe("acme", "company.md")
    end

    test "history disabled (no .git/) doesn't crash the bridge" do
      base =
        Path.join(
          System.tmp_dir!(),
          "glorbo-bridge-disabled-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(base, "companies/acme"))
      File.write!(Path.join(base, "companies/acme/company.md"), "---\nname: x\n---\n")

      bridge = start_bridge(base)

      WatcherBridge.observe("acme", "company.md", server: bridge)
      Process.sleep(@debounce_ms * 4)

      assert Process.alive?(bridge)

      File.rm_rf!(base)
    end
  end
end
