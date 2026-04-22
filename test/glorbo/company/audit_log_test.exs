defmodule Glorbo.Company.AuditLogTest do
  use Glorbo.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Glorbo.AuditEvent
  alias Glorbo.Company.AuditLog
  alias Glorbo.Test.TmpGlorboHome

  # Start a fresh AuditLog GenServer rooted at a tmp dir for each test.
  setup do
    base = TmpGlorboHome.setup()
    name = Glorbo.Test.UniqueName.gen("audit_log")
    {:ok, pid} = AuditLog.start_link(name: name, base: base)
    # Allow the GenServer to use the test's sandboxed Repo connection so
    # the SQLite mirror actually inserts inside the Sandbox transaction.
    Sandbox.allow(Glorbo.Repo, self(), pid)
    {:ok, base: base, name: name, pid: pid}
  end

  defp read_jsonl_files(dir) do
    dir
    |> Path.join("**/*.jsonl")
    |> Path.wildcard()
  end

  describe "append/2 (Tests 1–6)" do
    test "Test 1: writes a single JSONL line with valid JSON ending in \\n", %{
      base: base,
      name: name
    } do
      assert :ok =
               AuditLog.append(name, %{
                 company: "acme",
                 actor: "ceo",
                 action: "task.create",
                 target: "projects/x/tasks/1.md"
               })

      files = read_jsonl_files(base)
      assert length(files) == 1
      [path] = files

      content = File.read!(path)
      assert String.ends_with?(content, "\n")

      decoded = content |> String.trim_trailing("\n") |> Jason.decode!()
      assert decoded["actor"] == "ceo"
      assert decoded["action"] == "task.create"
      assert decoded["target"] == "projects/x/tasks/1.md"
    end

    test "Test 2: SQLite mirror row exists after append", %{name: name} do
      :ok =
        AuditLog.append(name, %{
          company: "acme",
          actor: "ceo",
          action: "task.create",
          target: "t1"
        })

      [row] = Repo.all(AuditEvent)
      assert row.company == "acme"
      assert row.actor == "ceo"
      assert row.action == "task.create"
      assert row.target == "t1"
    end

    test "Test 3: two appends in the same month append — first line preserved", %{
      base: base,
      name: name
    } do
      :ok = AuditLog.append(name, %{company: "acme", actor: "a", action: "x"})
      :ok = AuditLog.append(name, %{company: "acme", actor: "b", action: "y"})

      [path] = read_jsonl_files(base)
      lines = File.read!(path) |> String.split("\n", trim: true)
      assert length(lines) == 2

      [first, second] = Enum.map(lines, &Jason.decode!/1)
      assert first["actor"] == "a"
      assert second["actor"] == "b"
    end

    test "Test 4 is covered by stubs_test.exs — module exports only append/2 + start_link/1" do
      Code.ensure_loaded!(AuditLog)
      assert function_exported?(AuditLog, :append, 2)
      assert function_exported?(AuditLog, :start_link, 1)
      refute function_exported?(AuditLog, :update, 2)
      refute function_exported?(AuditLog, :delete, 1)
      refute function_exported?(AuditLog, :delete, 2)
      refute function_exported?(AuditLog, :edit, 2)
    end

    test "Test 5: two sequential appends both present (synchronous append semantics)", %{
      base: base,
      name: name
    } do
      # Simulate two processes by two quick sequential calls — the GenServer
      # serializes them, and [:append, :sync] guarantees both survive a
      # power-cut-style interruption would flush.
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            AuditLog.append(name, %{company: "acme", actor: "u#{i}", action: "write"})
          end)
        end

      Enum.each(tasks, &Task.await/1)

      [path] = read_jsonl_files(base)
      lines = File.read!(path) |> String.split("\n", trim: true)
      assert length(lines) == 5
    end

    test "Test 6: :_system audit goes under audit/_system/", %{base: base, name: name} do
      :ok =
        AuditLog.append(name, %{
          company: "_system",
          actor: "system",
          action: "init.step",
          step: "hierarchy"
        })

      sys_path = Path.wildcard(Path.join([base, "audit", "_system", "*.jsonl"]))
      assert length(sys_path) == 1

      [decoded] =
        sys_path
        |> List.first()
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert decoded["actor"] == "system"
      assert decoded["action"] == "init.step"
      # Extra keys land in detail
      assert decoded["detail"]["step"] == "hierarchy"
    end

    test "Test 7: mirror failure does not lose JSONL (JSONL is source of truth)", %{
      base: base,
      name: name
    } do
      # Force a SQLite insert failure by passing a non-castable ts. We feed
      # the entry through the public API; mirror_to_sqlite rescues and logs.
      import ExUnit.CaptureLog

      # A ts that will cast fine; trigger failure via a too-long `action`?
      # Schema has no length limit on SQLite, so instead we force failure by
      # closing the sandbox connection mid-call — simpler: violate a schema
      # implicit (no null) constraint. The mirror passes nil as target which
      # is allowed; the insert should normally succeed. To simulate real
      # mirror failure we drop the audit_events table and then call append.
      Repo.query!("DROP TABLE audit_events")

      log =
        capture_log(fn ->
          assert :ok =
                   AuditLog.append(name, %{company: "acme", actor: "x", action: "y"})
        end)

      assert log =~ "audit_events mirror"

      # JSONL still on disk despite mirror failure
      [path] = read_jsonl_files(base)
      assert File.read!(path) =~ ~s("actor":"x")

      # Re-create the table so sandbox rollback doesn't explode
      Repo.query!("""
      CREATE TABLE audit_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        company TEXT,
        actor TEXT NOT NULL,
        action TEXT NOT NULL,
        target TEXT,
        detail TEXT,
        ts TEXT NOT NULL
      )
      """)
    end

    # Test 8 — PubSub broadcast after a successful append (realtime UI).
    test "Test 8: append broadcasts {:audit_append, record} on company:<co>:audit",
         %{name: name} do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:acme:audit")

      :ok =
        AuditLog.append(name, %{
          company: "acme",
          actor: "director",
          action: "task.create",
          target: "projects/website/tasks/website-07.md"
        })

      assert_receive {:audit_append, record}, 500
      assert record.action == "task.create"
      assert record.actor == "director"
      assert record.target == "projects/website/tasks/website-07.md"
      assert is_binary(record.ts)
    end

    # Test 9 — _system audit does not broadcast (avoid noisy global topic).
    test "Test 9: :_system audit does not broadcast", %{name: name} do
      Phoenix.PubSub.subscribe(Glorbo.PubSub, "company:_system:audit")

      :ok =
        AuditLog.append(name, %{
          company: "_system",
          actor: "cli",
          action: "cli.up.start"
        })

      refute_receive {:audit_append, _}, 200
    end
  end

  # B1: LiveView call sites (`BrainDumpLive.emit_audit`, `CompanyLive.
  # do_wake_all`) used the default `__MODULE__` server arg, which is
  # never registered in production — per-company supervisor uses a
  # Registry via-tuple instead — so every event silently died under
  # the rescue :exit clause. `append_for/2` auto-resolves the target.
  describe "append_for/2 — B1 LV-call-site fix" do
    test "writes via the per-company via-tuple when that process is registered",
         %{base: base} do
      via = Glorbo.Company.Supervisor.via("acme", :audit_log)

      {:ok, pid} = AuditLog.start_link(name: via, base: base)
      Sandbox.allow(Glorbo.Repo, self(), pid)

      assert :ok =
               AuditLog.append_for("acme", %{
                 actor: "director",
                 action: "braindump.capture",
                 target: "2026-04-22T10:00:00Z"
               })

      [path] = read_jsonl_files(base)
      decoded = path |> File.read!() |> String.trim_trailing() |> Jason.decode!()
      assert decoded["action"] == "braindump.capture"
      assert decoded["actor"] == "director"
    end

    test "returns :ok silently when neither process is registered" do
      # If both targets are missing (early-boot, crashed supervisor),
      # the helper must still return :ok so a click handler doesn't
      # crash the LiveView. Audit loss is preferable to UI loss here.
      ghost = "ghost-company-#{System.unique_integer([:positive])}"

      assert :ok =
               AuditLog.append_for(ghost, %{
                 actor: "director",
                 action: "test",
                 target: ghost
               })
    end
  end
end
