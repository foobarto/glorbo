defmodule Glorbo.Doctor.Fixer do
  @moduledoc """
  Registry of repair functions keyed by Doctor check name (D-16).

  Each fixer takes the failing check map and returns one of three tagged
  tuples:

    * `{:ok, detail}`       — repair succeeded.
    * `{:error, reason}`    — repair attempted but failed.
    * `{:explain, msg}`     — no auto-repair possible (sudo or manual step
      required); guidance is printed to the Director.

  `run/1` iterates `Doctor.run_checks/0`, dispatches each failing check to
  its registered fixer by check name, emits
  `cli.doctor.fix.<check>.<ok|failed|explained>` audit events via
  `Glorbo.CLI.Audit.emit/3`, and returns a `Glorbo.CLI.result()` tuple.

  `run(dry_run: true)` prints what would be repaired without running
  repairs (D-17).

  The @fixers registry keys MUST match the check names produced by
  `Glorbo.Doctor.run_checks/0` — otherwise the dispatch falls through to
  the "no fixer registered" branch and the check is counted as skipped.
  """

  alias Glorbo.Doctor
  alias Glorbo.CLI.Audit

  # Fixer registry keyed by check name. The host-package fixers are
  # registered as `:explain` by default; `--install-deps` swaps in the
  # `install_X` variants which actually run `sudo <pkgmgr> install`.
  @explain_fixers %{
    "glorbo_dir" => &__MODULE__.fix_glorbo_dir/1,
    "audit_dir" => &__MODULE__.fix_audit_dir/1,
    "sockets_dir" => &__MODULE__.fix_sockets_dir/1,
    "private_files" => &__MODULE__.fix_private_files/1,
    "migrations_pending" => &__MODULE__.fix_migrations_pending/1,
    "uidmap" => &__MODULE__.explain_uidmap/1,
    "bwrap" => &__MODULE__.explain_bwrap/1,
    "pasta" => &__MODULE__.explain_pasta/1
  }

  @install_fixers %{
    "glorbo_dir" => &__MODULE__.fix_glorbo_dir/1,
    "audit_dir" => &__MODULE__.fix_audit_dir/1,
    "sockets_dir" => &__MODULE__.fix_sockets_dir/1,
    "private_files" => &__MODULE__.fix_private_files/1,
    "migrations_pending" => &__MODULE__.fix_migrations_pending/1,
    "uidmap" => &__MODULE__.install_uidmap/1,
    "bwrap" => &__MODULE__.install_bwrap/1,
    "pasta" => &__MODULE__.install_pasta/1
  }

  @doc "Public accessor for the default fixer registry (tests introspect this)."
  @spec fixers() :: %{String.t() => (map() -> term())}
  def fixers, do: @explain_fixers

  @doc """
  Resolve the active fixer registry for an option set. When
  `install_deps: true`, host-package checks (`bwrap`, `pasta`,
  `uidmap`) route to `install_*` variants that run `sudo <pkgmgr>`;
  otherwise they print install instructions via the `explain_*` path.
  """
  @spec fixers_for(keyword()) :: %{String.t() => (map() -> term())}
  def fixers_for(opts) do
    if Keyword.get(opts, :install_deps, false), do: @install_fixers, else: @explain_fixers
  end

  @spec run(keyword()) :: Glorbo.CLI.result()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    failing = Doctor.run_checks() |> Enum.reject(& &1.pass)

    if failing == [] do
      {:doctor, 0, "✓ all checks pass — nothing to repair.\n"}
    else
      registry = fixers_for(opts)

      acc = %{
        attempted: 0,
        repaired: 0,
        failed: 0,
        explained: 0,
        skipped: 0,
        lines: []
      }

      summary =
        Enum.reduce(failing, acc, fn check, acc ->
          handle_check(check, dry_run?, registry, acc)
        end)

      exit_code = resolve_exit_code(summary, dry_run?)
      {:doctor, exit_code, format_summary(summary)}
    end
  end

  # WR-05: after repairs, use Doctor.run_checks + Doctor.exit_code/1 to
  # get the severity-weighted truth. Unregistered blockers (no fixer
  # exists) were previously counted as `skipped` → exit 0, which
  # contradicts D-28. Re-running also covers WR-06 (check→fix→recheck)
  # automatically. For dry-run we keep the legacy semantics (no state
  # change → static summary-based code).
  defp resolve_exit_code(summary, true = _dry_run) do
    if summary.failed > 0, do: 1, else: 0
  end

  defp resolve_exit_code(_summary, false) do
    Doctor.exit_code(Doctor.run_checks())
  end

  defp handle_check(check, true = _dry_run, registry, acc) do
    case Map.fetch(registry, check.name) do
      {:ok, _fixer} ->
        line = "would repair: #{check.name}"
        %{acc | attempted: acc.attempted + 1, lines: [line | acc.lines]}

      :error ->
        line = "no fixer registered for: #{check.name}"
        %{acc | skipped: acc.skipped + 1, lines: [line | acc.lines]}
    end
  end

  defp handle_check(check, false = _dry_run, registry, acc) do
    case Map.fetch(registry, check.name) do
      {:ok, fixer} ->
        run_fixer(fixer, check, acc)

      :error ->
        line = "no fixer registered for: #{check.name}"
        %{acc | skipped: acc.skipped + 1, lines: [line | acc.lines]}
    end
  end

  defp run_fixer(fixer, check, acc) do
    case safe_apply(fixer, check) do
      {:ok, msg} ->
        # WR-06: re-invoke the single check by name; promote to `repaired`
        # only if the fresh check passes. A fixer that reports {:ok, _}
        # but leaves the check still failing is a genuine failure.
        case Doctor.recheck(check.name) do
          %{pass: true} ->
            line = "✓ #{check.name}: #{msg}"
            Audit.emit("doctor", "fix.#{check.name}.ok", %{detail: msg})

            %{
              acc
              | attempted: acc.attempted + 1,
                repaired: acc.repaired + 1,
                lines: [line | acc.lines]
            }

          %{pass: false, detail: detail} ->
            line = "✗ #{check.name}: fixer reported ok but recheck failed: #{detail}"

            Audit.emit("doctor", "fix.#{check.name}.recheck_failed", %{
              fixer_detail: msg,
              recheck_detail: detail
            })

            %{
              acc
              | attempted: acc.attempted + 1,
                failed: acc.failed + 1,
                lines: [line | acc.lines]
            }

          nil ->
            # Recheck impossible (check vanished from registry). Trust the
            # fixer's {:ok, _} and count as repaired — but log a warning
            # line so the Director sees the degraded verification.
            line = "✓ #{check.name}: #{msg} (recheck unavailable)"
            Audit.emit("doctor", "fix.#{check.name}.ok", %{detail: msg})

            %{
              acc
              | attempted: acc.attempted + 1,
                repaired: acc.repaired + 1,
                lines: [line | acc.lines]
            }
        end

      {:error, reason} ->
        line = "✗ #{check.name}: #{inspect(reason)}"
        Audit.emit("doctor", "fix.#{check.name}.failed", %{reason: inspect(reason)})

        %{
          acc
          | attempted: acc.attempted + 1,
            failed: acc.failed + 1,
            lines: [line | acc.lines]
        }

      {:explain, guidance} ->
        Audit.emit("doctor", "fix.#{check.name}.explained", %{guidance: guidance})

        line =
          "ℹ #{check.name}:\n#{String.trim_trailing(guidance)}"

        %{
          acc
          | attempted: acc.attempted + 1,
            explained: acc.explained + 1,
            lines: [line | acc.lines]
        }
    end
  end

  defp safe_apply(fixer, check) do
    fixer.(check)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exited, inspect(reason)}}
  end

  defp format_summary(%{
         attempted: a,
         repaired: r,
         failed: f,
         explained: e,
         lines: lines
       }) do
    body = lines |> Enum.reverse() |> Enum.join("\n")

    footer =
      "\n\ndoctor --fix summary: attempted=#{a} repaired=#{r} failed=#{f} explained=#{e}\n"

    body <> footer
  end

  # ---------- Individual fixers ----------

  @doc false
  def fix_glorbo_dir(_check) do
    path = Glorbo.Filesystem.Hierarchy.default_root()

    case File.mkdir_p(path) do
      :ok -> {:ok, "created #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_audit_dir(_check) do
    path = Path.join([Glorbo.Filesystem.Hierarchy.default_root(), "audit", "_system"])

    case File.mkdir_p(path) do
      :ok -> {:ok, "created #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_sockets_dir(_check) do
    path = Path.join([Glorbo.Filesystem.Hierarchy.default_root(), "runtime", "sockets"])

    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, "created #{path} (mode 0700)"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_private_files(_check) do
    base = Glorbo.Filesystem.Hierarchy.default_root()

    case chmod_private_files(
           [
             Path.join(base, "config.md"),
             Path.join([base, "logs", "glorbo.log"])
           ] ++ native_credentials_paths()
         ) do
      {:ok, []} ->
        {:ok, "no private files present"}

      {:ok, changed} ->
        {:ok, "chmod 0600 on #{Enum.join(changed, ", ")}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chmod_private_files(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular}} ->
          case File.chmod(path, 0o600) do
            :ok -> {:cont, {:ok, [path | acc]}}
            {:error, reason} -> {:halt, {:error, {path, reason}}}
          end

        {:error, :enoent} ->
          {:cont, {:ok, acc}}

        {:ok, %File.Stat{type: type}} ->
          {:halt, {:error, {path, {:not_regular_file, type}}}}

        {:error, reason} ->
          {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, changed} -> {:ok, Enum.reverse(changed)}
      {:error, _} = err -> err
    end
  end

  defp native_credentials_paths do
    dir = Glorbo.Filesystem.Hierarchy.native_credentials_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".toml"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  @doc false
  def fix_migrations_pending(_check) do
    case Glorbo.CLI.Migrate.run([]) do
      {:migrate, 0, out} ->
        {:ok, String.trim_trailing(out)}

      {:migrate, _code, out} ->
        {:error, String.trim_trailing(out)}
    end
  end

  @doc false
  def explain_bwrap(_check) do
    {:explain,
     """
     bwrap is required for sandboxed agent execution. Install via your package manager:

       fedora:  sudo dnf install bubblewrap
       debian:  sudo apt install bubblewrap
       arch:    sudo pacman -S bubblewrap

     Then re-run `glorbo doctor`.
     """}
  end

  @doc false
  def explain_pasta(_check) do
    {:explain,
     """
     pasta is required on Linux for enforced `network: proxy` agents. Install via your package manager:

       fedora:  sudo dnf install passt
       debian:  sudo apt install passt
       arch:    sudo pacman -S passt

     Then re-run `glorbo doctor`.
     """}
  end

  @doc false
  def explain_uidmap(_check) do
    {:explain,
     """
     newuidmap/newgidmap are required for rootless user-namespace mapping.
     Install via your package manager:

       fedora:  sudo dnf install shadow-utils
       debian:  sudo apt install uidmap
       arch:    sudo pacman -S shadow

     Then re-run `glorbo doctor`.
     """}
  end

  # ---------- Package installer (--install-deps path) ----------
  #
  # Each install_X fixer detects the host distro from /etc/os-release,
  # picks the right (pkgmgr, package_name) pair, and runs
  # `sudo <pkgmgr> install -y <pkg>`. Returns:
  #
  #   * `{:ok, "installed <pkg> via <pkgmgr>"}`  on exit 0
  #   * `{:error, {:install_failed, code, output}}`  on non-zero exit
  #   * `{:explain, …}`  when the distro isn't known to us — falls back
  #     to the same printed instructions the default --fix path emits,
  #     so a user on an unsupported distro still gets the runbook.
  #
  # `sudo` itself prompts for a password unless cached; the prompt
  # appears on the controlling TTY and the install proceeds normally
  # afterwards. There's no machine-readable signal for "missing
  # sudoers entry" so failures collapse into `:install_failed` with
  # the exit code + last output bytes.

  @doc false
  def install_bwrap(check), do: install_pkg(check, :bwrap)

  @doc false
  def install_pasta(check), do: install_pkg(check, :pasta)

  @doc false
  def install_uidmap(check), do: install_pkg(check, :uidmap)

  defp install_pkg(_check, kind) do
    case detect_distro() do
      {:ok, family} ->
        case package_command(family, kind) do
          {:ok, {pkgmgr, pkg, args}} ->
            run_install(pkgmgr, pkg, args)

          :unsupported ->
            explainer_for(kind).(%{})
        end

      :error ->
        explainer_for(kind).(%{})
    end
  end

  defp run_install(pkgmgr, pkg, args) do
    full_args = ["-n", pkgmgr | args] ++ [pkg]
    # `sudo -n` causes sudo to fail (rather than block forever) when no
    # cached credentials AND no controlling TTY are available; if the
    # user IS at a TTY, sudo will still prompt them via the parent
    # process. Stderr captured for the error path so the operator sees
    # the actual reason on failure.
    case System.cmd("sudo", full_args, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, "installed #{pkg} via #{pkgmgr}"}

      {output, code} ->
        trimmed =
          output
          |> String.trim()
          |> tail_lines(8)

        {:error, {:install_failed, code, trimmed}}
    end
  rescue
    e -> {:error, {:install_exception, Exception.message(e)}}
  end

  defp tail_lines(str, n) do
    str
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp explainer_for(:bwrap), do: &__MODULE__.explain_bwrap/1
  defp explainer_for(:pasta), do: &__MODULE__.explain_pasta/1
  defp explainer_for(:uidmap), do: &__MODULE__.explain_uidmap/1

  # Map (distro family, check kind) → (package manager, package name,
  # extra-args). Returns `:unsupported` when we don't know the distro;
  # caller falls back to the printed runbook.
  @spec package_command(:fedora | :debian | :arch, :bwrap | :pasta | :uidmap) ::
          {:ok, {String.t(), String.t(), [String.t()]}} | :unsupported
  defp package_command(:fedora, :bwrap), do: {:ok, {"dnf", "bubblewrap", ["install", "-y"]}}
  defp package_command(:fedora, :pasta), do: {:ok, {"dnf", "passt", ["install", "-y"]}}
  defp package_command(:fedora, :uidmap), do: {:ok, {"dnf", "shadow-utils", ["install", "-y"]}}

  defp package_command(:debian, :bwrap), do: {:ok, {"apt", "bubblewrap", ["install", "-y"]}}
  defp package_command(:debian, :pasta), do: {:ok, {"apt", "passt", ["install", "-y"]}}
  defp package_command(:debian, :uidmap), do: {:ok, {"apt", "uidmap", ["install", "-y"]}}

  defp package_command(:arch, :bwrap), do: {:ok, {"pacman", "bubblewrap", ["-S", "--noconfirm"]}}
  defp package_command(:arch, :pasta), do: {:ok, {"pacman", "passt", ["-S", "--noconfirm"]}}
  defp package_command(:arch, :uidmap), do: {:ok, {"pacman", "shadow", ["-S", "--noconfirm"]}}

  defp package_command(_family, _kind), do: :unsupported

  # Read /etc/os-release and classify into a distro family. Honours
  # `ID` first (canonical), then `ID_LIKE` (derivative distros — pop,
  # mint, manjaro, etc.). Test seam: GLORBO_DOCTOR_DISTRO_OVERRIDE
  # short-circuits so unit tests can pin a family without rewriting
  # /etc.
  @spec detect_distro() :: {:ok, :fedora | :debian | :arch} | :error
  def detect_distro do
    case System.get_env("GLORBO_DOCTOR_DISTRO_OVERRIDE") do
      nil -> read_os_release()
      "fedora" -> {:ok, :fedora}
      "debian" -> {:ok, :debian}
      "arch" -> {:ok, :arch}
      _ -> :error
    end
  end

  defp read_os_release do
    case File.read("/etc/os-release") do
      {:ok, body} -> classify_os_release(body)
      {:error, _} -> :error
    end
  end

  defp classify_os_release(body) do
    fields = parse_os_release(body)
    id = Map.get(fields, "ID", "") |> String.downcase()
    like = Map.get(fields, "ID_LIKE", "") |> String.downcase()

    cond do
      family_match?(id, like, ~w(fedora rhel centos rocky almalinux)) -> {:ok, :fedora}
      family_match?(id, like, ~w(debian ubuntu pop mint kali raspbian)) -> {:ok, :debian}
      family_match?(id, like, ~w(arch endeavouros manjaro)) -> {:ok, :arch}
      true -> :error
    end
  end

  defp family_match?(id, like, names) do
    id in names or
      Enum.any?(names, fn n ->
        String.contains?(like, n)
      end)
  end

  defp parse_os_release(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          Map.put(acc, String.trim(key), strip_quotes(String.trim(value)))

        _ ->
          acc
      end
    end)
  end

  defp strip_quotes(<<?", rest::binary>>),
    do: String.trim_trailing(rest, "\"")

  defp strip_quotes(<<?', rest::binary>>),
    do: String.trim_trailing(rest, "'")

  defp strip_quotes(other), do: other
end
