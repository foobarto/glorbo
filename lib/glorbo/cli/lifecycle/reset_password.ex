defmodule Glorbo.CLI.Lifecycle.ResetPassword do
  @moduledoc """
  `glorbo reset-password` — clear the director dashboard passphrase
  (GEP-0053 recovery path).

  Removes `director_password_hash` from `~/.glorbo/config.md`, dropping the
  instance back to BOOTSTRAP: on the next start the printed token URL leads
  to `/setup` to choose a new passphrase. The `dashboard_token` (MCP/CLI
  credential) is untouched.

  ## Refuses while the daemon is running (D17)

  This runs in a short-lived CLI BEAM that cannot mutate the daemon's
  `Application` env. If the server is up, clearing the file would NOT take
  effect until a restart — and worse, the running node would keep honouring
  the OLD passphrase, so the reset (which the operator may be running
  precisely because the passphrase is forgotten/compromised) would be a
  silent no-op. So we refuse with a "stop the server first" message when
  the pidfile shows a live process.

  Recovery requires local filesystem access — the same trust level as
  knowing the passphrase — so no further authentication is demanded here.

  ## Known limitation (accepted)

  The pidfile check is a point-in-time read: there is a narrow window where
  a daemon is *starting* (has already loaded the old hash into app-env) but
  has not yet written its pidfile, so `reset-password` could clear the disk
  hash while that daemon keeps serving the old passphrase until it
  restarts. This requires the operator to start and reset concurrently —
  not the normal stop → reset → start flow — so it is accepted rather than
  guarded with an OS-level startup lock (codex final review, Medium). The
  reset still takes effect on the next clean boot.
  """

  alias Glorbo.CLI.Audit
  alias Glorbo.CLI.Lifecycle.Pidfile

  @switches [help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @switches)

    if opts[:help], do: {:reset_password, 0, help_text()}, else: do_run()
  end

  defp do_run do
    base = glorbo_home()

    case Pidfile.status(base) do
      :running ->
        {:reset_password, 1,
         "glorbo is running — stop it first with `glorbo down`, then re-run " <>
           "`glorbo reset-password`.\nThe running daemon keeps the current " <>
           "passphrase in memory until it restarts, so a reset can't take " <>
           "effect while it is up.\n"}

      _not_running ->
        clear(base)
    end
  end

  defp clear(base) do
    Audit.emit("reset-password", "start", %{})

    case Glorbo.Config.clear_password_hash(base) do
      :ok ->
        Audit.emit("reset-password", "complete", %{})

        {:reset_password, 0,
         "Director passphrase cleared — Glorbo is back in first-run setup.\n" <>
           "Start it (`glorbo serve` or `glorbo up`) and open the printed " <>
           "token URL to choose a new passphrase.\n"}

      {:error, reason} ->
        {:reset_password, 1, "Could not clear the passphrase: #{inspect(reason)}\n"}
    end
  end

  defp glorbo_home do
    System.get_env("GLORBO_HOME") || Glorbo.Filesystem.Hierarchy.default_root()
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo reset-password — clear the director dashboard passphrase (GEP-0053).

    USAGE
      glorbo reset-password [--help]

    BEHAVIOR
      Removes `director_password_hash` from ~/.glorbo/config.md, returning
      the dashboard to first-run setup. On the next start, the token URL
      leads to /setup to choose a new passphrase. The MCP/CLI dashboard
      token is NOT changed.

      Refuses if the daemon is running (the running process keeps the old
      passphrase in memory until restart) — stop it with `glorbo down`
      first.

    EXIT CODES
      0   Passphrase cleared (or none was set).
      1   Refused (daemon running) or the config write failed.
    """
  end
end
