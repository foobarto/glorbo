defmodule Glorbo.CLI.Lifecycle.Serve do
  @moduledoc """
  `glorbo serve` — D-06: run glorbo in the foreground.

  Starts the full supervision tree (Phoenix endpoint + company + agent +
  watcher supervisors via `Glorbo.Application.start_supervision_tree_for_serve/0`)
  and blocks indefinitely. OTP's default `erl_signal_handler` converts
  SIGTERM → `init:stop/0`, which walks the supervision tree in the
  declared shutdown order and drains each child — no explicit signal trap
  is needed here.

  ## Test mode

  `--exit-after N` replaces the `Process.sleep(:infinity)` with
  `Process.sleep(N)` (milliseconds) and returns a tuple, so tests can
  exercise the "supervision tree starts" path without hanging the
  ExUnit runner. Production `glorbo serve` never passes this flag.
  """

  alias Glorbo.CLI.Audit

  @switches [help: :boolean, exit_after: :integer]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    cond do
      opts[:help] ->
        {:serve, 0, help_text()}

      is_integer(opts[:exit_after]) ->
        Audit.emit("serve", "start", %{exit_after_ms: opts[:exit_after]})
        :ok = ensure_tree_started()
        Process.sleep(opts[:exit_after])
        Audit.emit("serve", "complete", %{exit_after_ms: opts[:exit_after]})

        {:serve, 0,
         "glorbo serve exited (test mode after #{opts[:exit_after]}ms).\n"}

      true ->
        Audit.emit("serve", "start", %{})
        :ok = ensure_tree_started()
        IO.puts("Glorbo serving on http://127.0.0.1:4000 (Ctrl-C to stop)")
        Process.sleep(:infinity)
    end
  end

  defp ensure_tree_started do
    case Glorbo.Application.start_supervision_tree_for_serve() do
      {:ok, _pid} -> :ok
      {:ok, :already_started, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> raise "start_supervision_tree_for_serve failed: #{inspect(other)}"
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo serve — run the orchestrator in the foreground.

    USAGE
      glorbo serve [--exit-after MS] [--help]

    BEHAVIOR
      Starts the full supervision tree + Phoenix LiveView dashboard at
      http://127.0.0.1:4000. Blocks until SIGINT/SIGTERM (OTP's
      erl_signal_handler → init:stop/0 → supervisor drain).

    TEST-ONLY FLAGS
      --exit-after MS   Return after MS milliseconds instead of blocking
                        forever. Used by `mix test` to exercise the start
                        path without hanging.
    """
  end
end
