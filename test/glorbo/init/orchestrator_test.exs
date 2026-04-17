defmodule Glorbo.Init.OrchestratorTest do
  use Glorbo.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Glorbo.Company.AuditLog
  alias Glorbo.Init.Orchestrator
  alias Glorbo.Test.TmpGlorboHome

  setup do
    base = TmpGlorboHome.setup()

    # Stop a prior named AuditLog if a previous test left one running. The
    # orchestrator always registers under the module name; tests that run
    # sequentially share the atom.
    case Process.whereis(AuditLog) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
        # give the name registry a moment to release
        :ok
    end

    # Allow the AuditLog GenServer (once started) to see this test's Sandbox
    # connection. We start it eagerly so we can allow the pid before the
    # orchestrator's start_link no-ops on :already_started.
    {:ok, audit_pid} = AuditLog.start_link(name: AuditLog, base: base, company: "_system")
    Sandbox.allow(Glorbo.Repo, self(), audit_pid)

    {:ok, base: base}
  end

  # Canonical dep-injection set — doctor returns all-pass, binaries are
  # already-present, image pull is a no-op success.
  defp ok_deps do
    [
      doctor_fun: fn ->
        [
          %{name: "linux_kernel", pass: true, detail: "ok", required: "ok", severity: :blocker},
          %{name: "glorbo_dir", pass: true, detail: "ok", required: "ok", severity: :blocker}
        ]
      end,
      ensure_podman_fun: fn _o -> {:ok, :system, "/usr/bin/podman"} end,
      ensure_ollama_fun: fn _o -> {:ok, :system, "/usr/bin/ollama"} end,
      ensure_image_fun: fn _image -> :ok end,
      image_cached_fun: fn _ -> true end
    ]
  end

  defp opts(base, extra \\ []), do: Keyword.merge([base: base], ok_deps()) |> Keyword.merge(extra)

  describe "run/1 — 7-step pipeline" do
    test "Test 7: executes 7 steps in D-21 order", %{base: base} do
      {status, summary} = Orchestrator.run(opts(base))
      assert status in [:ok, :error]

      step_names = Enum.map(summary.results, & &1.step)

      assert step_names == [
               :pre_doctor,
               :hierarchy,
               :binary_bootstrap,
               :example_company,
               :reindex,
               :post_doctor
             ]
    end

    test "Test 8: each step appends one audit event → 6 JSONL lines", %{base: base} do
      Orchestrator.run(opts(base))

      files = Path.wildcard(Path.join([base, "audit", "_system", "*.jsonl"]))
      assert length(files) == 1

      lines =
        files
        |> hd()
        |> File.read!()
        |> String.split("\n", trim: true)

      assert length(lines) == 6

      # Every entry should have action "init.step.*"
      for line <- lines do
        decoded = Jason.decode!(line)
        assert String.starts_with?(decoded["action"], "init.step.")
        assert decoded["actor"] == "init"
      end
    end

    test "Test 9: continue-on-error — one failing step does not abort pipeline", %{base: base} do
      # TODO(GEP-5 D6 cleanup, commit 2): restore a real fault-injection test
      # once step_binary_bootstrap is pruned. Today it always returns :skipped,
      # so a failure-in-the-middle scenario needs a different step to target.
      {_status, summary} = Orchestrator.run(opts(base))
      assert length(summary.results) == 6
      assert Enum.find(summary.results, &(&1.step == :post_doctor))
    end

    test "Test 10: :skip-pull still accepted (no-op now that image_pull is gone)", %{base: base} do
      {_status, summary} = Orchestrator.run(opts(base, skip_pull: true))

      # binary_bootstrap is stubbed to always skip post-GEP-5 D6.
      bootstrap = Enum.find(summary.results, &(&1.step == :binary_bootstrap))
      assert bootstrap.status == :skipped

      # No image_pull step remains.
      refute Enum.find(summary.results, &(&1.step == :image_pull))
    end

    test "Test 11: example: false skips example_company", %{base: base} do
      {_status, summary} = Orchestrator.run(opts(base, example: false))

      example = Enum.find(summary.results, &(&1.step == :example_company))
      assert example.status == :skipped
      assert example.detail == "--no-example"
    end

    test "Test 12: post-doctor exit-code drives summary.exit_code", %{base: base} do
      # Post-doctor returns all-pass → exit 0.
      {:ok, s0} = Orchestrator.run(opts(base))
      assert s0.exit_code == 0

      # Post-doctor returns a :warning failure → exit 2.
      warn_deps =
        opts(base,
          doctor_fun: fn ->
            [
              %{
                name: "linux_kernel",
                pass: true,
                detail: "ok",
                required: "ok",
                severity: :blocker
              },
              %{
                name: "ollama_daemon",
                pass: false,
                detail: "daemon not reachable",
                required: "reachable",
                severity: :warning
              }
            ]
          end
        )

      {:ok, s2} = Orchestrator.run(warn_deps)
      assert s2.exit_code == 2

      # Post-doctor returns a :blocker failure → exit 1.
      blocker_deps =
        opts(base,
          doctor_fun: fn ->
            [
              %{
                name: "linux_kernel",
                pass: false,
                detail: "too old",
                required: ">= 5.13",
                severity: :blocker
              }
            ]
          end
        )

      {:error, s1} = Orchestrator.run(blocker_deps)
      assert s1.exit_code == 1
    end

    test "Test 13: re-running on an existing install is a no-op — no crash, steps ok/skipped",
         %{base: base} do
      {:ok, _} = Orchestrator.run(opts(base))
      # Second run: example_company returns :already_exists → :skipped; reindex
      # is no-op. No exceptions.
      assert {:ok, s2} = Orchestrator.run(opts(base))

      example = Enum.find(s2.results, &(&1.step == :example_company))
      assert example.status == :skipped
      assert example.detail =~ "already present"

      # All steps succeeded or skipped — no errors.
      assert Enum.all?(s2.results, &(&1.status in [:ok, :skipped]))
    end
  end

  describe "W3: AuditLog start is unconditional" do
    test "Test 14: second Orchestrator.run/1 handles :already_started gracefully", %{base: base} do
      {_, _} = Orchestrator.run(opts(base))
      # Second invocation — AuditLog named process is already started. Must
      # not crash; the {:error, {:already_started, _}} branch handles it.
      assert {_, _} = Orchestrator.run(opts(base))

      # Confirm the orchestrator source does NOT contain a Process.whereis check.
      src = File.read!("lib/glorbo/init/orchestrator.ex")
      refute src =~ "Process.whereis(Glorbo.Company.AuditLog)"
      refute src =~ "ensure_audit_log_started"
      assert src =~ ":already_started"
      assert src =~ "AuditLog.start_link"
    end
  end

  describe "W4: combine/1 correctness" do
    test "Test 15: all :system → :no_op; with :error → :error; mixed → :mixed" do
      # All system — no bootstrap work needed.
      assert %{status: :ok, mode: :no_op} =
               Orchestrator.combine([
                 {:ok, :system, "/usr/bin/podman"},
                 {:ok, :system, "/usr/bin/ollama"}
               ])

      # One error present.
      assert %{status: :error, errors: [_ | _]} =
               Orchestrator.combine([
                 {:ok, :system, "/usr/bin/podman"},
                 {:error, :boom}
               ])

      # Mixed system + downloaded.
      assert %{status: :ok, mode: :mixed} =
               Orchestrator.combine([
                 {:ok, :system, "/usr/bin/podman"},
                 {:ok, :downloaded, "/home/dev/.glorbo/bin/ollama"}
               ])
    end
  end
end
