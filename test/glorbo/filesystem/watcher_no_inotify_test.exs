defmodule Glorbo.Filesystem.WatcherNoInotifyTest do
  # Tests the graceful-degradation path when no usable filesystem backend
  # is available (no inotify-tools, fs_poll also refuses to start). This
  # path was previously crashing with `case_clause :ignore` inside
  # `Watcher.init/1` — the company supervisor would die silently after
  # `glorbo up`, leaving "running" status with no companies loaded.
  #
  # Module is intentionally NOT tagged `:inotify` — the whole point is
  # that it must run on hosts WITHOUT inotify-tools too. `FileSystem` is
  # stubbed via the `:fs_module` opt so we exercise the failure path
  # deterministically regardless of host state.
  use ExUnit.Case, async: true

  alias Glorbo.Filesystem.Watcher
  alias Glorbo.Test.TmpGlorboHome

  defmodule FsAlwaysIgnore do
    # Both the inotify attempt AND the fs_poll fallback return :ignore —
    # simulates a host where file_system can't bootstrap any backend.
    def start_link(_opts), do: :ignore
    def subscribe(_pid), do: :ok
  end

  defmodule FsErrorThenIgnore do
    # Inotify attempt errors (typical: inotify-tools not on PATH);
    # fs_poll fallback ALSO returns :ignore. Watcher must still
    # degrade to :ignore rather than crashing.
    def start_link(opts) do
      if Keyword.get(opts, :backend) == :fs_poll do
        :ignore
      else
        {:error, :enoent}
      end
    end

    def subscribe(_pid), do: :ok
  end

  defp opts_for_company(fs_module) do
    base = TmpGlorboHome.setup()
    company = "no_ino_#{System.unique_integer([:positive])}"

    [
      company: company,
      base: base,
      name: Glorbo.Test.UniqueName.gen("watcher_noino"),
      fs_module: fs_module
    ]
  end

  describe "init/1 with no usable backend" do
    test "returns :ignore (not a crash) when FileSystem.start_link returns :ignore for both backends" do
      # Before the fix: `start_backend/1` crashed with `case_clause :ignore`
      # because the case had only `{:ok, _}` and `{:error, _}` clauses.
      # The crash bubbled up as `{:error, {:case_clause, :ignore}}` and
      # the per-company supervisor died.
      assert :ignore = Watcher.start_link(opts_for_company(FsAlwaysIgnore))
    end

    test "returns :ignore when primary errors and fs_poll fallback returns :ignore" do
      assert :ignore = Watcher.start_link(opts_for_company(FsErrorThenIgnore))
    end

    test "supervisor with watcher returning :ignore stays alive" do
      # End-to-end: a parent supervisor with the Watcher as a child must
      # boot cleanly even when the watcher decides not to start. This is
      # the exact failure mode the user hit — `glorbo up` reporting OK
      # while the company supervisor was crashing on init.
      sup_name = Glorbo.Test.UniqueName.gen("watcher_noino_sup")
      child = {Watcher, opts_for_company(FsAlwaysIgnore)}

      {:ok, sup_pid} =
        Supervisor.start_link([child], strategy: :one_for_one, name: sup_name)

      assert Process.alive?(sup_pid)
      # `:ignore` from a child means "no child started"; the supervisor
      # keeps the spec but the running pid is `:undefined`. Either way
      # the supervisor itself is alive — that's the regression bar.
      for {_id, pid, _type, _mods} <- Supervisor.which_children(sup_pid) do
        assert pid in [:undefined, nil]
      end

      Supervisor.stop(sup_pid)
    end
  end
end
