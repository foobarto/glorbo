defmodule Glorbo.CLI.Lifecycle.Serve do
  @moduledoc """
  `glorbo serve` — D-06: run glorbo in the foreground.

  Starts the full supervision tree (Phoenix endpoint + company + agent +
  watcher supervisors via `Glorbo.Application.start_supervision_tree_for_serve/0`)
  and blocks indefinitely. OTP's default `erl_signal_handler` converts
  SIGTERM → `init:stop/0`, which walks the supervision tree in the
  declared shutdown order and drains each child — no explicit signal trap
  is needed here.

  ## Endpoint auto-enable

  Phoenix endpoints default to `server: false` outside `mix phx.server`.
  In a Burrito release `runtime.exs` only flips `:server` to true when
  `PHX_SERVER` is set. Without this, `glorbo serve` starts the tree, prints
  the banner, and silently fails to bind port 4000. To make the binary
  work as advertised, we set `server: true` on the Endpoint here before
  booting the tree, gated on `:serve_starts_endpoint` so test config can
  opt out (ConnCase runs against an unbound Endpoint).

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
        IO.puts("Glorbo serving on #{build_url()}  (Ctrl-C to stop)")
        Process.sleep(opts[:exit_after])
        Audit.emit("serve", "complete", %{exit_after_ms: opts[:exit_after]})

        {:serve, 0, "glorbo serve exited (test mode after #{opts[:exit_after]}ms).\n"}

      true ->
        Audit.emit("serve", "start", %{})
        :ok = ensure_tree_started()
        IO.puts("Glorbo serving on #{build_url()}  (Ctrl-C to stop)")
        Process.sleep(:infinity)
    end
  end

  defp ensure_tree_started do
    :ok = enable_endpoint_serving()

    # Start distribution FIRST. If the name is already taken, that's
    # a running daemon — abort with a clear message instead of
    # booting a second supervision tree that would collide on the
    # pidfile + the dashboard port.
    case Glorbo.CLI.Lifecycle.Distribution.start() do
      :ok ->
        :ok

      {:error, :name_collision, node} ->
        IO.puts(
          :stderr,
          "Another glorbo instance is already registered as #{inspect(node)}. " <>
            "Run `glorbo status` to confirm, then `glorbo down` to stop it."
        )

        System.halt(3)

      {:error, reason, other} ->
        raise "Distribution.start/0 failed: #{inspect(reason)} (#{inspect(other)})"

      {:error, reason} ->
        raise "Distribution.start/0 failed: #{inspect(reason)}"
    end

    case Glorbo.Application.start_supervision_tree_for_serve() do
      {:ok, _pid} -> :ok
      {:ok, :already_started, _pid} -> :ok
      other -> raise "start_supervision_tree_for_serve failed: #{inspect(other)}"
    end
  end

  # Flip `server: true` on the GlorboWeb.Endpoint config so the release
  # binary binds port 4000 without needing PHX_SERVER set in the env.
  # Idempotent + opt-out via :serve_starts_endpoint (test.exs sets false).
  # Public for direct test exercise; not part of the supported CLI surface.
  @doc false
  @spec enable_endpoint_serving() :: :ok
  def enable_endpoint_serving do
    if Application.get_env(:glorbo, :serve_starts_endpoint, true) do
      cfg = Application.get_env(:glorbo, GlorboWeb.Endpoint, [])
      Application.put_env(:glorbo, GlorboWeb.Endpoint, Keyword.put(cfg, :server, true))
    end

    :ok
  end

  # Build the dashboard URL. GEP-0053 D18: state-aware — the `?token=` URL
  # is printed only in BOOTSTRAP (to reach /setup); once a passphrase is
  # set the banner points at /login with no token (the token grants no
  # browser access anymore + stays out of scrollback).
  defp build_url do
    Glorbo.CLI.Lifecycle.Banner.dashboard_url(
      "http://127.0.0.1:4000",
      Application.get_env(:glorbo, :director_password_hash),
      Application.get_env(:glorbo, :dashboard_token)
    )
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
