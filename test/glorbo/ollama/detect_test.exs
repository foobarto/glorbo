defmodule Glorbo.Ollama.DetectTest do
  use ExUnit.Case, async: true

  alias Glorbo.Ollama.Detect

  describe "binary_path/installed?" do
    test "reports the path the finder returns" do
      finder = fn "ollama" -> "/usr/local/bin/ollama" end
      assert Detect.binary_path(finder) == "/usr/local/bin/ollama"
      assert Detect.installed?(finder)
    end

    test "not installed when the finder returns nil" do
      finder = fn _ -> nil end
      assert Detect.binary_path(finder) == nil
      refute Detect.installed?(finder)
    end
  end

  describe "version/1" do
    test "parses the dotted version from `ollama --version`" do
      runner = fn "/x/ollama", ["--version"], _opts -> {"ollama version is 0.6.2\n", 0} end
      assert {:ok, "0.6.2"} = Detect.version(binary_path: "/x/ollama", runner: runner)
    end

    test ":error when ollama isn't installed" do
      assert :error = Detect.version(finder: fn _ -> nil end)
    end

    test ":error on a non-zero exit" do
      runner = fn _p, _a, _o -> {"command failed", 1} end
      assert :error = Detect.version(binary_path: "/x/ollama", runner: runner)
    end
  end

  describe "daemon_reachable?/1" do
    test "true on an Ollama-shape 200 from /api/tags" do
      req = fn _ -> {:ok, %{status: 200, body: ~s({"models":[]}), headers: %{}}} end
      assert Detect.daemon_reachable?(request_fun: req)
    end

    test "false when the daemon is unreachable" do
      req = fn _ -> {:error, :econnrefused} end
      refute Detect.daemon_reachable?(request_fun: req)
    end

    test "false when something non-Ollama answers on the port" do
      req = fn _ ->
        {:ok, %{status: 200, body: ~s({"data":[]}), headers: %{"server" => "nginx"}}}
      end

      refute Detect.daemon_reachable?(request_fun: req)
    end
  end
end
