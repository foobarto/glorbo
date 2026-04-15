defmodule Glorbo.Company.AuditLog do
  @moduledoc """
  Append-only audit sink. Every security-relevant event (permission denial,
  budget hit, agent spawn, approval grant/deny) is written here as JSONL.

  *LOAD-BEARING INVARIANT (CLAUDE.md):* this module exposes ONLY `append/2`.
  There is no `update/2`, `delete/2`, or `edit/2`. Audit entries cannot be
  mutated. Enforced by `test/glorbo/stubs_test.exs`.

  *Phase 1 stub.* Phase 3 writes to `audit/YYYY-MM.jsonl` under the company
  directory and indexes into SQLite.
  """
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec append(GenServer.server(), map()) :: {:error, :not_implemented}
  def append(_server, _entry), do: {:error, :not_implemented}

  @impl GenServer
  def init(opts) do
    {:ok, %{company: Keyword.fetch!(opts, :company)}}
  end

  @impl GenServer
  def handle_call(_msg, _from, state),
    do: {:reply, {:error, :not_implemented}, state}

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(_msg, state), do: {:noreply, state}
end
