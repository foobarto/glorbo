defmodule Glorbo.CLI.Dispatcher.Acp.PortIO do
  @moduledoc """
  Adapter from an Erlang `Port` to a `Glorbo.CLI.Dispatcher.Acp.Client.IO`
  struct (GEP-45 Phase 1b sub-slice 1b.5).

  Wraps an open port — typically returned by `Glorbo.Sandbox.Bwrap.start_acp/2`
  — so the client state machine can drive it without knowing about Port
  semantics. Three callbacks:

    * `read.(timeout_ms)` — blocks the calling process in a `receive`
      until the next `{port, {:data, chunk}}` message arrives, the port
      closes (`{port, {:exit_status, _}}`), or `timeout_ms` elapses.
      Returns `{:ok, chunk}` / `{:ok, ""}` (EOF) / `{:error, :timeout}` /
      `{:error, {:port_exit, status}}`.

    * `write.(iodata)` — non-blocking `Port.command/2`. Returns
      `:ok` or `{:error, reason}` if the command can't be queued
      (port already closed, owner mismatch, etc.).

    * `close.()` — best-effort `Port.close/1`. Idempotent: closing a
      port that already exited returns `:ok` rather than raising.

  The adapter is owned by the calling process. Tests usually skip it
  and inject a hand-rolled `%Client.IO{}` directly; production wiring
  in `Glorbo.CLI.Dispatcher` does
  `Bwrap.start_acp/2 |> PortIO.wrap/0 |> Client.run/3`.
  """

  alias Glorbo.CLI.Dispatcher.Acp.Client

  @doc """
  Wrap a live `Port` into a `%Client.IO{}` ready for `Client.run/3`.

  The returned struct's callbacks close over `port`. The caller MUST
  invoke them from the process that owns the port — `Port.command/2`
  and the receive loop both fail otherwise.
  """
  @spec wrap(port()) :: Client.IO.t()
  def wrap(port) when is_port(port) do
    %Client.IO{
      read: fn timeout_ms -> read(port, timeout_ms) end,
      write: fn iodata -> write(port, iodata) end,
      close: fn -> close(port) end
    }
  end

  @spec read(port(), non_neg_integer()) ::
          {:ok, binary()} | {:error, :timeout | {:port_exit, integer()} | term()}
  def read(port, timeout_ms) when is_port(port) and is_integer(timeout_ms) and timeout_ms >= 0 do
    receive do
      {^port, {:data, chunk}} when is_binary(chunk) ->
        {:ok, chunk}

      {^port, {:exit_status, status}} ->
        # Re-emit the exit message into the mailbox so any later
        # `await_close/2` call can still observe it. Without this,
        # the second drainer hangs on a missing message.
        send(self(), {port, {:exit_status, status}})
        {:ok, ""}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  @spec write(port(), iodata()) :: :ok | {:error, term()}
  def write(port, iodata) when is_port(port) do
    true = Port.command(port, iodata)
    :ok
  rescue
    e in [ArgumentError] -> {:error, {:port_command_failed, Exception.message(e)}}
  catch
    :error, reason -> {:error, {:port_command_failed, reason}}
  end

  @doc """
  Best-effort port teardown.

  Sends `Port.close/1` and discards the resulting `:DOWN` if the port
  was already closed. Returns `:ok` unconditionally — the caller does
  not branch on close-failure since the kernel-level cleanup
  (`--die-with-parent` + `--unshare-pid`) handles the descendants
  regardless.
  """
  @spec close(port()) :: :ok
  def close(port) when is_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, _ -> :ok
    end

    :ok
  end

  @doc """
  Drain remaining `{port, {:data, _}}` and `{port, {:exit_status, _}}`
  messages from the mailbox after the conversation has ended. Optional
  utility — the dispatcher calls this to keep the calling process's
  mailbox clean across many dispatches.

  Returns the exit status if observed, or `:no_exit_observed` after
  draining `timeout_ms` of silence.
  """
  @spec drain(port(), non_neg_integer()) :: integer() | :no_exit_observed
  def drain(port, timeout_ms) when is_port(port) do
    receive do
      {^port, {:data, _}} -> drain(port, timeout_ms)
      {^port, {:exit_status, status}} -> status
    after
      timeout_ms -> :no_exit_observed
    end
  end
end
