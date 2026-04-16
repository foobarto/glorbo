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

  @fixers %{
    "glorbo_dir" => &__MODULE__.fix_glorbo_dir/1,
    "audit_dir" => &__MODULE__.fix_audit_dir/1,
    "sockets_dir" => &__MODULE__.fix_sockets_dir/1,
    "podman" => &__MODULE__.fix_podman/1,
    "ollama" => &__MODULE__.fix_ollama/1,
    "runtime_image" => &__MODULE__.fix_runtime_image/1,
    "bwrap" => &__MODULE__.explain_bwrap/1
  }

  @doc "Public accessor for the fixer registry (tests introspect this)."
  @spec fixers() :: %{String.t() => (map() -> term())}
  def fixers, do: @fixers

  @spec run(keyword()) :: Glorbo.CLI.result()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    failing = Doctor.run_checks() |> Enum.reject(& &1.pass)

    if failing == [] do
      {:doctor, 0, "✓ all checks pass — nothing to repair.\n"}
    else
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
          handle_check(check, dry_run?, acc)
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

  defp handle_check(check, true = _dry_run, acc) do
    case Map.fetch(@fixers, check.name) do
      {:ok, _fixer} ->
        line = "would repair: #{check.name}"
        %{acc | attempted: acc.attempted + 1, lines: [line | acc.lines]}

      :error ->
        line = "no fixer registered for: #{check.name}"
        %{acc | skipped: acc.skipped + 1, lines: [line | acc.lines]}
    end
  end

  defp handle_check(check, false = _dry_run, acc) do
    case Map.fetch(@fixers, check.name) do
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
    path = Path.expand("~/.glorbo")

    case File.mkdir_p(path) do
      :ok -> {:ok, "created #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_audit_dir(_check) do
    path = Path.expand("~/.glorbo/audit/_system")

    case File.mkdir_p(path) do
      :ok -> {:ok, "created #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_sockets_dir(_check) do
    path = Path.expand("~/.glorbo/runtime/sockets")

    with :ok <- File.mkdir_p(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, "created #{path} (mode 0700)"}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def fix_podman(_check), do: normalise_tuple(Glorbo.Init.BinaryBootstrap.ensure_podman([]))

  @doc false
  def fix_ollama(_check), do: normalise_tuple(Glorbo.Init.BinaryBootstrap.ensure_ollama([]))

  @doc false
  def fix_runtime_image(_check), do: normalise_map(Glorbo.Init.ImagePull.run([]))

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

  # BinaryBootstrap returns tuple-shaped results. Normalise to the fixer
  # contract ({:ok, _} | {:error, _} | {:explain, _}).
  #
  #   {:ok, :system, path}      — binary already on PATH (no-op repair)
  #   {:ok, :downloaded, path}  — downloaded into ~/.glorbo/bin/
  #   {:ok, :skipped, reason}   — offline fallback (warn, continue)
  #   {:error, reason}          — genuine failure
  defp normalise_tuple({:ok, :system, path}), do: {:ok, "already present at #{path}"}
  defp normalise_tuple({:ok, :downloaded, path}), do: {:ok, "downloaded to #{path}"}

  defp normalise_tuple({:ok, :skipped, reason}),
    do: {:ok, "skipped: #{detail_to_string(reason)}"}

  defp normalise_tuple({:ok, detail}), do: {:ok, detail_to_string(detail)}
  defp normalise_tuple({:error, reason}), do: {:error, reason}
  defp normalise_tuple(other), do: {:error, {:unexpected, other}}

  # ImagePull.run/1 returns a map shaped `%{status: :ok|:skipped|:error,
  # detail: binary()}`. Normalise to the fixer contract.
  defp normalise_map(%{status: :ok, detail: detail}), do: {:ok, detail_to_string(detail)}

  defp normalise_map(%{status: :skipped, detail: detail}),
    do: {:ok, "skipped: #{detail_to_string(detail)}"}

  defp normalise_map(%{status: :error, detail: detail}),
    do: {:error, detail_to_string(detail)}

  defp normalise_map(other), do: {:error, {:unexpected, other}}

  defp detail_to_string(d) when is_binary(d), do: d
  defp detail_to_string(other), do: inspect(other)
end
