defmodule Glorbo.CLI.Install do
  @moduledoc """
  `glorbo install` / `glorbo uninstall` — manage a user-level systemd
  unit so the Glorbo orchestrator runs in the background across logins
  without manual `glorbo up`.

  Linux-only. Writes `~/.config/systemd/user/glorbo.service`, calls
  `systemctl --user daemon-reload`, then `systemctl --user enable --now`
  on install / `disable --now` on uninstall.

  The service unit invokes `<self> serve` as `Type=simple` with
  `Restart=on-failure` — same in-foreground flow as `glorbo serve`,
  no separate daemon path. This avoids the `up`/`down` pidfile
  dance entirely; systemd owns the supervision.
  """

  alias Glorbo.CLI.Lifecycle.Daemon

  @unit_name "glorbo.service"
  @install_switches [help: :boolean, force: :boolean, no_start: :boolean]
  @uninstall_switches [help: :boolean]

  @spec run([String.t()]) :: Glorbo.CLI.result()
  def run(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @install_switches)

    cond do
      opts[:help] -> {:install, 0, install_help_text()}
      not systemd_available?() -> {:install, 2, no_systemd_message()}
      true -> do_install(opts)
    end
  end

  @spec uninstall([String.t()]) :: Glorbo.CLI.result()
  def uninstall(argv) do
    {opts, _positional, _invalid} = OptionParser.parse(argv, strict: @uninstall_switches)

    cond do
      opts[:help] -> {:uninstall, 0, uninstall_help_text()}
      not systemd_available?() -> {:uninstall, 2, no_systemd_message()}
      true -> do_uninstall()
    end
  end

  defp do_install(opts) do
    path = unit_path()

    if File.exists?(path) and opts[:force] != true do
      {:install, 2,
       "glorbo install — unit already exists at #{path}.\n" <>
         "Pass --force to overwrite, or run `glorbo uninstall` first.\n"}
    else
      with {:ok, binary} <- locate_binary(),
           :ok <- write_unit(path, binary),
           :ok <- daemon_reload(),
           :ok <- maybe_enable_now(opts) do
        {:install, 0, install_success_message(path, binary, opts)}
      else
        {:error, reason} ->
          {:install, 2, "glorbo install — failed: #{format_reason(reason)}\n"}
      end
    end
  end

  defp do_uninstall do
    path = unit_path()

    if File.exists?(path) do
      _ = systemctl(["disable", "--now", @unit_name])
      _ = File.rm(path)
      _ = systemctl(["daemon-reload"])
      _ = systemctl(["reset-failed", @unit_name])

      {:uninstall, 0,
       "glorbo uninstall — removed #{path} and disabled service.\n" <>
         "Filesystem state in ~/.glorbo/ is untouched.\n"}
    else
      {:uninstall, 0, "glorbo uninstall — no unit at #{path} (nothing to do).\n"}
    end
  end

  defp write_unit(path, binary) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, service_unit(binary))
    File.chmod!(path, 0o644)
    :ok
  rescue
    e -> {:error, {:unit_write, Exception.message(e)}}
  end

  defp daemon_reload do
    case systemctl(["daemon-reload"]) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:daemon_reload, code, String.trim(out)}}
    end
  end

  defp maybe_enable_now(opts) do
    if opts[:no_start] do
      :ok
    else
      case systemctl(["enable", "--now", @unit_name]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {:enable_now, code, String.trim(out)}}
      end
    end
  end

  defp install_success_message(path, binary, opts) do
    base =
      "glorbo install — unit installed at #{path}\n" <>
        "  binary: #{binary}\n"

    base <>
      if opts[:no_start] do
        "  service NOT started (--no-start). Run `systemctl --user enable --now glorbo` to enable.\n"
      else
        "  service: enabled + running. Dashboard: http://127.0.0.1:4000\n" <>
          linger_hint()
      end
  end

  # systemd user services stop when the user logs out unless lingering
  # is enabled. Detect via `loginctl show-user` and print a one-liner
  # so the user can opt in (sudo loginctl enable-linger <user>).
  defp linger_hint do
    case lingering?() do
      true ->
        "  linger: enabled (service survives logout).\n"

      false ->
        "  linger: not enabled. To keep the service running across logouts:\n" <>
          "    sudo loginctl enable-linger #{System.get_env("USER") || "$USER"}\n"

      :unknown ->
        ""
    end
  end

  defp lingering? do
    user = System.get_env("USER")

    cond do
      is_nil(user) ->
        :unknown

      System.find_executable("loginctl") == nil ->
        :unknown

      true ->
        case System.cmd("loginctl", ["show-user", user, "--property=Linger"],
               stderr_to_stdout: true
             ) do
          {"Linger=yes\n", 0} -> true
          {"Linger=no\n", 0} -> false
          _ -> :unknown
        end
    end
  end

  defp locate_binary do
    {:ok, Daemon.self_binary()}
  rescue
    e in RuntimeError -> {:error, {:binary_not_found, Exception.message(e)}}
  end

  defp systemctl(args) do
    System.cmd("systemctl", ["--user" | args], stderr_to_stdout: true)
  end

  defp systemd_available? do
    # Probe the user manager rather than `/run/systemd/system` so the
    # check works inside containers/distroboxes where the host's user
    # systemd is reachable over the socket but the system manager
    # isn't bind-mounted in.
    case System.find_executable("systemctl") do
      nil ->
        false

      _ ->
        case System.cmd("systemctl", ["--user", "show", "--property=Version"],
               stderr_to_stdout: true
             ) do
          {_, 0} -> true
          _ -> false
        end
    end
  end

  defp no_systemd_message do
    "glorbo install — requires systemd (Linux user services).\n" <>
      "On macOS, run `glorbo up` from a launchd .plist or use `glorbo serve`\n" <>
      "under your supervisor of choice.\n"
  end

  defp format_reason({:binary_not_found, msg}), do: "binary not found — #{msg}"
  defp format_reason({:unit_write, msg}), do: "unit write failed — #{msg}"

  defp format_reason({:daemon_reload, code, out}),
    do: "systemctl daemon-reload exit=#{code}: #{out}"

  defp format_reason({:enable_now, code, out}),
    do: "systemctl enable --now exit=#{code}: #{out}"

  defp format_reason(other), do: inspect(other)

  @doc """
  Returns the absolute path the unit file is written to.
  Honours `XDG_CONFIG_HOME`; falls back to `$HOME/.config`.
  """
  @spec unit_path() :: Path.t()
  def unit_path do
    config_home =
      System.get_env("XDG_CONFIG_HOME") ||
        Path.join(System.get_env("HOME") || System.user_home!(), ".config")

    Path.join([config_home, "systemd", "user", @unit_name])
  end

  @doc """
  Render the systemd unit file for a given binary path. Pure — exposed
  so tests can assert exact content without writing to disk.
  """
  @spec service_unit(Path.t()) :: String.t()
  def service_unit(binary) do
    """
    [Unit]
    Description=Glorbo — filesystem-first agent orchestration
    Documentation=https://github.com/foobarto/glorbo
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    ExecStart=#{shell_quote(binary)} serve
    Restart=on-failure
    RestartSec=3
    KillSignal=SIGINT
    TimeoutStopSec=15

    [Install]
    WantedBy=default.target
    """
  end

  defp shell_quote(path) do
    if String.contains?(path, [" ", "\t", "'", "\"", "$"]) do
      "\"" <> String.replace(path, "\"", "\\\"") <> "\""
    else
      path
    end
  end

  @spec install_help_text() :: String.t()
  def install_help_text do
    """
    glorbo install — install + enable a user-level systemd service.

    USAGE
      glorbo install [--force] [--no-start] [--help]

    FLAGS
      --force      Overwrite an existing #{@unit_name}.
      --no-start   Write the unit but don't `enable --now` it.

    SIDE EFFECTS
      Writes ~/.config/systemd/user/#{@unit_name} (or
      $XDG_CONFIG_HOME/systemd/user/#{@unit_name}), runs
      `systemctl --user daemon-reload`, then by default
      `systemctl --user enable --now #{@unit_name}`.

      The unit invokes `<this binary> serve` under Type=simple with
      Restart=on-failure. `~/.glorbo/` is untouched.

      To survive logouts: `sudo loginctl enable-linger <you>`.

    EXIT CODES
      0   Unit installed (and started, unless --no-start).
      2   Unit already exists (use --force), systemd unavailable,
          or systemctl failed (message names the cause).

    SEE ALSO
      glorbo uninstall, glorbo serve, glorbo up
    """
  end

  @spec uninstall_help_text() :: String.t()
  def uninstall_help_text do
    """
    glorbo uninstall — disable + remove the systemd unit.

    USAGE
      glorbo uninstall [--help]

    SIDE EFFECTS
      `systemctl --user disable --now #{@unit_name}`, removes
      ~/.config/systemd/user/#{@unit_name}, then
      `systemctl --user daemon-reload`. ~/.glorbo/ is untouched.

    EXIT CODES
      0   Unit removed (or no unit was present).
      2   Systemd unavailable.

    SEE ALSO
      glorbo install, glorbo down, glorbo backup
    """
  end
end
