defmodule Glorbo.OllamaTest do
  use ExUnit.Case, async: true

  test "status/1 composes install + version + daemon into a snapshot" do
    s =
      Glorbo.Ollama.status(
        finder: fn "ollama" -> "/usr/local/bin/ollama" end,
        runner: fn _p, _a, _o -> {"ollama version is 0.6.2", 0} end,
        request_fun: fn _ -> {:ok, %{status: 200, body: ~s({"models":[]}), headers: %{}}} end
      )

    assert s.installed?
    assert s.version == "0.6.2"
    assert s.binary_path == "/usr/local/bin/ollama"
    assert s.daemon_reachable?
    assert s.endpoint == "http://127.0.0.1:11434"
  end

  test "status/1 when ollama is absent — no version, daemon down" do
    s =
      Glorbo.Ollama.status(
        finder: fn _ -> nil end,
        request_fun: fn _ -> {:error, :econnrefused} end
      )

    refute s.installed?
    assert s.version == nil
    assert s.binary_path == nil
    refute s.daemon_reachable?
  end
end
