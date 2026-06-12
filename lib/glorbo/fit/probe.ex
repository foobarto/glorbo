defmodule Glorbo.Fit.Probe do
  @moduledoc """
  Host hardware probe for `Glorbo.Fit` (GEP-59). Reads system RAM and,
  best-effort, the GPU (VRAM + name + backend) so the scorer can size a
  fitting model. Ported from odysseus `services/hwfit/hardware.py`.

  Probe order, Linux-first (the glorbo host platform):

    1. `/proc/meminfo` → total + available RAM (read once, no shell).
    2. `nvidia-smi` → NVIDIA VRAM + name (`backend: "cuda"`).
    3. `rocm-smi` → AMD VRAM + name (`backend: "rocm"`).
    4. macOS `sysctl` → Apple-Silicon unified memory (`backend: "metal"`).

  ## Degradation contract (GEP-59 goal)

  **A probe FAILURE never crashes.** Every external call is wrapped so a
  missing binary, a driver error, or a parse failure degrades to
  RAM-only scoring (`has_gpu: false`, `gpu_vram_gb: 0`, a `cpu_*`
  backend). The returned map always has the keys `Glorbo.Fit.Scorer`
  needs.

  The probe runs ON THE HOST, never inside an agent sandbox — it reads
  host hardware, which is the correct trust placement (GEP-59 open
  question, resolved: host-side, same as `detect-providers`).

  ## Injectable seams (tests)

    * `:meminfo_read_fun` — `(-> {:ok, binary} | {:error, term})`,
      default reads `/proc/meminfo`.
    * `:cmd_fun` — `(binary, [binary], keyword -> {binary, integer})`,
      default `System.cmd/3` bounded by a per-call timeout.
    * `:os_type_fun` — `(-> {atom, atom})`, default `:os.type/0`.
    * `:host` — remote host string; when set, every probe command is
      run over `ssh <host>` (GEP-59 `--host`).
  """

  @type system :: %{
          has_gpu: boolean(),
          gpu_name: String.t() | nil,
          gpu_vram_gb: number(),
          gpu_count: non_neg_integer(),
          total_ram_gb: number(),
          available_ram_gb: number(),
          backend: String.t(),
          probe_errors: [term()]
        }

  @cmd_timeout_ms 8_000

  @doc """
  Probe the host and return a `system()` map ready for
  `Glorbo.Fit.Scorer`. Never raises; failures land in `:probe_errors`
  and degrade the result (RAM-only when the GPU probe fails).

  Options: see the moduledoc "Injectable seams" list.
  """
  @spec run(keyword()) :: system()
  def run(opts \\ []) do
    {total_ram, avail_ram, mem_errs} = probe_memory(opts)
    {gpu, gpu_errs} = probe_gpu(opts)

    base = %{
      total_ram_gb: round1(total_ram),
      available_ram_gb: round1(avail_ram),
      probe_errors: mem_errs ++ gpu_errs
    }

    case gpu do
      nil ->
        Map.merge(base, %{
          has_gpu: false,
          gpu_name: nil,
          gpu_vram_gb: 0,
          gpu_count: 0,
          backend: cpu_backend(opts)
        })

      %{} = g ->
        Map.merge(base, %{
          has_gpu: true,
          gpu_name: g.gpu_name,
          gpu_vram_gb: round1(g.gpu_vram_gb),
          gpu_count: g.gpu_count,
          backend: g.backend
        })
    end
  end

  # ------------------------------------------------------------------
  # Memory
  # ------------------------------------------------------------------

  defp probe_memory(opts) do
    read_fun = Keyword.get(opts, :meminfo_read_fun, default_meminfo_read(opts))

    case safe(fn -> read_fun.() end) do
      {:ok, {:ok, text}} when is_binary(text) ->
        parse_meminfo(text)

      {:ok, {:error, reason}} ->
        macos_or_zero(opts, [{:meminfo_read, reason}])

      {:error, reason} ->
        macos_or_zero(opts, [{:meminfo_read_crashed, reason}])

      _ ->
        macos_or_zero(opts, [{:meminfo_read, :bad_return}])
    end
  end

  defp parse_meminfo(text) do
    kv =
      text
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, &parse_meminfo_line/2)

    total_kb = Map.get(kv, "MemTotal", 0)
    avail_kb = Map.get(kv, "MemAvailable")

    total_gb = total_kb / 1_048_576.0

    avail_gb =
      case avail_kb do
        nil -> total_gb * 0.7
        kb -> kb / 1_048_576.0
      end

    errs = if total_kb > 0, do: [], else: [{:meminfo_parse, :no_memtotal}]
    {total_gb, avail_gb, errs}
  end

  # Fold one "Key:   <N> kB" meminfo line into the accumulator. Lines we
  # can't parse (no colon, no leading integer) are skipped silently.
  defp parse_meminfo_line(line, acc) do
    with [key, val] <- String.split(line, ":", parts: 2),
         [kb | _] <- val |> String.trim() |> String.split(),
         {n, _} <- Integer.parse(kb) do
      Map.put(acc, String.trim(key), n)
    else
      _ -> acc
    end
  end

  # No /proc/meminfo (macOS / remote Mac) — try sysctl hw.memsize.
  defp macos_or_zero(opts, errs) do
    case run_cmd(opts, "sysctl", ["-n", "hw.memsize"]) do
      {:ok, out} ->
        case Integer.parse(String.trim(out)) do
          {bytes, _} when bytes > 0 ->
            gb = bytes / :math.pow(1024, 3)
            {gb, gb * 0.7, errs}

          _ ->
            {0.0, 0.0, errs ++ [{:sysctl_memsize, :parse}]}
        end

      {:error, reason} ->
        {0.0, 0.0, errs ++ [{:sysctl_memsize, reason}]}
    end
  end

  # ------------------------------------------------------------------
  # GPU
  # ------------------------------------------------------------------

  defp probe_gpu(opts) do
    cond do
      result = probe_nvidia(opts) -> {result, []}
      result = probe_rocm(opts) -> {result, []}
      result = probe_apple(opts) -> {result, []}
      true -> {nil, [:no_gpu_detected]}
    end
  end

  defp probe_nvidia(opts) do
    args = ["--query-gpu=memory.total,name", "--format=csv,noheader,nounits"]

    with {:ok, out} <- run_cmd(opts, "nvidia-smi", args),
         false <- nvidia_driver_error?(out),
         [_ | _] = gpus <- parse_nvidia(out) do
      total = gpus |> Enum.map(& &1.vram_gb) |> Enum.sum()

      %{
        gpu_name: hd(gpus).name,
        gpu_vram_gb: total,
        gpu_count: length(gpus),
        backend: "cuda"
      }
    else
      _ -> nil
    end
  end

  defp nvidia_driver_error?(out) do
    low = String.downcase(out)

    Enum.any?(
      [
        "nvml",
        "driver/library version mismatch",
        "couldn't communicate",
        "no devices were found",
        "failed to initialize"
      ],
      &String.contains?(low, &1)
    )
  end

  defp parse_nvidia(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ",", parts: 2) do
        [vram, name] ->
          case Float.parse(String.trim(vram)) do
            {mb, _} -> [%{vram_gb: mb / 1024.0, name: String.trim(name)}]
            :error -> []
          end

        _ ->
          []
      end
    end)
  end

  # rocm-smi --showmeminfo vram --csv → "card,VRAM Total Memory (B),...".
  # We sum the byte totals across cards and read the name via
  # --showproductname (best-effort).
  defp probe_rocm(opts) do
    with {:ok, mem_out} <- run_cmd(opts, "rocm-smi", ["--showmeminfo", "vram", "--csv"]),
         [_ | _] = bytes_list <- parse_rocm_vram(mem_out) do
      total_gb = Enum.sum(bytes_list) / :math.pow(1024, 3)
      name = rocm_name(opts)

      %{
        gpu_name: name,
        gpu_vram_gb: total_gb,
        gpu_count: length(bytes_list),
        backend: "rocm"
      }
    else
      _ -> nil
    end
  end

  defp parse_rocm_vram(out) do
    out
    |> String.split("\n", trim: true)
    # Drop the CSV header row.
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      line
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.find_value([], fn cell ->
        case Integer.parse(cell) do
          # VRAM totals are large byte counts; ignore small index/temp cells.
          {n, ""} when n > 1_000_000 -> [n]
          _ -> nil
        end
      end)
    end)
  end

  defp rocm_name(opts) do
    case run_cmd(opts, "rocm-smi", ["--showproductname", "--csv"]) do
      {:ok, out} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.drop(1)
        |> List.first()
        |> case do
          nil -> "AMD GPU"
          line -> line |> String.split(",") |> List.last() |> to_string() |> String.trim()
        end
        |> blank_to("AMD GPU")

      {:error, _} ->
        "AMD GPU"
    end
  end

  # Apple Silicon: only on Darwin. Unified memory — report a fraction of
  # total RAM as the usable Metal budget (matching macOS working-set
  # defaults). Ported from odysseus _detect_apple_silicon.
  defp probe_apple(opts) do
    os_type = Keyword.get(opts, :os_type_fun, &:os.type/0).()

    if darwin?(os_type, opts) do
      with {:ok, memsize} <- run_cmd(opts, "sysctl", ["-n", "hw.memsize"]),
           {bytes, _} <- Integer.parse(String.trim(memsize)),
           true <- bytes > 0 do
        total_gb = bytes / :math.pow(1024, 3)
        brand = apple_brand(opts)
        frac = apple_frac(total_gb)

        %{
          gpu_name: brand,
          gpu_vram_gb: total_gb * frac,
          gpu_count: 1,
          backend: "metal"
        }
      else
        _ -> nil
      end
    else
      nil
    end
  end

  defp darwin?({:unix, :darwin}, _opts), do: true

  # Over SSH the host OS is unknown locally; probe `uname -s` on remote.
  defp darwin?(_os_type, opts) do
    if Keyword.get(opts, :host) do
      case run_cmd(opts, "uname", ["-s"]) do
        {:ok, out} -> String.downcase(String.trim(out)) == "darwin"
        _ -> false
      end
    else
      false
    end
  end

  defp apple_brand(opts) do
    case run_cmd(opts, "sysctl", ["-n", "machdep.cpu.brand_string"]) do
      {:ok, out} -> out |> String.trim() |> blank_to("Apple Silicon")
      _ -> "Apple Silicon"
    end
  end

  defp apple_frac(total_gb) when total_gb <= 16, do: 0.67
  defp apple_frac(total_gb) when total_gb <= 64, do: 0.75
  defp apple_frac(_total_gb), do: 0.80

  # ------------------------------------------------------------------
  # Command + IO seams
  # ------------------------------------------------------------------

  # Default meminfo reader: local file, or `cat /proc/meminfo` over SSH.
  defp default_meminfo_read(opts) do
    case Keyword.get(opts, :host) do
      nil ->
        fn -> File.read("/proc/meminfo") end

      host ->
        fn ->
          case run_ssh(opts, host, "cat", ["/proc/meminfo"]) do
            {:ok, out} -> {:ok, out}
            err -> err
          end
        end
    end
  end

  # Run a probe command, locally or over SSH, bounded by a wall-clock
  # timeout. Returns `{:ok, trimmed_stdout}` on exit 0, else `{:error, _}`.
  # NEVER raises — a missing binary, ssh failure, or kill all become
  # `{:error, reason}` so the caller degrades cleanly.
  defp run_cmd(opts, cmd, args) do
    case Keyword.get(opts, :host) do
      nil -> run_local(opts, cmd, args)
      host -> run_ssh(opts, host, cmd, args)
    end
  end

  defp run_local(opts, cmd, args) do
    cmd_fun = Keyword.get(opts, :cmd_fun, &default_cmd/3)
    timeout = Keyword.get(opts, :cmd_timeout_ms, @cmd_timeout_ms)

    task =
      Task.async(fn ->
        safe(fn -> cmd_fun.(cmd, args, stderr_to_stdout: true) end)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {out, 0}}} when is_binary(out) -> {:ok, String.trim(out)}
      {:ok, {:ok, {_out, code}}} -> {:error, {:non_zero_exit, code}}
      {:ok, {:error, reason}} -> {:error, {:cmd_crashed, reason}}
      nil -> {:error, {:timeout, timeout}}
      _ -> {:error, :cmd_bad_return}
    end
  end

  defp run_ssh(opts, host, cmd, args) do
    ssh_args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, cmd | args]
    run_local(opts, "ssh", ssh_args)
  end

  defp default_cmd(cmd, args, cmd_opts) do
    System.cmd(cmd, args, cmd_opts)
  end

  defp cpu_backend(opts) do
    os_type = Keyword.get(opts, :os_type_fun, &:os.type/0).()
    arch_arm? = arch_arm?(os_type, opts)
    if arch_arm?, do: "cpu_arm", else: "cpu_x86"
  end

  defp arch_arm?(_os_type, opts) do
    case run_cmd(opts, "uname", ["-m"]) do
      {:ok, out} ->
        low = String.downcase(out)
        String.contains?(low, "aarch64") or String.contains?(low, "arm")

      _ ->
        false
    end
  end

  # ------------------------------------------------------------------
  # Tiny helpers
  # ------------------------------------------------------------------

  # Wrap an external call so exceptions and exits become `{:error, _}`.
  defp safe(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp blank_to("", default), do: default
  defp blank_to(nil, default), do: default
  defp blank_to(s, _default), do: s

  defp round1(n) when is_number(n), do: Float.round(n * 1.0, 1)
  defp round1(_), do: 0.0
end
