defmodule Glorbo.StubsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Asserts every §4.1 domain stub is real, exports `start_link/1`, and obeys
  load-bearing invariants from CLAUDE.md — most importantly the audit log's
  append-only surface.
  """

  @modules [
    Glorbo.ContainerManager,
    Glorbo.Company.FileWatcher,
    Glorbo.Company.Router,
    Glorbo.Company.Scheduler,
    Glorbo.Company.BudgetTracker,
    Glorbo.Company.AuditLog,
    Glorbo.Agent.Server
  ]

  for mod <- @modules do
    test "#{inspect(mod)} is a loaded module exporting start_link/1" do
      assert Code.ensure_loaded?(unquote(mod)),
             "Module #{unquote(inspect(mod))} not loaded"

      assert function_exported?(unquote(mod), :start_link, 1)
    end
  end

  alias Glorbo.Company.Router

  test "Glorbo.Company.Router.route/2 returns {:error, :not_implemented} placeholder" do
    # Phase 1 stub — called without running pid; returns placeholder regardless.
    assert Router.route(:anything, %{}) == {:error, :not_implemented}
  end

  test "Glorbo.Company.AuditLog exposes only append/2 (append-only invariant from CLAUDE.md)" do
    # function_exported?/3 returns false on modules that have not yet been
    # loaded — force-load first so this assertion is deterministic.
    Code.ensure_loaded!(Glorbo.Company.AuditLog)

    assert function_exported?(Glorbo.Company.AuditLog, :append, 2)
    refute function_exported?(Glorbo.Company.AuditLog, :update, 2)
    refute function_exported?(Glorbo.Company.AuditLog, :delete, 2)
    refute function_exported?(Glorbo.Company.AuditLog, :edit, 2)
    # Phase 2 addition: also verify no mutation under arity 1 (delete/1 is a
    # common single-arg footgun — e.g. delete by id).
    refute function_exported?(Glorbo.Company.AuditLog, :delete, 1)
    refute function_exported?(Glorbo.Company.AuditLog, :update, 1)
  end

  describe "AuditLog append/2 smoke (Phase 2 positive assertion)" do
    alias Glorbo.Company.AuditLog

    test "append/2 is a live GenServer call that writes a JSONL line" do
      base =
        Path.join(
          System.tmp_dir!(),
          "stubs_audit_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(base) end)

      name = :"stubs_audit_#{System.unique_integer([:positive])}"
      {:ok, _pid} = AuditLog.start_link(name: name, base: base)

      assert :ok =
               AuditLog.append(name, %{
                 company: "_system",
                 actor: "test",
                 action: "smoke"
               })

      files = Path.wildcard(Path.join([base, "audit", "_system", "*.jsonl"]))
      assert length(files) == 1
    end
  end
end
