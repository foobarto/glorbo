defmodule Glorbo.Fit.ProbeTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Unit tests for the host probe (GEP-59). Every external call is
  injected — these tests never touch the real host hardware. The
  load-bearing case is the degradation contract: a probe FAILURE must
  degrade to RAM-only scoring, never crash.
  """

  alias Glorbo.Fit.Probe

  @meminfo """
  MemTotal:       65792840 kB
  MemFree:        12345678 kB
  MemAvailable:   48000000 kB
  Buffers:          123456 kB
  """

  defp meminfo_ok, do: fn -> {:ok, @meminfo} end

  # Build a cmd_fun that dispatches on the command name.
  defp cmd_router(routes) do
    fn cmd, args, _opts ->
      case Map.get(routes, cmd) do
        nil -> {"", 127}
        fun when is_function(fun, 1) -> fun.(args)
        {out, code} -> {out, code}
      end
    end
  end

  describe "memory probe" do
    test "parses /proc/meminfo total + available" do
      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: cmd_router(%{}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      # 65792840 kB / 1048576 ≈ 62.7 GB; 48000000 kB ≈ 45.8 GB
      assert_in_delta sys.total_ram_gb, 62.7, 0.2
      assert_in_delta sys.available_ram_gb, 45.8, 0.2
    end

    test "falls back to 70% of total when MemAvailable is absent" do
      text = "MemTotal:       16777216 kB\n"

      sys =
        Probe.run(
          meminfo_read_fun: fn -> {:ok, text} end,
          cmd_fun: cmd_router(%{}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      # 16777216 kB = 16 GB; available ≈ 11.2 GB
      assert_in_delta sys.total_ram_gb, 16.0, 0.1
      assert_in_delta sys.available_ram_gb, 11.2, 0.1
    end
  end

  describe "nvidia probe" do
    test "single GPU: VRAM + name + cuda backend" do
      nvidia = fn _args -> {"24564, NVIDIA GeForce RTX 4090\n", 0} end

      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: cmd_router(%{"nvidia-smi" => nvidia}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      assert sys.has_gpu
      assert sys.gpu_name == "NVIDIA GeForce RTX 4090"
      assert_in_delta sys.gpu_vram_gb, 24.0, 0.1
      assert sys.gpu_count == 1
      assert sys.backend == "cuda"
    end

    test "multi-GPU: sums VRAM, counts cards" do
      nvidia = fn _ -> {"24564, RTX 4090\n24564, RTX 4090\n", 0} end

      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: cmd_router(%{"nvidia-smi" => nvidia}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      assert sys.gpu_count == 2
      assert_in_delta sys.gpu_vram_gb, 48.0, 0.2
    end

    test "driver/library mismatch degrades to RAM-only (no crash)" do
      nvidia = fn _ -> {"Failed to initialize NVML: Driver/library version mismatch\n", 0} end

      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: cmd_router(%{"nvidia-smi" => nvidia}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      refute sys.has_gpu
      assert sys.gpu_vram_gb == 0
      assert sys.backend in ["cpu_x86", "cpu_arm"]
    end
  end

  describe "rocm probe" do
    test "AMD VRAM via --showmeminfo, name via --showproductname" do
      rocm = fn
        ["--showmeminfo", "vram", "--csv"] ->
          {"card,VRAM Total Memory (B),VRAM Total Used Memory (B)\ncard0,17163091968,1000\n", 0}

        ["--showproductname", "--csv"] ->
          {"card,Card series\ncard0,Radeon RX 7900 XTX\n", 0}
      end

      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          # nvidia-smi missing (127) so probe falls through to rocm-smi
          cmd_fun: cmd_router(%{"rocm-smi" => rocm}),
          os_type_fun: fn -> {:unix, :linux} end
        )

      assert sys.has_gpu
      assert sys.backend == "rocm"
      assert sys.gpu_name =~ "7900 XTX"
      # 17163091968 B / 1024^3 ≈ 15.98 GB
      assert_in_delta sys.gpu_vram_gb, 16.0, 0.1
    end
  end

  describe "apple silicon probe" do
    test "Darwin: unified-memory budget + metal backend" do
      # 64 GB box -> 0.75 frac -> 48 GB Metal budget.
      sysctl = fn
        ["-n", "hw.memsize"] -> {"68719476736\n", 0}
        ["-n", "machdep.cpu.brand_string"] -> {"Apple M4 Max\n", 0}
      end

      sys =
        Probe.run(
          # macOS has no /proc/meminfo — meminfo read fails, sysctl gives RAM.
          meminfo_read_fun: fn -> {:error, :enoent} end,
          cmd_fun: cmd_router(%{"sysctl" => sysctl}),
          os_type_fun: fn -> {:unix, :darwin} end
        )

      assert sys.has_gpu
      assert sys.backend == "metal"
      assert sys.gpu_name == "Apple M4 Max"
      # 64 GB * 0.75 = 48 GB
      assert_in_delta sys.gpu_vram_gb, 48.0, 0.5
      assert_in_delta sys.total_ram_gb, 64.0, 0.5
    end
  end

  describe "degradation contract — probe failure never crashes" do
    test "every command missing (exit 127) -> RAM-only, errors captured" do
      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: fn _cmd, _args, _opts -> {"", 127} end,
          os_type_fun: fn -> {:unix, :linux} end
        )

      refute sys.has_gpu
      assert sys.gpu_vram_gb == 0
      assert sys.total_ram_gb > 0
      assert :no_gpu_detected in sys.probe_errors
    end

    test "cmd_fun raising is caught and degraded (no crash)" do
      sys =
        Probe.run(
          meminfo_read_fun: meminfo_ok(),
          cmd_fun: fn _cmd, _args, _opts -> raise "boom" end,
          os_type_fun: fn -> {:unix, :linux} end
        )

      refute sys.has_gpu
      assert sys.total_ram_gb > 0
    end

    test "meminfo read failure + no GPU -> well-shaped zero result, no crash" do
      sys =
        Probe.run(
          meminfo_read_fun: fn -> {:error, :enoent} end,
          cmd_fun: fn _cmd, _args, _opts -> {"", 127} end,
          os_type_fun: fn -> {:unix, :linux} end
        )

      assert sys.total_ram_gb == 0.0
      refute sys.has_gpu
      assert is_list(sys.probe_errors)
    end

    test "result always has the keys the Scorer needs" do
      sys = Probe.run(meminfo_read_fun: meminfo_ok(), cmd_fun: fn _, _, _ -> {"", 127} end)

      for key <- [:has_gpu, :gpu_name, :gpu_vram_gb, :available_ram_gb, :backend] do
        assert Map.has_key?(sys, key), "missing #{key}"
      end
    end
  end

  describe "--host remote probe" do
    test "routes commands through ssh and reads remote /proc/meminfo via cat" do
      # cmd_fun sees ssh as the binary; assert the host + inner command rode along.
      cmd_fun = fn "ssh", args, _opts ->
        cond do
          "cat" in args and "/proc/meminfo" in args -> {@meminfo, 0}
          "nvidia-smi" in args -> {"24564, RTX 4090\n", 0}
          true -> {"", 127}
        end
      end

      sys =
        Probe.run(
          host: "user@remote",
          cmd_fun: cmd_fun,
          os_type_fun: fn -> {:unix, :linux} end
        )

      assert sys.has_gpu
      assert sys.gpu_name == "RTX 4090"
      assert sys.total_ram_gb > 0
    end
  end
end
