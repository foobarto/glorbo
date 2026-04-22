defmodule Glorbo.Doctor do
  @moduledoc """
  Host prerequisite checks for Glorbo.

  Shared between `mix glorbo.doctor` (dev entry — `Mix.Tasks.Glorbo.Doctor`)
  and `./glorbo doctor` (release binary — argv dispatch in `Glorbo.Application`).
  Both entry points call `run_checks/0` and render via `Glorbo.Doctor.Formatter`.

  Every check is non-destructive: `check_glorbo_dir/1` creates
  `~/.glorbo/` idempotently but installs no system packages.
  `glorbo init` does package-level bootstrapping.

  Each check carries a `:severity` field (`:blocker` | `:warning`).
  Exit codes are severity-weighted via `exit_code/1`: 0 = all pass,
  1 = any blocker fails, 2 = only warnings fail.

  Podman/Ollama/runtime-image checks were removed in 2026-04-17 along
  with the Python-in-Podman runtime (GEP-5 D6). The remaining checks
  cover the host primitives that `bwrap`-sandboxed CLI agents depend
  on.
  """

  @type severity :: :blocker | :warning

  @type check :: %{
          name: String.t(),
          pass: boolean(),
          detail: String.t(),
          required: String.t(),
          severity: severity()
        }

  @minimum_kernel {5, 13}
  @minimum_disk_bytes 1_073_741_824
  @minimum_otp_release 27

  @spec run_checks() :: [check()]
  def run_checks, do: run_checks([])

  @doc """
  Re-run a single check by its string name (e.g. `"sockets_dir"`).
  Returns the `check()` map if the name is known, `nil` otherwise.

  Used by `Glorbo.Doctor.Fixer` to implement check→fix→recheck (WR-06):
  after a fixer reports success the caller invokes `recheck/1` on the
  same name and promotes `{:ok, _}` to `repaired` only when the fresh
  run returns `pass: true`.
  """
  @spec recheck(String.t()) :: check() | nil
  def recheck(name) when is_binary(name) do
    Enum.find(run_checks(), &(&1.name == name))
  end

  @spec run_checks(keyword()) :: [check()]
  def run_checks(deps) when is_list(deps) do
    # R30.2: on darwin, the linux-only kernel / namespace / bwrap
    # checks can't pass meaningfully. We keep the check list length
    # stable (10) but reclassify them to `:info` severity with a
    # `skipped_on: <os>` detail so:
    #   * existing tests asserting length == 10 still pass
    #   * macOS directors see which checks were skipped + why
    #   * exit-code math is unaffected (info passes are not blockers)
    linux_only =
      if linux?(),
        do: &run/3,
        else: &run_skipped_on_non_linux/3

    [
      linux_only.(:linux_kernel, :blocker, fn -> check_linux_kernel(deps) end),
      linux_only.(:uidmap, :blocker, fn -> check_uidmap(deps) end),
      run(:disk_space, :warning, fn -> check_disk_space(deps) end),
      run(:glorbo_dir, :blocker, fn -> check_glorbo_dir(deps) end),
      run(:erts_version, :blocker, fn -> check_erts_version(deps) end),
      run(:audit_dir, :blocker, fn -> check_audit_dir(deps) end),
      run(:sockets_dir, :warning, fn -> check_sockets_dir(deps) end),
      run(:private_files, :warning, fn -> check_private_files(deps) end),
      run(:tar_zstd, :warning, fn -> check_tar_zstd(deps) end),
      linux_only.(:bwrap, :blocker, fn -> check_bwrap(deps) end),
      linux_only.(:user_namespaces, :warning, fn -> check_user_namespaces(deps) end)
    ]
  end

  # Synthesise a `pass: true` entry with `:info` severity on non-
  # Linux hosts so the check list length + structure stay stable.
  # Real check body never runs.
  defp run_skipped_on_non_linux(name, _severity, _fun) do
    os = to_string(:os.type() |> elem(1))

    %{
      name: Atom.to_string(name),
      pass: true,
      detail: "skipped on #{os} (linux-only prerequisite; agent runtime runs unsandboxed here)",
      required: "linux",
      severity: :info
    }
  end

  defp linux?, do: match?({_, :linux}, :os.type())

  @doc """
  Severity-weighted exit code (D-45).

    * `0` — all checks pass
    * `1` — at least one blocker check fails
    * `2` — only warnings fail (no blockers failing)
  """
  @spec exit_code([check()]) :: 0 | 1 | 2
  def exit_code(results) when is_list(results) do
    cond do
      Enum.all?(results, & &1.pass) -> 0
      Enum.any?(results, &blocker_failed?/1) -> 1
      true -> 2
    end
  end

  defp blocker_failed?(%{pass: false} = check),
    do: Map.get(check, :severity, :blocker) == :blocker

  defp blocker_failed?(_), do: false

  defp run(name, severity, fun) do
    case fun.() do
      {:ok, detail, required} ->
        %{
          name: Atom.to_string(name),
          pass: true,
          detail: detail,
          required: required,
          severity: severity
        }

      {:fail, detail, required} ->
        %{
          name: Atom.to_string(name),
          pass: false,
          detail: detail,
          required: required,
          severity: severity
        }
    end
  end

  # ------ individual checks ------

  @spec check_linux_kernel(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_linux_kernel(deps) do
    cmd = Keyword.get(deps, :cmd_fun, &System.cmd/2)

    with {output, 0} <- cmd.("uname", ["-r"]),
         version <- String.trim(output),
         {:ok, {major, minor}} <- parse_kernel(version) do
      {min_major, min_minor} = @minimum_kernel
      pass = major > min_major or (major == min_major and minor >= min_minor)
      tag = if pass, do: :ok, else: :fail
      {tag, version, "≥ #{min_major}.#{min_minor}"}
    else
      {_output, _code} ->
        {:fail, "uname failed", "≥ #{elem(@minimum_kernel, 0)}.#{elem(@minimum_kernel, 1)}"}

      _ ->
        {:fail, "unknown kernel version",
         "≥ #{elem(@minimum_kernel, 0)}.#{elem(@minimum_kernel, 1)}"}
    end
  rescue
    _ ->
      {:fail, "uname not available", "≥ #{elem(@minimum_kernel, 0)}.#{elem(@minimum_kernel, 1)}"}
  end

  defp parse_kernel(v) do
    parts = v |> String.split(".") |> Enum.take(2) |> Enum.map(&Integer.parse/1)

    case parts do
      [{major, _}, {minor, _}] -> {:ok, {major, minor}}
      _ -> :error
    end
  end

  @spec check_uidmap(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_uidmap(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)

    case {which.("newuidmap"), which.("newgidmap")} do
      {nil, _} ->
        {:fail, "newuidmap not found in PATH", "uidmap (or shadow-utils) package installed"}

      {_, nil} ->
        {:fail, "newgidmap not found in PATH", "uidmap (or shadow-utils) package installed"}

      {u, g} ->
        {:ok, "#{u}, #{g}", "uidmap package installed"}
    end
  end

  @spec check_disk_space(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_disk_space(deps) do
    cmd = Keyword.get(deps, :cmd_fun, &System.cmd/2)
    home_fun = Keyword.get(deps, :home_fun, &System.user_home!/0)
    home = home_fun.()

    case cmd.("df", ["-B1", "--output=avail", home]) do
      {output, 0} ->
        bytes =
          output
          |> String.split("\n")
          |> Enum.at(1, "0")
          |> String.trim()
          |> parse_bytes()

        pass = bytes >= @minimum_disk_bytes
        tag = if pass, do: :ok, else: :fail
        {tag, "#{format_gb(bytes)} GB available in #{home}", "≥ 1 GB"}

      {_output, _code} ->
        {:fail, "df failed for #{home}", "≥ 1 GB"}
    end
  rescue
    _ -> {:fail, "df not available", "≥ 1 GB"}
  end

  defp parse_bytes(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp format_gb(bytes), do: Float.round(bytes / 1_073_741_824, 1)

  @spec check_glorbo_dir(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_glorbo_dir(deps) do
    path = glorbo_base(deps)
    write_probe(path, "writable directory", "#{path} (writable)")
  end

  # Resolves the Glorbo base directory honoring, in precedence:
  #   1. `deps[:base]` (test injection)
  #   2. `deps[:home_fun]` + ".glorbo" (legacy test override)
  #   3. `Glorbo.Filesystem.Hierarchy.default_root/0` (production: reads
  #      `:glorbo, :glorbo_base` or `GLORBO_HOME` env, falls back to
  #      `~/.glorbo`)
  defp glorbo_base(deps) do
    cond do
      base = Keyword.get(deps, :base) -> base
      home_fun = Keyword.get(deps, :home_fun) -> Path.join(home_fun.(), ".glorbo")
      true -> Glorbo.Filesystem.Hierarchy.default_root()
    end
  end

  @spec check_erts_version(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_erts_version(deps) do
    otp =
      Keyword.get(deps, :otp_release_fun, fn ->
        :otp_release |> :erlang.system_info() |> List.to_string()
      end)

    release = otp.()

    case Integer.parse(release) do
      {v, _} when v >= @minimum_otp_release ->
        {:ok, "OTP #{v}", "≥ #{@minimum_otp_release}"}

      {v, _} ->
        {:fail, "OTP #{v}", "≥ #{@minimum_otp_release}"}

      :error ->
        {:fail, "unparseable otp_release: #{release}", "≥ #{@minimum_otp_release}"}
    end
  end

  @spec check_audit_dir(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_audit_dir(deps) do
    path = Path.join([glorbo_base(deps), "audit", "_system"])
    write_probe(path, "writable append-only audit dir", "#{path} (writable)")
  end

  @spec check_sockets_dir(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_sockets_dir(deps) do
    path = Path.join([glorbo_base(deps), "runtime", "sockets"])

    try do
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
      write_probe(path, "writable runtime socket dir, mode 0700", "#{path} (writable, 0700)")
    rescue
      e in [File.Error] -> {:fail, Exception.message(e), "writable runtime socket dir, mode 0700"}
    end
  end

  @spec check_private_files(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_private_files(deps) do
    base = glorbo_base(deps)
    required = "config.md and logs/glorbo.log mode <= 0600"

    offenders =
      [{"config.md", "config.md"}, {"logs/glorbo.log", "logs/glorbo.log"}]
      |> Enum.flat_map(fn {label, rel} ->
        path = Path.join(base, rel)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, mode: mode}} ->
            perms = Bitwise.band(mode, 0o777)

            if perms > 0o600 do
              ["#{label}=0#{Integer.to_string(perms, 8)}"]
            else
              []
            end

          {:ok, %File.Stat{type: type}} ->
            ["#{label}=#{type}"]

          {:error, :enoent} ->
            []

          {:error, reason} ->
            ["#{label}=#{inspect(reason)}"]
        end
      end)

    if offenders == [] do
      {:ok, "config.md/logs.glorbo.log absent or private", required}
    else
      {:fail, Enum.join(offenders, ", "), required}
    end
  end

  # Canonical doctor write-probe: make the dir, touch a uniquely-named
  # sentinel, remove it, report writable. WR-04: unique-per-invocation
  # probe name so two concurrent doctors don't collide. Consolidates
  # the three duplicated probe blocks (TODO.md audit Medium #6).
  @spec write_probe(String.t(), String.t(), String.t()) ::
          {:ok | :fail, String.t(), String.t()}
  defp write_probe(path, required, ok_detail) do
    File.mkdir_p!(path)
    probe = Path.join(path, ".doctor_probe_#{System.unique_integer([:positive])}")
    File.write!(probe, "ok")
    File.rm!(probe)
    {:ok, ok_detail, required}
  rescue
    e in [File.Error] -> {:fail, Exception.message(e), required}
  end

  @spec check_tar_zstd(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_tar_zstd(deps) do
    cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    required = "tar with --zstd OR zstd binary in PATH"

    tar_has_zstd? =
      case invoke_cmd(cmd, "tar", ["--version"], stderr_to_stdout: true) do
        {output, 0} -> String.contains?(output, "zstd")
        _ -> false
      end

    cond do
      tar_has_zstd? -> {:ok, "tar --zstd supported", required}
      which.("zstd") != nil -> {:ok, "zstd binary present", required}
      true -> {:fail, "neither tar --zstd nor zstd binary available", required}
    end
  end

  # ------ Phase 3 checks (Plan 03-05) ------

  @spec check_bwrap(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_bwrap(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    required = "bubblewrap ≥ 0.8.0"

    case which.("bwrap") do
      nil ->
        {:fail, "bwrap not found in PATH (install `bubblewrap` package)", required}

      path ->
        cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)

        case invoke_cmd(cmd, path, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output), required}
          {output, code} -> {:fail, "bwrap --version exit #{code}: #{output}", required}
        end
    end
  end

  @spec check_user_namespaces(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_user_namespaces(deps) do
    read_fun = Keyword.get(deps, :read_fun, &File.read/1)
    required = "kernel user namespaces enabled (user.max_user_namespaces > 0)"

    case read_fun.("/proc/sys/user/max_user_namespaces") do
      {:ok, content} ->
        trimmed = String.trim(content)

        case Integer.parse(trimmed) do
          {n, _} when n > 0 ->
            {:ok, "max_user_namespaces=#{n}", required}

          {0, _} ->
            {:fail,
             "userns disabled (max_user_namespaces=0); bwrap --unshare-user-try will fall back insecurely",
             required}

          :error ->
            {:fail, "unparseable max_user_namespaces: #{trimmed}", required}
        end

      {:error, :enoent} ->
        {:fail,
         "/proc/sys/user/max_user_namespaces not present — running inside a container without proc mounted? bwrap sandboxing will not work here",
         required}

      {:error, reason} ->
        {:fail, "cannot read /proc/sys/user/max_user_namespaces: #{inspect(reason)}", required}
    end
  end

  # System.cmd/3 wrapper to let tests inject a 3-arity cmd_fun while keeping
  # Phase 1's 2-arity default for the original checks (kernel, uidmap, disk).
  defp default_cmd3(cmd, args, opts), do: System.cmd(cmd, args, opts)

  # Invoke a cmd_fun that may be 2-arity (Phase 1 tests) or 3-arity (Phase 2).
  # Preserves the D-44 additive-only contract: Phase 1 tests keep working with
  # their 2-arity fakes; Phase 2 checks that need stderr_to_stdout get it when
  # running on a 3-arity function (or fall back to ignoring opts on 2-arity).
  defp invoke_cmd(fun, cmd, args, opts) when is_function(fun, 3), do: fun.(cmd, args, opts)
  defp invoke_cmd(fun, cmd, args, _opts) when is_function(fun, 2), do: fun.(cmd, args)
end
