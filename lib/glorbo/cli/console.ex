defmodule Glorbo.CLI.Console do
  @moduledoc """
  `glorbo console` — open `iex --remsh` into the running release (D-24).

  Node name (`glorbo@127.0.0.1`) comes from `rel/vm.args.eex` and uses
  `--name` (long-name) per WR-09 correction. Cookie is read from
  `~/.glorbo/config.md` via `Glorbo.Config.erl_cookie/1`.

  When glorbo is not running (pidfile absent or stale), exits with code
  3 — matching the `systemctl is-active`-style convention established in
  Plan 05-02 for `down`/`status`.

  The `:skip_exec` option (test-only — never set by production callers)
  returns the iex argv as a string instead of spawning the child; tests
  assert argv shape without launching a real iex.

  Cookie handling (T-05-02): the cookie string is passed directly to
  `Port.open` as a `--cookie` argv element. It is NEVER logged, NEVER
  echoed to stdout (except under `:skip_exec` which is test-only), and
  the audit event detail payloads are empty maps (no cookie, no binary
  path). The cookie flows via argv → erlexec → Erlang distribution
  handshake — stdout/stderr/audit channels never see it in production.
  """
  alias Glorbo.CLI.Lifecycle.Pidfile
  alias Glorbo.CLI.Audit

  @remote_node "glorbo@127.0.0.1"
  @console_node "console@127.0.0.1"

  @spec run([String.t()]) :: Glorbo.CLI.result()
  @spec run([String.t()], keyword()) :: Glorbo.CLI.result()
  def run(argv, opts \\ []) do
    {parsed_opts, _positional, _invalid} =
      OptionParser.parse(argv, strict: [help: :boolean])

    cond do
      parsed_opts[:help] -> {:console, 0, help_text()}
      true -> do_run(opts)
    end
  end

  defp do_run(opts) do
    base = Keyword.get(opts, :base, Glorbo.Filesystem.Hierarchy.default_root())
    skip_exec? = Keyword.get(opts, :skip_exec, false)

    case Pidfile.status(base) do
      status when status in [:stopped, :stale] ->
        {:console, 3, "⚠ glorbo is not running. Run `glorbo up` first.\n"}

      :running ->
        case Glorbo.Config.erl_cookie(base) do
          {:ok, cookie} -> launch(cookie, skip_exec?)
          {:error, reason} -> {:console, 2, "Cookie read failed: #{inspect(reason)}\n"}
        end
    end
  end

  defp launch(cookie, skip_exec?) do
    argv = [
      "--name",
      @console_node,
      "--cookie",
      cookie,
      "--remsh",
      @remote_node
    ]

    cond do
      skip_exec? ->
        # Test-only path: return the argv shape without spawning iex.
        # Never reached in production (callers never set :skip_exec).
        {:console, 0, "iex " <> Enum.join(argv, " ") <> "\n"}

      is_nil(System.find_executable("iex")) ->
        {:console, 2, "iex not in PATH. Please install Elixir.\n"}

      true ->
        Audit.emit("console", "start", %{})
        iex = System.find_executable("iex")

        port =
          Port.open(
            {:spawn_executable, iex},
            [:nouse_stdio, :exit_status, args: argv]
          )

        receive do
          {^port, {:exit_status, code}} ->
            Audit.emit("console", "complete", %{exit: code})
            {:console, code, ""}
        end
    end
  end

  @spec help_text() :: String.t()
  def help_text do
    """
    glorbo console — open remote shell into the running orchestrator.

    USAGE
      glorbo console

    BEHAVIOR
      Spawns `iex --name console@127.0.0.1 --cookie <from config.md>
      --remsh glorbo@127.0.0.1`. Exits with code 3 if glorbo is not
      running.
    """
  end
end
