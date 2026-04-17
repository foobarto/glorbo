defmodule Glorbo.Test.GateHelpers do
  @moduledoc """
  Test-only shortcuts for driving `Glorbo.Approvals.Gate` without
  going through the PubSub broadcast path.

  Production code never needs these — the real trigger is a
  `Glorbo.Filesystem.Watcher` emitting `{:file_event, rel_path,
  events}` on `company:<co>:projects`. Tests that assert the
  Gate's behaviour in isolation synthesise the same message shape
  directly and flush via `:sys.get_state/1`.

  These helpers previously lived on `Glorbo.Approvals.Gate` as
  `resolve_approval/3` (public API). They were moved here because:

  * `:sys.get_state/1` is a debug-only hook — using it in production
    code makes the GenServer synchronous on a path where the
    real flow is `Process.send` + PubSub, which never blocks on the
    recipient's mailbox.

  * The only caller lives in `test/`, so the Gate's public surface
    can shrink accordingly.
  """

  @doc """
  Synthesise a `{:file_event, rel_path, [:modified]}` message to the
  Gate as if the Watcher had observed a write to the task sentinel,
  then round-trip `:sys.get_state/1` so the caller can assert on
  post-state immediately.

  The third argument is cosmetic (the Gate re-reads the file to
  determine approval state); it remains in the signature for call-
  site readability but is otherwise ignored.
  """
  @spec resolve_approval(GenServer.server(), String.t(), String.t()) :: :ok
  def resolve_approval(server, task_path, _status) do
    send(server, {:file_event, task_path, [:modified]})
    _ = :sys.get_state(server)
    :ok
  end
end
