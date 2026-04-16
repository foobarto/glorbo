defmodule Glorbo.Doctor do
  @moduledoc """
  Host prerequisite checks for Glorbo.

  Shared between `mix glorbo.doctor` (dev entry — `Mix.Tasks.Glorbo.Doctor`)
  and `./glorbo doctor` (release binary — argv dispatch in `Glorbo.Application`).
  Both entry points call `run_checks/0` and render via `Glorbo.Doctor.Formatter`.

  Per D-21, every check is non-destructive: `check_glorbo_dir/1` creates
  `~/.glorbo/` idempotently but installs no system packages. Phase 2's
  `glorbo init` does package-level bootstrapping.

  **Phase 2 extensions (D-43, D-44, D-45).** 8 runtime checks appended
  after the original 5:

    podman, ollama, ollama_daemon, runtime_image, runtime_exec,
    audit_dir, sockets_dir, tar_zstd

  Each check carries a `:severity` field (`:blocker` | `:warning`).
  Exit codes are severity-weighted via `exit_code/1`: 0 = all pass,
  1 = any blocker fails, 2 = only warnings fail. JSON schema is
  purely additive — every Phase 1 key is preserved verbatim.
  """

  alias Glorbo.Init.Versions

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

  @runtime_image "ghcr.io/foobarto/glorbo-runtime:v0.1.0"
  @ollama_daemon_url ~c"http://127.0.0.1:11434/api/version"

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
    [
      # Phase 1 checks — names, shape, and order preserved (D-44 additive-only)
      run(:linux_kernel, :blocker, fn -> check_linux_kernel(deps) end),
      run(:uidmap, :blocker, fn -> check_uidmap(deps) end),
      run(:disk_space, :warning, fn -> check_disk_space(deps) end),
      run(:glorbo_dir, :blocker, fn -> check_glorbo_dir(deps) end),
      run(:erts_version, :blocker, fn -> check_erts_version(deps) end),
      # Phase 2 additions (D-43)
      run(:podman, :warning, fn -> check_podman(deps) end),
      run(:ollama, :warning, fn -> check_ollama(deps) end),
      run(:ollama_daemon, :warning, fn -> check_ollama_daemon(deps) end),
      run(:runtime_image, :warning, fn -> check_runtime_image(deps) end),
      run(:runtime_exec, :warning, fn -> check_runtime_exec(deps) end),
      run(:audit_dir, :blocker, fn -> check_audit_dir(deps) end),
      run(:sockets_dir, :warning, fn -> check_sockets_dir(deps) end),
      run(:tar_zstd, :warning, fn -> check_tar_zstd(deps) end),
      # Phase 3 additions (Plan 03-05; D-44 additive-only)
      run(:bwrap, :blocker, fn -> check_bwrap(deps) end),
      run(:user_namespaces, :warning, fn -> check_user_namespaces(deps) end)
    ]
  end

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
    {output, 0} = cmd.("uname", ["-r"])
    version = String.trim(output)

    case parse_kernel(version) do
      {:ok, {major, minor}} ->
        {min_major, min_minor} = @minimum_kernel
        pass = major > min_major or (major == min_major and minor >= min_minor)
        tag = if pass, do: :ok, else: :fail
        {tag, version, "≥ #{min_major}.#{min_minor}"}

      :error ->
        {:fail, "unparseable kernel version: #{version}", "≥ 5.13"}
    end
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
    {output, 0} = cmd.("df", ["-B1", "--output=avail", home])

    bytes =
      output
      |> String.split("\n")
      |> Enum.at(1, "0")
      |> String.trim()
      |> parse_bytes()

    pass = bytes >= @minimum_disk_bytes
    tag = if pass, do: :ok, else: :fail

    {tag, "#{format_gb(bytes)} GB available in #{home}", "≥ 1 GB"}
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
    home_fun = Keyword.get(deps, :home_fun, &System.user_home!/0)
    path = Path.join(home_fun.(), ".glorbo")

    try do
      File.mkdir_p!(path)
      # WR-04: unique probe name per invocation so two concurrent doctors
      # don't race on the same filename (doctor is documented idempotent).
      probe = Path.join(path, ".doctor_probe_#{System.unique_integer([:positive])}")
      File.write!(probe, "ok")
      File.rm!(probe)
      {:ok, "#{path} (writable)", "writable directory"}
    rescue
      e in [File.Error] ->
        {:fail, Exception.message(e), "writable directory"}
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

  # ------ Phase 2 checks ------

  @spec check_podman(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_podman(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    required = "podman ≥ #{Versions.podman_version()}"

    case which.("podman") do
      nil ->
        {:fail, "podman not found in PATH or ~/.glorbo/bin/", required}

      path ->
        cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)

        case invoke_cmd(cmd, path, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output), required}
          {output, code} -> {:fail, "podman --version exit #{code}: #{output}", required}
        end
    end
  end

  @spec check_ollama(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_ollama(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    home_fun = Keyword.get(deps, :home_fun, &System.user_home!/0)
    managed = Path.join([home_fun.(), ".glorbo", "bin", "ollama"])

    required = "ollama ≥ #{Versions.ollama_version()}"

    path =
      case which.("ollama") do
        p when is_binary(p) -> p
        nil -> if File.exists?(managed), do: managed, else: nil
      end

    case path do
      nil ->
        {:fail, "binary not found (checked PATH + ~/.glorbo/bin/ollama)", required}

      bin ->
        cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)

        case invoke_cmd(cmd, bin, ["--version"], stderr_to_stdout: true) do
          {output, 0} -> {:ok, String.trim(output), required}
          {output, code} -> {:fail, "ollama --version exit #{code}: #{output}", required}
        end
    end
  end

  @spec check_ollama_daemon(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_ollama_daemon(deps) do
    http_fun = Keyword.get(deps, :http_fun, &default_ollama_http/0)
    required = "HTTP 200 on http://127.0.0.1:11434/api/version"

    case http_fun.() do
      {:ok, 200, body} ->
        preview = body |> to_string() |> String.slice(0, 60)
        {:ok, "daemon responding (#{preview})", required}

      {:ok, status, _} ->
        {:fail, "daemon returned HTTP #{status}", required}

      {:error, reason} ->
        {:fail, "daemon not reachable: #{inspect(reason)}", required}
    end
  end

  defp default_ollama_http do
    _ = :inets.start()
    _ = :ssl.start()

    case :httpc.request(:get, {@ollama_daemon_url, []}, [{:timeout, 1000}], []) do
      {:ok, {{_, status, _}, _headers, body}} ->
        {:ok, status, List.to_string(body)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :httpc_error}
  end

  @spec check_runtime_image(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_runtime_image(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)
    required = "#{@runtime_image} present"

    case which.("podman") do
      nil ->
        {:fail, "podman not available; cannot check image", required}

      podman ->
        case invoke_cmd(cmd, podman, ["image", "exists", @runtime_image], stderr_to_stdout: true) do
          {_, 0} -> {:ok, "#{@runtime_image} present", required}
          {_, _} -> {:fail, "image not present (run `glorbo doctor --fix` to pull)", required}
        end
    end
  end

  @spec check_runtime_exec(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_runtime_exec(deps) do
    which = Keyword.get(deps, :which_fun, &System.find_executable/1)
    cmd = Keyword.get(deps, :cmd_fun, &default_cmd3/3)
    required = "`import litellm` succeeds in runtime image"

    case which.("podman") do
      nil ->
        {:fail, "podman not available", required}

      podman ->
        args = [
          "run",
          "--rm",
          "--network",
          "none",
          @runtime_image,
          "python3",
          "-c",
          "import litellm"
        ]

        case invoke_cmd(cmd, podman, args, stderr_to_stdout: true) do
          {_, 0} ->
            {:ok, "litellm importable in #{@runtime_image}", required}

          {output, code} ->
            {:fail, "podman run exit #{code}: #{String.slice(output, 0, 120)}", required}
        end
    end
  end

  @spec check_audit_dir(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_audit_dir(deps) do
    home_fun = Keyword.get(deps, :home_fun, &System.user_home!/0)
    path = Path.join([home_fun.(), ".glorbo", "audit", "_system"])

    try do
      File.mkdir_p!(path)
      # WR-04: unique per-invocation probe name.
      probe = Path.join(path, ".doctor_probe_#{System.unique_integer([:positive])}")
      File.write!(probe, "ok")
      File.rm!(probe)
      {:ok, "#{path} (writable)", "writable append-only audit dir"}
    rescue
      e in [File.Error] ->
        {:fail, Exception.message(e), "writable append-only audit dir"}
    end
  end

  @spec check_sockets_dir(keyword()) :: {:ok | :fail, String.t(), String.t()}
  defp check_sockets_dir(deps) do
    home_fun = Keyword.get(deps, :home_fun, &System.user_home!/0)
    path = Path.join([home_fun.(), ".glorbo", "runtime", "sockets"])

    try do
      File.mkdir_p!(path)
      File.chmod!(path, 0o700)
      # WR-04: unique per-invocation probe name.
      probe = Path.join(path, ".doctor_probe_#{System.unique_integer([:positive])}")
      File.write!(probe, "ok")
      File.rm!(probe)
      {:ok, "#{path} (writable, 0700)", "writable runtime socket dir, mode 0700"}
    rescue
      e in [File.Error] ->
        {:fail, Exception.message(e), "writable runtime socket dir, mode 0700"}
    end
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
    required = "bubblewrap ≥ #{Versions.bwrap_version()}"

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
