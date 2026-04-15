defmodule Glorbo.Doctor do
  @moduledoc """
  Host prerequisite checks for Glorbo.

  Shared between `mix glorbo.doctor` (dev entry — `Mix.Tasks.Glorbo.Doctor`)
  and `./glorbo doctor` (release binary — argv dispatch in `Glorbo.Application`).
  Both entry points call `run_checks/0` and render via `Glorbo.Doctor.Formatter`.

  Per D-21, every check is non-destructive: `check_glorbo_dir/1` creates
  `~/.glorbo/` idempotently but installs no system packages. Phase 2's
  `glorbo init` does package-level bootstrapping.
  """

  @type check :: %{
          name: String.t(),
          pass: boolean(),
          detail: String.t(),
          required: String.t()
        }

  @minimum_kernel {5, 13}
  @minimum_disk_bytes 1_073_741_824
  @minimum_otp_release 27

  @spec run_checks() :: [check()]
  def run_checks, do: run_checks([])

  @spec run_checks(keyword()) :: [check()]
  def run_checks(deps) when is_list(deps) do
    [
      run(:linux_kernel, fn -> check_linux_kernel(deps) end),
      run(:uidmap, fn -> check_uidmap(deps) end),
      run(:disk_space, fn -> check_disk_space(deps) end),
      run(:glorbo_dir, fn -> check_glorbo_dir(deps) end),
      run(:erts_version, fn -> check_erts_version(deps) end)
    ]
  end

  defp run(name, fun) do
    case fun.() do
      {:ok, detail, required} ->
        %{name: Atom.to_string(name), pass: true, detail: detail, required: required}

      {:fail, detail, required} ->
        %{name: Atom.to_string(name), pass: false, detail: detail, required: required}
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
      probe = Path.join(path, ".doctor_probe")
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
end
