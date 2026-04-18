defmodule Glorbo.CLI.Registry.DetectionTest do
  use ExUnit.Case, async: true

  alias Glorbo.CLI.Registry.Detection
  alias Glorbo.CLI.Registry.Provider

  defp provider(opts) do
    struct!(
      %Provider{
        name: "test",
        binary: "test-cli",
        args: [],
        reply_dir: "x",
        reply_filename_template: "y",
        source: :builtin,
        source_file: "<test>"
      },
      opts
    )
  end

  describe "detect_all/2 — PATH resolution" do
    test "marks installed? true when binary is on PATH" do
      p = provider(binary: "echo")

      [result] =
        Detection.detect_all([p], find_executable_fun: fn "echo" -> "/usr/bin/echo" end)

      assert result.installed? == true
      assert result.resolved_path == "/usr/bin/echo"
    end

    test "marks installed? false when binary is missing" do
      p = provider(binary: "nonesuch")

      [result] =
        Detection.detect_all([p], find_executable_fun: fn _ -> nil end)

      assert result.installed? == false
      assert result.resolved_path == nil
    end

    test "handles absolute-path binary via stat" do
      p = provider(binary: "/opt/tools/pi")

      [result] =
        Detection.detect_all([p],
          file_stat_fun: fn "/opt/tools/pi" -> {:ok, %{}} end
        )

      assert result.installed? == true
      assert result.resolved_path == "/opt/tools/pi"
    end

    test "absolute-path binary missing file" do
      p = provider(binary: "/opt/tools/missing")

      [result] =
        Detection.detect_all([p],
          file_stat_fun: fn _ -> {:error, :enoent} end
        )

      assert result.installed? == false
    end

    test "falls back to fallback_paths when PATH misses" do
      home = Path.expand("~")
      fallback = Path.join([home, ".opencode/bin/opencode"])

      p = provider(binary: "opencode", fallback_paths: ["~/.opencode/bin/opencode"])

      [result] =
        Detection.detect_all([p],
          find_executable_fun: fn _ -> nil end,
          file_stat_fun: fn
            ^fallback -> {:ok, %{}}
            _ -> {:error, :enoent}
          end
        )

      assert result.installed? == true
      assert result.resolved_path == fallback
    end

    test "walks fallback_paths in order; first hit wins" do
      p =
        provider(
          binary: "unfound",
          fallback_paths: ["/a/missing", "/b/found", "/c/also-found"]
        )

      [result] =
        Detection.detect_all([p],
          find_executable_fun: fn _ -> nil end,
          file_stat_fun: fn
            "/a/missing" -> {:error, :enoent}
            "/b/found" -> {:ok, %{}}
            "/c/also-found" -> {:ok, %{}}
          end
        )

      assert result.resolved_path == "/b/found"
    end

    test "fallback_paths ignored when PATH resolves" do
      p = provider(binary: "echo", fallback_paths: ["/never/looked/at"])

      [result] =
        Detection.detect_all([p],
          find_executable_fun: fn "echo" -> "/usr/bin/echo" end,
          file_stat_fun: fn _ -> flunk("stat_fun must not be called when PATH hits") end
        )

      assert result.resolved_path == "/usr/bin/echo"
    end

    test "installed? false when neither PATH nor any fallback resolves" do
      p = provider(binary: "gone", fallback_paths: ["/x", "/y"])

      [result] =
        Detection.detect_all([p],
          find_executable_fun: fn _ -> nil end,
          file_stat_fun: fn _ -> {:error, :enoent} end
        )

      assert result.installed? == false
      assert result.resolved_path == nil
    end

    test "absolute binary with fallback — fallback wins when primary missing" do
      p = provider(binary: "/opt/primary/cli", fallback_paths: ["/opt/fallback/cli"])

      [result] =
        Detection.detect_all([p],
          file_stat_fun: fn
            "/opt/primary/cli" -> {:error, :enoent}
            "/opt/fallback/cli" -> {:ok, %{}}
          end
        )

      assert result.installed? == true
      assert result.resolved_path == "/opt/fallback/cli"
    end
  end

  describe "probe_versions/2 — version probing" do
    test "runs probes only for allow_version_probe: true" do
      opted_in =
        provider(
          name: "opted-in",
          installed?: true,
          resolved_path: "/bin/opted-in",
          version_flag: "--version",
          allow_version_probe: true
        )

      opted_out =
        provider(
          name: "opted-out",
          installed?: true,
          resolved_path: "/bin/opted-out",
          version_flag: "--version",
          allow_version_probe: false
        )

      calls = :ets.new(:calls, [:public, :set])

      cmd_fun = fn path, _args, _opts ->
        :ets.insert(calls, {path, true})
        {"1.2.3\n", 0}
      end

      result = Detection.probe_versions([opted_in, opted_out], system_cmd_fun: cmd_fun)

      # Order is not guaranteed (async_stream + split_with); look up by name.
      found = Map.new(result, &{&1.name, &1})
      assert found["opted-in"].version == "1.2.3"
      assert found["opted-out"].version == nil
      assert :ets.member(calls, "/bin/opted-in")
      refute :ets.member(calls, "/bin/opted-out")
    end

    test "skips non-installed providers" do
      p =
        provider(
          name: "missing",
          installed?: false,
          version_flag: "--version",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> flunk("should not invoke") end

      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == nil
      assert result.installed? == false
    end

    test "skips providers with empty version_flag" do
      p =
        provider(
          name: "no-flag",
          installed?: true,
          resolved_path: "/bin/no-flag",
          version_flag: "",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> flunk("should not invoke") end

      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == nil
    end

    test "applies version_regex to capture" do
      p =
        provider(
          name: "regex",
          installed?: true,
          resolved_path: "/bin/regex",
          version_flag: "--version",
          version_regex: "(\\d+\\.\\d+\\.\\d+)",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> {"myapp v1.2.3 (build abc)\n", 0} end
      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == "1.2.3"
      assert result.probe_error == nil
    end

    test "records :regex_miss when pattern does not match" do
      p =
        provider(
          name: "miss",
          installed?: true,
          resolved_path: "/bin/miss",
          version_flag: "--version",
          version_regex: "(\\d+\\.\\d+\\.\\d+)",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> {"build info only\n", 0} end
      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == nil
      assert result.probe_error == :regex_miss
    end

    test "records non-zero exit as probe_error" do
      p =
        provider(
          name: "crashy",
          installed?: true,
          resolved_path: "/bin/crashy",
          version_flag: "--version",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> {"segfault\n", 139} end
      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == nil
      assert result.probe_error == {:non_zero_exit, 139}
    end

    test "records timeout when probe exceeds timeout_ms" do
      p =
        provider(
          name: "slow",
          installed?: true,
          resolved_path: "/bin/slow",
          version_flag: "--version",
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ ->
        Process.sleep(200)
        {"never", 0}
      end

      [result] =
        Detection.probe_versions([p],
          system_cmd_fun: cmd_fun,
          timeout_ms: 50
        )

      assert result.version == nil
      assert result.probe_error == {:timeout, 50}
    end

    test "uses raw trimmed output when version_regex is nil" do
      p =
        provider(
          name: "no-regex",
          installed?: true,
          resolved_path: "/bin/no-regex",
          version_flag: "--version",
          version_regex: nil,
          allow_version_probe: true
        )

      cmd_fun = fn _, _, _ -> {"  4.2.0  \n", 0} end
      [result] = Detection.probe_versions([p], system_cmd_fun: cmd_fun)
      assert result.version == "4.2.0"
    end
  end
end
