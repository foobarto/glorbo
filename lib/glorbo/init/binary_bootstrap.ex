defmodule Glorbo.Init.BinaryBootstrap do
  @moduledoc """
  Downloads, verifies, and installs the two third-party static binaries
  (`podman` and `ollama`) that Phase 2 depends on.

  **System-first preference (D-04).** If the binary is in `$PATH`, return
  `{:ok, :system, path}` without touching `~/.glorbo/bin/`. Only download
  when absent.

  **SHA256 verification (D-03, Pitfall 1).** Downloaded archive bytes are
  hashed against the pinned hash in `Glorbo.Init.Versions` BEFORE any
  extraction. Mismatch returns `{:error, {:checksum_mismatch, expected,
  actual}}` and nothing lands in `~/.glorbo/bin/`.

  **Staging-dir extraction (W1 deviation vs D-05, T-2-12 mitigation).**
  D-05 locks the install location at `~/.glorbo/bin/`, but extraction goes
  through a tmp staging dir first — the verified bytes are unpacked there,
  then the explicit allow-list of binaries is copied into the final install
  path. This mitigates tarball "zip-slip" path escapes and TOCTOU races.
  The locked decision's intent (binary lives at `~/.glorbo/bin/`) is
  preserved; only the interim extraction path hops through tmp.

  **Offline tolerance (D-09).** curl failures for unreachable networks
  (DNS, connect-refused) return `{:ok, :skipped, reason}` so the caller
  (init orchestrator) can continue.

  **`.tar.zst` handling (Pitfall 2).** Ollama ships a zstd-compressed tar
  archive; extraction requires GNU tar ≥ 1.31 with `--zstd` OR a separate
  `zstd` binary on PATH. When absent, returns
  `{:error, :tar_zstd_missing}`.
  """

  require Logger
  alias Glorbo.Init.Versions

  @type arch :: :amd64 | :arm64

  @type result ::
          {:ok, :system, Path.t()}
          | {:ok, :downloaded, Path.t()}
          | {:ok, :skipped, String.t()}
          | {:error, term()}

  @spec ensure_podman(keyword()) :: result()
  def ensure_podman(opts \\ []), do: ensure(:podman, opts)

  @spec ensure_ollama(keyword()) :: result()
  def ensure_ollama(opts \\ []), do: ensure(:ollama, opts)

  @spec verify_sha256(Path.t(), String.t()) ::
          :ok | {:error, {:checksum_mismatch, String.t(), String.t()}}
  def verify_sha256(path, expected) when is_binary(expected) do
    actual =
      path
      |> File.stream!([], 65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
        :crypto.hash_update(acc, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected do
      :ok
    else
      {:error, {:checksum_mismatch, expected, actual}}
    end
  end

  # ---- dispatch ----

  defp ensure(binary, opts) do
    which_fun = Keyword.get(opts, :which_fun, &System.find_executable/1)

    case which_fun.(Atom.to_string(binary)) do
      path when is_binary(path) -> {:ok, :system, path}
      nil -> download_and_install(binary, opts)
    end
  end

  defp download_and_install(binary, opts) do
    arch = Keyword.get(opts, :arch, Versions.detect_arch())
    base = Keyword.get(opts, :base, Path.expand("~/.glorbo"))
    bin_dir = Path.join(base, "bin")
    File.mkdir_p!(bin_dir)

    url = Keyword.get(opts, :url, url_for(binary, arch))
    expected_sha = Keyword.get(opts, :expected_sha, sha_for(binary, arch))
    download_fun = Keyword.get(opts, :download_fun, &default_download/2)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "glorbo_#{binary}_#{arch}_#{System.unique_integer([:positive])}"
      )

    with {:ok, _} <- download_fun.(url, tmp),
         :ok <- verify_sha256(tmp, expected_sha),
         {:ok, dest} <- extract(binary, tmp, bin_dir, opts) do
      File.rm(tmp)
      {:ok, :downloaded, dest}
    else
      {:error, :enetunreach} ->
        _ = File.rm(tmp)
        {:ok, :skipped, "no network"}

      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  defp url_for(:podman, arch), do: Versions.podman_url(arch)
  defp url_for(:ollama, arch), do: Versions.ollama_url(arch)
  defp sha_for(:podman, arch), do: Versions.podman_sha256(arch)
  defp sha_for(:ollama, arch), do: Versions.ollama_sha256(arch)

  defp default_download(url, dest) do
    case System.cmd(
           "curl",
           ["-fsSL", "--connect-timeout", "10", url, "-o", dest],
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, dest}
      {_, code} when code in [6, 7] -> {:error, :enetunreach}
      {output, code} -> {:error, {:download_failed, code, output}}
    end
  end

  # ---- extraction ----

  defp extract(:podman, tar_gz, bin_dir, _opts) do
    staging = staging_dir("podman")

    case System.cmd("tar", ["-xzf", tar_gz, "-C", staging], stderr_to_stdout: true) do
      {_, 0} ->
        copy_podman_binaries(staging, bin_dir)
        File.rm_rf!(staging)
        {:ok, Path.join(bin_dir, "podman")}

      {output, code} ->
        File.rm_rf!(staging)
        {:error, {:extract_failed, code, output}}
    end
  end

  defp extract(:ollama, tar_zst, bin_dir, opts) do
    if tar_supports_zstd?(opts) do
      do_extract_ollama(tar_zst, bin_dir)
    else
      {:error, :tar_zstd_missing}
    end
  end

  defp do_extract_ollama(tar_zst, bin_dir) do
    staging = staging_dir("ollama")

    case System.cmd("tar", ["--zstd", "-xf", tar_zst, "-C", staging], stderr_to_stdout: true) do
      {_, 0} ->
        finish_ollama_install(staging, bin_dir)

      {output, code} ->
        File.rm_rf!(staging)
        {:error, {:extract_failed, code, output}}
    end
  end

  defp finish_ollama_install(staging, bin_dir) do
    src = Path.join([staging, "usr/bin/ollama"])
    dst = Path.join(bin_dir, "ollama")

    if File.exists?(src) do
      File.cp!(src, dst)
      File.chmod!(dst, 0o755)
      File.rm_rf!(staging)
      {:ok, dst}
    else
      File.rm_rf!(staging)
      {:error, :ollama_binary_not_in_archive}
    end
  end

  defp copy_podman_binaries(staging, bin_dir) do
    for bin <- ~w(podman crun conmon runc) do
      src = Path.join([staging, "usr/bin", bin])

      if File.exists?(src) do
        dst = Path.join(bin_dir, bin)
        File.cp!(src, dst)
        File.chmod!(dst, 0o755)
      end
    end
  end

  defp staging_dir(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "glorbo_#{name}_extract_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp tar_supports_zstd?(opts) do
    cmd = Keyword.get(opts, :cmd_fun, &System.cmd/3)

    case cmd.("tar", ["--version"], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, "zstd") or zstd_present?(opts)
      _ -> zstd_present?(opts)
    end
  end

  defp zstd_present?(opts) do
    which_fun = Keyword.get(opts, :which_fun, &System.find_executable/1)
    which_fun.("zstd") != nil
  end
end
